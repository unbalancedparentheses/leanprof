module

public import Leanprof.Core
public meta import Lean.Elab.Command
public meta import Lean.Data.Json
-- String.splitOn, outside the prelude of Lean before 4.28
public meta import Init.Data.String.Legacy

/-!
# `#leanprof`: results next to the code

`#leanprof` (or `#leanprof "path/to/report.json"`) reads the reports in
`.lake/leanprof/`: `report.json` from a profiled run (`lake exe leanprof run`
or `sample`) and `elab.json` from `lake exe leanprof elab`. It shows inlay
hints at the end of each line of this file they mention: run time per
`profile!` scope or function, copies of shared values per declaration, and
compile time per declaration, tactic and term (with `elab`'s exact source
ranges, `line:column`, in the hover). Hover a hint for
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

/-- Explanations written by `leanprof explain` (`.lake/leanprof/explain.json`),
one entry per explained copy site, keyed by the copying function's symbol. -/
def explanations : CommandElabM (Array Json) := do
  let path := ".lake/leanprof/explain.json"
  unless ← System.FilePath.pathExists path do return #[]
  match Json.parse (← (IO.FS.readFile path : IO String)) with
  | .ok (.arr a) => return a
  | _ => return #[]

/-- What a row marked `near_probe_cost` means. -/
def nearProbeNote : String := "near the probe cost: use `leanprof sample` for this function's time"

/-- What a row with `holds_tiny` means: it calls scopes too small to time,
whose probes change its code by more than any subtraction can undo. -/
def holdsTinyNote (names : List String) : String :=
  s!"calls scopes too small to time ({", ".intercalate names}): the calls around them change this code, " ++
    "so its time is off whatever leanprof subtracts, and so is a sample of this build; remove those " ++
    "profile! (or `set_option leanprof.enabled false`) and use `leanprof sample`"

/-- How a time too small to measure is shown, never as 0: what is left of a
scope after subtracting the probes' cost, or a copy shorter than one clock
tick. -/
def tooSmallScope : String := "< probe cost"
def tooSmallTick : String := "< 1 clock tick"

/-- Whether a row lists `field` in `too_small`. -/
def isTooSmall (r : Json) (field : String) : Bool :=
  (arr r "too_small").any (·.getStr?.toOption == some field)

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
    let near := (s.getObjVal? "near_probe_cost").toOption == some (.bool true)
    let t (field : String) := if isTooSmall s field then tooSmallScope else fmtNs (num s field)
    let label :=
      if compile then s!"⚙ {amount total} to compile"
      else if sampled then s!"≈ {fmtNs total} CPU · {fmt1 pct}%"
      else s!"⏱ {t "total_ns"}{if near then "*" else ""} · {fmt1 pct}% · {calls}×"
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
      else s!"{str s "name"}: {calls} calls, total {t "total_ns"}, self {t "self_ns"}, " ++
        s!"mean {t "mean_ns"}, p50 {t "p50_ns"}, p99 {t "p99_ns"}" ++
        (if near then s!"\n* {nearProbeNote}" else "") ++
        (let held := (arr s "holds_tiny").toList.filterMap (·.getStr?.toOption)
         if held.isEmpty then "" else s!"\n* {holdsTinyNote held}")
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
  -- terms and tactics by exact source range (`elab` with its driver): listed in the
  -- hover of the line they start on, a hint of their own on a line with none
  let mut onLine : Std.HashMap Nat (Array (Float × String × String)) := {}
  for r in arr j "ranges" do
    let some line := lineIn file (str r "pos") | continue
    let x := num r "amount"
    let n := (num r "count").toUInt64.toNat
    -- `File.lean:12:3-12:40` without the file
    let cols := ":".intercalate (((str r "range").splitOn ":").reverse.take 3).reverse
    let syn := (((str r "syntax").splitOn ".").getLast?).getD ""
    onLine := onLine.insert line ((onLine.getD line #[]).push
      (x, cols, s!"{amount x}{if n > 1 then s!" ({n}×)" else ""}  {str r "kind"} {syn}: {str r "text"}"))
  for (line, rs) in onLine.toList do
    let rs := rs.qsort (fun a b => a.1 > b.1)
    let list := "by exact source range (line:column, inclusive):" ++
      String.join (rs.toList.take 6 |>.map fun (_, c, d) => s!"\n  {c}  {d}")
    match best.get? line with
    | some (x, label, tip) => best := best.insert line (x, label, tip ++ "\n" ++ list)
    | none =>
      let (x, c, d) := rs[0]!
      best := best.insert line (x, s!"⚙ {amount x}", list)
      lines := lines.push s!"{file}:{c}  ⚙ {d}"
  for (line, (_, label, tip)) in best.toList do
    hint (endOfLine fm line) label tip
  let explained ← explanations
  for c in arr j "copies" do
    let shared := num c "shared" + num c "multi_threaded"
    -- copies of empty or tiny values are summarized in the report, not hinted
    if shared == 0 || (c.getObjValAs? Bool "tiny").toOption == some true then continue
    let some line := lineIn file (str c "where") | continue
    let why := if num c "multi_threaded" > 0 then "multi-threaded" else "shared"
    let ct := if isTooSmall c "copy_ns" then tooSmallTick else fmtNs (num c "copy_ns")
    -- its share of the run (`pct_run`; older reports: of the wall time)
    let share := if (c.getObjVal? "pct_run").isOk then num c "pct_run"
      else if wall > 0 then num c "copy_ns" / wall * 100 else 0
    let label := s!"⚠ {shared.toUInt64} copies · {fmtBytes (num c "bytes")} · {ct} · {fmt1 share}%"
    let tip := s!"{str c "function"} copied a {why} {str c "kind"} {shared.toUInt64} times " ++
      s!"({fmtBytes (num c "bytes")}, {ct}, {fmt1 share}% of the run) in scope {str c "scope"}. " ++
      "Each copy happens because another reference to the value is still alive (or the value " ++
      "was shared between threads), so Lean cannot update it in place." ++
      String.join ((explained.filter (str · "symbol" == str c "symbol")).toList.map fun e =>
        s!"\n\nwhy: {str e "why"}" ++ (if (str e "fix").isEmpty then "" else s!"\nfix: {str e "fix"}") ++
          String.join ((((e.getObjValAs? (Array String) "fix_code").toOption).getD #[]).toList.map
            fun c => s!"\n```lean\n{c}\n```") ++
          s!"\n(leanprof explain; confidence {str e "confidence"})")
    hint (endOfLine fm line) label tip
    lines := lines.push s!"{file}:{line}  {label}  ({str c "function"})"
  return lines

/-- `n` with thousands separators. -/
def groupDigits (n : Nat) : String :=
  let cs := (toString n).toList.reverse
  String.ofList (cs.zipIdx.foldl (fun acc (c, i) => if i > 0 && i % 3 == 0 then c :: ',' :: acc else c :: acc) [])

/-- `+x` or `−x`. -/
def signed (d : Float) (f : Float → String) : String :=
  if d > 0 then s!"+{f d}" else if d < 0 then s!"−{f d.abs}" else "±0"

/-- The differences written by `--since-last` (`elab`, `run`, `stat`; editors run it on
save) that concern `file`: `.lake/leanprof/onsave/FILE.delta.json` and every
`run-EXE.delta.json` there. Hints `Δ +12.3 kHB since the last profile`, `Δ +2,000 copies`;
the hover says what changed inside the declaration. -/
def showDeltas (file : String) (fm : FileMap) : CommandElabM (Array String) := do
  let dir : System.FilePath := ".lake/leanprof/onsave"
  unless ← dir.pathExists do return #[]
  let mut paths : Array System.FilePath := #[dir / s!"{file}.delta.json"]
  for e in ← (dir.readDir : IO _) do
    if e.fileName.startsWith "run-" && e.fileName.endsWith ".delta.json" then paths := paths.push e.path
  let mut lines : Array String := #[]
  for path in paths do
    unless ← path.pathExists do continue
    let .ok j := Json.parse (← (IO.FS.readFile path : IO String)) | continue
    if (j.getObjValAs? Bool "first").toOption == some true then continue
    let hb := str j "unit" == "heartbeats"
    let amount (x : Float) := if hb then s!"{fmt1 (x / 1000)} kHB" else fmtNs x
    for d in arr j "decls" do
      let some line := lineIn file (str d "pos") | continue
      let change := num d "change"
      let status := str d "status"
      let label := s!"Δ {signed change amount}{if status == "new" then " (new)" else ""} since the last profile"
      let w := (d.getObjVal? "why").toOption.getD Json.null
      let rows := (arr w "rows").toList.map fun r =>
        s!"\n  {str r "change"}  {str r "label"} `{str r "name"}`" ++
          (if (str r "where").isEmpty then "" else s!" ({str r "where"})") ++ s!": {str r "base"} → {str r "new"}"
      let notes := (arr w "notes").toList.filterMap (·.getStr?.toOption) |>.map (s!"\nnote: {·}")
      let tip := s!"{amount (num d "base")} → {amount (num d "new")} to compile" ++
        (if rows.isEmpty then "" else "\nwhat changed inside it:" ++ String.join rows) ++ String.join notes
      hint (endOfLine fm line) label tip
      lines := lines.push s!"{file}:{line}  {label}  ({str d "key"})"
    for (field, what) in [("copies", "copies"), ("allocations", "allocations")] do
      for c in arr j field do
        let some line := lineIn file (str c "where") | continue
        let change := num c "change"
        let label := s!"Δ {signed change (fun x => groupDigits x.toUInt64.toNat)} {what} since the last run"
        let tip := s!"{str c "key"}: {groupDigits (num c "base").toUInt64.toNat} → {groupDigits (num c "new").toUInt64.toNat} {what} " ++
          s!"({fmtBytes (num c "base_bytes")} → {fmtBytes (num c "new_bytes")}); counts are exact"
        hint (endOfLine fm line) label tip
        lines := lines.push s!"{file}:{line}  {label}  ({str c "key"})"
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
  -- what changed since the previous `--since-last` profile (an editor's on-save run)
  let deltas ← if stx[1].getOptional?.isSome then pure #[] else showDeltas file fm
  if !deltas.isEmpty then
    found := true
    lines := lines ++ #["since the last profile:"] ++ deltas
  if !found then
    logInfo m!"no leanprof report: run `lake exe leanprof run EXE`, `lake exe leanprof sample EXE` or `lake exe leanprof elab FILE`"
  else if lines.isEmpty then
    logInfo m!"leanprof: the reports mention nothing in {file}"
  else
    logInfo m!"leanprof:\n{"\n".intercalate lines.toList}"

end Leanprof.Editor
