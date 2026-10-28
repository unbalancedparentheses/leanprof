import Lean.Data.Json
import LeanprofElab
import Leanprof.Contract

/-!
# `leanprof build-memory`: the memory of compiling a Lake project

A Lake build runs one `lean` process per module. This command runs a real
`lake build` in which every `lean` is started by a small wrapper
(`c/leanwrap.c`, the reusable piece): it runs the real `lean`, waits for it and
records its peak resident set size, on macOS its peak physical footprint, its
CPU time and when it started and ended. Nothing in the `lean` process changes,
so the numbers are those of an ordinary build.

From the records:

* modules ranked by peak memory, flagged against `--mem-limit`;
* the cost of the imports, measured apart: `lean` run again on the module's
  header alone (its `import` lines, with Lake's setup file), whose peak is the
  environment after the imports; the rest of the module's peak is put down
  to its own elaboration (approximately: elaboration also touches more of
  the imported `.olean` files);
* concurrency: which modules ran at the same time, the largest sum of their
  peaks, and the memory sampled (with `ps`) while the build ran;
* the largest number of jobs whose heaviest modules fit under the limit;
* `--max-memory`: a budget per module, failing (exit 1) when one is above it.

`--decls N` (or files given on the command line) elaborates the heaviest
modules serially in `leanprof-elab-driver --memory` and reports the memory
around each command: the commands during which the process's peak rose. This
is approximate, and says when memory was reached, not who owns it (see the
driver).

The wrapper is reached through Lake's own configuration: `LEAN_SYSROOT` names a
copy of the Lean installation whose `bin/lean` is the wrapper (links to
everything else) and `LAKE_OVERRIDE_LEAN` makes Lake use it.
-/

namespace Leanprof.BuildMem

open Lean System

/-- The wrapper's source, compiled into the command (the lakefile's `needs`
rebuilds this module when it changes) and built with `cc` when first needed. -/
def wrapperSource : String := include_str "../c/leanwrap.c"

/-! ## Sizes -/

/-- `8G`, `512M`, `1.5GiB`, `2048K`, or bytes. Units are binary (G = 2^30 bytes). -/
def parseSize (s : String) : Option Nat := Id.run do
  let cs := s.trimAscii.toString.toList
  let num := cs.takeWhile fun c => c.isDigit || c == '.'
  let unit := String.ofList ((cs.drop num.length).filter (· != ' ')) |>.toUpper
  let mult : Nat ← match unit with
    | "" | "B" => pure 1
    | "K" | "KB" | "KIB" => pure 1024
    | "M" | "MB" | "MIB" => pure (1024 * 1024)
    | "G" | "GB" | "GIB" => pure (1024 * 1024 * 1024)
    | "T" | "TB" | "TIB" => pure (1024 * 1024 * 1024 * 1024)
    | _ => return none
  match (String.ofList num).splitOn "." with
  | [i] => return i.toNat?.map (· * mult)
  | [i, f] =>
    let some whole := i.toNat? | return none
    let some frac := f.toNat? | return none
    let scale := 10 ^ f.length
    return some ((whole * scale + frac) * mult / scale)
  | _ => return none

/-- Bytes as `1.23 GiB`, `456 MiB` or `12 KiB`. -/
def fmtBytes (b : Nat) : String :=
  let f (x : Nat) (d : Nat) : String :=
    let hundredths := (x * 100 + d / 2) / d
    s!"{hundredths / 100}.{if hundredths % 100 < 10 then "0" else ""}{hundredths % 100}"
  if b ≥ 1024 * 1024 * 1024 then s!"{f b (1024 * 1024 * 1024)} GiB"
  else if b ≥ 1024 * 1024 then s!"{(b + 512 * 1024) / (1024 * 1024)} MiB"
  else s!"{(b + 512) / 1024} KiB"

def fmtSecs (us : Nat) : String :=
  let tenths := (us + 50000) / 100000
  s!"{tenths / 10}.{tenths % 10} s"

def rpad (s : String) (n : Nat) : String := if s.length ≥ n then s else "".pushn ' ' (n - s.length) ++ s

/-! ## The wrapper's records -/

/-- One `lean` process of the build, as the wrapper recorded it. -/
structure Proc where
  startUs : Nat
  stopUs : Nat
  userUs : Nat
  sysUs : Nat
  /-- peak resident set size, bytes -/
  maxrss : Nat
  /-- peak private memory, bytes: macOS's physical footprint (exact), Linux's
  RssAnon (sampled every 20 ms); none when unknown -/
  priv : Option Nat
  privSampled : Bool
  exit : Int
  signal : Nat
  cwd : String
  leanPath : String
  args : Array String
  deriving Inhabited

def natField (j : Json) (k : String) : Nat :=
  match j.getObjValAs? Int k with
  | .ok v => v.toNat
  | .error _ => 0

def strField (j : Json) (k : String) : String := (j.getObjValAs? String k).toOption.getD ""

def Proc.ofJson? (j : Json) : Option Proc := do
  let args ← (j.getObjValAs? (Array String) "args").toOption
  let fp := (j.getObjValAs? Int "private_peak").toOption.getD (-1)
  return { startUs := natField j "start_us", stopUs := natField j "end_us", userUs := natField j "user_us",
           sysUs := natField j "sys_us", maxrss := natField j "maxrss",
           priv := if fp < 0 then none else some fp.toNat,
           privSampled := (j.getObjValAs? Bool "private_sampled").toOption.getD false,
           exit := (j.getObjValAs? Int "exit").toOption.getD 0, signal := natField j "signal",
           cwd := strField j "cwd", leanPath := strField j "lean_path", args }

/-- The records of a log, one JSON object per line (lines that do not parse are skipped). -/
def readLog (path : FilePath) : IO (Array Proc) := do
  if !(← path.pathExists) then return #[]
  let text ← IO.FS.readFile path
  return (text.splitOn "\n").toArray.filterMap fun l =>
    if l.isEmpty then none else (Json.parse l).toOption.bind Proc.ofJson?

/-- The value after option `opt` in a command line. -/
def argAfter (args : Array String) (opt : String) : Option String := do
  let i ← args.findIdx? (· == opt)
  args[i + 1]?

/-- The source file a `lean` command line compiles: its argument ending in `.lean`
that is not an option's value. -/
def sourceOf (args : Array String) : Option String := Id.run do
  let mut skip := false
  for a in args do
    if skip then skip := false; continue
    if a == "-o" || a == "-i" || a == "-c" || a == "-b" || a == "--setup" || a == "--bc" || a == "--ilean" then
      skip := true; continue
    if a.endsWith ".lean" && !a.startsWith "-" then return some a
  return none

/-! ## Modules -/

/-- A module compiled by the build: its process, and the imports-only run. -/
structure Module where
  name : String
  file : String
  setup : Option String
  proc : Proc
  /-- the peak of `lean` on the module's header alone -/
  importRss : Option Nat := none
  importPriv : Option Nat := none
  deriving Inhabited

def Module.wallUs (m : Module) : Nat := m.proc.stopUs - m.proc.startUs

/-- What is left of the peak once the imports' peak is taken out (approximate). -/
def Module.ownRss (m : Module) : Option Nat := m.importRss.map (m.proc.maxrss - ·)
def Module.ownPriv (m : Module) : Option Nat := do (← m.proc.priv) - (← m.importPriv)
/-- The rest of the resident peak: pages of mapped files (`.olean` files, the
`lean` binary), which processes share. Approximate: the two peaks need not be
at the same moment. -/
def Module.shared (m : Module) : Nat := m.proc.maxrss - m.proc.priv.getD 0

/-- `A/B/C.lean` relative to `cwd` as `A.B.C`. -/
def moduleOfPath (cwd file : String) : String :=
  let rel := if file.startsWith (cwd ++ "/") then String.ofList (file.toList.drop (cwd.length + 1)) else file
  let rel := if rel.endsWith ".lean" then String.ofList (rel.toList.take (rel.length - 5)) else rel
  rel.replace "/" "."

/-- The module name in Lake's setup file, if it can be read. -/
def setupName (setup : String) : IO (Option String) := do
  try
    let j ← IO.ofExcept (Json.parse (← IO.FS.readFile setup))
    return (j.getObjValAs? String "name").toOption
  catch _ => return none

/-- The modules among the records: processes that compiled a `.lean` file. -/
def modulesOf (procs : Array Proc) : IO (Array Module) := do
  let mut out := #[]
  for p in procs do
    let some file := sourceOf p.args | continue
    -- the build's own `lean` runs write an `.olean`; others (`lean --run`) are left out
    if (argAfter p.args "-o").isNone then continue
    let setup := argAfter p.args "--setup"
    let name ← match setup with
      | some s => pure ((← setupName s).getD (moduleOfPath p.cwd file))
      | none => pure (moduleOfPath p.cwd file)
    out := out.push { name, file, setup, proc := p }
  return out

/-! ## The header alone -/

/-- The module's header: everything before its first command (`module`, `prelude`
and `import` lines, with their comments). -/
def headerText (src : String) : String := Id.run do
  let cs := src.toList.toArray
  let n := cs.size
  let mut i := 0
  let mut stop := 0
  -- after `import` (and `all`), a module name is expected
  let mut wantName := false
  while i < n do
    let c := cs[i]!
    if c.isWhitespace then i := i + 1; continue
    if c == '-' && cs[i+1]? == some '-' then
      while i < n && cs[i]! != '\n' do i := i + 1
      continue
    if c == '/' && cs[i+1]? == some '-' then
      -- a doc comment starts a command
      if cs[i+2]? == some '-' || cs[i+2]? == some '!' then break
      let mut depth := 1
      i := i + 2
      while i < n && depth > 0 do
        if cs[i]! == '/' && cs[i+1]? == some '-' then depth := depth + 1; i := i + 2
        else if cs[i]! == '-' && cs[i+1]? == some '/' then depth := depth - 1; i := i + 2
        else i := i + 1
      continue
    -- a word: a keyword or a (possibly «quoted») name
    let start := i
    while i < n && !cs[i]!.isWhitespace && !(cs[i]! == '-' && cs[i+1]? == some '-') do
      if cs[i]! == '«' then
        while i < n && cs[i]! != '»' do i := i + 1
      i := i + 1
    let w := String.ofList (cs.extract start i).toList
    if wantName && w != "all" then
      wantName := false
      stop := i
    else if w == "import" || w == "all" then
      wantName := true
    else if w == "module" || w == "prelude" then
      stop := i
    else if w == "public" || w == "meta" || w == "private" then
      pure ()
    else break
  return String.ofList (cs.extract 0 stop).toList

/-! ## Running the build -/

/-- The wrapper, built with `cc` from its source into leanprof's cache (once per source). -/
def buildWrapper : IO FilePath := do
  let dir := (← Leanprof.Elab.cacheDir) / "leanwrap" / Leanprof.Elab.hexHash wrapperSource
  let exe := dir / "leanprof-lean-wrap"
  if ← exe.pathExists then return exe
  IO.FS.createDirAll dir
  let stage : FilePath := dir / s!"build-{← IO.Process.getPID}"
  IO.FS.createDirAll stage
  IO.FS.writeFile (stage / "leanwrap.c") wrapperSource
  let out ← IO.Process.output { cmd := "cc", args := #["-O2", "-o", (stage / "leanprof-lean-wrap").toString,
    (stage / "leanwrap.c").toString] }
  if out.exitCode != 0 then
    throw <| IO.userError s!"could not build the lean wrapper with cc:\n{out.stderr}"
  unless ← exe.pathExists do IO.FS.rename (stage / "leanprof-lean-wrap") exe
  IO.FS.removeDirAll stage
  return exe

/-- A copy of the Lean installation at `sysroot` in `dir`: links to everything,
except `bin/lean`, which is the wrapper. -/
def fakeSysroot (sysroot dir wrapper : FilePath) : IO Unit := do
  if ← dir.pathExists then IO.FS.removeDirAll dir
  IO.FS.createDirAll (dir / "bin")
  let link (targets : Array FilePath) (into : FilePath) : IO Unit := do
    if targets.isEmpty then return
    let out ← IO.Process.output { cmd := "ln", args := #["-s"] ++ targets.map (·.toString) ++ #[into.toString] }
    if out.exitCode != 0 then throw <| IO.userError s!"ln failed: {out.stderr}"
  let top ← sysroot.readDir
  link (top.filter (·.fileName != "bin") |>.map (·.path)) dir
  let bin ← (sysroot / "bin").readDir
  link (bin.filter (·.fileName != "lean") |>.map (·.path)) (dir / "bin")
  link #[wrapper] (dir / "bin")
  IO.FS.rename (dir / "bin" / "leanprof-lean-wrap") (dir / "bin" / "lean")

/-- The `lean` processes running now, from the wrappers' live readings
(`DIR/PID`: `RSS PRIVATE FILE`): resident set, private memory, file. -/
def readLive (dir : FilePath) : IO (Array (Nat × Nat × String)) := do
  let entries ← try dir.readDir catch _ => return #[]
  let mut out := #[]
  for e in entries do
    if e.fileName.endsWith ".tmp" then continue
    let text ← try IO.FS.readFile e.path catch _ => continue
    match (text.trimAscii.toString.splitOn " ") with
    | rss :: priv :: file =>
      out := out.push (rss.toNat?.getD 0, priv.toNat?.getD 0, " ".intercalate file)
    | _ => pure ()
  return out

/-- The memory of the `lean` processes running together, sampled while the build runs. -/
structure Sampled where
  /-- the largest sum of their resident sets (shared pages counted once per process) -/
  rssPeak : Nat := 0
  rssFiles : Array String := #[]
  /-- the largest sum of their private memory plus the largest shared part of one of them:
  shared pages counted once, when the processes map the same files -/
  estPeak : Nat := 0
  estFiles : Array String := #[]
  samples : Nat := 0

def Sampled.add (s : Sampled) (live : Array (Nat × Nat × String)) : Sampled :=
  let rss : Nat := live.foldl (fun a (r, _, _) => a + r) 0
  let priv : Nat := live.foldl (fun a (_, p, _) => a + p) 0
  let shared : Nat := live.foldl (fun a (r, p, _) => max a (r - p)) 0
  let files := live.map (·.2.2)
  let s := { s with samples := s.samples + 1 }
  let s := if rss > s.rssPeak then { s with rssPeak := rss, rssFiles := files } else s
  if priv + shared > s.estPeak then { s with estPeak := priv + shared, estFiles := files } else s

/-- Sample every `periodMs` until `stop` is set. -/
partial def sampler (dir : FilePath) (stop : IO.Ref Bool) (periodMs : UInt32) : IO Sampled := do
  let rec loop (s : Sampled) : IO Sampled := do
    if ← stop.get then return s
    let live ← readLive dir
    let s := if live.isEmpty then s else s.add live
    IO.sleep periodMs
    loop s
  loop {}

/-! ## Analysis -/

/-- The moment the sum of the peaks of the processes running together was largest:
that sum, the modules (indices), and the most processes ever running together. -/
def concurrentPeak (ms : Array Module) : Nat × Array Nat × Nat := Id.run do
  let mut best := 0
  let mut bestSet : Array Nat := #[]
  let mut most := 0
  for i in [0:ms.size] do
    let t := ms[i]!.proc.startUs
    let mut sum := 0
    let mut set := #[]
    for j in [0:ms.size] do
      let p := ms[j]!.proc
      if p.startUs ≤ t && t < p.stopUs then
        sum := sum + p.maxrss
        set := set.push j
    most := max most set.size
    if sum > best then
      best := sum
      bestSet := set
  return (best, bestSet, most)

/-- The largest number of jobs `j ≤ maxJobs` for which `base` plus the `j` largest
peaks is at most `limit` (0: not even one fits), and that total. Any `j` modules
may run together, so with resident peaks (`base` 0) this bounds the build's
memory from above whatever modules run together, counting the pages of shared
`.olean` files once per process; with private peaks and `base` the largest
shared part, it estimates the memory with those pages counted once. -/
def safeJobs (peaks : Array Nat) (limit maxJobs : Nat) (base : Nat := 0) : Nat × Nat := Id.run do
  let sorted := peaks.qsort (· > ·)
  let mut sum := base
  let mut j := 0
  for p in sorted do
    if j ≥ maxJobs || sum + p > limit then break
    sum := sum + p
    j := j + 1
  return (j, sum)

/-! ## Memory per command -/

/-- One command of a serial elaboration (`leanprof-elab-driver --memory`). -/
structure Command where
  line : Nat
  endLine : Nat
  name : String
  text : String
  heartbeats : Nat
  rssBefore : Nat
  rssAfter : Nat
  peakBefore : Nat
  peakAfter : Nat
  privBefore : Nat
  privAfter : Nat
  privPeakBefore : Nat
  privPeakAfter : Nat
  deriving Inhabited

/-- How much the process's peak rose during the command. -/
def Command.peakRise (c : Command) : Nat := c.peakAfter - c.peakBefore
def Command.privPeakRise (c : Command) : Nat := c.privPeakAfter - c.privPeakBefore
/-- Resident memory after the command minus before it (negative: it went down). -/
def Command.growth (c : Command) : Int := (c.rssAfter : Int) - c.rssBefore

structure Serial where
  module : String
  file : String
  /-- after the imports -/
  importRss : Nat := 0
  importPriv : Nat := 0
  peak : Nat := 0
  privPeak : Nat := 0
  commands : Array Command := #[]
  error : String := ""
  deriving Inhabited

def Serial.ofLines (module file : String) (lines : List String) : Serial := Id.run do
  let mut s : Serial := { module, file }
  for l in lines do
    let some j := (Json.parse l).toOption | continue
    if (j.getObjValAs? Bool "imports").toOption == some true then
      s := { s with importRss := natField j "rss_after", importPriv := natField j "private_after",
                    peak := natField j "peak_after", privPeak := natField j "private_peak_after" }
      continue
    let name := strField j "name"
    let text := strField j "text"
    if name.isEmpty && text.isEmpty then continue
    let c : Command := {
      line := natField j "line", endLine := natField j "end_line", name, text,
      heartbeats := natField j "heartbeats_after" - natField j "heartbeats_before",
      rssBefore := natField j "rss_before", rssAfter := natField j "rss_after",
      peakBefore := natField j "peak_before", peakAfter := natField j "peak_after",
      privBefore := natField j "private_before", privAfter := natField j "private_after",
      privPeakBefore := natField j "private_peak_before", privPeakAfter := natField j "private_peak_after" }
    s := { s with commands := s.commands.push c, peak := max s.peak c.peakAfter,
                  privPeak := max s.privPeak c.privPeakAfter }
  return s

/-- The command during which the process reached its peak (its last rise). -/
def Serial.peakCommand? (s : Serial) : Option Command :=
  s.commands.foldl (init := none) fun acc c =>
    if c.peakRise > 0 && c.peakAfter == s.peak then some c else acc

/-- Elaborate `file` serially with the driver and read its memory per command. -/
def serialRun (le : Leanprof.Elab.LeanEnv) (file module : String) : IO Serial := do
  if le.driver.isEmpty then return { module, file, error := "no leanprof-elab-driver for this Lean" }
  let setup ← Leanprof.Elab.setupFile file module
  let path := (← IO.getEnv "PATH").getD ""
  let out ← IO.Process.output {
    cmd := le.driver,
    args := #["--memory"] ++ (match setup with | some s => #["--setup", s.toString] | none => #[]) ++ #[file],
    env := #[("LEAN_PATH", some le.path), ("PATH", some s!"{le.sysroot / "bin"}:{path}")] }
  let s := Serial.ofLines module file (out.stdout.splitOn "\n")
  if out.exitCode != 0 && s.commands.isEmpty then
    return { s with error := s!"the driver exited with code {out.exitCode}: {String.ofList (out.stderr.toList.take 400)}" }
  return s

/-! ## Options -/

structure Opts where
  memLimit : Option Nat := none
  maxMemory : Option Nat := none
  imports : Bool := true
  clean : Bool := false
  jobs : Option Nat := none
  out : String := ".lake/leanprof/build-memory.json"
  top : Nat := 20
  decls : Nat := 0
  files : Array String := #[]
  sample : Bool := true
  /-- analyse an existing wrapper log instead of building -/
  log : Option String := none
  targets : Array String := #[]

def usage : String :=
  "usage: leanprof build-memory [--mem-limit SIZE] [--max-memory SIZE] [--jobs N] [--clean] [--no-imports] " ++
  "[--decls N] [--top N] [--out FILE] [--no-sample] [--log FILE] [FILE.lean...] [-- LAKE-TARGETS...]"

partial def parseOpts (o : Opts) : List String → Except String Opts
  | [] => .ok o
  | "--mem-limit" :: v :: r => match parseSize v with
    | some n => parseOpts { o with memLimit := some n } r
    | none => .error s!"not a size: {v} (examples: 8G, 512M)"
  | "--max-memory" :: v :: r => match parseSize v with
    | some n => parseOpts { o with maxMemory := some n } r
    | none => .error s!"not a size: {v} (examples: 8G, 512M)"
  | "--jobs" :: v :: r => match v.toNat? with
    | some n => if n == 0 then .error "--jobs needs at least 1" else parseOpts { o with jobs := some n } r
    | none => .error s!"not a number: {v}"
  | "--clean" :: r => parseOpts { o with clean := true } r
  | "--no-imports" :: r => parseOpts { o with imports := false } r
  | "--no-sample" :: r => parseOpts { o with sample := false } r
  | "--decls" :: v :: r => match v.toNat? with
    | some n => parseOpts { o with decls := n } r
    | none => .error s!"not a number: {v}"
  | "--top" :: v :: r => match v.toNat? with
    | some n => parseOpts { o with top := n } r
    | none => .error s!"not a number: {v}"
  | "--out" :: f :: r => parseOpts { o with out := f } r
  | "--log" :: f :: r => parseOpts { o with log := some f } r
  | "--" :: r => .ok { o with targets := o.targets ++ r.toArray }
  | f :: r =>
    if f.startsWith "-" then .error s!"unknown option {f}\n{usage}"
    else if f.endsWith ".lean" then parseOpts { o with files := o.files.push f } r
    else .error s!"not a Lean file: {f} (Lake targets go after --)\n{usage}"

/-! ## Imports alone -/

/-- Run `lean` on each module's header alone (in batches of `jobs`), through the
wrapper, and record its peak. -/
def measureImports (wrapper : FilePath) (real : String) (dir : FilePath) (ms : Array Module) (jobs : Nat) :
    IO (Array Module) := do
  IO.FS.createDirAll dir
  let mut out := ms
  let mut i := 0
  while i < ms.size do
    let batch := (List.range (min jobs (ms.size - i))).map (· + i)
    let mut running : Array (Nat × FilePath × IO.Process.Child ⟨.null, .null, .null⟩) := #[]
    for k in batch do
      let m := ms[k]!
      let src ← try IO.FS.readFile m.file catch _ => pure ""
      let log := dir / s!"{k}.jsonl"
      if ← log.pathExists then IO.FS.removeFile log
      let child ← IO.Process.spawn {
        cmd := wrapper.toString, args := #["--stdin"] ++ (match m.setup with | some s => #["--setup", s] | none => #[]),
        cwd := m.proc.cwd, stdin := .piped, stdout := .null, stderr := .null,
        env := #[("LEANPROF_REAL_LEAN", some real), ("LEANPROF_BUILD_LOG", some log.toString),
                 ("LEAN_PATH", some m.proc.leanPath)] }
      let (stdin, child) ← child.takeStdin
      stdin.putStr (headerText src)
      stdin.flush
      running := running.push (k, log, (child : IO.Process.Child ⟨.null, .null, .null⟩))
    for (k, log, child) in running do
      let rc ← child.wait
      let procs ← readLog log
      if let some (p : Proc) := procs[0]? then
        if rc == 0 then
          out := out.set! k { out[k]! with importRss := some p.maxrss, importPriv := p.priv }
    i := i + batch.length
  return out

/-! ## Report -/

def platformName : String :=
  if System.Platform.isOSX then "macOS" else if System.Platform.isWindows then "Windows" else "Linux"

/-- What private memory is on this platform. -/
def privName : String :=
  if System.Platform.isOSX then "footprint" else "anonymous"

def optJson (v : Option Nat) : Json := match v with | some n => toJson n | none => Json.null

def moduleJson (m : Module) : Json :=
  Json.mkObj [("module", Json.str m.name), ("file", Json.str m.file), ("peak_rss", toJson m.proc.maxrss),
    ("private_peak", optJson m.proc.priv), ("private_sampled", Json.bool m.proc.privSampled),
    ("imports_rss", optJson m.importRss), ("imports_private", optJson m.importPriv),
    ("own_rss", optJson m.ownRss), ("own_private", optJson m.ownPriv),
    ("wall_ms", toJson (m.wallUs / 1000)), ("cpu_ms", toJson ((m.proc.userUs + m.proc.sysUs) / 1000)),
    ("exit", toJson m.proc.exit), ("start_ms", toJson (m.proc.startUs / 1000)), ("end_ms", toJson (m.proc.stopUs / 1000))]

def commandJson (c : Command) : Json :=
  Json.mkObj [("line", toJson c.line), ("end_line", toJson c.endLine), ("name", Json.str c.name),
    ("text", Json.str c.text), ("heartbeats", toJson c.heartbeats), ("rss_before", toJson c.rssBefore),
    ("rss_after", toJson c.rssAfter), ("peak_rise", toJson c.peakRise), ("peak_after", toJson c.peakAfter),
    ("private_before", toJson c.privBefore), ("private_after", toJson c.privAfter),
    ("private_peak_rise", toJson c.privPeakRise)]

def serialJson (s : Serial) : Json :=
  Json.mkObj [("module", Json.str s.module), ("file", Json.str s.file), ("imports_rss", toJson s.importRss),
    ("imports_private", toJson s.importPriv), ("peak_rss", toJson s.peak), ("private_peak", toJson s.privPeak),
    ("error", Json.str s.error), ("commands", Json.arr (s.commands.map commandJson))]

/-- The per-command section of the report for one module. -/
def serialText (s : Serial) (top : Nat) : Array String := Id.run do
  let mut out := #[s!"\n  {s.module} ({s.file}), elaborated serially:"]
  if !s.error.isEmpty then return out.push s!"    not measured: {s.error}"
  out := out.push s!"    after the imports: {fmtBytes s.importRss} resident; peak of the run: {fmtBytes s.peak}"
  if let some c := s.peakCommand? then
    out := out.push s!"    the peak was reached during line {c.line}{if c.name.isEmpty then "" else s!" ({c.name})"}"
  let risers := (s.commands.filter (·.peakRise > 0)).qsort (fun a b => a.peakRise > b.peakRise)
  if risers.isEmpty then return out.push "    no command raised the peak above what the imports reached"
  out := out.push "    commands during which the process's peak rose (when memory was reached, not who owns it):"
  out := out.push s!"    {rpad "peak rise" 10} {rpad "resident after" 14} {rpad "heartbeats" 12}  line  command"
  for c in risers.toList.take top do
    out := out.push s!"    {rpad (fmtBytes c.peakRise) 10} {rpad (fmtBytes c.rssAfter) 14} {rpad (toString (c.heartbeats / 1000) ++ "k") 12}  {rpad (toString c.line) 4}  {if c.name.isEmpty then c.text else c.name}"
  return out

structure Result where
  modules : Array Module
  /-- the build's exit code -/
  buildExit : UInt32 := 0
  sampled : Option Sampled := none
  serial : Array Serial := #[]
  jobs : Option Nat := none

def listNames (names : Array String) : String :=
  s!"{", ".intercalate (names.toList.take 6)}{if names.size > 6 then s!", and {names.size - 6} more" else ""}"

def report (o : Opts) (r : Result) (ncpu : Nat) : String × Json × Bool := Id.run do
  let ms := r.modules.qsort (fun a b => a.proc.maxrss > b.proc.maxrss)
  let (concPeak, concSet, most) := concurrentPeak ms
  let hasPriv := ms.any (·.proc.priv.isSome)
  let sampledPriv := ms.any (·.proc.privSampled)
  let mut out := #[s!"leanprof build-memory: {ms.size} {if ms.size == 1 then "module" else "modules"} compiled by `lake build`, at most {most} at a time ({platformName}, {ncpu} CPUs{match r.jobs with | some j => s!", --jobs {j}" | none => ""})"]
  if r.buildExit != 0 then out := out.push s!"  the build failed (exit code {r.buildExit}): only the modules it compiled are measured"
  if ms.isEmpty then
    out := out.push "  no module was compiled: everything was up to date (--clean rebuilds the project's own modules)"
  else
    out := out.push s!"\n  peak memory of each module's `lean` process:"
    out := out.push s!"  {rpad "peak RSS" 10}{if hasPriv then rpad privName 11 else ""} {rpad "imports" 10} {rpad "own" 10} {rpad "wall" 8}  module"
    for m in ms.toList.take o.top do
      let imp := match m.importRss with | some v => fmtBytes v | none => "-"
      let own := match m.ownRss with | some v => fmtBytes v | none => "-"
      let pv := if hasPriv then rpad (match m.proc.priv with | some v => fmtBytes v | none => "-") 11 else ""
      out := out.push s!"  {rpad (fmtBytes m.proc.maxrss) 10}{pv} {rpad imp 10} {rpad own 10} {rpad (fmtSecs m.wallUs) 8}  {m.name}{if m.proc.exit != 0 then s!"  (exit {m.proc.exit})" else ""}"
    if ms.size > o.top then out := out.push s!"  ... {ms.size - o.top} more in the JSON report"
    out := out.push "  peak RSS: resident set, with the pages of mapped .olean files, which processes share"
    if hasPriv then
      out := out.push (if System.Platform.isOSX then
        "  footprint: what macOS charges the process (its private memory), without the mapped files"
        else s!"  anonymous: private memory (RssAnon){if sampledPriv then ", the largest of readings every 20 ms" else ""}")
    if ms.any (·.importRss.isSome) then
      out := out.push "  imports: the peak of `lean` on the module's header alone (the environment after its imports)"
      out := out.push "  own: the rest of the peak, approximately the module's own elaboration"
    -- concurrency
    out := out.push s!"\n  modules running at the same time: their peaks add up to at most {fmtBytes concPeak}"
    out := out.push s!"    ({listNames (concSet.map (ms[·]!.name))})"
    if let some s := r.sampled then
      if s.samples > 0 then
        out := out.push s!"  sampled every 0.2 s while the build ran ({s.samples} samples):"
        out := out.push s!"    resident sets added up: {fmtBytes s.rssPeak} at most"
        if hasPriv then
          out := out.push s!"    private memory added up, plus the largest shared part once: {fmtBytes s.estPeak} at most"
          out := out.push s!"    ({listNames (s.estFiles.map fun f => ((ms.find? (·.file == f)).map (·.name)).getD f)})"
  -- limit and jobs
  let mut limitJ := Json.null
  if let some lim := o.memLimit then
    let near := ms.filter (·.proc.maxrss * 4 ≥ lim * 3)
    out := out.push s!"\n  memory limit {fmtBytes lim}:"
    if near.isEmpty then out := out.push "    no module's peak is above 75% of it"
    else
      for m in near do
        out := out.push s!"    {if m.proc.maxrss > lim then "ABOVE" else "near "} {fmtBytes m.proc.maxrss} ({m.proc.maxrss * 100 / lim}% of the limit): {m.name}"
    let (j, sum) := safeJobs (ms.map (·.proc.maxrss)) lim ncpu
    let shared := ms.foldl (fun a m => max a m.shared) 0
    let (je, sume) := safeJobs (ms.map (·.proc.priv.getD 0)) lim ncpu shared
    if !ms.isEmpty then
      let all := min ncpu ms.size
      if j == 0 then
        out := out.push s!"    jobs: the heaviest module alone needs {fmtBytes ms[0]!.proc.maxrss} resident"
      else if j == all then
        out := out.push s!"    jobs: any number fits: the {j} largest resident peaks add up to {fmtBytes sum}"
      else
        out := out.push s!"    jobs: at most {j} at once is safe: the {j} largest resident peaks add up to {fmtBytes sum}"
      if hasPriv && je > j then
        out := out.push s!"    with the shared .olean pages counted once (the {je} largest private peaks plus the largest shared part, {fmtBytes shared}): {if je == all then "any number of" else toString je} jobs, {fmtBytes sume}; an estimate, not a bound"
      if j > 0 && j < all then
        out := out.push s!"    Lake runs as many jobs as it has Lean threads: `LEAN_NUM_THREADS={j} lake build` (each `lean` then has {j} threads too); `leanprof build-memory --clean --jobs {j}` runs the build that way, with each `lean` at its usual threads, and measures it"
    limitJ := Json.mkObj [("limit", toJson lim), ("safe_jobs", toJson j), ("largest_rss_sum", toJson sum),
      ("estimated_jobs", if hasPriv then toJson je else Json.null),
      ("estimated_sum", if hasPriv then toJson sume else Json.null), ("largest_shared", toJson shared),
      ("near", Json.arr (near.map (Json.str ·.name)))]
  -- budget
  let mut failed := false
  let mut budgetJ := Json.null
  if let some b := o.maxMemory then
    let over := ms.filter (·.proc.maxrss > b)
    if over.isEmpty then out := out.push s!"\n  memory budget: no module above {fmtBytes b}"
    else
      failed := true
      out := out.push s!"\n  memory budget: {over.size} {if over.size == 1 then "module" else "modules"} above {fmtBytes b}:"
      for m in over do out := out.push s!"    {fmtBytes m.proc.maxrss}: {m.name}"
    budgetJ := Json.mkObj [("limit", toJson b), ("over", Json.arr (over.map fun m =>
      Json.mkObj [("module", Json.str m.name), ("peak_rss", toJson m.proc.maxrss)]))]
  -- per command
  if !r.serial.isEmpty then
    out := out.push "\n  memory per command, in a serial elaboration (one command at a time, no parallel proofs; approximate):"
    for s in r.serial do out := out ++ serialText s 10
  let j := Json.mkObj [("kind", Json.str "build-memory"), ("version", toJson (1 : Nat)),
    ("schema", Leanprof.Contract.schema "build-memory"),
    ("platform", Json.str platformName), ("cpus", toJson ncpu), ("jobs", match r.jobs with | some j => toJson j | none => Json.null),
    ("build_exit", toJson r.buildExit.toNat), ("max_concurrent", toJson most),
    ("concurrent_peak", Json.mkObj [("sum_of_peaks", toJson concPeak),
      ("modules", Json.arr (concSet.map (Json.str ms[·]!.name)))]),
    ("sampled", match r.sampled with
      | some s => Json.mkObj [("rss_sum", toJson s.rssPeak), ("rss_files", Json.arr (s.rssFiles.map Json.str)),
          ("private_sum_plus_shared", toJson s.estPeak), ("private_files", Json.arr (s.estFiles.map Json.str)),
          ("samples", toJson s.samples)]
      | none => Json.null),
    ("mem_limit", limitJ), ("budget", budgetJ),
    ("modules", Json.arr (ms.map moduleJson)), ("declarations", Json.arr (r.serial.map serialJson))]
  return ("\n".intercalate out.toList, j, failed)

/-! ## The command -/

def ncpus : IO Nat := do
  let (cmd, args) := if System.Platform.isOSX then ("sysctl", #["-n", "hw.ncpu"]) else ("nproc", #[])
  let out ← try IO.Process.output { cmd, args } catch _ => return 1
  return out.stdout.trimAscii.toString.toNat?.getD 1

/-- Run `lake build TARGETS` with every `lean` wrapped (`c/leanwrap.c`), sampling
the memory of the running ones every 0.2 s when `sample`: Lake's exit code, the
wrapper's records and the samples. `extraEnv` is added to Lake's environment
(`LEAN_NUM_THREADS` sets its parallelism; `LEANPROF_CHILD_NUM_THREADS` the
threads of each `lean`, empty for Lean's default). Usable for anything that
needs each `lean` process of a real build (its time, CPU and memory). -/
def wrappedBuild (le : Leanprof.Elab.LeanEnv) (work : FilePath) (targets : Array String)
    (extraEnv : Array (String × Option String)) (sample : Bool) : IO (UInt32 × Array Proc × Option Sampled) := do
  let wrapper ← buildWrapper
  let sys := work / "sysroot"
  fakeSysroot le.sysroot sys wrapper
  let log := work / "lean.jsonl"
  if ← log.pathExists then IO.FS.removeFile log
  let live := work / "live"
  if ← live.pathExists then IO.FS.removeDirAll live
  IO.FS.createDirAll live
  let real := (le.sysroot / "bin" / "lean").toString
  -- absolute: `lean` runs in each package's directory
  let logAbs := (← IO.FS.realPath work) / "lean.jsonl"
  let liveAbs ← IO.FS.realPath live
  let env : Array (String × Option String) :=
    #[("LAKE_OVERRIDE_LEAN", some "1"), ("LEAN_SYSROOT", some (← IO.FS.realPath sys).toString),
      ("LEANPROF_REAL_LEAN", some real), ("LEANPROF_BUILD_LOG", some logAbs.toString),
      ("LEANPROF_BUILD_LIVE", if sample then some liveAbs.toString else none)] ++ extraEnv
  let stop ← IO.mkRef false
  let samp ← if sample then some <$> IO.asTask (prio := .dedicated) (sampler live stop 200) else pure none
  let child ← IO.Process.spawn { cmd := "lake", args := #["build"] ++ targets, env, stdin := .null }
  let rc ← child.wait
  stop.set true
  let sampled ← match samp with
    | some t => match ← IO.wait t with
      | .ok s => pure (some s)
      | .error _ => pure none
    | none => pure none
  return (rc, ← readLog log, sampled)

def main (argv : List String) : IO UInt32 := do
  let o ← match parseOpts {} argv with
    | .ok o => pure o
    | .error e =>
      Leanprof.Contract.reportError "bad_argument" e
      IO.eprintln s!"leanprof build-memory: {e}"; return 2
  let ncpu ← ncpus
  let le ← Leanprof.Elab.leanEnv
  let work : FilePath := ".lake" / "leanprof" / "build-memory"
  IO.FS.createDirAll work
  -- files only: per command, no build
  let mut r : Result := { modules := #[], jobs := o.jobs }
  let needDriver := o.decls > 0 || !o.files.isEmpty
  let le ← if !needDriver then pure le else match ← Leanprof.Elab.findDriver le.lean le.sysroot with
    | .ok d => pure { le with driver := d }
    | .error why => IO.eprintln s!"leanprof: memory per command needs leanprof-elab-driver: {why}"; pure le
  if o.files.isEmpty || o.log.isSome || !o.targets.isEmpty then
    let (rc, procs, sampled) ← match o.log with
      | some f => pure ((0 : UInt32), ← readLog f, none)
      | none =>
        if o.clean then
          let b : FilePath := ".lake" / "build"
          if ← b.pathExists then
            IO.eprintln "leanprof: --clean: removing .lake/build so that the project's modules are compiled again"
            IO.FS.removeDirAll b
        let threads := (← IO.getEnv "LEAN_NUM_THREADS").getD ""
        wrappedBuild le work o.targets (match o.jobs with
          | some j => #[("LEAN_NUM_THREADS", some (toString j)), ("LEANPROF_CHILD_NUM_THREADS", some threads)]
          | none => #[]) o.sample
    let mut ms ← modulesOf procs
    if o.imports && !ms.isEmpty then
      IO.eprintln s!"leanprof: measuring the imports of {ms.size} {if ms.size == 1 then "module" else "modules"} (lean on each header alone)"
      ms ← measureImports (← buildWrapper) (le.sysroot / "bin" / "lean").toString (work / "imports") ms (max 1 (ncpu / 2))
    r := { r with modules := ms, buildExit := rc, sampled }
  -- per command: the files given, or the heaviest modules
  let heaviest := (r.modules.qsort (fun a b => a.proc.maxrss > b.proc.maxrss)).toList.take o.decls
  let cwd ← IO.currentDir
  let targets := o.files.toList.map (fun f => (f, Leanprof.Elab.moduleOfFile f)) ++
    heaviest.map fun m =>
      let rel := if m.file.startsWith (cwd.toString ++ "/") then String.ofList (m.file.toList.drop (cwd.toString.length + 1)) else m.file
      (rel, m.name)
  for (f, mod) in targets do
    IO.eprintln s!"leanprof: elaborating {f} serially for its memory per command"
    r := { r with serial := r.serial.push (← serialRun le f mod) }
  let (text, j, failed) := report o r ncpu
  IO.println text
  if let some dir := (o.out : FilePath).parent then IO.FS.createDirAll dir
  let prov ← Leanprof.Contract.provenance (← Leanprof.Contract.workload "" o.files)
    (Json.mkObj [("mode", Json.str "build-memory"), ("targets", toJson o.targets), ("clean", Json.bool o.clean),
      ("jobs", match o.jobs with | some n => toJson n | none => Json.null), ("imports", Json.bool o.imports)])
  let j := j.setObjVal! "provenance" prov
  if r.buildExit != 0 then
    Leanprof.Contract.reportError "build_failed" s!"`lake build` exited with code {r.buildExit}"
  IO.FS.writeFile o.out (j.pretty ++ "\n")
  IO.println s!"\n  report: {o.out}"
  return if failed then 1 else if r.buildExit != 0 then r.buildExit else 0

end Leanprof.BuildMem
