import Lean.Data.Json
import Leanprof.Fix
import Leanprof.Judge

/-!
# `leanprof experiment`: one complete experiment operation

An agent (or a person) changes a Lean project and needs a verdict it can
trust, without writing the checks by hand each time. `experiment start`
records the baseline once, under an experiment id in
`.lake/leanprof/experiments/ID/`: its commit, the build, its behaviour on
every input (stdout, stderr, exit code and the output files named), the
tests, and the exact counts and time of `leanprof measure`. Each
`experiment try` then checks one candidate (a commit, or the working tree)
in a git worktree of its own, and returns KEEP, DISCARD, INCONCLUSIVE or
ERROR with a JSON evidence file, one step at a time, each step only when
the one before passed:

1. **build**: the package's default targets (its proofs are checked again)
   and the executable;
2. **guard**: the proof-preservation auditor (`scripts/proof-audit`, its
   source compiled in) on the changed modules and every module of the
   package that imports them. A FAIL (a protected file changed: tests,
   expected outputs, the experiment's inputs; a `sorry`, a new axiom, a new
   `@[implemented_by]`, `@[extern]`, `unsafe` or `partial`; a removed
   theorem) is a DISCARD; an INCONCLUSIVE (a theorem statement, or a
   definition it mentions, changed; a change outside the Lean modules) can
   never be a KEEP. The one finding accepted alone is `no_theorems`: the
   audited modules state no theorem, so there is no statement to weaken;
   the other checks (sorry, axioms, runtime overrides, protected files)
   still ran;
3. **tests** pass;
4. **outputs** are byte for byte the baseline's on every input;
5. **compiled code**: when every C file Lean generated for the package
   (`.lake/build/ir`) is the baseline's, the program cannot run any
   differently, so no time is spent measuring it (unless `--time`): the
   measure becomes the compile heartbeats of the changed modules;
6. **exact counts** (`measure`: copies, allocations, calls) must not get
   worse; if they do, no time is spent on timing;
7. **timing** of the two plain binaries in AB/BA pairs (`measure-pair`,
   stopping once settled).

A library with no executable is measured by its compile heartbeats
(`elab --heartbeats`) on the changed modules and their dependents in the
package: exact, no timing noise.

A KEEP moves the experiment's base to the candidate (the next candidate is
judged against it), and leaves evidence in git: a candidate from the
working tree is committed on the current branch with the evidence in the
message, a commit gets a note (`refs/notes/leanprof-experiments`).
`experiment finish` runs the held-out inputs, which no try saw, on the final
base, and compares them with the baseline's (recorded as hashes only).

Git runs without hooks (`Fix.gitRaw`), the worktrees use the project's
`.lake/packages` (a link) and start from copies of its build, and the base
build is kept between tries, so a try rebuilds only what the candidate
changed. Pure parts (argument substitution, module names, imports and
dependents, the guard's policy, the verdict) are tested in `Tests/Main.lean`;
`scripts/experiment-check.sh` runs the whole operation on fixture projects.
-/

namespace Leanprof.Experiment

open Lean System
open Leanprof.Explain (trim jstr jarr)
open Leanprof.Fix (capture gitRaw git tailOf shellQuote)

/-- The proof-preservation auditor, written next to each experiment and run
with `python3` (`scripts/proof-audit/`). -/
def auditScript : String := include_str "../scripts/proof-audit/audit.py"
def auditSnapshot : String := include_str "../scripts/proof-audit/Snapshot.lean"

/-! ## Pure parts -/

/-- The arguments for one input: `{}` replaced by its path, or the path
appended when the arguments have no `{}`. -/
def substInput (args : Array String) (input : String) : Array String :=
  if args.any (·.contains "{}") then args.map (·.replace "{}" input) else args.push input

/-- One argument list per line of a `--cases` file (split at whitespace;
blank lines and lines starting with `#` are skipped). -/
def parseCases (text : String) : Array (Array String) :=
  ((text.splitOn "\n").filterMap fun l =>
    let t := trim l
    if t.isEmpty || t.startsWith "#" then none
    else some ((t.split Char.isWhitespace).toList.map (·.toString) |>.filter (· != "")).toArray).toArray

def isIdent (s : String) : Bool :=
  match s.toList with
  | c :: cs => (c.isAlpha || c == '_') && cs.all (fun c => c.isAlphanum || c == '_' || c == '\'')
  | [] => false

/-- The module a Lean file in the package defines, by Lake's default layout
(`Foo/Bar.lean` is `Foo.Bar`), from its path relative to the package
directory. -/
def moduleOfPath (rel : String) : Option String := do
  unless rel.endsWith ".lean" do none
  let parts := ((rel.dropEnd 5).toString.splitOn "/")
  unless parts.all isIdent do none
  return ".".intercalate parts

/-- A path relative to the repository top, made relative to the package
directory `pre` (`git rev-parse --show-prefix`, ending in `/` or empty);
`none` when it is outside the package. -/
def inPackage (pre path : String) : Option String :=
  if pre.isEmpty then some path
  else if path.startsWith pre then some (path.drop pre.length).toString else none

/-- The modules a Lean file imports, from its header (`import`, `public
import`, `meta import`, …, until the first other command). -/
def parseImports (src : String) : Array String := Id.run do
  let mut out := #[]
  let mut inComment := false
  for line in src.splitOn "\n" do
    let t := trim line
    if inComment then
      if t.contains "-/" then inComment := false
      continue
    if t.isEmpty || t.startsWith "--" then continue
    if t.startsWith "/-" then
      unless (t.drop 2).toString.contains "-/" do inComment := true
      continue
    let ws := (t.split Char.isWhitespace).toList.map (·.toString) |>.filter (· != "")
    let ws := ws.dropWhile (fun w => w == "public" || w == "meta" || w == "private")
    match ws with
    | "import" :: rest =>
      for w in rest do
        if w == "all" then continue
        if w.startsWith "--" then break
        out := out.push w
    | "prelude" :: _ => continue
    | "module" :: _ => continue
    | _ => break
  return out

/-- The modules that import any of `changed`, directly or not, in the order
found (breadth first), without `changed` themselves. -/
def dependents (imports : Array (String × Array String)) (changed : Array String) : Array String := Id.run do
  let mut seen : Std.HashSet String := changed.foldl (·.insert ·) {}
  let mut frontier := changed
  let mut out := #[]
  while !frontier.isEmpty do
    let mut next := #[]
    for (m, is) in imports do
      if !seen.contains m && is.any frontier.contains then
        seen := seen.insert m
        next := next.push m
        out := out.push m
    frontier := next
  return out

/-- What the experiment makes of the auditor's report. -/
structure Guard where
  /-- `PASS`, `FAIL` or `INCONCLUSIVE` -/
  status : String
  reasons : Array String := #[]
  notes : Array String := #[]
  deriving Inhabited

def findingText (f : Json) : String :=
  let t := s!"{jstr f "code"} {jstr f "subject"}: {jstr f "detail"}"
  if t.length > 600 then String.ofList (t.toList.take 600) ++ " …" else t

/-- At most `n` reasons, then how many more there are and where. -/
def fewer (rs : Array String) (path : FilePath) (n : Nat := 8) : Array String :=
  if rs.size ≤ n then rs else rs.extract 0 n |>.push s!"… and {rs.size - n} more findings, all in {path}"

/-- The auditor's status, except that `no_theorems` alone is accepted: the
audited modules state no theorem, so none can be weakened, and every other
check of the audit ran. -/
def guardOf (audit : Json) : Guard := Id.run do
  let findings := jarr audit "findings"
  let fails := findings.filter (jstr · "status" == "FAIL")
  let open_ := findings.filter fun f => jstr f "status" != "FAIL" && jstr f "code" != "no_theorems"
  let noTheorems := findings.any (jstr · "code" == "no_theorems")
  match jstr audit "status" with
  | "PASS" => return { status := "PASS" }
  | "FAIL" =>
    -- what was written first (a sorry, a protected file), then what follows from it,
    -- and declarations the user named before generated or private ones
    let rank (f : Json) : Nat :=
      (match jstr f "code" with
        | "sorry_dependency" | "protected_file_changed" | "added_axiom" | "removed_declaration" => 0
        | _ => 2) + (if ((jstr f "subject").splitOn ".").any (·.startsWith "_") then 1 else 0)
    let sorted := (fails.toList.mergeSort fun a b => rank a ≤ rank b).toArray
    return { status := "FAIL", reasons := sorted.map findingText }
  | "INCONCLUSIVE" =>
    if open_.isEmpty && noTheorems then
      return { status := "PASS", notes := #["the audited modules state no theorems, so none can be weakened " ++
        "(sorry, axioms, runtime overrides and protected files were still checked)"] }
    return { status := "INCONCLUSIVE", reasons := open_.map findingText }
  | s => return { status := "INCONCLUSIVE", reasons := #[s!"the auditor returned no verdict ({if s.isEmpty then "none" else s})"] }

/-- The four outcomes, and the exit codes of `experiment try`. -/
inductive Outcome | keep | discard | inconclusive | error
  deriving BEq, Repr, Inhabited

def Outcome.name : Outcome → String
  | .keep => "KEEP" | .discard => "DISCARD" | .inconclusive => "INCONCLUSIVE" | .error => "ERROR"

def Outcome.exitCode : Outcome → UInt32
  | .keep => 0 | .discard => 1 | .error => 2 | .inconclusive => 3

/-- The verdict of a run-time experiment, once the build, the guard, the tests
and the outputs passed: from the exact counts of `measure` (time not judged)
and the paired timing of the plain binaries (`none`: not timed, because the
exact counts got worse). -/
def combine (exact : Judge.Verdict) (paired : Option Judge.Verdict) : Outcome × Array String :=
  if !exact.worse.isEmpty then (.discard, exact.worse.map ("exact counts: " ++ ·))
  else if !exact.coverage.isEmpty then (.inconclusive, exact.coverage.map ("exact counts: " ++ ·))
  else match paired with
    | none => (.discard, #["exact counts got worse"])
    | some p =>
      if !p.worse.isEmpty then (.discard, p.worse)
      else if !exact.better.isEmpty || !p.better.isEmpty then (.keep, exact.better ++ p.better)
      else if p.unsettled then
        (.inconclusive, #["neither the exact counts nor the paired time changed beyond noise, and the time " ++
          "was not settled (more pairs, --pairs N, or a quieter machine may settle it)"])
      else (.discard, #["no measurable improvement: exact counts unchanged and paired time within the --min-change"])

/-- What `combine`'s verdict means (`Contract.Outcome`). -/
def combineOutcome (exact : Judge.Verdict) (paired : Option Judge.Verdict) : Contract.Outcome :=
  if !exact.worse.isEmpty || !exact.coverage.isEmpty then exact.outcome
  else match paired with
    | none => .regression
    | some p =>
      if !p.worse.isEmpty then p.outcome
      else if !exact.better.isEmpty || !p.better.isEmpty then .improved
      else if p.unsettled then .insufficientEvidence
      else .noImprovement

/-- The outcome a verdict word means when nothing more specific is known. -/
def Outcome.default : Outcome → Contract.Outcome
  | .keep => .improved | .discard => .noImprovement | .inconclusive => .insufficientEvidence
  | .error => .measurementFailed

/-- A compile-time verdict: from two heartbeat summaries (`Judge.judge`'s
heartbeat rule: the total must go down by more than 1% and 1,000). -/
def heartbeatOutcome (v : Judge.Verdict) : Outcome × Array String :=
  if !v.worse.isEmpty then (.discard, v.worse)
  else if !v.coverage.isEmpty then (.inconclusive, v.coverage)
  else if !v.better.isEmpty then (.keep, v.better)
  else (.discard, #["compile heartbeats did not go down by more than 1% and 1,000"])

/-- 64-bit FNV-1a of `b` as hex: a stable fingerprint of an output (not
cryptographic), as `measure` and `measure-pair` hash them. -/
def hashOf (b : ByteArray) : String := Id.run do
  let mut h : UInt64 := 14695981039346656037
  for x in b do h := (h ^^^ x.toUInt64) * 1099511628211
  let hex := Nat.toDigits 16 h.toNat
  return "fnv1a64:" ++ String.ofList (List.replicate (16 - hex.length) '0' ++ hex)

/-! ## State -/

/-- How a program behaved on one case: hashes, so held-out results can be
recorded without their contents. -/
structure CaseSig where
  args : Array String
  exit_code : Nat
  stdout : String
  stderr : String
  /-- each output file named with `--check-output`, and its hash (`missing`) -/
  files : Array (String × String)
  deriving ToJson, FromJson, BEq, Inhabited

structure InputFile where
  path : String
  hash : String
  deriving ToJson, FromJson, Inhabited

structure TryRecord where
  n : Nat
  verdict : String
  candidate : String
  source : String
  base : String
  reasons : Array String
  committed : Option String := none
  evidence : String
  deriving ToJson, FromJson, Inhabited

structure State where
  version : Nat := 1
  leanprof : String := "experiment"
  id : String
  created : String
  /-- the repository's top directory and the package's directory below it (`regex/`, or empty) -/
  top : String
  pkg_prefix : String
  /-- `exe`: run time; `library`: compile heartbeats -/
  mode : String
  exe : String := ""
  args : Array String := #[]
  /-- the argument lists checked for identical behaviour; the first is the timed workload -/
  cases : Array (Array String) := #[]
  heldout : Array (Array String) := #[]
  check_outputs : Array String := #[]
  /-- lines of stdout and stderr containing any of these are not compared (a program's own timings) -/
  ignore_lines : Array String := #[]
  inputs : Array InputFile := #[]
  test : Option String := none
  protect : Array String := #[]
  runs : Nat := 3
  pairs : Nat := 30
  min_change : Float := 1
  deps : Bool := true
  start_commit : String
  base_commit : String
  base_summary : String := ""
  base_bin : String := ""
  baseline : Array CaseSig := #[]
  heldout_baseline : Array CaseSig := #[]
  tries : Array TryRecord := #[]
  finished : Bool := false
  deriving ToJson, FromJson, Inhabited

/-! ## Files and processes -/

def experimentsDir (proj : FilePath) : FilePath := proj / ".lake" / "leanprof" / "experiments"

/-- An experiment id names a directory: letters, digits, `-` and `_` only. -/
def validId (i : String) : Bool := !i.isEmpty && i.all fun c => c.isAlphanum || c == '-' || c == '_'

def under (root : FilePath) (pre : String) : FilePath :=
  if pre.isEmpty then root else root / ((pre.dropEndWhile (· == '/')).toString)

def statePath (proj : FilePath) (id : String) : FilePath := experimentsDir proj / id / "experiment.json"

def saveState (proj : FilePath) (s : State) : IO Unit :=
  IO.FS.writeFile (statePath proj s.id) ((Contract.withSchema "experiment-status" (toJson s)).pretty ++ "\n")

def loadState (proj : FilePath) (id? : Option String) : IO State := do
  let id ← match id? with
    | some i => pure i
    | none => do
      let cur := experimentsDir proj / "current"
      unless ← cur.pathExists do
        throw <| IO.userError "no experiment here: start one with `leanprof experiment start`"
      pure (trim (← IO.FS.readFile cur))
  unless validId id do throw <| IO.userError s!"not an experiment id: {id} (letters, digits, - and _)"
  let p := statePath proj id
  unless ← p.pathExists do throw <| IO.userError s!"no experiment {id} ({p} is missing)"
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile p))
  match fromJson? j with
  | .ok s => return s
  | .error e => throw <| IO.userError s!"{p}: {e}"

/-- Appends each step's output to a log. -/
structure Log where
  path : FilePath

def Log.write (l : Log) (title : String) (out : IO.Process.Output) : IO Unit := do
  let h ← IO.FS.Handle.mk l.path .append
  h.putStr s!"== {title} (exit code {out.exitCode})\n{out.stdout}{out.stderr}\n"

def Log.note (l : Log) (s : String) : IO Unit := do
  let h ← IO.FS.Handle.mk l.path .append
  h.putStrLn s

def hashFile (p : FilePath) : IO String := do
  if ← p.pathExists then return hashOf (← IO.FS.readBinFile p) else return "missing"

/-- `cp -cRp` (a copy-on-write clone where the file system has them), else `cp -Rp`. -/
def copyTree (src dst : FilePath) : IO Bool := do
  if (← capture "cp" #["-cRp", src.toString, dst.toString]).exitCode == 0 then return true
  if ← dst.pathExists then IO.FS.removeDirAll dst
  return (← capture "cp" #["-Rp", src.toString, dst.toString]).exitCode == 0

def copyFile (src dst : FilePath) : IO Unit := do
  let out ← capture "cp" #["-p", src.toString, dst.toString]
  unless out.exitCode == 0 do throw <| IO.userError s!"could not copy {src}: {out.stderr}"

/-- A git worktree of `commit` at `root`, with the project's `.lake/packages`
linked in; a new one starts from a copy of `seed`'s `.lake/build`. An
existing one is checked out at `commit` and cleaned (ignored files, and
`.lake`, stay), so its build is kept and only what changed is rebuilt. -/
def ensureWorktree (root : FilePath) (commit : String) (proj : FilePath) (pre : String)
    (seed : Option FilePath) : IO Unit := do
  let ok ← if ← (root / ".git").pathExists then
      pure ((← gitRaw #["rev-parse", "--is-inside-work-tree"] (cwd := root)).exitCode == 0)
    else pure false
  if ok then
    discard <| git #["checkout", "-q", "--detach", "--force", commit] (cwd := root)
    discard <| git #["clean", "-fdq", "-e", ".lake"] (cwd := root)
    return
  discard <| gitRaw #["worktree", "remove", "--force", root.toString]
  if ← root.pathExists then IO.FS.removeDirAll root
  discard <| gitRaw #["worktree", "prune"]
  discard <| git #["worktree", "add", "--detach", "-q", root.toString, commit]
  let dir := under root pre
  if ← (proj / ".lake" / "packages").pathExists then
    IO.FS.createDirAll (dir / ".lake")
    discard <| capture "ln" #["-s", (proj / ".lake" / "packages").toString, (dir / ".lake" / "packages").toString]
  if let some src := seed then
    if ← (src / ".lake" / "build").pathExists then
      IO.FS.createDirAll (dir / ".lake")
      discard <| copyTree (src / ".lake" / "build") (dir / ".lake" / "build")

def removeWorktree (root : FilePath) : IO Unit := do
  let r ← gitRaw #["worktree", "remove", "--force", root.toString] (stop := false)
  if r.exitCode != 0 then
    try IO.FS.removeDirAll root catch _ => pure ()
  discard <| gitRaw #["worktree", "prune"] (stop := false)

/-- `lake build ARGS` in `dir`: the error's last lines, or the seconds it took. -/
def lakeBuild (log : Log) (dir : FilePath) (targets : Array String) : IO (Except String Float) := do
  let t0 ← IO.monoNanosNow
  let out ← capture "lake" (#["build"] ++ targets) (cwd := dir)
  log.write s!"lake build {" ".intercalate targets.toList} in {dir}" out
  if out.exitCode != 0 then return .error (tailOf (out.stdout ++ out.stderr))
  return .ok (((← IO.monoNanosNow) - t0).toFloat / 1e9)

/-- The build of a try or of the baseline: the default targets (the
library and its proofs), then the executable. -/
def buildAll (log : Log) (s : State) (dir : FilePath) : IO (Except String Float) := do
  match ← lakeBuild log dir #[] with
  | .error e => return .error e
  | .ok t =>
    if s.mode != "exe" then return .ok t
    match ← lakeBuild log dir #[s.exe] with
    | .error e => return .error e
    | .ok t2 => return .ok (t + t2)

def runTests (log : Log) (s : State) (dir : FilePath) : IO (Except String Unit) := do
  let some t := s.test | return .ok ()
  let out ← capture "sh" #["-c", t] (cwd := dir)
  log.write s!"tests: {t}" out
  return if out.exitCode == 0 then .ok () else .error (tailOf (out.stdout ++ out.stderr))

/-- One case, the plain binary run as `lake exe` would run it in `dir`. -/
def runCase (s : State) (dir : FilePath) (bin : FilePath) (args : Array String) :
    IO (CaseSig × String × String) := do
  for f in s.check_outputs do
    let p := dir / f
    if ← p.pathExists then IO.FS.removeFile p
  let out ← capture "lake" (#["env", bin.toString] ++ args) (cwd := dir)
  let (stdout, stderr) := (Judge.dropLines s.ignore_lines out.stdout, Judge.dropLines s.ignore_lines out.stderr)
  let mut files := #[]
  for f in s.check_outputs do files := files.push (f, ← hashFile (dir / f))
  let sig : CaseSig := {
    args, exit_code := out.exitCode.toNat, stdout := hashOf stdout.toUTF8,
    stderr := hashOf stderr.toUTF8, files }
  return (sig, stdout, stderr)

/-- How two runs of a case differ, in words. -/
def caseDifference (a b : CaseSig) (aOut bOut aErr bErr : String) : String := Id.run do
  let mut ds := #[]
  if a.exit_code != b.exit_code then ds := ds.push s!"exit code {a.exit_code} -> {b.exit_code}"
  if a.stdout != b.stdout then
    ds := ds.push (if aOut.isEmpty && bOut.isEmpty then "stdout changed" else s!"stdout, {Fix.firstDifference aOut bOut}")
  if a.stderr != b.stderr then
    ds := ds.push (if aErr.isEmpty && bErr.isEmpty then "stderr changed" else s!"stderr, {Fix.firstDifference aErr bErr}")
  for ((f, h1), (_, h2)) in a.files.zip b.files do
    if h1 != h2 then ds := ds.push s!"{f} changed ({h1} -> {h2})"
  return "; ".intercalate ds.toList

def argsText (args : Array String) : String := " ".intercalate (args.toList.map shellQuote)

def fmtS (secs : Float) : String := s!"{Judge.fmt2 secs} s"

/-- The package's Lean files, relative to its directory (without `.lake`
and hidden directories). -/
partial def leanFiles (dir : FilePath) (rel : String := "") : IO (Array String) := do
  let mut out := #[]
  let here := if rel.isEmpty then dir else dir / rel
  for e in ← here.readDir do
    if e.fileName.startsWith "." then continue
    let r := if rel.isEmpty then e.fileName else rel ++ "/" ++ e.fileName
    if ← e.path.isDir then out := out ++ (← leanFiles dir r)
    else if e.fileName.endsWith ".lean" && r != "lakefile.lean" then out := out.push r
  return out

/-- Whether a module was built (its `.olean` is in the build): modules the
default layout names but Lake does not know (files under an executable's
`srcDir`) are left out of the audit and the heartbeats. -/
def built (dir : FilePath) (m : String) : IO Bool := do
  let rel := (m.replace "." "/") ++ ".olean"
  return (← (dir / ".lake" / "build" / "lib" / "lean" / rel).pathExists) ||
    (← (dir / ".lake" / "build" / "lib" / rel).pathExists)

/-- The package's module import graph, by the default layout. -/
def importGraph (dir : FilePath) : IO (Array (String × Array String)) := do
  let mut out := #[]
  for f in ← leanFiles dir do
    if let some m := moduleOfPath f then
      out := out.push (m, parseImports (← IO.FS.readFile (dir / f)))
  return out

/-- Every C file Lean generated for the package, by path, and its hash. -/
partial def irHashes (dir : FilePath) : IO (Std.HashMap String String) := do
  let root := dir / ".lake" / "build" / "ir"
  let rec go (d : FilePath) (rel : String) (acc : Std.HashMap String String) : IO (Std.HashMap String String) := do
    let mut acc := acc
    unless ← d.pathExists do return acc
    for e in ← d.readDir do
      let r := if rel.isEmpty then e.fileName else rel ++ "/" ++ e.fileName
      if ← e.path.isDir then acc ← go e.path r acc
      else if e.fileName.endsWith ".c" then acc := acc.insert r (hashOf (← IO.FS.readBinFile e.path))
    return acc
  go root "" {}

/-- Heartbeats per declaration, from an `elab --heartbeats` report. -/
def heartbeatsOf (path : FilePath) : IO (Std.HashMap String Float) := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
  let mut m : Std.HashMap String Float := {}
  for sc in jarr j "scopes" do
    let key := if (jstr sc "key").isEmpty then s!"{jstr sc "name"} {jstr sc "pos"}" else jstr sc "key"
    m := m.insert key (m.getD key 0 + Explain.jnum sc "total_ns")
  return m

def hbTotal (m : Std.HashMap String Float) : Float := m.fold (fun a _ v => a + v) 0

/-! ## The commands -/

structure StartOpts where
  exe : Option String := none
  args : Array String := #[]
  inputs : Option String := none
  cases : Option String := none
  heldout : Option String := none
  checkOutputs : Array String := #[]
  ignoreLines : Array String := #[]
  test : Option String := none
  noTest : Bool := false
  protect : Array String := #[]
  runs : Nat := 3
  pairs : Nat := 30
  minChange : Float := 1
  deps : Bool := true
  base : String := "HEAD"
  id : Option String := none
  json : Bool := false

partial def parseStart (o : StartOpts) : List String → Except String StartOpts
  | [] => .ok o
  | "--exe" :: e :: rest =>
    if e.isEmpty || e.startsWith "-" || e.contains '/' then .error "--exe needs the name of a Lake executable"
    else parseStart { o with exe := some e } rest
  | "--inputs" :: d :: rest => parseStart { o with inputs := some d } rest
  | "--cases" :: f :: rest => parseStart { o with cases := some f } rest
  | "--heldout" :: d :: rest => parseStart { o with heldout := some d } rest
  | "--check-output" :: f :: rest =>
    if (f : FilePath).isAbsolute || (f : FilePath).components.contains ".." then
      .error "--check-output takes a path relative to the package directory"
    else parseStart { o with checkOutputs := o.checkOutputs.push f } rest
  | "--test" :: c :: rest => parseStart { o with test := some c } rest
  | "--ignore-lines" :: t :: rest =>
    if t.isEmpty then .error "--ignore-lines needs a text" else parseStart { o with ignoreLines := o.ignoreLines.push t } rest
  | "--no-test" :: rest => parseStart { o with noTest := true } rest
  | "--protect" :: g :: rest => parseStart { o with protect := o.protect.push g } rest
  | "--runs" :: n :: rest => do
    let some k := n.toNat? | throw "--runs must be a number from 1 to 100"
    unless k ≥ 1 && k ≤ 100 do throw "--runs must be a number from 1 to 100"
    parseStart { o with runs := k } rest
  | "--pairs" :: n :: rest => do
    let some k := n.toNat? | throw "--pairs must be a number from 6 to 1000"
    unless k ≥ 6 && k ≤ 1000 do throw "--pairs must be a number from 6 to 1000"
    parseStart { o with pairs := k } rest
  | "--min-change" :: x :: rest => do
    let some pct := (Lean.Json.parse x).toOption.bind (·.getNum?.toOption) |>.map (·.toFloat)
      | throw "--min-change must be a percentage from 0 to 100"
    unless pct ≥ 0 && pct ≤ 100 do throw "--min-change must be a percentage from 0 to 100"
    parseStart { o with minChange := pct } rest
  | "--no-deps" :: rest => parseStart { o with deps := false } rest
  | "--base" :: r :: rest => parseStart { o with base := r } rest
  | "--id" :: i :: rest =>
    if validId i then parseStart { o with id := some i } rest
    else .error "--id takes letters, digits, - and _"
  | "--json" :: rest => parseStart { o with json := true } rest
  | "--" :: rest => .ok { o with args := o.args ++ rest.toArray }
  | a :: _ => .error s!"unknown or incomplete experiment start option: {a}"

/-- The files of an inputs directory (or the one file named), sorted, absolute. -/
def inputFiles (p : FilePath) : IO (Array FilePath) := do
  unless ← p.pathExists do throw <| IO.userError s!"no such inputs: {p}"
  let p ← IO.FS.realPath p
  if !(← p.isDir) then return #[p]
  let mut out := #[]
  for e in ← p.readDir do
    if e.fileName.startsWith "." then continue
    unless ← e.path.isDir do out := out.push e.path
  if out.isEmpty then throw <| IO.userError s!"{p} has no input files"
  return out.qsort (·.toString < ·.toString)

/-- The protect pattern for an inputs path inside the repository. -/
def protectFor (top : FilePath) (p : FilePath) : IO (Option String) := do
  let real ← IO.FS.realPath p
  let t := top.toString ++ "/"
  unless real.toString.startsWith t do return none
  let rel := (real.toString.drop t.length).toString
  return some (if ← real.isDir then rel ++ "/**" else rel)

def nowText : IO String := do
  let out ← capture "date" #["-u", "+%Y-%m-%dT%H:%M:%SZ"]
  return trim out.stdout

def newId : IO String := do
  let out ← capture "date" #["-u", "+%Y%m%d-%H%M%S"]
  return trim out.stdout

structure Ctx where
  proj : FilePath
  runSelf : Array String → FilePath → IO IO.Process.Output

def expDir (c : Ctx) (s : State) : FilePath := experimentsDir c.proj / s.id
def baseRoot (c : Ctx) (s : State) : FilePath := expDir c s / "base"
def candRoot (c : Ctx) (s : State) : FilePath := expDir c s / "candidate"
def baseDir (c : Ctx) (s : State) : FilePath := under (baseRoot c s) s.pkg_prefix
def candDir (c : Ctx) (s : State) : FilePath := under (candRoot c s) s.pkg_prefix

def checkArgs (s : State) : Array String :=
  (match s.check_outputs[0]? with | some f => #["--check-output", f] | none => #[]) ++
    s.ignore_lines.flatMap (#["--ignore-lines", ·])

/-- `measure` of the workload in `dir` into `out`. -/
def measure (c : Ctx) (log : Log) (s : State) (dir out : FilePath) : IO (Except String Judge.Summary) := do
  let args := s.cases[0]?.getD s.args
  let r ← c.runSelf (#["measure", "--runs", toString s.runs] ++ (if s.deps then #[] else #["--no-deps"]) ++
    checkArgs s ++ #["--out", out.toString, s.exe, "--"] ++ args) dir
  log.write s!"leanprof measure into {out}" r
  if r.exitCode != 0 then return .error (tailOf (r.stdout ++ r.stderr))
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile out))
  return Judge.Summary.ofJson j

def startCmd (c : Ctx) (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parseStart {} argv)
  unless (← gitRaw #["rev-parse", "--is-inside-work-tree"]).exitCode == 0 do
    throw <| IO.userError "not in a git repository: an experiment checks each candidate in a git worktree"
  let top : FilePath ← IO.FS.realPath (← git #["rev-parse", "--show-toplevel"])
  let pre ← git #["rev-parse", "--show-prefix"]
  if let some why ← Fix.outsidePathDeps c.proj top then
    throw <| IO.userError (why.replace "apply the fix by hand (--dry-run prints it)" "run the checks by hand")
  if o.exe.isNone && (o.inputs.isSome || o.cases.isSome || o.heldout.isSome || !o.args.isEmpty) then
    throw <| IO.userError "--inputs, --cases, --heldout and ARGS need --exe EXE (without it the measure is compile heartbeats)"
  let commit ← git #["rev-parse", "--verify", "--quiet", o.base ++ "^{commit}"]
  let id ← match o.id with | some i => pure i | none => newId
  if ← (experimentsDir c.proj / id).pathExists then
    throw <| IO.userError s!"an experiment {id} exists already ({experimentsDir c.proj / id}); give another --id"
  -- the cases: the workload, then one per input or per line of --cases
  let mut cases : Array (Array String) := #[]
  let mut heldout : Array (Array String) := #[]
  let mut inputs : Array InputFile := #[]
  let mut protect := o.protect
  let addInputs (dir : String) : IO (Array FilePath) := inputFiles dir
  let hasHole := o.args.any (·.contains "{}")
  if o.exe.isSome && !hasHole then cases := cases.push o.args
  if let some d := o.inputs then
    for f in ← addInputs d do
      cases := cases.push (substInput o.args f.toString)
      inputs := inputs.push { path := f.toString, hash := ← hashFile f }
    if let some g ← protectFor top d then protect := protect.push g
  if let some f := o.cases then
    for a in parseCases (← IO.FS.readFile f) do cases := cases.push a
    inputs := inputs.push { path := (← IO.FS.realPath f).toString, hash := ← hashFile f }
    if let some g ← protectFor top f then protect := protect.push g
  if let some d := o.heldout then
    for f in ← addInputs d do
      heldout := heldout.push (substInput o.args f.toString)
      inputs := inputs.push { path := f.toString, hash := ← hashFile f }
    if let some g ← protectFor top d then protect := protect.push g
  if o.exe.isSome && cases.isEmpty then
    throw <| IO.userError "ARGS has {} but no --inputs: nothing to run"
  let dir := experimentsDir c.proj / id
  IO.FS.createDirAll dir
  let log : Log := { path := dir / "start-log.txt" }
  IO.FS.writeFile log.path ""
  let mut s : State := {
    id, created := ← nowText, top := top.toString, pkg_prefix := pre
    mode := if o.exe.isSome then "exe" else "library", exe := o.exe.getD "", args := o.args
    cases, heldout, check_outputs := o.checkOutputs, ignore_lines := o.ignoreLines, inputs, protect
    runs := o.runs, pairs := o.pairs, min_change := o.minChange, deps := o.deps
    start_commit := commit, base_commit := commit }
  IO.println s!"leanprof experiment start: {id}, base {commit.take 12} ({o.base}){if pre.isEmpty then "" else s!", package in {pre}"}"
  IO.println s!"  in a git worktree of the base ({baseRoot c s}); the steps' output is in {log.path}"
  ensureWorktree (baseRoot c s) commit c.proj pre (some c.proj)
  let bdir := baseDir c s
  -- tests: --test CMD, or the Lake test driver
  let test ← if o.noTest then pure none else match o.test with
    | some t => pure (some t)
    | none => do
      if (← capture "lake" #["check-test"] (cwd := bdir)).exitCode == 0 then pure (some "lake test") else pure none
  s := { s with test }
  let fail (why : String) : IO UInt32 := do
    IO.eprintln s!"leanprof experiment start: {why}"
    IO.eprintln s!"  (the steps' output is in {log.path}; nothing was recorded)"
    removeWorktree (baseRoot c s)
    IO.FS.removeDirAll dir
    return 2
  let buildS ← match ← buildAll log s bdir with
    | .ok t => pure t
    | .error e => return ← fail s!"the base does not build:\n{e}"
  IO.println s!"  build      ok ({fmtS buildS}): lake build{if s.mode == "exe" then s!", lake build {s.exe}" else ""}"
  if let .error e ← runTests log s bdir then return ← fail s!"the tests fail on the base ({s.test.getD ""}):\n{e}"
  IO.println s!"  tests      {match s.test with | some t => s!"pass (`{t}`)" | none => "none (no --test CMD and no Lake test driver)"}"
  if s.mode == "exe" then
    let bin := bdir / ".lake" / "build" / "bin" / s.exe
    copyFile bin (dir / "base-bin")
    -- every case twice: an output that varies between runs cannot be compared
    let mut baseline := #[]
    IO.FS.createDirAll (dir / "baseline")
    for h : k in [0:cases.size] do
      let (a, aOut, aErr) ← runCase s bdir bin cases[k]
      let (b, bOut, bErr) ← runCase s bdir bin cases[k]
      unless a == b do
        return ← fail (s!"case {k} ({argsText cases[k]}) behaves differently on two runs of the base: " ++
          s!"{caseDifference a b aOut bOut aErr bErr}; make it deterministic or compare an output file (--check-output)")
      IO.FS.writeFile (dir / "baseline" / s!"case-{k}.stdout") aOut
      IO.FS.writeFile (dir / "baseline" / s!"case-{k}.stderr") aErr
      baseline := baseline.push a
    let mut held := #[]
    for args in heldout do
      let (a, _, _) ← runCase s bdir bin args
      held := held.push a
    s := { s with baseline, heldout_baseline := held, base_bin := (dir / "base-bin").toString }
    let first := if hasHole then "the first input is the timed workload" else s!"the workload and {cases.size - 1} more"
    IO.println (s!"  cases      {cases.size} ({first}), " ++
      s!"each the same on two runs (stdout, stderr, exit code{if s.check_outputs.isEmpty then "" else ", " ++ ", ".intercalate s.check_outputs.toList})" ++
      (if heldout.isEmpty then "" else s!"; {heldout.size} held out (recorded as hashes, run by finish)"))
    match ← measure c log s bdir (dir / "base.json") with
    | .error e => return ← fail s!"measuring the base failed:\n{e}"
    | .ok sum =>
      s := { s with base_summary := (dir / "base.json").toString }
      let allocs := match sum.allocs with | some (n, _, _) => s!", allocations {Judge.groupDigits n}" | none => ""
      IO.println s!"  measure    copies {Judge.groupDigits sum.copies}{allocs}, time median {Judge.fmtMs sum.median} ({s.runs} runs, with probes)"
  else
    IO.println "  measure    compile heartbeats of the modules each candidate changes and of their dependents"
  saveState c.proj s
  IO.FS.writeFile (experimentsDir c.proj / "current") (id ++ "\n")
  IO.println s!"\nrecorded in {statePath c.proj id}"
  IO.println "next: change the code, then `leanprof experiment try --working-tree` (or `try REV` for a commit)"
  return 0

structure TryOpts where
  rev : Option String := none
  workingTree : Bool := false
  id : Option String := none
  time : Bool := false
  commit : Bool := true
  message : Option String := none
  allowOverloaded : Bool := false
  json : Bool := false

partial def parseTry (o : TryOpts) : List String → Except String TryOpts
  | [] => .ok o
  | "--working-tree" :: rest => parseTry { o with workingTree := true } rest
  | "--id" :: i :: rest => parseTry { o with id := some i } rest
  | "--time" :: rest => parseTry { o with time := true } rest
  | "--no-commit" :: rest => parseTry { o with commit := false } rest
  | "--message" :: m :: rest => parseTry { o with message := some m } rest
  | "--allow-overloaded" :: rest => parseTry { o with allowOverloaded := true } rest
  | "--json" :: rest => parseTry { o with json := true } rest
  | a :: rest =>
    if a.startsWith "-" then .error s!"unknown or incomplete experiment try option: {a}"
    else if o.rev.isSome then .error s!"one candidate at a time: {o.rev.get!} and {a}"
    else parseTry { o with rev := some a } rest

/-- The working tree (tracked changes and untracked files that are not
ignored) as a commit on top of HEAD, made with a separate index: the
checkout, its index and its stash are not touched. -/
def snapshotWorkingTree (dir : FilePath) (top : FilePath) : IO (String × String) := do
  let head ← git #["rev-parse", "HEAD"]
  let idx := dir / "index"
  let real ← git #["rev-parse", "--git-path", "index"] (cwd := top)
  let realP : FilePath := if (real : FilePath).isAbsolute then real else top / real
  if ← realP.pathExists then copyFile realP idx
  let env := #[("GIT_INDEX_FILE", some idx.toString)]
  let gitEnv (args : Array String) : IO String := do
    let out ← capture "git" (#["-c", "core.hooksPath=/dev/null"] ++ args) env (cwd := top)
    unless out.exitCode == 0 do throw <| IO.userError s!"git {" ".intercalate args.toList} failed: {trim out.stderr}"
    return trim out.stdout
  discard <| gitEnv #["add", "-A", "--", "."]
  let tree ← gitEnv #["write-tree"]
  let commit ← gitEnv #["commit-tree", tree, "-p", head, "-m", "leanprof experiment: the working tree"]
  if ← idx.pathExists then IO.FS.removeFile idx
  return (commit, head)

def tryCmd (c : Ctx) (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parseTry {} argv)
  let s0 ← loadState c.proj o.id
  if s0.finished then throw <| IO.userError s!"experiment {s0.id} is finished; start a new one"
  if o.workingTree && o.rev.isSome then throw <| IO.userError "give REV or --working-tree, not both"
  let stRef ← IO.mkRef s0
  let s := s0
  let t0 ← IO.monoNanosNow
  let top : FilePath := s.top
  let n := s.tries.size + 1
  let tdir := expDir c s / "tries" / toString n
  if ← tdir.pathExists then IO.FS.removeDirAll tdir
  IO.FS.createDirAll tdir
  let log : Log := { path := tdir / "log.txt" }
  IO.FS.writeFile log.path ""
  let (cand, source, parent) ← if o.workingTree then do
      let (cm, head) ← snapshotWorkingTree tdir top
      pure (cm, "working-tree", some head)
    else
      let r := o.rev.getD "HEAD"
      pure (← git #["rev-parse", "--verify", "--quiet", r ++ "^{commit}"], s!"rev {r}", none)
  -- the candidate stays reachable: its evidence names it
  discard <| git #["update-ref", s!"refs/leanprof/experiments/{s.id}/try-{n}", cand]
  let base := s.base_commit
  let lines ← IO.mkRef (#[] : Array String)
  let say (step text : String) : IO Unit := do
    let l := s!"  {step}{String.ofList (List.replicate (11 - min 11 step.length) ' ')}{text}"
    unless o.json do IO.println l
    lines.modify (·.push l)
  let steps ← IO.mkRef (#[] : Array (String × Json))
  let step (k : String) (v : Json) : IO Unit := steps.modify (·.push (k, v))
  unless o.json do
    IO.println s!"leanprof experiment try {n} ({s.id}): candidate {cand.take 12} ({source}) against base {base.take 12}"
  let changed := ((← git #["diff", "--name-only", "--no-renames", base, cand] (cwd := top)).splitOn "\n").filter (· != "") |>.toArray
  step "changed_files" (toJson changed)
  -- the verdict, the evidence file, the experiment's record and the summary
  let finish (out : Outcome) (reasons : Array String) (committed : Option String := none)
      (cat : Option Contract.Outcome := none) : IO UInt32 := do
    let secs := ((← IO.monoNanosNow) - t0).toFloat / 1e9
    let cat := cat.getD out.default
    let evidence := Json.mkObj ([("version", toJson (1 : Nat)), ("schema", Contract.schema "experiment-try"), ("leanprof", Json.str "experiment-try"),
      ("experiment", Json.str s.id), ("try", toJson n), ("verdict", Json.str out.name),
      ("reasons", toJson reasons), ("mode", Json.str s.mode)] ++ cat.json ++ [
      ("base_commit", Json.str base), ("candidate_commit", Json.str cand), ("candidate_source", Json.str source),
      ("committed", match committed with | some x => Json.str x | none => Json.null),
      ("seconds", toJson secs),
      ("provenance", ← Contract.provenance (← Contract.workload s.exe s.args) (Json.mkObj [("mode", Json.str s.mode),
        ("runs", toJson s.runs), ("pairs", toJson s.pairs), ("min_change", toJson s.min_change)]))] ++
      (← steps.get).toList)
    let ePath := tdir / "evidence.json"
    IO.FS.writeFile ePath (evidence.pretty ++ "\n")
    let r : TryRecord := {
      n, verdict := out.name, candidate := cand, source, base, reasons, committed,
      evidence := ePath.toString }
    stRef.modify fun st => { st with tries := st.tries.push r }
    saveState c.proj (← stRef.get)
    if o.json then IO.println evidence.pretty
    else
      IO.println s!"{out.name}{if reasons.isEmpty then "" else ":"}"
      for x in reasons do IO.println (Explain.wrap s!"  - {x}" "    ")
      if let some x := committed then IO.println s!"  committed {x.take 12} on your branch, with the evidence in its message"
      IO.println s!"  evidence: {ePath} ({fmtS secs})"
    return out.exitCode
  -- KEEP: evidence in git, and the candidate becomes the base
  let keep (reasons : Array String) (summary : Option FilePath) (bin : Option FilePath) : IO UInt32 := do
    let subject := o.message.getD s!"leanprof experiment {s.id}, try {n}"
    let msg := s!"{subject}\n\n" ++
      s!"leanprof experiment {s.id}, try {n}: KEEP against {base.take 12}\n" ++
      "\n".intercalate ((← lines.get).toList) ++ "\n" ++
      "\n".intercalate (reasons.toList.map ("- " ++ ·)) ++ "\n"
    let msgFile := tdir / "commit-message.txt"
    IO.FS.writeFile msgFile msg
    let mut committed : Option String := none
    let mut newBase := cand
    if source == "working-tree" && o.commit then
      let head ← git #["rev-parse", "HEAD"]
      if parent == some head then
        let tree ← git #["rev-parse", s!"{cand}^\{tree}"]
        let c' ← git #["commit-tree", tree, "-p", head, "-F", msgFile.toString] (cwd := top)
        discard <| git #["update-ref", "-m", s!"leanprof experiment {s.id} try {n}", "HEAD", c', head] (cwd := top)
        -- the index follows the new commit; the working tree is the commit
        discard <| git #["reset", "-q"] (cwd := top)
        committed := some c'
        newBase := c'
      else
        say "commit" s!"not committed: HEAD moved from {(parent.getD "").take 12} to {head.take 12} during the try"
    else if source != "working-tree" then
      discard <| gitRaw #["notes", "--ref=leanprof-experiments", "add", "-f", "-F", msgFile.toString, cand] (cwd := top)
    if let some b := bin then copyFile b (expDir c s / "base-bin")
    stRef.modify fun st => { st with
      base_commit := newBase
      base_summary := match summary with | some p => p.toString | none => st.base_summary }
    finish .keep reasons committed
  if changed.isEmpty then
    step "guard" (Json.mkObj [("status", "PASS"), ("note", "nothing changed")])
    return ← finish .discard #["the candidate changes nothing against the base"] (cat := some .noImprovement)
  -- inputs must be the ones recorded
  for i in s.inputs do
    if (← hashFile i.path) != i.hash then
      return ← finish .error #[s!"the input {i.path} changed since the experiment started: start a new experiment"]
  -- the build configuration: the worktrees share .lake/packages, which a
  -- different manifest would make Lake update
  let pre := s.pkg_prefix
  let config := changed.filter fun f => match inPackage pre f with
    | some r => r == "lake-manifest.json" || r == "lakefile.lean" || r == "lakefile.toml" || r == "lean-toolchain"
    | none => false
  unless config.isEmpty do
    step "guard" (Json.mkObj [("status", "INCONCLUSIVE"), ("changed_build_configuration", toJson config)])
    return ← finish .inconclusive #[s!"the candidate changes the build configuration ({", ".intercalate config.toList}); " ++
      "an experiment compares code under one configuration (its worktrees share .lake/packages)"] (cat := some .incompatible)
  try
    -- the base as the experiment recorded it (an interrupted try may have
    -- left its worktree elsewhere), then the candidate from the base's build
    ensureWorktree (baseRoot c s) base c.proj pre (some c.proj)
    let bdir := baseDir c s
    if let .error e ← buildAll log s bdir then
      return ← finish .error #[s!"the base no longer builds in its worktree:\n{e}"]
    ensureWorktree (candRoot c s) cand c.proj pre (some bdir)
    let cdir := candDir c s
    -- 1. build
    match ← buildAll log s cdir with
    | .error e =>
      step "build" (Json.mkObj [("ok", Json.bool false), ("error", Json.str e)])
      say "build" "FAILED"
      return ← finish .discard #[s!"it does not build:\n{e}"] (cat := some .correctnessFailure)
    | .ok t =>
      step "build" (Json.mkObj [("ok", Json.bool true), ("seconds", toJson t)])
      say "build" s!"ok ({fmtS t})"
    -- 2. the guard, on the changed modules and their dependents in the package
    let changedMods := changed.filterMap fun f => (inPackage pre f).bind moduleOfPath
    let deps := dependents (← importGraph cdir) changedMods
    let mut audited := #[]
    for m in changedMods ++ deps do
      if (← built cdir m) && (← built bdir m) then audited := audited.push m
    -- the modules that import the change must build too (a test module's
    -- `#guard` fails there), before the auditor builds them for its evidence
    let extra := audited.filter (!changedMods.contains ·)
    unless extra.isEmpty do
      if let .error e ← lakeBuild log cdir extra then
        step "build" (Json.mkObj [("ok", Json.bool false), ("modules", toJson extra), ("error", Json.str e)])
        say "build" s!"FAILED: the modules that import the change ({extra.size})"
        return ← finish .discard #[s!"a module that imports the change does not build:\n{e}"] (cat := some .correctnessFailure)
    let adir := expDir c s / "audit"
    IO.FS.createDirAll adir
    IO.FS.writeFile (adir / "audit.py") auditScript
    IO.FS.writeFile (adir / "Snapshot.lean") auditSnapshot
    let subdir := (pre.dropEndWhile (· == '/')).toString
    let auditArgs := #["-B", (adir / "audit.py").toString, "--base", (baseRoot c s).toString,
        "--candidate", (candRoot c s).toString, "--timeout", "3600"] ++
      (if subdir.isEmpty then #[] else #["--subdir", subdir]) ++
      audited.flatMap (#["--module", ·]) ++ s.protect.flatMap (#["--protect", ·])
    let aout ← capture "python3" auditArgs
    log.write s!"python3 {" ".intercalate auditArgs.toList}" aout
    let auditJson := match Json.parse aout.stdout with
      | .ok j => j
      | .error _ => Json.mkObj [("status", "INCONCLUSIVE"), ("findings", Json.arr #[Json.mkObj [
          ("status", "INCONCLUSIVE"), ("code", "audit_failed"), ("subject", "audit"),
          ("detail", Json.str s!"the auditor did not run (exit code {aout.exitCode}): {tailOf (aout.stderr ++ aout.stdout) 5}")]])]
    IO.FS.writeFile (tdir / "audit.json") (auditJson.pretty ++ "\n")
    let g := guardOf auditJson
    step "guard" (Json.mkObj [("status", Json.str g.status), ("reasons", toJson g.reasons), ("notes", toJson g.notes),
      ("modules", toJson audited), ("changed_modules", toJson changedMods),
      ("audit", Json.str (tdir / "audit.json").toString)])
    let thms := (auditJson.getObjValAs? Nat "checkedTheorems").toOption.getD 0
    match g.status with
    | "FAIL" =>
      say "guard" s!"FAIL ({audited.size} module(s) audited)"
      return ← finish .discard (fewer (g.reasons.map ("guard: " ++ ·)) (tdir / "audit.json")) (cat := some .correctnessFailure)
    | "PASS" =>
      say "guard" (s!"PASS: {audited.size} module(s) audited ({thms} theorems): no sorry, new axiom, " ++
        "implemented_by, extern or protected file" ++ (if g.notes.isEmpty then "" else s!"; {g.notes[0]!}"))
    | _ =>
      say "guard" s!"INCONCLUSIVE ({audited.size} module(s) audited)"
      return ← finish .inconclusive (fewer (g.reasons.map ("guard: " ++ ·)) (tdir / "audit.json"))
    -- 3. tests
    if let .error e ← runTests log s cdir then
      step "tests" (Json.mkObj [("command", toJson s.test), ("passed", Json.bool false)])
      say "tests" "FAILED"
      return ← finish .discard #[s!"the tests fail (`{s.test.getD ""}`):\n{e}"] (cat := some .correctnessFailure)
    step "tests" (Json.mkObj [("command", toJson s.test), ("passed", Json.bool true)])
    say "tests" (match s.test with | some t => s!"pass (`{t}`)" | none => "none configured")
    -- the compile-time measure: heartbeats of the changed modules and their dependents
    let heartbeats (why : String) : IO UInt32 := do
      let mut files : Array String := #[]
      for m in changedMods ++ deps do
        if (← built cdir m) then files := files.push ((m.replace "." "/") ++ ".lean")
      if files.isEmpty then
        return ← finish .inconclusive #[s!"{why}, and no changed module of the package is built to count its heartbeats"]
      let key := ((hashOf (" ".intercalate files.toList).toUTF8).drop 8).toString
      IO.FS.createDirAll (expDir c s / "heartbeats")
      let cache := expDir c s / "heartbeats" / s!"{base.take 12}-{key}.json"
      let countHb (dir out : FilePath) : IO (Except String (Std.HashMap String Float)) := do
        let present ← files.filterM fun (f : String) => (dir / f).pathExists
        let r ← c.runSelf (#["elab", "--heartbeats", "--out", out.toString] ++ present) dir
        log.write s!"leanprof elab --heartbeats in {dir}" r
        if r.exitCode != 0 then return .error (tailOf (r.stdout ++ r.stderr))
        return .ok (← heartbeatsOf out)
      let bh ← if ← cache.pathExists then pure (.ok (← heartbeatsOf cache)) else countHb bdir cache
      let nh ← countHb cdir (tdir / "heartbeats-new.json")
      match bh, nh with
      | .error e, _ | _, .error e => return ← finish .error #[s!"counting heartbeats failed:\n{e}"]
      | .ok bh, .ok nh =>
        let v := Judge.judge { heartbeats := some bh } { heartbeats := some nh } s.min_change (judgeTime := false)
        let (out, reasons) := heartbeatOutcome v
        step "heartbeats" (Json.mkObj [("why", Json.str why), ("files", toJson files),
          ("base_total", toJson (hbTotal bh)), ("candidate_total", toJson (hbTotal nh)),
          ("worse", toJson v.worse), ("better", toJson v.better),
          ("notes", toJson (v.notes.filter (!·.startsWith "time:")))])
        say "heartbeats" s!"{Judge.fmt2 (hbTotal bh / 1000)} -> {Judge.fmt2 (hbTotal nh / 1000)} kHB in {files.size} module(s) ({why})"
        if out == .keep then keep reasons none none else finish out reasons (cat := some v.outcome)
    if s.mode != "exe" then return ← heartbeats "a library: the measure is compile heartbeats"
    -- 4. outputs, on every case
    let bin := cdir / ".lake" / "build" / "bin" / s.exe
    copyFile bin (tdir / "candidate-bin")
    let mut diffs := #[]
    for h : k in [0:s.cases.size] do
      let (sig, out, err) ← runCase s cdir bin s.cases[k]
      let want := s.baseline[k]!
      unless sig == want do
        let rd (ext : String) : IO String := do
          let p := expDir c s / "baseline" / s!"case-{k}.{ext}"
          if ← p.pathExists then IO.FS.readFile p else pure ""
        diffs := diffs.push s!"case {k} ({argsText s.cases[k]}): {caseDifference want sig (← rd "stdout") out (← rd "stderr") err}"
    step "outputs" (Json.mkObj [("cases", toJson s.cases.size), ("identical", Json.bool diffs.isEmpty),
      ("differences", toJson diffs), ("compared", toJson (#["stdout", "stderr", "exit code"] ++ s.check_outputs))])
    unless diffs.isEmpty do
      say "outputs" s!"DIFFER on {diffs.size} of {s.cases.size} cases"
      return ← finish .discard (#[s!"the behaviour changed on {diffs.size} of {s.cases.size} cases"] ++ diffs.extract 0 5)
        (cat := some .correctnessFailure)
    say "outputs" (s!"identical on {s.cases.size} case(s) (stdout, stderr, exit code" ++
      (if s.check_outputs.isEmpty then ")" else s!", {", ".intercalate s.check_outputs.toList})"))
    -- 5. the compiled code: identical C means an identical run
    let bir ← irHashes bdir
    let cir ← irHashes cdir
    let irChanged := ((bir.toList.map (·.1) ++ cir.toList.map (·.1)).eraseDups.filter fun k => bir.get? k != cir.get? k).toArray
    step "compiled" (Json.mkObj [("ir_files", toJson cir.size), ("changed", toJson irChanged)])
    if irChanged.isEmpty && !o.time then
      say "compiled" s!"identical: every one of the {cir.size} C files Lean generated is the base's, so the run cannot change (--time measures it anyway)"
      return ← heartbeats "the compiled code is the base's"
    say "compiled" s!"{irChanged.size} of {max bir.size cir.size} generated C files differ"
    -- 6. exact counts
    let baseSum ← IO.ofExcept (Judge.Summary.ofJson (← IO.ofExcept (Json.parse (← IO.FS.readFile s.base_summary))))
    let newSum ← match ← measure c log s cdir (tdir / "new.json") with
      | .ok x => pure x
      | .error e => return ← finish .error #[s!"measuring the candidate with probes failed:\n{e}"]
    let exact := Judge.judge baseSum newSum s.min_change (judgeTime := false)
    let exactNotes := exact.notes.filter (!·.startsWith "time:")
    step "exact" (Json.mkObj [("summary", Json.str (tdir / "new.json").toString), ("base_summary", Json.str s.base_summary),
      ("worse", toJson exact.worse), ("better", toJson exact.better), ("notes", toJson exactNotes),
      ("coverage", toJson exact.coverage)])
    let allocText := match baseSum.allocs, newSum.allocs with
      | some (a, _, _), some (b, _, _) => s!", allocations {Judge.groupDigits a} -> {Judge.groupDigits b}"
      | _, _ => ""
    say "exact" s!"copies {Judge.groupDigits baseSum.copies} -> {Judge.groupDigits newSum.copies}{allocText} ({s.runs} runs with probes)"
    unless exact.worse.isEmpty do
      step "timing" (Json.mkObj [("skipped", Json.str "the exact counts got worse")])
      let (out, reasons) := combine exact none
      return ← finish out reasons (cat := some (combineOutcome exact none))
    -- 7. paired timing of the plain binaries
    let paired := tdir / "paired.json"
    let args := s.cases[0]?.getD s.args
    let r ← c.runSelf (#["measure-pair", "--base", s.base_bin, "--candidate", (tdir / "candidate-bin").toString,
      "--base-cwd", bdir.toString, "--candidate-cwd", cdir.toString, "--runs", toString s.pairs,
      "--min-change", toString s.min_change, "--out", paired.toString] ++ checkArgs s ++ #["--"] ++ args) cdir
    log.write "leanprof measure-pair" r
    if r.exitCode != 0 then return ← finish .error #[s!"measure-pair failed:\n{tailOf (r.stdout ++ r.stderr)}"]
    let pv ← IO.ofExcept (Judge.judgePaired (← IO.ofExcept (Json.parse (← IO.FS.readFile paired))) s.min_change o.allowOverloaded)
    step "timing" (Json.mkObj [("session", Json.str paired.toString), ("worse", toJson pv.worse),
      ("better", toJson pv.better), ("notes", toJson pv.notes), ("unsettled", Json.bool pv.unsettled)])
    let timeLine := (pv.worse ++ pv.better ++ pv.notes.filter (·.startsWith "paired time")).toList.head?.getD ""
    say "time" timeLine
    let (out, reasons) := combine exact (some pv)
    if out == .keep then keep reasons (some (tdir / "new.json")) (some (tdir / "candidate-bin"))
    else finish out reasons (cat := some (combineOutcome exact (some pv)))
  catch e =>
    finish .error #[toString e]

structure FinishOpts where
  id : Option String := none
  keepWorktrees : Bool := false
  json : Bool := false

partial def parseFinish (o : FinishOpts) : List String → Except String FinishOpts
  | [] => .ok o
  | "--id" :: i :: rest => parseFinish { o with id := some i } rest
  | "--keep-worktrees" :: rest => parseFinish { o with keepWorktrees := true } rest
  | "--json" :: rest => parseFinish { o with json := true } rest
  | a :: _ => .error s!"unknown or incomplete experiment finish option: {a}"

/-- The tries, one line each. -/
def triesText (s : State) : String :=
  "\n".intercalate (s.tries.toList.map fun t =>
    s!"  try {t.n}: {t.verdict}, {t.candidate.take 12} ({t.source})" ++
      (match t.committed with | some x => s!", committed {x.take 12}" | none => "") ++
      (match t.reasons[0]? with | some r => s!": {(r.splitOn "\n").head!}" | none => ""))

def finishCmd (c : Ctx) (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parseFinish {} argv)
  let s ← loadState c.proj o.id
  let dir := expDir c s
  let log : Log := { path := dir / "finish-log.txt" }
  IO.FS.writeFile log.path ""
  let kept := s.tries.filter (·.verdict == "KEEP")
  let mut diffs := #[]
  let mut ran := false
  if s.mode == "exe" && !s.heldout.isEmpty then
    ensureWorktree (baseRoot c s) s.base_commit c.proj s.pkg_prefix (some c.proj)
    let bdir := baseDir c s
    if let .error e ← buildAll log s bdir then
      throw <| IO.userError s!"the final base {s.base_commit.take 12} does not build:\n{e}"
    let bin := bdir / ".lake" / "build" / "bin" / s.exe
    for h : k in [0:s.heldout.size] do
      let (sig, _, _) ← runCase s bdir bin s.heldout[k]
      if let some want := s.heldout_baseline[k]? then
        unless sig == want do
          diffs := diffs.push s!"held-out case {k} ({argsText s.heldout[k]}): {caseDifference want sig "" "" "" ""}"
    ran := true
  unless o.keepWorktrees do
    removeWorktree (baseRoot c s)
    removeWorktree (candRoot c s)
  let s := { s with finished := true }
  saveState c.proj s
  let cur := experimentsDir c.proj / "current"
  if ← cur.pathExists then
    if trim (← IO.FS.readFile cur) == s.id then IO.FS.removeFile cur
  let result := Json.mkObj [("version", toJson (1 : Nat)), ("schema", Contract.schema "experiment-finish"), ("leanprof", Json.str "experiment-finish"),
    ("experiment", Json.str s.id), ("start_commit", Json.str s.start_commit), ("final_commit", Json.str s.base_commit),
    ("tries", toJson s.tries.size), ("kept", toJson (kept.map (·.n))),
    ("heldout_cases", toJson s.heldout.size), ("heldout_identical", Json.bool diffs.isEmpty),
    ("heldout_differences", toJson diffs)]
  IO.FS.writeFile (dir / "finish.json") (result.pretty ++ "\n")
  if o.json then IO.println result.pretty
  else
    IO.println s!"leanprof experiment finish: {s.id}, {s.tries.size} tries, {kept.size} kept; base {s.start_commit.take 12} -> {s.base_commit.take 12}"
    unless s.tries.isEmpty do IO.println (triesText s)
    if !ran then IO.println "  held out: none (start --heldout DIR)"
    else if diffs.isEmpty then IO.println s!"  held out: identical on all {s.heldout.size} case(s), which no try saw"
    else
      IO.println s!"  held out: DIFFER on {diffs.size} of {s.heldout.size} case(s): the kept changes do not preserve behaviour beyond the inputs they were checked on"
      for d in diffs do IO.println (Explain.wrap s!"  - {d}" "    ")
    IO.println s!"  written to {dir / "finish.json"}"
  return if diffs.isEmpty then 0 else 1

def statusCmd (c : Ctx) (argv : List String) : IO UInt32 := do
  let (id, json) ← match argv with
    | [] => pure (none, false)
    | ["--json"] => pure (none, true)
    | ["--id", i] => pure (some i, false)
    | ["--id", i, "--json"] | ["--json", "--id", i] => pure (some i, true)
    | _ => throw <| IO.userError "usage: leanprof experiment status [--id ID] [--json]"
  let s ← loadState c.proj id
  if json then IO.println (Contract.withSchema "experiment-status" (toJson s)).pretty; return 0
  IO.println s!"experiment {s.id} ({s.mode}{if s.finished then ", finished" else ""}), started {s.created}"
  IO.println s!"  base {s.base_commit.take 12} (started at {s.start_commit.take 12}){if s.pkg_prefix.isEmpty then "" else s!", package in {s.pkg_prefix}"}"
  if s.mode == "exe" then
    IO.println s!"  {s.exe} -- {argsText (s.cases[0]?.getD s.args)}; {s.cases.size} case(s), {s.heldout.size} held out"
  IO.println s!"  tests: {s.test.getD "none"}"
  unless s.tries.isEmpty do IO.println (triesText s)
  return 0

/-- `leanprof experiment start|try|finish|status`. Exit codes of `try`: 0 KEEP,
1 DISCARD, 2 ERROR, 3 INCONCLUSIVE. -/
def experimentCmd (argv : List String) (runSelf : Array String → FilePath → IO IO.Process.Output) : IO UInt32 := do
  let c : Ctx := { proj := ← IO.currentDir, runSelf }
  match argv with
  | "start" :: rest => startCmd c rest
  | "try" :: rest => tryCmd c rest
  | "finish" :: rest => finishCmd c rest
  | "status" :: rest => statusCmd c rest
  | _ => throw <| IO.userError "usage: leanprof experiment start|try|finish|status (leanprof help experiment)"

end Leanprof.Experiment
