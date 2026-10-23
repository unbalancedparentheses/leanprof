module

public import Leanprof.Core
public meta import Lean.Elab.Command
public meta import Lean.Data.Json

/-!
# `#leanprof`: results next to the code

`#leanprof` (or `#leanprof "path/to/report.json"`) reads the reports in
`.lake/leanprof/`: `report.json` from a profiled run (`lake exe leanprof run`
or `sample`) and `elab.json` from `lake exe leanprof elab`. It shows inlay
hints at the end of each line of this file they mention: run time per
`profile!` scope or function, copies of shared values per declaration, and
compile time per declaration. Hover a hint for
details; the infoview at `#leanprof` lists everything for the file.

The report describes the source as it was when the program ran; after edits,
rerun the program.
-/

public meta section
namespace Leanprof.Editor
open Lean Elab Command

def defaultReport : String := ".lake/leanprof/report.json"

def num (j : Json) (k : String) : Float :=
  match j.getObjVal? k with
  | .ok (.num n) => n.toFloat
  | _ => 0

def str (j : Json) (k : String) : String :=
  (j.getObjVal? k >>= Json.getStr?).toOption.getD ""

def arr (j : Json) (k : String) : Array Json :=
  (j.getObjVal? k >>= Json.getArr?).toOption.getD #[]

/-- `x` with one decimal. -/
def fmt1 (x : Float) : String :=
  let v := (x.abs * 10).round.toUInt64.toNat
  s!"{v / 10}.{v % 10}"

def fmtNs (ns : Float) : String :=
  if ns < 1e3 then s!"{fmt1 ns} ns"
  else if ns < 1e6 then s!"{fmt1 (ns / 1e3)} µs"
  else if ns < 1e9 then s!"{fmt1 (ns / 1e6)} ms"
  else s!"{fmt1 (ns / 1e9)} s"

def fmtBytes (b : Float) : String :=
  if b < 1024 then s!"{b.toUInt64} B"
  else if b < 1048576 then s!"{fmt1 (b / 1024)} KiB"
  else if b < 1073741824 then s!"{fmt1 (b / 1048576)} MiB"
  else s!"{fmt1 (b / 1073741824)} GiB"

/-- The line of `pos` (`File.lean:12`) when it is in `file`. -/
def lineIn (file pos : String) : Option Nat :=
  match pos.splitOn ":" with
  | [p, l] => if p == file || p.endsWith ("/" ++ file) then l.toNat? else none
  | _ => none

/-- End of 1-based `line`, before its newline. -/
def endOfLine (fm : FileMap) (line : Nat) : String.Pos.Raw :=
  let next := fm.lineStart (line + 1)
  let bytes := fm.source.toUTF8
  if line < fm.positions.size && next.byteIdx > 0 && bytes[next.byteIdx - 1]? == some 10 then
    ⟨next.byteIdx - 1⟩
  else next

def hint (pos : String.Pos.Raw) (label tooltip : String) : CommandElabM Unit :=
  pushInfoLeaf <| .ofCustomInfo
    ({ position := pos, label := .name label, tooltip? := some tooltip, paddingLeft := true, lctx := {} } :
      InlayHint).toCustomInfo

/-- How `elab` reached a definition (`unfold`, `whnf`, `instance`, `simp`). -/
def unfoldVerb : String → String
  | "unfold" => "unfolding"
  | "whnf" => "reducing"
  | "instance" => "trying instance"
  | "simp" => "rewriting with"
  | k => k

syntax (name := leanprofCmd) "#leanprof" (ppSpace str)? : command

/-- Hints and summary lines for one report. -/
def showReport (path : String) (file : String) (fm : FileMap) : CommandElabM (Array String) := do
  let j ← match Json.parse (← (IO.FS.readFile path : IO String)) with
    | .ok j => pure j
    | .error e => throwError "leanprof: cannot parse {path}: {e}"
  let wall := num j "wall_ns"
  let flag (k : String) := (j.getObjVal? k).toOption == some (.bool true)
  let sampled := flag "sampled"
  let compile := flag "elab"
  let heartbeats := str j "unit" == "heartbeats"
  let amount (x : Float) := if heartbeats then s!"{fmt1 (x / 1000)} kHB" else fmtNs x
  let mut lines : Array String := #[]
  -- many entries can share a line (a function and its specializations): keep the largest
  let mut best : Std.HashMap Nat (Float × String × String) := {}
  for s in arr j "scopes" do
    let some line := lineIn file (str s "pos") | continue
    let total := num s "total_ns"
    let calls := (num s "calls").toUInt64.toNat
    let pct := if wall > 0 then total / wall * 100 else 0
    let label :=
      if compile then s!"⚙ {amount total} to compile"
      else if sampled then s!"≈ {fmtNs total} CPU · {fmt1 pct}%"
      else s!"⏱ {fmtNs total} · {fmt1 pct}% · {calls}×"
    let tip :=
      if compile then
        let ops := (arr s "top").toList.map fun o => s!"\n  {amount (num o "amount")}  {str o "op"}"
        -- `elab` names the definitions behind the work, each with its own file:line
        let defs := (arr s "unfolded").toList.map fun u =>
          let w := str u "where"
          let sites := (num u "sites").toUInt64.toNat
          s!"\n  {amount (num u "amount")} {unfoldVerb (str u "kind")} `{str u "name"}`" ++
            (if w.isEmpty then "" else s!" ({w})") ++
            (if sites > 1 then s!", reached from {sites} call sites" else "")
        s!"compile cost: elaboration {amount (num s "elab_ns")}, kernel {amount (num s "kernel_ns")}, " ++
          s!"compiler {amount (num s "compile_ns")}, linters {amount (num s "lint_ns")}" ++
          (if ops.isEmpty then "" else "\ncostliest operations:" ++ String.join ops) ++
          (if defs.isEmpty then "" else "\ndefinitions behind it:" ++ String.join defs)
      else if sampled then s!"{str s "name"}: {fmtNs total} CPU inclusive, {fmtNs (num s "self_ns")} self (sampled)"
      else s!"{str s "name"}: {calls} calls, total {fmtNs total}, self {fmtNs (num s "self_ns")}, " ++
        s!"mean {fmtNs (num s "mean_ns")}, p50 {fmtNs (num s "p50_ns")}, p99 {fmtNs (num s "p99_ns")}"
    if (best.get? line).all (·.1 < total) then best := best.insert line (total, label, tip)
    lines := lines.push s!"{file}:{line}  {label}  ({str s "name"})"
  -- tactic steps inside proofs (`elab`), on lines no declaration starts on
  for t in arr j "tactics" do
    let some line := lineIn file (str t "pos") | continue
    if best.contains line then continue
    let x := num t "amount"
    let n := (num t "count").toUInt64.toNat
    best := best.insert line (x, s!"⚙ {amount x}", s!"tactic step{if n > 1 then s!" (run {n} times)" else ""}: {str t "tactic"}\n" ++
      "inclusive: includes the steps nested in it")
    lines := lines.push s!"{file}:{line}  ⚙ {amount x}  ({str t "tactic"})"
  for (line, (_, label, tip)) in best.toList do
    hint (endOfLine fm line) label tip
  for c in arr j "copies" do
    let shared := num c "shared" + num c "multi_threaded"
    if shared == 0 then continue
    let some line := lineIn file (str c "where") | continue
    let why := if num c "multi_threaded" > 0 then "multi-threaded" else "shared"
    let label := s!"⚠ {shared.toUInt64} copies · {fmtBytes (num c "bytes")} · {fmtNs (num c "copy_ns")}"
    let tip := s!"{str c "function"} copied a {why} {str c "kind"} {shared.toUInt64} times " ++
      s!"({fmtBytes (num c "bytes")}, {fmtNs (num c "copy_ns")}) in scope {str c "scope"}. " ++
      "Each copy happens because another reference to the value is still alive (or the value " ++
      "was shared between threads), so Lean cannot update it in place."
    hint (endOfLine fm line) label tip
    lines := lines.push s!"{file}:{line}  {label}  ({str c "function"})"
  return lines

@[command_elab leanprofCmd] def elabLeanprof : CommandElab := fun stx => do
  -- this file, relative to the project (where the reports' positions start)
  let cwd ← (IO.currentDir : IO System.FilePath)
  let fileName ← getFileName
  let mainModule ← getMainModule
  let file :=
    if fileName.startsWith (cwd.toString ++ "/") then (fileName.drop (cwd.toString.length + 1)).toString
    else mainModule.toString.replace "." "/" ++ ".lean"
  let fm ← getFileMap
  let paths : Array String := match stx[1].getOptional?.bind (·.isStrLit?) with
    | some p => #[p]
    | none => #[defaultReport, ".lake/leanprof/elab.json"]
  let mut lines : Array String := #[]
  let mut found := false
  for (path : String) in paths do
    unless ← System.FilePath.pathExists path do continue
    found := true
    lines := lines ++ (← showReport path file fm)
  if !found then
    logInfo m!"no leanprof report: run `lake exe leanprof run EXE`, `lake exe leanprof sample EXE` or `lake exe leanprof elab FILE`"
  else if lines.isEmpty then
    logInfo m!"leanprof: the reports mention nothing in {file}"
  else
    logInfo m!"leanprof:\n{"\n".intercalate lines.toList}"

end Leanprof.Editor
