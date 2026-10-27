import Lean.Data.Json

/-!
# Retained memory in reports

The `retained` section of a run report (`leanprof run --retained`, see
`c/retained.inc.c` and docs/guide/memory.md) as text, for `leanprof explain`,
the MCP server's `report`, `hot` and `explain` tools, and `leanprof top`.
A report without the section did not track retained memory: that is said as
such, never shown as zero.
-/

open Lean

namespace Leanprof.Retained

private def num (j : Json) (k : String) : Float :=
  match j.getObjVal? k with
  | .ok (.num n) => n.toFloat
  | _ => 0

private def str (j : Json) (k : String) : String := (j.getObjVal? k >>= Json.getStr?).toOption.getD ""
private def arr (j : Json) (k : String) : Array Json := (j.getObjVal? k >>= Json.getArr?).toOption.getD #[]
private def obj (j : Json) (k : String) : Json := (j.getObjVal? k).toOption.getD Json.null
private def bool (j : Json) (k : String) : Bool := (j.getObjVal? k >>= Json.getBool?).toOption.getD false

private def fixed1 (x : Float) : String :=
  let r := (x * 10).round / 10
  let s := toString r
  match s.splitOn "." with
  | [a, b] => a ++ "." ++ String.ofList (b.toList.take 1)
  | _ => s

/-- Bytes as `512 B`, `4.0 KiB`, `1.8 MiB`, `2.1 GiB`. -/
def fmtBytes (b : Float) : String :=
  if b < 1024 then s!"{b.round.toUInt64} B"
  else if b < 1024 * 1024 then s!"{fixed1 (b / 1024)} KiB"
  else if b < 1024 * 1024 * 1024 then s!"{fixed1 (b / 1048576)} MiB"
  else s!"{fixed1 (b / 1073741824)} GiB"

/-- The report's `retained` section, if it tracked retained memory. -/
def section? (j : Json) : Option Json :=
  match j.getObjVal? "retained" with
  | .ok r => if r.isNull then none else some r
  | _ => none

/-- What a report without retained memory says about it. -/
def notTracked : String :=
  "retained memory: not tracked in this report (`leanprof run --retained` tracks which allocation sites hold memory)"

private def placed (fn place : String) : String := if place.isEmpty then fn else s!"{fn} ({place})"

/-- One holder, as `IO.Ref from F (pos)` or `closure of F`. -/
def holder (h : Json) : String :=
  let k := str h "kind"
  let fn := str h "function"
  if fn.isEmpty then s!"{k} (made where leanprof does not look)"
  else if k == "closure" then s!"closure of {placed fn (str h "where")}"
  else s!"{k} from {placed fn (str h "where")}"

/-- The root of a chain, in words. -/
def root (r : Json) : String :=
  match str r "kind" with
  | "global" => s!"global {placed (str r "name") (str r "where")}"
  | "stack" => s!"a local of {placed (if (str r "name").isEmpty then "an unknown function" else str r "name") (str r "where")} (stack)"
  | "constant" => "a module constant (persistent)"
  | "cycle" => "a reference cycle"
  | _ => "nothing leanprof can see (another thread's stack, the runtime, or an object made in precompiled code)"

/-- What holds a row of a walk, nearest first, down to its root. -/
def chain (p : Json) : String :=
  let hs := (arr p "held_by").map holder
  let hs := if bool p "elided" then hs.push "..." else hs
  " <- ".intercalate (hs.push (root (obj p "root"))).toList

/-- The walk that best shows the peak: the one near the peak, else the
snapshot with the most live bytes, else the one at exit. -/
def mainWalk? (r : Json) : Option Json :=
  let ws := arr r "walks"
  match ws.find? (str · "when" == "peak") with
  | some w => some w
  | none =>
    let snaps := (ws.filter (str · "when" == "snapshot")).qsort fun a b => num a "live_bytes" > num b "live_bytes"
    snaps[0]? <|> ws.find? (str · "when" == "exit")

/-- Sites by live bytes at the peak (or at exit, when more), as one line each. -/
def siteLines (r : Json) (limit : Nat) : Array String :=
  let key (s : Json) := max (num s "peak_bytes") (num s "exit_bytes")
  let sites := ((arr r "sites").filter (key · > 0)).qsort fun a b => key a > key b
  sites[0:min limit sites.size].toArray.map fun s =>
    s!"{fmtBytes (num s "peak_bytes")} in {(num s "peak_objects").toUInt64} objects at the peak, " ++
    s!"{fmtBytes (num s "exit_bytes")} at exit{if bool s "growing" then ", growing" else ""}: " ++
    placed (str s "function") (str s "where") ++ (if str s "scope" == "-" || (str s "scope").isEmpty then "" else s!" in scope {str s "scope"}")

/-- Sites whose live bytes kept rising over the run. -/
def growthLines (r : Json) : Array String :=
  ((arr r "sites").filter (bool · "growing")).map fun s =>
    let g := obj s "growth"
    s!"{placed (str s "function") (str s "where")} kept growing over the second half of the run, " ++
    s!"{fmtBytes (num g "from")} -> {fmtBytes (num g "to")} (rose in {(num g "rises").toUInt64} of {(num g "steps").toUInt64} samples)"

/-- The rows of a walk: bytes, objects, what, and what holds them. -/
def walkLines (w : Json) (limit : Nat) (fixes := true) : Array String := Id.run do
  let mut out : Array String := #[]
  let ps := arr w "paths"
  for p in ps[0:min limit ps.size] do
    out := out.push s!"{fmtBytes (num p "bytes")} in {(num p "objects").toUInt64} {str p "kind"} from {placed (str p "function") (str p "where")}"
    out := out.push s!"  held by {chain p}"
    if fixes && !(str p "hint").isEmpty then out := out.push s!"  fix: {str p "hint"}"
  return out

/-- Coverage: what leanprof saw and did not see. -/
def coverage (r : Json) : String :=
  if !bool r "frees_seen" then
    "frees were not seen (the program was built without the free shims): live counts are upper bounds"
  else
    s!"{(num r "unseen_objects").toUInt64} objects ({fmtBytes (num r "unseen_bytes")}) were freed where leanprof " ++
    "does not look (precompiled code, the runtime) and found freed later; objects made there are not tracked"

/-- The section as text: totals, sites, growth and what holds the most at the peak. -/
def lines (j : Json) (limit : Nat := 5) : Array String := Id.run do
  let some r := section? j | return #[notTracked]
  let mut out := #[s!"retained memory: peak {fmtBytes (num r "peak_bytes")} in {(num r "peak_objects").toUInt64} objects, " ++
    s!"{fmtBytes (num r "exit_bytes")} in {(num r "exit_objects").toUInt64} objects at exit (objects compiled Lean code allocated)",
    s!"  coverage: {coverage r}"]
  out := out ++ (siteLines r limit).map ("  " ++ ·)
  out := out ++ (growthLines r).map ("  growing: " ++ ·)
  if let some w := mainWalk? r then
    out := out.push s!"  what holds it ({str w "when"} walk, {fmtBytes (num w "live_bytes")} live):"
    out := out ++ (walkLines w limit).map ("    " ++ ·)
  return out

/-- `hot retained`: sites by live bytes at the peak. -/
def hotLines (j : Json) (limit : Nat) : Array String :=
  match section? j with
  | some r => siteLines r limit
  | none => #[notTracked]

/-- Findings for `explain`: the largest retention chains with their causes
and fixes, then leak-like growth. `filter` keeps rows whose function contains it. -/
def findings (j : Json) (filter : String := "") (limit : Nat := 5) : Array String := Id.run do
  let some r := section? j | return #[]
  let has (p : Json) := filter.isEmpty || ((str p "function").splitOn filter).length > 1
  let mut out : Array String := #[]
  if let some w := mainWalk? r then
    -- small rows (module constants, runtime glue) are left to the report
    let ps := (arr w "paths").filter fun p => has p && num p "bytes" ≥ 1024
    for p in ps[0:min limit ps.size] do
      out := out.push (s!"RETAINED {fmtBytes (num p "bytes")} in {(num p "objects").toUInt64} {str p "kind"} from " ++
        s!"{placed (str p "function") (str p "where")} at the {str w "when"} walk")
      out := out.push s!"  held by: {chain p}"
      unless (str p "hint").isEmpty do out := out.push s!"  fix: {str p "hint"}"
  for s in (arr r "sites").filter fun s => bool s "growing" && has s do
    let g := obj s "growth"
    out := out.push (s!"GROWING {placed (str s "function") (str s "where")}: its live objects kept rising, " ++
      s!"{fmtBytes (num g "from")} -> {fmtBytes (num g "to")} over the second half of the run. In a long-running " ++
      "program this is a leak: find what holds them in the RETAINED rows (or take Leanprof.retainedSnapshot later in the run).")
  return out

/-- Findings as JSON, for `explain --json`. -/
def findingsJson (j : Json) (limit : Nat := 10) : Json := Id.run do
  let some r := section? j | return Json.null
  let w := (mainWalk? r).getD Json.null
  let ps := arr w "paths"
  return Json.mkObj [("walk", str w "when"),
    ("paths", Json.arr ps[0:min limit ps.size].toArray),
    ("growing", Json.arr ((arr r "sites").filter (bool · "growing")))]

end Leanprof.Retained
