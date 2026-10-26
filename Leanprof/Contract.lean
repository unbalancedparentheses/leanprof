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

end Leanprof.Contract
