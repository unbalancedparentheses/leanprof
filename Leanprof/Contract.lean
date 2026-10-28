import Lean.Data.Json

/-!
# The machine-readable contract

Every JSON report and summary leanprof writes carries a `schema` field,
`{"name": "leanprof.NAME", "version": N}`, which names its JSON Schema in
`schemas/NAME.schema.json`. A version goes up only when a field is removed or
changes meaning; new fields keep the version (readers ignore fields they do
not know). `scripts/contract-check.py` validates real outputs against the
schemas in CI.

The verdicts of `judge`, `experiment try` and `fix` also carry an `outcome`
from one vocabulary (`Outcome`), so that an agent can tell a valid DISCARD
from a measurement that failed, and no improvement from too little evidence
or a correctness failure, without reading the reasons.
-/

namespace Leanprof.Contract
open Lean

/-- leanprof's own version (the package's, in `lakefile.lean`). -/
def leanprofVersion : String := "0.1.0"

/-- The `schema` field of a document: its name and version. -/
def schema (name : String) (version : Nat := 1) : Json :=
  Json.mkObj [("name", Json.str s!"leanprof.{name}"), ("version", toJson version)]

/-- `j` with its `schema` field (an object; anything else is returned as is). -/
def withSchema (name : String) (j : Json) (version : Nat := 1) : Json :=
  match j with
  | .obj _ => j.setObjVal! "schema" (schema name version)
  | _ => j

/-- What a verdict means, beyond KEEP or DISCARD.

* `improved`: something got better beyond noise and nothing got worse (KEEP);
* `regression`: a measured cost got worse (a valid DISCARD);
* `no_improvement`: measured, nothing worse, nothing better beyond noise (a
  valid DISCARD);
* `insufficient_evidence`: the measurement could not settle it (time
  unsettled, or not judged on an overloaded machine); measuring again, longer
  or on a quieter machine may;
* `correctness_failure`: the change altered behaviour: exit code, output, a
  failing test or build, or a proof the guard rejects;
* `incompatible`: the two sides measured different things (another command,
  scope, `--core`, Lean version or platform), so no verdict follows;
* `measurement_failed`: the measurement itself failed (a crash, a missing
  file, an output that differs between runs of the same code); not a
  verdict on the change. -/
inductive Outcome
  | improved | regression | noImprovement | insufficientEvidence | correctnessFailure | incompatible
  | measurementFailed
  deriving BEq, Repr, Inhabited

def Outcome.name : Outcome → String
  | .improved => "improved" | .regression => "regression" | .noImprovement => "no_improvement"
  | .insufficientEvidence => "insufficient_evidence" | .correctnessFailure => "correctness_failure"
  | .incompatible => "incompatible" | .measurementFailed => "measurement_failed"

/-- Whether the measurement is a valid basis for the verdict: false when it
failed or compared incompatible things (then the verdict says nothing about
the change). -/
def Outcome.valid : Outcome → Bool
  | .incompatible | .measurementFailed => false
  | _ => true

/-- Whether measuring again may change the outcome without changing the code. -/
def Outcome.retryable : Outcome → Bool
  | .insufficientEvidence | .measurementFailed => true
  | _ => false

/-- The verdict word a command prints for an outcome. -/
def Outcome.verdict : Outcome → String
  | .improved => "KEEP"
  | .regression | .noImprovement | .correctnessFailure => "DISCARD"
  | .insufficientEvidence => "INCONCLUSIVE"
  | .incompatible | .measurementFailed => "ERROR"

def Outcome.json (o : Outcome) : List (String × Json) :=
  [("outcome", Json.str o.name), ("measurement_valid", Json.bool o.valid), ("retryable", Json.bool o.retryable)]

/-- 64-bit FNV-1a of `b` as 16 hex digits: a stable fingerprint (not
cryptographic). -/
def fnv1a (b : ByteArray) : String := Id.run do
  let mut h : UInt64 := 14695981039346656037
  for x in b do h := (h ^^^ x.toUInt64) * 1099511628211
  let hex := Nat.toDigits 16 h.toNat
  return String.ofList (List.replicate (16 - hex.length) '0' ++ hex)

/-! ## Errors an agent can act on

A command that fails writes what went wrong to the file named by
`LEANPROF_ERROR_JSON` (when set; the MCP server sets it for the commands it
runs): its kind, whether trying again unchanged may succeed, and what to do
(`schemas/common.schema.json#/$defs/error`). The first error written wins: it
is the cause, later ones are consequences. -/

/-- The kinds of failure, whether a retry without changes may succeed, and
what to do about each. -/
def errorKinds : List (String × Bool × String) := [
  ("not_lake_project", false,
    "run it in the root directory of a Lake project (one with lakefile.lean or lakefile.toml), or pass cwd"),
  ("build_failed", false,
    "the project does not build: fix the error in the message (`lake build EXE` shows it), then call again"),
  ("lean_not_found", false,
    "install Lean with elan (https://github.com/leanprover/elan) and put ~/.elan/bin on the PATH leanprof runs with"),
  ("samply_missing", false,
    "install samply (`leanprof doctor` prints the command), or use `run` or `stat`, which need no sampler"),
  ("overloaded", true,
    "the machine ran more jobs than it has CPUs, so time was not judged: measure again when it is quieter, or allow it explicitly (--allow-overloaded) for a machine that is always shared"),
  ("bad_argument", false, "correct the argument the message names (`leanprof help COMMAND`, or the tool's input schema)"),
  ("not_found", false, "the file does not exist: run the command that writes it first (run, elab, measure), or give its path"),
  ("incompatible", false,
    "the two inputs were measured differently (Lean version, platform, flags or workload): measure both the same way, or pass --allow-incompatible"),
  ("stale_source", true,
    "the source changed after the report was written, so its lines may not be the ones measured: profile again"),
  ("timeout", true, "the job ran out of time: call again with a larger timeout, or a smaller workload"),
  ("cancelled", true, "the job was cancelled: start it again if it is still needed"),
  ("failed", false, "see the message and the command's output; `leanprof doctor` checks the setup")]

/-- An error as JSON: `code`, `message`, `retryable`, `hint`. -/
def errorJson (code message : String) (hint : String := "") : Json :=
  let (retryable, dflt) := match errorKinds.find? (·.1 == code) with
    | some (_, r, h) => (r, h)
    | none => (false, "")
  Json.mkObj [("code", Json.str code), ("message", Json.str message), ("retryable", Json.bool retryable),
    ("hint", Json.str (if hint.isEmpty then dflt else hint))]

/-- Record an error for the caller (`LEANPROF_ERROR_JSON`), unless one is
recorded already. -/
def reportError (code message : String) (hint : String := "") : IO Unit := do
  let some path ← IO.getEnv "LEANPROF_ERROR_JSON" | return
  if path.isEmpty then return
  try
    if ← (path : System.FilePath).pathExists then
      if !(← IO.FS.readFile path).isEmpty then return
    IO.FS.writeFile path ((withSchema "error" (errorJson code message hint)).compress ++ "\n")
  catch _ => pure ()

/-- The kind of an error from its message, for errors no code path named:
usage and option errors are bad arguments. -/
def classifyError (message : String) : String :=
  let has (s : String) := (message.splitOn s).length > 1
  if has "usage:" || has "unknown option" || has "unknown argument" || has "must be a" || has "takes a" ||
      has "give " || has "not a file name" || has "not an executable name" || has "not a revision" then "bad_argument"
  else if has "no such file" || has "does not exist" || has "no report at" then "not_found"
  else if has "`lean` was not found" then "lean_not_found"
  else if has "samply" then "samply_missing"
  else "failed"

/-! ## Provenance

Where a report or summary came from, so that two of them are compared only
when they can be, and advice is not given from a source that changed since
(`schemas/common.schema.json#/$defs/provenance`): leanprof's version, the
Lean the project uses, the platform, the source revision with a fingerprint
of uncommitted changes, the build flags, and the workload (executable,
arguments, the binary's hash and each input file's). -/

/-- A command's standard output, or none when it does not run or fails. -/
def outputOf (cmd : String) (args : Array String) (cwd : Option System.FilePath := none) : IO (Option String) := do
  try
    let o ← IO.Process.output { cmd, args, cwd, stdin := .null }
    return if o.exitCode == 0 then some o.stdout else none
  catch _ => return none

/-- A file's FNV-1a hash over its whole contents, read 1 MiB at a time (any
size), as `fnv1a` gives it; none when it cannot be read. -/
def hashFile (p : System.FilePath) : IO (Option String) := do
  try
    if (← p.metadata).type != .file then return none
    let h ← IO.FS.Handle.mk p .read
    let mut acc : UInt64 := 14695981039346656037
    repeat
      let chunk ← h.read 1048576
      if chunk.isEmpty then break
      for x in chunk do acc := (acc ^^^ x.toUInt64) * 1099511628211
    let hex := Nat.toDigits 16 acc.toNat
    return some (String.ofList (List.replicate (16 - hex.length) '0' ++ hex))
  catch _ => return none

/-- The source revision of the repository around `dir`: the commit, whether the
tree has uncommitted changes, and a fingerprint of them: `git status`, `git
diff HEAD` (tracked files) and the contents of every untracked file that is
not ignored, so that editing an untracked source changes it too (`git status`
and
`git diff HEAD`), or null outside a git repository. -/
def gitState (dir : System.FilePath := ".") : IO Json := do
  let some rev ← outputOf "git" #["rev-parse", "HEAD"] (some dir) | return Json.null
  let status := (← outputOf "git" #["status", "--porcelain=v1", "--untracked-files=normal"] (some dir)).getD ""
  let dirty := !status.trimAscii.toString.isEmpty
  let diff ← if dirty then pure ((← outputOf "git" #["diff", "HEAD", "--binary"] (some dir)).getD "") else pure ""
  -- untracked files: `git status` names them, their contents must count too
  let mut untracked := ""
  if dirty then
    let top := ((← outputOf "git" #["rev-parse", "--show-toplevel"] (some dir)).getD "").trimAscii.toString
    let names := ((← outputOf "git" #["ls-files", "--others", "--exclude-standard", "-z", "--full-name", ":/"]
      (some dir)).getD "").splitOn "\x00"
    for n in names do
      if n.isEmpty then continue
      let h ← hashFile ((top : System.FilePath) / n)
      untracked := untracked ++ s!"{n}\x00{h.getD "unreadable"}\x00"
  return Json.mkObj [("rev", Json.str rev.trimAscii.toString), ("dirty", Json.bool dirty),
    ("dirty_fingerprint", if dirty then Json.str (fnv1a (status ++ "\x00" ++ diff ++ "\x00" ++ untracked).toUTF8)
      else Json.null)]

/-- The Lean the project uses: its version and commit (`lean --version`). -/
def leanVersion : IO Json := do
  let some v ← outputOf "lean" #["--version"] | return Json.null
  -- `Lean (version 4.35.0, arm64-apple-darwin24.6.0, commit eb6caf…, Release)`
  let field (k : String) : String :=
    match v.splitOn s!"{k} " with
    | _ :: rest :: _ => (rest.splitOn ",").headD ""
    | _ => ""
  return Json.mkObj [("version", Json.str (field "version")), ("commit", Json.str (field "commit"))]

def platform : Json :=
  Json.mkObj [("target", Json.str System.Platform.target),
    ("os", Json.str (if System.Platform.isOSX then "macos" else if System.Platform.isWindows then "windows" else "linux"))]

/-- The workload: the executable (and its binary's hash, when given), the
arguments and their hash, and each argument that names a file with that
file's hash (the program's inputs). -/
def workload (exe : String) (args : Array String) (binary : Option System.FilePath := none) : IO Json := do
  let mut inputs : Array Json := #[]
  for a in args.toList.take 64 do
    if a.startsWith "-" || a.isEmpty then continue
    if let some h ← hashFile a then
      inputs := inputs.push (Json.mkObj [("path", Json.str a), ("hash", Json.str h)])
  let bin ← match binary with
    | some b => pure ((← hashFile b).map Json.str |>.getD Json.null)
    | none => pure Json.null
  return Json.mkObj [("executable", Json.str exe), ("args", toJson args),
    ("args_hash", Json.str (fnv1a ("\x00".intercalate args.toList).toUTF8)), ("binary_hash", bin),
    ("inputs", Json.arr inputs)]

/-- The provenance of a document made now, in the current directory. -/
def provenance (work : Json) (build : Json) : IO Json := do
  let created := ((← outputOf "date" #["-u", "+%Y-%m-%dT%H:%M:%SZ"]).getD "").trimAscii.toString
  return Json.mkObj [("leanprof_version", Json.str leanprofVersion), ("lean", ← leanVersion), ("platform", platform),
    ("git", ← gitState), ("build", build), ("workload", work), ("created", Json.str created)]

/-- A field of a provenance at a path, compressed (`""` when absent). -/
def provAt (p : Json) (path : List String) : String :=
  match path.foldl (fun (j : Option Json) k => j.bind fun x => (x.getObjVal? k).toOption) (some p) with
  | some (.str s) => s
  | some Json.null | none => ""
  | some j => j.compress

/-- Whether two documents can be compared, from their provenance: refusals
(another Lean version or platform: the numbers are not of the same code),
and warnings (another leanprof, other build flags or workload). `compatible`
is null when either has no provenance (made before leanprof recorded it). -/
def provenanceCheck (b n : Json) : Json × Array String × Array String := Id.run do
  let bp := (b.getObjVal? "provenance").toOption.getD Json.null
  let np := (n.getObjVal? "provenance").toOption.getD Json.null
  if bp == Json.null || np == Json.null then
    let which := if bp == Json.null && np == Json.null then "either" else if bp == Json.null then "the base" else "the new one"
    return (Json.mkObj [("compatible", Json.null), ("refusals", Json.arr #[]), ("warnings", Json.arr #[]),
      ("note", Json.str s!"no provenance recorded in {which}: not checked")], #[], #[])
  let mut refusals : Array String := #[]
  let mut warnings : Array String := #[]
  let differs (path : List String) := provAt bp path != provAt np path
  let both (path : List String) := s!"{provAt bp path} vs {provAt np path}"
  if differs ["lean", "version"] || differs ["lean", "commit"] then
    refusals := refusals.push s!"different Lean versions: {both ["lean", "version"]}"
  if differs ["platform", "target"] then refusals := refusals.push s!"different platforms: {both ["platform", "target"]}"
  if differs ["leanprof_version"] then warnings := warnings.push s!"different leanprof versions: {both ["leanprof_version"]}"
  if differs ["build"] then warnings := warnings.push s!"different build flags: {both ["build"]}"
  if differs ["workload", "executable"] || differs ["workload", "args_hash"] then
    warnings := warnings.push s!"different workloads: {provAt bp ["workload", "executable"]} {provAt bp ["workload", "args"]} vs {provAt np ["workload", "executable"]} {provAt np ["workload", "args"]}"
  else if differs ["workload", "inputs"] then
    warnings := warnings.push "the same arguments, but input files with other contents"
  let side (p : Json) := Json.mkObj [("lean", Json.str (provAt p ["lean", "version"])),
    ("rev", Json.str (provAt p ["git", "rev"])), ("dirty", Json.bool (provAt p ["git", "dirty"] == "true")),
    ("created", Json.str (provAt p ["created"]))]
  return (Json.mkObj [("compatible", Json.bool refusals.isEmpty), ("refusals", toJson refusals),
    ("warnings", toJson warnings), ("same_revision", Json.bool (!differs ["git", "rev"] && !differs ["git", "dirty_fingerprint"])),
    ("base", side bp), ("new", side np)], refusals, warnings)

/-- Why the source `file` may no longer be what the report at `report` (its
JSON `j`) measured, or none: modified after the report was written, or
different from the revision its provenance records. -/
def staleSource (report : System.FilePath) (j : Json) (file : System.FilePath) : IO (Option String) := do
  try
    let r ← report.metadata
    let f ← file.metadata
    if f.modified.sec > r.modified.sec || (f.modified.sec == r.modified.sec && f.modified.nsec > r.modified.nsec) then
      return some "modified after the report was written"
  catch _ => pure ()
  let p := (j.getObjVal? "provenance").toOption.getD Json.null
  let rev := provAt p ["git", "rev"]
  if !rev.isEmpty && provAt p ["git", "dirty"] != "true" then
    if let some head ← outputOf "git" #["rev-parse", "HEAD"] then
      if head.trimAscii.toString != rev then
        -- `git diff --quiet` exits 1 when the file differs
        let args := #["diff", "--quiet", rev, "--", file.toString]
        let same ← try pure ((← IO.Process.output { cmd := "git", args, stdin := .null }).exitCode == 0)
          catch _ => pure true
        unless same do return some s!"differs from the revision profiled ({rev.take 12})"
  return none

end Leanprof.Contract
