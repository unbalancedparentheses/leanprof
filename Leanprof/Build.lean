import Lean.Data.Json
import Leanprof.Experiment

/-!
# `leanprof build`: what a whole-project `lake build` spends its time on

`leanprof elab --project` sums per-declaration costs from a traced
re-elaboration; its wall time is not a build's. This command measures a real
`lake build`: every process Lake runs, when it started and ended, its peak
memory, what it depended on, and how busy the build's workers were.

**How the processes are seen.** Lake runs the toolchain's own programs:
`<sysroot>/bin/lean` for each module, `leanir` (4.33 and later, for modules
that postpone code generation), `clang` (or `LEAN_CC`) for each C file and
each link, `llvm-ar` (or `LEAN_AR`) for static libraries. With
`LAKE_OVERRIDE_LEAN=true` and `LEAN_SYSROOT` set, Lake takes the toolchain
from `LEAN_SYSROOT` (Lake 4.27 to 4.35, `Lake/Config/InstallPath.lean`).
`leanprof build` points it at a directory of links to the real toolchain
whose `bin/` holds one small script per program: it calls
`leanprof-build-shim` (Leanprof/BuildShim.lean), which runs the real program
and writes a record of it. Lake's traces do not depend on the toolchain's
path, so the build reuses and leaves an ordinary build (checked on 4.27 and
4.35: a shimmed build after a plain one rebuilds nothing, and back). The
alternatives were worse: Lake's `-v` output has each job's duration but no
start, so neither the schedule nor the concurrency; `LEAN` alone is ignored
when Lake and Lean are installed together (the usual case); sampling the
process table misses short processes and costs CPU.

**Rebuilt or not.** `lake build -v` prints every job with what it did
(`Built`, `Replayed`, `Fetched`, `Unpacked`, or `Ran` for nothing to do);
those verbs give each module's state.

**Dependencies.** Lake writes each module's setup (`--setup FILE`, Lean 4.22
and later): its name, package and every module it imports, transitively. A
module's job depends on the jobs of the rebuilt modules among those; a C
compile on its module's job; a link or archive on the jobs that wrote its
inputs (response files are read).

**From the jobs:** the critical path as it happened (from the job that ended
last, back through the dependency that finished last), each job's slack
(critical-path method with unlimited workers), the number of busy workers
over time and where the build ran one job or none. A list scheduler with
the same number of workers replays the measured durations to estimate the
rebuild after touching each module (the module, every module importing it,
its C compile, the links that use it); `--validate` checks that estimate
against real builds in a git worktree, and `--imports` tries removing
imports there, accepting one only after the build (proofs included) passes.
-/

namespace Leanprof.Build
open Lean System
open Leanprof.Explain (trim jstr jarr jnum fmtBytes)
open Leanprof.Fix (capture tailOf shellQuote)

/-! ## Jobs -/

/-- One process Lake ran, from the shim's record. Times are seconds since
`lake build` started. -/
structure Job where
  id : Nat := 0
  /-- `lean` (a module), `leanir`, `cc` (a C file), `link` or `ar`. -/
  kind : String
  /-- The module, or the output's file name. -/
  name : String
  /-- "" for the workspace's root package. -/
  pkg : String := ""
  start : Float
  stop : Float
  exitCode : Nat := 0
  rss : Nat := 0
  user : Float := 0
  sys : Float := 0
  output : String := ""
  source : String := ""
  /-- Link and archive jobs: their arguments (response files expanded). -/
  inputs : Array String := #[]
  /-- Module jobs: the modules imported, transitively, that have a job in the
  same build (`analyze` keeps only those: with Mathlib cached they are a
  few among thousands). -/
  imports : Array String := #[]
  /-- Module jobs: every module imported, transitively (the setup's `importArts`). -/
  allImports : Array String := #[]
  deps : Array Nat := #[]
  lane : Nat := 0
  slack : Float := 0
  deriving Inhabited

def Job.dur (j : Job) : Float := j.stop - j.start

/-- Seconds rounded to milliseconds, for JSON. -/
def r3 (x : Float) : Float := (x * 1000).round / 1000

def fmtS (x : Float) : String :=
  if x.abs < 10 then s!"{Judge.fmt2 x} s"
  else
    let v := (x.abs * 10).round.toUInt64.toNat
    s!"{if x < 0 then "-" else ""}{v / 10}.{v % 10} s"

def pct (part whole : Float) : String :=
  if whole <= 0 then "-" else s!"{((part / whole) * 100).round.toUInt64}%"

def argAfter (args : Array String) (flag : String) : Option String := Id.run do
  for i in [0:args.size] do
    if args[i]! == flag then return args[i+1]?
  return none

def baseName (p : String) : String := ((p.splitOn "/").getLast?).getD p

/-- `X` for a file under `.lake/packages/X/`, "" otherwise (the root package). -/
def packageOf (p : String) : String :=
  let parts := p.splitOn "/.lake/packages/"
  if parts.length < 2 then "" else ((parts.getLast!.splitOn "/").head?).getD ""

/-- The module a generated C file belongs to (`.lake/build/ir/A/B.c` is `A.B`). -/
def moduleOfIr (p : String) : Option String :=
  let parts := p.splitOn "/.lake/build/ir/"
  if parts.length < 2 then none else
    let rel := parts.getLast!
    let rel := if rel.endsWith ".c" then (rel.dropEnd 2).toString else rel
    some (rel.replace "/" ".")

/-- The module an `.olean` belongs to (`.lake/build/lib/lean/A/B.olean` is `A.B`). -/
def moduleOfOlean (p : String) : Option String :=
  let parts := p.splitOn "/lib/lean/"
  if parts.length < 2 || !p.endsWith ".olean" then none else
    some ((parts.getLast!.dropEnd 6).toString.replace "/" ".")

/-- The arguments in a response file: whitespace separated, `"…"` quoted
with `\"` and `\\` escapes (what Lake writes). -/
def rspArgs (text : String) : Array String := Id.run do
  let mut out := #[]
  let mut cur := ""
  let mut inQ := false
  let mut esc := false
  let mut has := false
  for c in text.toList do
    if esc then cur := cur.push c; esc := false
    else if inQ && c == '\\' then esc := true
    else if c == '"' then inQ := !inQ; has := true
    else if !inQ && c.isWhitespace then
      if has then out := out.push cur
      cur := ""; has := false
    else cur := cur.push c; has := true
  if has then out := out.push cur
  return out

def expandArgs (args : Array String) : IO (Array String) := do
  let mut out := #[]
  for a in args do
    if a.startsWith "@" then
      let p : FilePath := (a.drop 1).toString
      if ← p.pathExists then out := out ++ rspArgs (← IO.FS.readFile p) else out := out.push a
    else out := out.push a
  return out

/-- A module's name, package and every module it imports, from Lake's setup file. -/
def readSetup (p : FilePath) : IO (Option (String × String × Array String)) := do
  unless ← p.pathExists do return none
  let some j := (Json.parse (← IO.FS.readFile p)).toOption | return none
  let imports := match j.getObjVal? "importArts" with
    | .ok (.obj kvs) => kvs.toList.toArray.map (·.1)
    | _ => #[]
  return some (jstr j "name", jstr j "package", imports)

def natField (j : Json) (k : String) : Nat := (j.getObjValAs? Nat k).toOption.getD 0

/-- The job a shim record describes; none for a program run that builds
nothing (`lean --githash`, …). -/
def classify (r : Json) (t0 : Nat) : IO (Option Job) := do
  let prog := jstr r "program"
  let args := (jarr r "args").filterMap (·.getStr?.toOption)
  let tool := baseName prog
  let sec (k : String) : Float := ((natField r k).toFloat - t0.toFloat) / 1e9
  let base : Job := {
    kind := "", name := "", start := sec "start_ns", stop := sec "end_ns",
    exitCode := natField r "exit_code", rss := natField r "max_rss_bytes",
    user := (natField r "user_us").toFloat / 1e6, sys := (natField r "sys_us").toFloat / 1e6 }
  if tool == "lean" || tool == "lean.exe" then
    unless args.contains "--setup" || args.contains "-o" do return none
    let src := (args.find? (·.endsWith ".lean")).getD ""
    let out := (argAfter args "-o").getD ""
    let setup ← match argAfter args "--setup" with
      | some s => readSetup ⟨s⟩
      | none => pure none
    let (name, pkg, imports) := setup.getD ((moduleOfOlean out).getD (baseName src), packageOf src, #[])
    return some { base with
      kind := "lean", name, pkg := if pkg == "" then packageOf src else pkg,
      output := out, source := src, imports, allImports := imports }
  if tool == "leanir" || tool == "leanir.exe" then
    let setupFile : String := args[0]?.getD ""
    let some (name, pkg, _) ← readSetup ⟨setupFile⟩ | return none
    return some { base with
      kind := "leanir", name, pkg, output := (args[2]?).getD "" }
  if tool == "ar" || tool.endsWith "-ar" || tool == "llvm-ar" then
    let all ← expandArgs args
    let some out := all.find? (·.endsWith ".a") | return none
    return some { base with
      kind := "ar", name := baseName out, pkg := packageOf out, output := out,
      inputs := all.filter (· != out) }
  -- a C compiler: a compile (`-c`) or a link
  let some out := argAfter args "-o" | return none
  if args.contains "-c" then
    let src := (args.find? fun a => a.endsWith ".c" || a.endsWith ".cpp" || a.endsWith ".cc").getD ""
    return some { base with
      kind := "cc", name := (moduleOfIr src).getD (baseName src), pkg := packageOf out,
      output := out, source := src }
  let all ← expandArgs args
  return some { base with
    kind := "link", name := baseName out, pkg := packageOf out, output := out,
    inputs := all.filter (· != out) }

/-! ## Lake's output -/

def verbs : List String :=
  ["Built", "Replayed", "Ran", "Fetched", "Unpacked", "Building", "Replaying", "Running", "Fetching", "Unpacking"]

/-- `✔ [2/13] Built P.A (433ms)` → ("Built", "P.A"). -/
def parseLakeLine (l : String) : Option (String × String) := do
  let parts := l.splitOn "] "
  guard (parts.length ≥ 2)
  let head := parts.head!
  guard ((head.splitOn "[").length ≥ 2 && ((head.splitOn "[").getLast!.splitOn "/").length == 2)
  let rest := "] ".intercalate parts.tail!
  let ws := rest.splitOn " "
  let verb := ws.head!
  guard (verbs.contains verb)
  let name := " ".intercalate ws.tail!
  -- a trailing time: "(433ms)", "(1.2s)", "(1m 3s)"
  let cut := name.splitOn " ("
  let lastPart := cut.getLast!
  let isTime := cut.length ≥ 2 && lastPart.endsWith ")" &&
    (lastPart.dropEnd 1).toString.all fun c => c.isDigit || c == '.' || c == 'm' || c == 's' || c == 'h' || c == ' '
  let name := if isTime then " (".intercalate cut.dropLast else name
  return (verb, name)

/-- A job name that is a module (`Foo.Bar`, not `Foo.Bar:c.o` or `pkg/lib:default`). -/
def isModuleJob (n : String) : Bool := !n.isEmpty && !n.contains ':' && !n.contains ' ' && !n.contains '/'

/-- What a verb says about a module: built, cache (fetched or unpacked) or up to date. -/
def stateOf (verb : String) : String :=
  if verb == "Built" then "built"
  else if verb == "Fetched" || verb == "Unpacked" then "cache"
  else if verb.endsWith "ing" then "failed"
  else "up-to-date"

/-! ## Running a shimmed `lake build` -/

/-- How the command line hands over signal handling (`c/cli.c`): the child
to pass INT, TERM and HUP to, and a check that throws once one was caught. -/
structure Hooks where
  guard : UInt32 → IO Unit := fun _ => pure ()
  interrupted : IO Unit := pure ()

instance : Inhabited Hooks := ⟨{}⟩

initialize hooks : IO.Ref Hooks ← IO.mkRef {}

/-- One shimmed `lake build -v`. -/
structure Run where
  exitCode : UInt32
  /-- Seconds from starting `lake` to its exit. -/
  elapsed : Float
  lines : Array String
  jobs : Array Job
  /-- Module job name → Lake's verb. -/
  states : Std.HashMap String String

def Run.sorries (r : Run) : Nat :=
  (r.lines.filter fun l => (l.splitOn "declaration uses 'sorry'").length > 1).size

def Run.built (r : Run) : Array String := (r.jobs.filter (·.kind == "lean")).map (·.name)

/-- The project's toolchain directory, as `lean --print-prefix` there says. -/
def realSysroot (proj : FilePath) : IO FilePath := do
  let out ← capture "lean" #["--print-prefix"] (cwd := proj)
  if out.exitCode != 0 then throw <| IO.userError s!"`lean --print-prefix` failed in {proj}: {trim out.stderr}"
  return trim out.stdout

def leanVersion (proj : FilePath) : IO String := do
  let out ← capture "lean" #["--short-version"] (cwd := proj)
  return if out.exitCode == 0 then trim out.stdout else "unknown"

/-- The shim's command: `leanprof-build-shim` next to this program, copied
into `dir` (a `--clean` build may remove the original), else this program's
own `__build-shim`. -/
def shimCommand (dir : FilePath) : IO (Array String) := do
  let app ← IO.appPath
  let exe := (app.parent.getD ".") / ("leanprof-build-shim" ++ (if System.Platform.isWindows then ".exe" else ""))
  if ← exe.pathExists then
    let dst := dir / "leanprof-build-shim"
    let out ← capture "cp" #["-p", exe.toString, dst.toString]
    if out.exitCode == 0 then return #[dst.toString]
  return #[app.toString, "__build-shim"]

def script (shim : Array String) (real logDir : String) : String :=
  "#!/bin/sh\nexec " ++ " ".intercalate ((shim ++ #[real, logDir]).toList.map shellQuote) ++ " \"$@\"\n"

/-- A toolchain directory of links to `real`, whose `bin/` programs are
scripts running the shim. Returns the environment for Lake. -/
def makeSysroot (real fake logDir : FilePath) (shim : Array String) : IO (Array (String × Option String)) := do
  if ← fake.pathExists then IO.FS.removeDirAll fake   -- does not follow links
  IO.FS.createDirAll (fake / "bin")
  for e in ← real.readDir do
    if e.fileName != "bin" then
      let out ← capture "ln" #["-s", e.path.toString, (fake / e.fileName).toString]
      unless out.exitCode == 0 do throw <| IO.userError s!"cannot link {e.path}: {trim out.stderr}"
  let mut scripts := #[]
  for e in ← (real / "bin").readDir do
    IO.FS.writeFile (fake / "bin" / e.fileName) (script shim e.path.toString logDir.toString)
    scripts := scripts.push (fake / "bin" / e.fileName).toString
  let mut env : Array (String × Option String) :=
    #[("LAKE_OVERRIDE_LEAN", some "true"), ("LEAN_SYSROOT", some fake.toString)]
  -- a compiler or archiver of the user's choice is wrapped too
  for (var, file) in [("LEAN_CC", "leanprof-cc"), ("LEAN_AR", "leanprof-ar")] do
    if let some v ← IO.getEnv var then
      unless v.isEmpty do
        IO.FS.writeFile (fake / "bin" / file) (script shim v logDir.toString)
        scripts := scripts.push (fake / "bin" / file).toString
        env := env.push (var, some (fake / "bin" / file).toString)
  let out ← capture "chmod" (#["+x"] ++ scripts)
  unless out.exitCode == 0 do throw <| IO.userError s!"chmod failed: {trim out.stderr}"
  return env

partial def readLines (h : IO.FS.Handle) (echo : String → Bool) : IO (Array String) := do
  let rec loop (acc : Array String) : IO (Array String) := do
    let l ← h.getLine
    if l.isEmpty then return acc
    let l := if l.endsWith "\n" then (l.dropEnd 1).toString else l
    if echo l then IO.eprintln l
    loop (acc.push l)
  loop #[]

/-- Lake's lines worth showing while it builds: what was built or failed. -/
def echoLine (l : String) : Bool :=
  match parseLakeLine l with
  | some (v, _) => v != "Ran" && v != "Replayed"
  | none => l.startsWith "error" || l.startsWith "Build completed" || l.startsWith "Some required"

/-- `lake build -v TARGETS` in `proj` with every toolchain program recorded.
`work` holds the toolchain directory and the records. -/
def runLake (proj work : FilePath) (targets : Array String) (echo : Bool) : IO Run := do
  (← hooks.get).interrupted
  IO.FS.createDirAll work
  let real ← realSysroot proj
  let logDir := work / "records"
  if ← logDir.pathExists then IO.FS.removeDirAll logDir
  IO.FS.createDirAll logDir
  let shim ← shimCommand work
  let env ← makeSysroot real (work / "sysroot") logDir shim
  let t0 ← IO.monoNanosNow
  let child ← IO.Process.spawn {
    cmd := "lake", args := #["build", "-v"] ++ targets, cwd := proj, env,
    stdin := .null, stdout := .piped, stderr := .piped }
  (← hooks.get).guard child.pid
  let (code, lines) ← try
      let shown := fun l => echo && echoLine l
      let errTask ← IO.asTask (readLines child.stderr shown) Task.Priority.dedicated
      let outLines ← readLines child.stdout shown
      let errLines ← IO.ofExcept errTask.get
      pure (← child.wait, outLines ++ errLines)
    finally (← hooks.get).guard 0
  let t1 ← IO.monoNanosNow
  (← hooks.get).interrupted
  let mut jobs := #[]
  for e in ← logDir.readDir do
    let some r := (Json.parse (← IO.FS.readFile e.path)).toOption | continue
    if let some j ← classify r t0 then jobs := jobs.push j
  jobs := (jobs.qsort fun a b => a.start < b.start || (a.start == b.start && a.name < b.name)).mapIdx
    fun i j => { j with id := i }
  let mut states : Std.HashMap String String := {}
  for l in lines do
    if let some (v, n) := parseLakeLine l then
      if isModuleJob n then states := states.insert n v
  return { exitCode := code, elapsed := (t1 - t0).toFloat / 1e9, lines, jobs, states }

/-! ## Analysis -/

/-- Each job's dependencies among the jobs of the same build. -/
def linkDeps (jobs : Array Job) : Array Job := Id.run do
  let mut lean : Std.HashMap String Nat := {}
  let mut leanir : Std.HashMap String Nat := {}
  let mut byOut : Std.HashMap String Nat := {}
  for j in jobs do
    if j.kind == "lean" then lean := lean.insert j.name j.id
    if j.kind == "leanir" then leanir := leanir.insert j.name j.id
    unless j.output.isEmpty do byOut := byOut.insert j.output j.id
  jobs.map fun j =>
    let ds : Array Nat :=
      if j.kind == "lean" then j.imports.filterMap lean.get?
      else if j.kind == "leanir" then (lean.get? j.name).toArray
      else if j.kind == "cc" then ((leanir.get? j.name) <|> (lean.get? j.name)).toArray
      else j.inputs.filterMap byOut.get?
    -- a dependency ended before the job started (10 ms of slack for clocks)
    let ds := ds.filter fun d => d != j.id && jobs[d]!.stop <= j.start + 0.01
    { j with deps := ds }

/-- Lanes: each job on the lowest lane free when it started. Lake has no
fixed workers; the lanes are a way to draw the schedule, and their number
is the peak number of jobs running at once. -/
def assignLanes (jobs : Array Job) : Array Job := Id.run do
  let mut ends : Array Float := #[]
  let mut out := jobs
  for j in jobs do
    let mut lane := ends.size
    for i in [0:ends.size] do
      if ends[i]! <= j.start then lane := i; break
    if lane == ends.size then ends := ends.push j.stop else ends := ends.set! lane j.stop
    out := out.set! j.id { j with lane }
  return out

/-- The number of jobs running over time: (time, count from then on). -/
def profile (jobs : Array Job) : Array (Float × Nat) := Id.run do
  let evs := (jobs.map (fun j => (j.start, true)) ++ jobs.map (fun j => (j.stop, false))).qsort
    fun a b => a.1 < b.1 || (a.1 == b.1 && !a.2 && b.2)
  let mut out : Array (Float × Nat) := #[(0, 0)]
  let mut n := 0
  for (t, up) in evs do
    n := if up then n + 1 else n - 1
    if out.back!.1 == t then out := out.pop
    out := out.push (t, n)
  return out

/-- Seconds spent with each number of jobs running, up to `elapsed`. -/
def timeAt (prof : Array (Float × Nat)) (elapsed : Float) : Array Float := Id.run do
  let peak := prof.foldl (fun m p => max m p.2) 0
  let mut acc : Array Float := Array.replicate (peak + 1) 0
  for i in [0:prof.size] do
    let (t, n) := prof[i]!
    let next := if i + 1 < prof.size then prof[i+1]!.1 else elapsed
    if next > t then acc := acc.set! n (acc[n]! + (next - t))
  return acc

/-- Stretches of at least `minLen` seconds, between the first job's start and
the last one's end, when at most one job ran. -/
def serialized (prof : Array (Float × Nat)) (first last minLen : Float) : Array (Float × Float) := Id.run do
  let mut out : Array (Float × Float) := #[]
  let mut open_ : Option Float := none
  for i in [0:prof.size] do
    let (t, n) := prof[i]!
    let t := max t first
    if t > last then break
    if n <= 1 then
      if open_.isNone then open_ := some t
    else if let some s := open_ then
      if t - s >= minLen then out := out.push (s, t)
      open_ := none
  if let some s := open_ then
    if last - s >= minLen then out := out.push (s, last)
  return out

/-- The critical path as it happened: from the job that ended last, back
through the dependency that ended last. Each step: (job, seconds between
that dependency's end and this job's start). -/
def observedPath (jobs : Array Job) : Array (Nat × Float) := Id.run do
  if jobs.isEmpty then return #[]
  let mut cur : Nat := jobs.foldl (fun (b : Nat) (j : Job) => if j.stop > jobs[b]!.stop then j.id else b) 0
  let mut out := #[]
  for _ in [0:jobs.size] do
    let j := jobs[cur]!
    if j.deps.isEmpty then
      out := out.push (cur, j.start)
      break
    let d := j.deps.foldl (fun (b d : Nat) => if jobs[d]!.stop > jobs[b]!.stop then d else b) j.deps[0]!
    out := out.push (cur, j.start - jobs[d]!.stop)
    cur := d
  return out.reverse

/-- Slack per job (critical-path method, unlimited workers, no overhead):
how much later it could have ended without delaying the end. Also returns
that lower bound on the build's length. Jobs are in start order, so every
dependency comes before its job. -/
def cpm (jobs : Array Job) : Array Float × Float := Id.run do
  let n := jobs.size
  let mut ef : Array Float := Array.replicate n 0
  for j in jobs do
    let es := j.deps.foldl (fun m d => max m ef[d]!) 0
    ef := ef.set! j.id (es + j.dur)
  let len := ef.foldl max 0
  let mut lf : Array Float := Array.replicate n len
  for k in [0:n] do
    let j := jobs[n - 1 - k]!
    for d in j.deps do
      lf := lf.set! d (min lf[d]! (lf[j.id]! - j.dur))
  return ((List.range n).toArray.map fun i => max 0 (lf[i]! - ef[i]!), len)

/-! ## Scheduling simulation -/

structure SimJob where
  /-- The job's measured wall time. -/
  dur : Float
  /-- Its time alone on the machine: its CPU time when that is less than its
  wall time (it waited for a core), else its wall time (it used several
  threads). -/
  iso : Float := 0
  /-- How many cores it keeps busy alone: CPU time over `iso`, at least 1. -/
  par : Float := 1
  /-- Indices into the same array. -/
  deps : Array Nat
  /-- Ties among ready jobs: the earlier measured start first. -/
  order : Float
  deriving Inhabited

/-- The time from the first job's start to the last job's end when `workers`
jobs can run at once (Lake's thread pool), each starting `latency` seconds
after its last dependency ends (Lake's own work between jobs), ready jobs
first come first served.

With `cores = 0` each job takes its measured wall time: the build replayed
as it ran, contention included. With `cores > 0` each job needs its time
alone (`iso`) and keeps `par` cores busy; when the running jobs want more
cores than there are, all of them slow down by the same factor (processor
sharing). That is the model for a rebuild, where far fewer jobs run than in
a clean build. -/
def simulate (js : Array SimJob) (workers : Nat) (latency : Float) (cores : Nat := 0) : Float := Id.run do
  let n := js.size
  if n == 0 then return 0
  let workers := max workers 1
  let mut dependents : Array (Array Nat) := Array.replicate n #[]
  let mut remaining : Array Nat := Array.replicate n 0
  for i in [0:n] do
    remaining := remaining.set! i js[i]!.deps.size
    for d in js[i]!.deps do dependents := dependents.modify d (·.push i)
  let mut ready : Array (Float × Nat) := #[]
  for i in [0:n] do
    if js[i]!.deps.isEmpty then ready := ready.push (0, i)
  -- running jobs: the work left, in seconds of running alone (or of the replay)
  let mut running : Array (Float × Nat) := #[]
  let mut time : Float := 0
  let mut guard := 0
  while (!ready.isEmpty || !running.isEmpty) && guard < 4 * n + 4 do
    guard := guard + 1
    -- start what can start
    let mut progress := true
    while progress && running.size < workers do
      progress := false
      let mut best : Option Nat := none
      for k in [0:ready.size] do
        let (r, i) := ready[k]!
        if r <= time then
          match best with
          | none => best := some k
          | some b =>
            let (rb, ib) := ready[b]!
            if r < rb || (r == rb && js[i]!.order < js[ib]!.order) then best := some k
      if let some k := best then
        let (_, i) := ready[k]!
        ready := ready.eraseIdx! k
        running := running.push (if cores == 0 then js[i]!.dur else js[i]!.iso, i)
        progress := true
    -- how fast the running jobs progress, then the next event
    let demand := running.foldl (fun s r => s + js[r.2]!.par) 0
    let rate : Float := if cores == 0 || demand <= cores.toFloat then 1 else cores.toFloat / demand
    let nextEnd := running.foldl (fun m r => min m (time + r.1 / rate)) (1e300 : Float)
    let nextReady := if running.size < workers then ready.foldl (fun m r => min m r.1) (1e300 : Float) else 1e300
    let t := min nextEnd nextReady
    if t >= 1e300 then break
    let t := max time t
    let dt := t - time
    time := t
    -- finish what ended (within a nanosecond, for rounding)
    let advanced := running.map fun (w, i) => (w - dt * rate, i)
    let (done, still) := advanced.partition (·.1 <= 1e-9)
    running := still
    for (_, i) in done do
      for d in dependents[i]! do
        remaining := remaining.set! d (remaining[d]! - 1)
        if remaining[d]! == 0 then ready := ready.push (time + latency, d)
  return time

/-- A quantile (0 to 1) of the waits between a job's last dependency ending
and the job starting, over jobs with dependencies. The median is what the
build had, waits for a free worker included; a low quantile is Lake's own
time between jobs when a worker was free. -/
def latencyQuantile (jobs : Array Job) (q : Float) : Float := Id.run do
  let mut gaps : Array Float := #[]
  for j in jobs do
    unless j.deps.isEmpty do
      let last := j.deps.foldl (fun m d => max m jobs[d]!.stop) 0
      gaps := gaps.push (max 0 (j.start - last))
  if gaps.isEmpty then return 0
  let s := gaps.qsort (· < ·)
  return s[min (s.size - 1) (q * s.size.toFloat).toUInt64.toNat]!

/-- The jobs of a subset as a simulation. A job outside the subset is not
rerun, but Lake still waits for its inputs before checking it, so a job of
the subset depends on the subset's jobs it reaches through jobs outside it:
a link waits for every module's C compile, and a compile that is not rerun
still waits for its module's rerun elaboration. -/
def simOf (jobs : Array Job) (ids : Array Nat) : Array SimJob := Id.run do
  let mut pos : Std.HashMap Nat Nat := {}
  for k in [0:ids.size] do pos := pos.insert ids[k]! k
  -- in start order, so a job's dependencies are resolved before it
  let mut eff : Array (Array Nat) := Array.replicate jobs.size #[]
  for j in jobs do
    let mut acc : Array Nat := #[]
    for d in j.deps do
      if let some p := pos.get? d then
        unless acc.contains p do acc := acc.push p
      else
        for p in eff[d]! do
          unless acc.contains p do acc := acc.push p
    eff := eff.set! j.id acc
  return ids.map fun i =>
    let j := jobs[i]!
    let cpu := j.user + j.sys
    -- no CPU time recorded: the wall time, one core
    let iso := if cpu <= 0 then j.dur else min j.dur cpu
    { dur := j.dur, iso, par := if iso > 0 then max 1 (cpu / iso) else 1, deps := eff[i]!, order := j.start }

/-- The modules that import `m`, directly or not, among those with a job. -/
def dependentsOf (jobs : Array Job) (m : String) : Array Nat :=
  (jobs.filter fun j => j.kind == "lean" && j.imports.contains m).map (·.id)

/-- The jobs a change to module `m` reruns: its own job, those of every
module importing it, its C compile (the importers' C usually does not
change, and Lake then skips it), and the archives and links using that
object. -/
def rebuildSet (jobs : Array Job) (m : String) : Array Nat := Id.run do
  let own := jobs.filter fun j => j.name == m && (j.kind == "lean" || j.kind == "leanir" || j.kind == "cc")
  let mut set : Std.HashSet Nat := {}
  for j in own do set := set.insert j.id
  for d in dependentsOf jobs m do set := set.insert d
  -- links and archives that use a rerun output, transitively (jobs are in start order)
  for j in jobs do
    if (j.kind == "link" || j.kind == "ar") && j.deps.any set.contains then set := set.insert j.id
  return (set.toArray.qsort (· < ·))

/-! ## A git worktree for experiments -/

/-- A worktree of the working tree (tracked changes and untracked files)
at `root`, starting from a copy of the project's build, with its
packages linked (`Experiment.ensureWorktree`). Returns the package's
directory inside it. -/
def makeWork (proj root : FilePath) : IO FilePath := do
  let pre ← Leanprof.Fix.git #["rev-parse", "--show-prefix"] (cwd := proj)
  let top ← Leanprof.Fix.git #["rev-parse", "--show-toplevel"] (cwd := proj)
  let tmp := root.parent.getD proj
  IO.FS.createDirAll tmp
  Experiment.removeWorktree root
  let (commit, _) ← Experiment.snapshotWorkingTree tmp top
  Experiment.ensureWorktree root commit proj pre (some proj)
  return Experiment.under root pre

/-- `src` with a definition added at its end: a change to the module's
interface (its `.olean` changes), so Lake rebuilds every module importing
it. In a `module` file the definition is `public`. -/
def touched (src : String) (k : Nat) : String :=
  let isModule := (src.splitOn "\n").any fun l => trim l == "module"
  src ++ (if src.endsWith "\n" then "" else "\n") ++
    s!"\n{if isModule then "public " else ""}def leanprofTouch{k} : Nat := {k}\n"

/-- `src` without the module `imp` in its header's `import` lines, plus
`extra` imported instead (on a line of their own). None if `imp` is not there. -/
def withoutImport (src : String) (imp : String) (extra : Array String := #[]) : Option String := Id.run do
  let lines := (src.splitOn "\n").toArray
  let mut out : Array String := #[]
  let mut found := false
  let mut inHeader := true
  let mut inComment := false
  for l in lines do
    if !inHeader then out := out.push l; continue
    let t := trim l
    if inComment then
      if (t.splitOn "-/").length > 1 then inComment := false
      out := out.push l; continue
    if t.startsWith "/-" then
      unless ((t.drop 2).toString.splitOn "-/").length > 1 do inComment := true
      out := out.push l; continue
    let ws := (t.splitOn " ").filter (· != "")
    let lead := ws.takeWhile fun w => w == "public" || w == "meta" || w == "private"
    let rest := ws.drop lead.length
    match rest with
    | "import" :: mods =>
      let (code, comment) := mods.span fun w => !w.startsWith "--"
      if !found && code.contains imp then
        found := true
        let kept := code.filter (· != imp)
        let kept := if kept == ["all"] then [] else kept
        unless kept.isEmpty do out := out.push (" ".intercalate (lead ++ ["import"] ++ kept ++ comment))
        for e in extra do out := out.push (" ".intercalate (lead ++ ["import", e]))
      else out := out.push l
    | [] => out := out.push l
    | w :: _ =>
      if w.startsWith "--" || w == "module" || w == "prelude" then out := out.push l
      else inHeader := false; out := out.push l
  return if found then some ("\n".intercalate out.toList) else none

/-- The modules a module imports directly, from its header. -/
def directImports (src : String) : Array String := Experiment.parseImports src

/-- The imports a header marks as kept on purpose (`-- shake: keep`, the
comment Mathlib's and Batteries' import tools honour): a module re-exporting
something for its users. -/
def keptImports (src : String) : Array String := Id.run do
  let mut out := #[]
  for l in src.splitOn "\n" do
    if (l.splitOn "shake: keep").length > 1 then
      let code := ((l.splitOn "--").headD "")
      if (code.splitOn "import ").length > 1 then
        out := out ++ Experiment.parseImports code
  return out

/-! ## The report -/

/-- "12.34" as 12.34. -/
def parseDec (w : String) : Option Float :=
  match w.splitOn "." with
  | [i] => i.toNat?.map (·.toFloat)
  | [i, f] => do
    let a ← i.toNat?
    let b ← f.toNat?
    return a.toFloat + b.toFloat / (10 : Float) ^ f.length.toFloat
  | _ => none

/-- The 1-minute load average (`sysctl vm.loadavg` on macOS, `/proc/loadavg`
on Linux); -1 when unknown. -/
def loadNow : IO Float := do
  let words (x : String) := (x.split (fun c => c == ' ' || c == '\n' || c == '{' || c == '}')).toList.map (·.toString)
    |>.filter (· != "")
  let out ← capture "sysctl" #["-n", "vm.loadavg"]
  let txt ← if out.exitCode == 0 then pure out.stdout else try IO.FS.readFile "/proc/loadavg" catch _ => pure ""
  return ((words txt).head? >>= parseDec).getD (-1)

def hardwareThreads : IO Nat := do
  if let some v ← IO.getEnv "LEAN_NUM_THREADS" then
    if let some n := v.toNat? then if n > 0 then return n
  let out ← capture "sysctl" #["-n", "hw.ncpu"]
  if out.exitCode == 0 then if let some n := (trim out.stdout).toNat? then return n
  let out ← capture "nproc" #[]
  return ((trim out.stdout).toNat?).getD 1

def jobJson (j : Job) (critical : Bool) : Json :=
  Json.mkObj [("id", toJson j.id), ("kind", Json.str j.kind), ("name", Json.str j.name),
    ("package", Json.str j.pkg), ("start_s", toJson (r3 j.start)), ("end_s", toJson (r3 j.stop)),
    ("duration_s", toJson (r3 j.dur)), ("lane", toJson j.lane), ("exit_code", toJson j.exitCode),
    ("max_rss_bytes", toJson j.rss), ("user_s", toJson (r3 j.user)), ("sys_s", toJson (r3 j.sys)),
    ("slack_s", toJson (r3 j.slack)), ("critical", Json.bool critical), ("deps", toJson j.deps),
    ("output", Json.str j.output), ("source", Json.str j.source)]

/-- Everything measured and derived from one build, as the report's JSON. -/
structure Analysis where
  jobs : Array Job
  path : Array (Nat × Float)
  cpmLen : Float
  prof : Array (Float × Nat)
  workers : Nat
  /-- The cores of the machine, for the rebuild model. -/
  cores : Nat := 1
  /-- The median wait before a job (the replay of the build). -/
  latency : Float
  /-- A low quantile of the waits: Lake's own time when a worker is free (the rebuild model). -/
  latencyFree : Float := 0
  /-- The build replayed with its measured wall times. -/
  simulated : Float
  /-- The build in the rebuild model (times alone, cores shared). -/
  simulatedShared : Float := 0
  first : Float
  last : Float

def analyze (jobs : Array Job) (workers : Nat) (cores : Nat := workers) : Analysis := Id.run do
  let measured : Std.HashSet String := jobs.foldl (init := {}) fun s j => if j.kind == "lean" then s.insert j.name else s
  let jobs := jobs.map fun j => { j with imports := j.allImports.filter measured.contains }
  let jobs := assignLanes (linkDeps jobs)
  let (slack, cpmLen) := cpm jobs
  let jobs := jobs.map fun j => { j with slack := slack[j.id]! }
  let first := jobs.foldl (fun m j => min m j.start) (if jobs.isEmpty then 0 else jobs[0]!.start)
  let last := jobs.foldl (fun m j => max m j.stop) 0
  let latency := latencyQuantile jobs 0.5
  let latencyFree := latencyQuantile jobs 0.25
  let all := simOf jobs ((List.range jobs.size).toArray)
  let simulated := simulate all workers latency
  let simulatedShared := simulate all workers latencyFree (max cores 1)
  return {
    jobs, path := observedPath jobs, cpmLen, prof := profile jobs, workers, cores := max cores 1, latency,
    latencyFree, simulated, simulatedShared, first, last }

/-- A module's estimated rebuild after touching it: (jobs, task seconds, elapsed
seconds). The jobs' times alone, sharing the machine's cores (a clean build
runs every core with many jobs at once, so its wall times are longer than
the same jobs take in a rebuild), plus a no-op build. -/
def rebuildEstimate (a : Analysis) (noop : Float) (m : String) : Nat × Float × Float :=
  let ids := rebuildSet a.jobs m
  let task := ids.foldl (fun s i => s + a.jobs[i]!.dur) 0
  (ids.size, task, noop + simulate (simOf a.jobs ids) a.workers a.latencyFree a.cores)

/-! ## Rendering (from the report's JSON, so `--from` shows a saved one) -/

def jfloat (j : Json) (k : String) : Float := jnum j k
def jnatv (j : Json) (k : String) : Nat := (jnum j k).toUInt64.toNat
def jobj (j : Json) (k : String) : Json := (j.getObjVal? k).toOption.getD Json.null

def rpad (s : String) (n : Nat) : String := s ++ String.ofList (List.replicate (n - min n s.length) ' ')
def lpad (s : String) (n : Nat) : String := String.ofList (List.replicate (n - min n s.length) ' ') ++ s

/-- The text report. -/
def render (r : Json) (top : Nat) : String := Id.run do
  let jobs := jarr r "jobs"
  let byId (i : Nat) : Json := jobs[i]?.getD Json.null
  let elapsed := jfloat r "elapsed_s"
  let mut out : Array String := #[]
  let mods := jarr r "modules"
  let count (s : String) := (mods.filter (jstr · "state" == s)).size
  out := out.push s!"leanprof build: `{jstr r "command"}` (Lean {jstr r "lean"}), exit code {jnatv r "exit_code"}, {fmtS elapsed}"
  out := out.push s!"  {jobs.size} processes: {(jobs.filter (jstr · "kind" == "lean")).size} modules elaborated, {(jobs.filter (jstr · "kind" == "cc")).size} C compiles, {(jobs.filter fun j => jstr j "kind" == "link" || jstr j "kind" == "ar").size} links/archives"
  out := out.push s!"  modules: {count "built"} built, {count "up-to-date"} up to date, {count "cache"} from a cache{if count "failed" > 0 then s!", {count "failed"} failed" else ""} (Lake's -v)"
  let load := jobj r "load"
  out := out.push s!"  machine: {jnatv r "hardware_threads"} hardware threads, load {Judge.fmt2 (jfloat load "before")} before and {Judge.fmt2 (jfloat load "after")} after"
  if jobs.isEmpty then
    out := out.push "\nNo process ran: everything was up to date. `leanprof build --clean` rebuilds the package."
    return "\n".intercalate out.toList
  -- critical path
  let cp := jobj r "critical_path"
  let steps := jarr cp "steps"
  let work := steps.foldl (fun s st => s + jfloat (byId (jnatv st "job")) "duration_s") 0
  let waits := (steps.extract 1 steps.size).foldl (fun s st => s + jfloat st "wait_s") 0
  out := out.push ""
  out := out.push s!"Critical path: {steps.size} jobs, {fmtS work} of work and {fmtS waits} of waits between them, of {fmtS elapsed}"
  out := out.push s!"  (before the first: {fmtS (jfloat cp "startup_s")} of Lake starting up; after the last: {fmtS (jfloat cp "tail_s")})"
  out := out.push s!"  {lpad "start" 9} {lpad "time" 9} {lpad "wait" 8}  job"
  let shown := if steps.size > 2 * top then (steps.extract 0 top) ++ #[Json.null] ++ steps.extract (steps.size - top) steps.size else steps
  for (st, i) in shown.zipIdx do
    if st.isNull then
      out := out.push s!"  … {steps.size - 2 * top} more"
      continue
    let j := byId (jnatv st "job")
    let w := if i == 0 then "" else fmtS (jfloat st "wait_s")
    out := out.push s!"  {lpad (fmtS (jfloat j "start_s")) 9} {lpad (fmtS (jfloat j "duration_s")) 9} {lpad w 8}  {jstr j "kind"} {jstr j "name"}"
  out := out.push s!"  With unlimited workers and no time between jobs the build would take {fmtS (jfloat cp "unlimited_workers_s")} (the longest chain of dependent jobs)."
  -- parallelism
  let par := jobj r "parallelism"
  out := out.push ""
  out := out.push s!"Parallelism: {Judge.fmt2 (jfloat par "average")} jobs running on average while any ran, at most {jnatv par "peak"} ({jnatv r "workers"} workers assumed)"
  let at_ := jarr par "time_at"
  for x in at_ do
    let s := jfloat x "seconds"
    if s >= 0.05 then
      out := out.push s!"  {lpad (toString (jnatv x "running")) 3} running: {lpad (fmtS s) 9} {lpad (pct s elapsed) 4}"
  let ser := jarr par "serialized"
  unless ser.isEmpty do
    out := out.push s!"  Serialized (at most one job running for {fmtS (jfloat par "serialized_min_s")} or more):"
    for x in ser.extract 0 top do
      let names := (jarr x "running").filterMap (·.getStr?.toOption)
      out := out.push s!"    {fmtS (jfloat x "start_s")} to {fmtS (jfloat x "end_s")} ({fmtS (jfloat x "end_s" - jfloat x "start_s")}): {if names.isEmpty then "no job (Lake itself)" else ", ".intercalate names.toList}"
  -- slowest jobs and memory
  out := out.push ""
  out := out.push "Longest jobs:"
  let byDur := jobs.qsort fun a b => jfloat a "duration_s" > jfloat b "duration_s"
  for j in byDur.extract 0 top do
    out := out.push s!"  {lpad (fmtS (jfloat j "duration_s")) 9}  slack {lpad (fmtS (jfloat j "slack_s")) 8}  {rpad (fmtBytes (jfloat j "max_rss_bytes")) 10} {jstr j "kind"} {jstr j "name"}{if (j.getObjValAs? Bool "critical").toOption.getD false then "  (critical)" else ""}"
  out := out.push ""
  out := out.push "Peak memory (resident, per process):"
  let byMem := jobs.qsort fun a b => jfloat a "max_rss_bytes" > jfloat b "max_rss_bytes"
  for j in byMem.extract 0 (min top 5) do
    out := out.push s!"  {lpad (fmtBytes (jfloat j "max_rss_bytes")) 10}  {jstr j "kind"} {jstr j "name"}"
  -- model
  let model := jobj r "model"
  out := out.push ""
  let span := jfloat model "measured_span_s"
  out := out.push s!"Model: from the first job's start to the last one's end the build took {fmtS span}. Replaying the measured wall times with {jnatv model "workers"} workers and the median wait between dependent jobs ({fmtS (jfloat model "latency_s")}) gives {fmtS (jfloat model "simulated_span_s")} ({pct (jfloat model "simulated_span_s" - span) span} off)."
  unless (model.getObjVal? "simulated_alone_span_s").toOption.isNone do
    out := out.push s!"  With each job's time alone (its CPU time when it waited for a core) sharing {jnatv model "cores"} cores, and {fmtS (jfloat model "latency_free_s")} between jobs (a quarter of the waits were shorter), the rebuild model gives {fmtS (jfloat model "simulated_alone_span_s")}: the difference is time lost to contention, from this build's own jobs and from other load."
  -- rebuild
  let rb := (mods.filter fun m => !(jobj m "rebuild").isNull).qsort fun a b =>
    jfloat (jobj a "rebuild") "estimate_s" > jfloat (jobj b "rebuild") "estimate_s"
  unless rb.isEmpty do
    out := out.push ""
    out := out.push s!"Rebuild after touching a module (estimated: a no-op build, {fmtS (jfloat model "noop_s")}, plus the jobs it reruns in the rebuild model):"
    out := out.push s!"  {lpad "elapsed" 9} {lpad "jobs" 5} {lpad "job time" 9}  module"
    for m in rb.extract 0 top do
      let x := jobj m "rebuild"
      out := out.push s!"  {lpad (fmtS (jfloat x "estimate_s")) 9} {lpad (toString (jnatv x "jobs")) 5} {lpad (fmtS (jfloat x "task_s")) 9}  {jstr m "name"}"
  -- validation
  let v := jobj r "validation"
  unless v.isNull do
    out := out.push ""
    out := out.push s!"Validation: touched {(jarr v "samples").size} modules in a worktree and rebuilt (each twice: touched, then put back)"
    for s in jarr v "samples" do
      let ms := (jarr s "measured_s").filterMap fun x => match x with | .num n => some n.toFloat | _ => none
      let errs := (jarr s "error_pct").filterMap fun x => match x with | .num n => some n.toFloat | _ => none
      out := out.push s!"  {jstr s "module"}: estimated {fmtS (jfloat s "estimate_s")}, measured {", ".intercalate (ms.toList.map fmtS)} (error {", ".intercalate (errs.toList.map fun e => s!"{if e > 0 then "+" else ""}{Judge.fmt2 e}%")}); rebuilt modules {if (s.getObjValAs? Bool "same_modules").toOption.getD false then "as predicted" else s!"differ: {jstr s "module_difference"}"}"
      unless (jstr s "error").isEmpty do out := out.push s!"    {jstr s "error"}"
    out := out.push s!"  mean absolute error {Judge.fmt2 (jfloat v "mean_abs_error_pct")}%, largest {Judge.fmt2 (jfloat v "max_abs_error_pct")}%"
    unless (v.getObjVal? "replay_mean_abs_error_pct").toOption.isNone do
      out := out.push s!"  (replaying the clean build's wall times instead: mean absolute error {Judge.fmt2 (jfloat v "replay_mean_abs_error_pct")}%, largest {Judge.fmt2 (jfloat v "replay_max_abs_error_pct")}%)"
  -- imports
  let im := jobj r "imports"
  unless im.isNull do
    out := out.push ""
    let cands := jarr im "candidates"
    out := out.push s!"Imports: {jnatv im "considered"} imports of rebuilt modules considered: {jnatv im "needed"} name declarations of the module they import, {jnatv im "reexport"} are in modules that define nothing (they re-export), {jnatv im "redundant"} are reached through another import too, {jnatv im "importers_use_it"} would leave a module that imports the module without a declaration it names, {jnatv im "marked_keep"} are marked `-- shake: keep`{if jnatv im "no_ilean" > 0 then s!", {jnatv im "no_ilean"} without an .ilean" else ""}; {cands.size} candidates shown, the best {(jarr im "tried").size} tried in a worktree"
    let names (k : String) (c : Json) := ", ".intercalate ((jarr c k).filterMap (·.getStr?.toOption)).toList
    for c in cands.extract 0 top do
      let instead := if (jarr c "replace_with").isEmpty then "" else s!" (importing {names "replace_with" c} instead)"
      out := out.push s!"  {jstr c "module"} without `import {jstr c "import"}`{instead}: estimated {fmtS (jfloat c "clean_gain_s")} off the clean build, {fmtS (jfloat c "rebuild_gain_s")} off a rebuild after touching {jstr c "import"} ({jnatv c "modules_freed"} {if jnatv c "modules_freed" == 1 then "module no longer depends" else "modules no longer depend"} on it)"
    for t in jarr im "tried" do
      let verdict := jstr t "verdict"
      out := out.push s!"  tried: {jstr t "module"} without `import {jstr t "import"}`{if (jarr t "replaced_by").isEmpty then "" else s!" (importing {names "replaced_by" t} instead)"}: {verdict}"
      if verdict == "builds" then
        out := out.push s!"    rebuild after touching {jstr t "import"}: {fmtS (jfloat t "before_s")} before, {fmtS (jfloat t "after_s")} after (measured, mean of {jnatv t "samples"} builds each); clean build estimated {fmtS (jfloat t "clean_gain_s")} shorter"
      unless (jstr t "reason").isEmpty do out := out.push s!"    {jstr t "reason"}"
  return "\n".intercalate out.toList

/-! ## HTML -/

def htmlEscapeJson (s : String) : String := s.replace "</" "<\\/"

def htmlPage (r : Json) : String :=
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">" ++
  "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
  "<title>Build timeline</title><style>" ++ css ++ "</style></head><body>" ++
  "<main><h1>Build timeline</h1><p id=\"summary\"></p>" ++
  "<h2>Jobs running</h2><div id=\"conc\" class=\"chart\"></div>" ++
  "<h2>Schedule</h2><p class=\"note\">One row per lane (a lane is not a fixed Lake worker; the number of lanes is the most jobs that ran at once). The critical path is drawn solid; hover a bar for its job.</p>" ++
  "<div id=\"legend\"></div><div id=\"gantt\" class=\"chart\"></div><div id=\"tip\" hidden></div>" ++
  "<h2>Critical path</h2><table id=\"path\"></table>" ++
  "<h2>Rebuild after touching a module (estimated)</h2><table id=\"rebuild\"></table>" ++
  "</main><script id=\"data\" type=\"application/json\">" ++ htmlEscapeJson r.compress ++ "</script><script>" ++ js ++ "</script></body></html>\n"
where
  css := ":root{--bg:#fff;--fg:#1d2330;--muted:#5f6b7a;--grid:#e3e7ec;--lean:#7d9cc4;--cc:#7fb3a6;--link:#b39ad0;--crit:#d9480f;--area:#9fb4cc}" ++
    "@media (prefers-color-scheme:dark){:root{--bg:#14171c;--fg:#e4e8ee;--muted:#9aa5b1;--grid:#2a3038;--lean:#4f6d93;--cc:#4d7f73;--link:#7a62a0;--crit:#ff7a45;--area:#4a5d74}}" ++
    "body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,sans-serif}main{max-width:1200px;margin:0 auto;padding:16px}" ++
    "h1{font-size:20px;margin:8px 0}h2{font-size:16px;margin:24px 0 8px}.note{color:var(--muted);margin:4px 0}.chart{overflow-x:auto}" ++
    "svg text{fill:var(--muted);font-size:11px}table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}" ++
    "td,th{text-align:left;padding:3px 8px;border-bottom:1px solid var(--grid)}td.n,th.n{text-align:right}" ++
    "#tip{position:fixed;pointer-events:none;background:var(--bg);color:var(--fg);border:1px solid var(--grid);padding:6px 8px;border-radius:4px;font-size:12px;box-shadow:0 2px 8px rgba(0,0,0,.2)}" ++
    "#legend span{display:inline-block;margin-right:14px;color:var(--muted)}#legend i{display:inline-block;width:12px;height:10px;margin-right:4px;vertical-align:-1px}"
  js := "const R=JSON.parse(document.getElementById('data').textContent);const J=R.jobs;const E=R.elapsed_s||1;" ++
    "const cs=getComputedStyle(document.documentElement);const col=k=>cs.getPropertyValue(k==='lean'||k==='leanir'?'--lean':k==='cc'?'--cc':'--link').trim();" ++
    "const crit=cs.getPropertyValue('--crit').trim();const fmt=s=>s<10?s.toFixed(2)+' s':s.toFixed(1)+' s';" ++
    "const mb=b=>(b/1048576).toFixed(0)+' MiB';const NS='http://www.w3.org/2000/svg';" ++
    "function el(t,a,p){const e=document.createElementNS(NS,t);for(const k in a)e.setAttribute(k,a[k]);if(p)p.appendChild(e);return e}" ++
    "const W=Math.max(700,document.querySelector('main').clientWidth-10),L=8,X=t=>L+(W-L-8)*t/E;" ++
    "function axis(svg,y){const step=[1,2,5,10,15,30,60,120,300,600,1200,1800,3600].find(s=>E/s<=10)||3600;for(let t=0;t<=E;t+=step){el('line',{x1:X(t),x2:X(t),y1:0,y2:y,stroke:cs.getPropertyValue('--grid')},svg);const tx=el('text',{x:X(t)+2,y:y+12},svg);tx.textContent=t>=60?Math.floor(t/60)+'m'+(t%60?String(t%60).padStart(2,'0')+'s':''):t+'s'}}" ++
    "document.getElementById('summary').textContent=`${R.command} (Lean ${R.lean}): ${fmt(E)}, ${J.length} processes, at most ${R.parallelism.peak} at once, critical path ${R.critical_path.steps.length} jobs.`;" ++
    "{const H=70,svg=el('svg',{width:W,height:H+16});document.getElementById('conc').appendChild(svg);const P=R.parallelism.profile,pk=Math.max(1,R.parallelism.peak);" ++
    "let d=`M${X(0)},${H}`;for(let i=0;i<P.length;i++){const[t,n]=P[i];const nt=i+1<P.length?P[i+1][0]:E;d+=`L${X(t)},${H-H*n/pk}L${X(nt)},${H-H*n/pk}`}d+=`L${X(E)},${H}Z`;axis(svg,H);el('path',{d,fill:cs.getPropertyValue('--area')},svg);" ++
    "const t=el('text',{x:L+2,y:10},svg);t.textContent=pk+' jobs'}" ++
    "{const lanes=1+J.reduce((m,j)=>Math.max(m,j.lane),0),RH=lanes>40?6:lanes>20?10:14,H=lanes*RH,svg=el('svg',{width:W,height:H+16});document.getElementById('gantt').appendChild(svg);axis(svg,H);" ++
    "const tip=document.getElementById('tip');for(const j of J){const r=el('rect',{x:X(j.start_s),y:j.lane*RH+1,width:Math.max(1,X(j.end_s)-X(j.start_s)),height:RH-2,fill:j.critical?crit:col(j.kind),'fill-opacity':j.critical?1:.75},svg);" ++
    "r.addEventListener('mousemove',e=>{tip.hidden=false;tip.style.left=(e.clientX+12)+'px';tip.style.top=(e.clientY+12)+'px';tip.textContent=`${j.kind} ${j.name}: ${fmt(j.start_s)} to ${fmt(j.end_s)} (${fmt(j.duration_s)}), slack ${fmt(j.slack_s)}, peak ${mb(j.max_rss_bytes)}${j.critical?', on the critical path':''}`});" ++
    "r.addEventListener('mouseleave',()=>{tip.hidden=true})}}" ++
    "document.getElementById('legend').innerHTML=[['lean','Lean module'],['cc','C compile'],['link','link or archive']].map(([k,n])=>`<span><i style=\"background:${col(k)}\"></i>${n}</span>`).join('')+`<span><i style=\"background:${crit}\"></i>critical path</span>`;" ++
    "function table(id,head,rows){const t=document.getElementById(id);t.innerHTML='<tr>'+head.map(h=>`<th class=\"${h[1]||''}\">${h[0]}</th>`).join('')+'</tr>'+rows.map(r=>'<tr>'+r.map((c,i)=>`<td class=\"${head[i][1]||''}\">${c}</td>`).join('')+'</tr>').join('')}" ++
    "const esc=s=>String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));" ++
    "table('path',[['start','n'],['time','n'],['wait','n'],['job']],R.critical_path.steps.map((s,i)=>{const j=J[s.job];return[fmt(j.start_s),fmt(j.duration_s),i?fmt(s.wait_s):'',esc(j.kind+' '+j.name)]}));" ++
    "const rb=R.modules.filter(m=>m.rebuild).sort((a,b)=>b.rebuild.estimate_s-a.rebuild.estimate_s).slice(0,30);" ++
    "table('rebuild',[['elapsed','n'],['jobs','n'],['job time','n'],['module']],rb.map(m=>[fmt(m.rebuild.estimate_s),m.rebuild.jobs,fmt(m.rebuild.task_s),esc(m.name)]));"

end Leanprof.Build
