import Lean.Data.Json
import Leanprof.Regress

/-!
# The difference of two compile-time reports, per declaration

`elab --since-last` writes it (`FILE.delta.json` next to the report): what an
edit did to a file's compile time, for a person or an agent ("+12.3 kHB in
`foo`, from unfolding `bar`").

For two `elab` reports: each declaration whose cost changed, at its first line
in the newer report, with what changed inside it when both reports have it
(`Regress.explainDecl`: the definitions unfolded, instances and simp lemmas
whose credited work or counts changed).

Counts are exact and heartbeats nearly so, so a declaration counts as changed
when its heartbeats moved by more than `Regress.hbNoise` (1,000), and as a
regression above 1% and 1,000 heartbeats, as in `compare`. Time (an `elab`
report without `--heartbeats`) counts when it moved by more
than `Thresholds.pct` percent and `Thresholds.minMs` ms: `compare`'s
`--threshold` and `--min-ms`, 10 and 1 by default.
-/

namespace Leanprof.Delta
open Lean Leanprof.Regress

/-- The version of the JSON written by `compute`. -/
def version : Nat := 1

def isElab (j : Json) : Bool := (j.getObjValAs? Bool "elab").toOption.getD false

def heartbeats (j : Json) : Bool := jstr j "unit" == "heartbeats"

/-- Errors in the files of an `elab` report (costs stop at the first error of a file). -/
def errors (j : Json) : Nat := (jarr j "files").foldl (fun a f => a + jnat f "errors") 0

/-- The files of an `elab` report that had errors. -/
def failedFiles (j : Json) : Std.HashSet String :=
  (jarr j "files").foldl (fun s f => if jnat f "errors" > 0 then s.insert (jstr f "file") else s) {}

/-- `File.lean:12` as (file, line). -/
def splitPos (p : String) : String × Nat :=
  match p.splitOn ":" with
  | [f, l] => (f, l.toNat?.getD 0)
  | _ => (p, 0)

/-- Per declaration key of an `elab` report: its first line (where it starts:
kernel and compiler work can sit on later lines of it) and its name there. -/
def declStarts (j : Json) : Std.HashMap String (String × String) := Id.run do
  let mut out : Std.HashMap String (String × String) := {}
  for s in jarr j "scopes" do
    let k := scopeKey s
    let p := jstr s "pos"
    let name := (jstr s "name").replace "\n" " "
    match out.get? k with
    | some (p', _) => if (splitPos p).2 < (splitPos p').2 then out := out.insert k (p, name)
    | none => out := out.insert k (p, name)
  return out

/-- What changed inside a declaration, as JSON: `headline` (the change to
name first), the parts that changed, at most `top` rows of credited work and of
exact counts (each with both sides and the change, as `compare` prints them),
and the notes saying what could not be attributed. For a declaration that got
cheaper (`down`), the decreases first, and no notes (they explain increases). -/
def whyJson (e : Explanation) (down : Bool := false) (top : Nat := 8) : Json :=
  let fell (r : Row) : Bool := r.delta?.any fun d => d < (if r.isCount then 0 else -hbNoise)
  let byFall (rs : Array Row) : Array Row :=
    if !down then rs else rs.filter fell ++ rs.filter (!fell ·)
  let work := byFall e.work
  let counts := byFall e.counts
  let rows := work.toList.take top ++ counts.toList.take top
  let headline := if down then work.find? fell <|> counts.find? fell else e.headline
  Json.mkObj [
    ("headline", match headline with
      | some r => Json.str s!"{whatLabel r.what} {r.name}{if r.loc.isEmpty then "" else s!" ({r.loc})"} {rowChange r}"
      | none => Json.null),
    ("parts", Json.arr (e.parts.map fun (p, x, y) => Json.mkObj [("part", Json.str p), ("base", toJson x), ("new", toJson y)])),
    ("rows", Json.arr (rows.toArray.map fun r => Json.mkObj [("what", Json.str r.what), ("label", Json.str (whatLabel r.what)),
      ("name", Json.str r.name), ("where", Json.str r.loc), ("base", Json.str (rowSide r r.base r.baseTimes)),
      ("new", Json.str (rowSide r r.new r.newTimes)), ("change", Json.str (rowChange r)), ("up", Json.bool r.up)])),
    ("more", toJson (e.work.size + e.counts.size - rows.length)),
    ("notes", toJson (if down then #[] else e.notes))]

/-- When a change of time counts, as `compare --threshold PCT --min-ms MS`. -/
structure Thresholds where
  pct : Float := 10
  minMs : Float := 1

/-- Time moved from `b` to `n` (ns) by more than the thresholds. -/
def Thresholds.moved (t : Thresholds) (b n : Float) : Bool :=
  (n - b).abs / 1e6 > t.minMs && (b <= 0 || (n - b).abs / b * 100 > t.pct)

/-- Whether a change of a declaration's cost from `b` to `n` counts: above
`hbNoise` heartbeats, or the time thresholds. -/
def changed (t : Thresholds) (hb : Bool) (b n : Float) : Bool :=
  if hb then (n - b).abs > hbNoise else t.moved b n

/-- A regression as `compare` counts it: above 1% and 1,000 heartbeats, or slower
by more than the time thresholds. -/
def regressed (t : Thresholds) (hb : Bool) (b n : Float) : Bool :=
  if hb then n - b > max (b * 0.01) 1000 else n > b && t.moved b n

def elabDelta (t : Thresholds) (bj nj : Json) : Json := Id.run do
  let hb := heartbeats bj && heartbeats nj
  let bi := loadElab bj
  let ni := loadElab nj
  let starts := declStarts nj
  let baseStarts := declStarts bj
  -- a file with errors stops being elaborated at the first: its declarations that are
  -- missing are not gone (those of the other files are)
  let failed := failedFiles nj
  let keys := (bi.decls.toList.map (·.1) ++ ni.decls.toList.map (·.1)).eraseDups.toArray
  let mut rows : Array (Float × Json) := #[]
  for k in keys do
    let (pos, name) := (starts.get? k <|> baseStarts.get? k).getD ("", k)
    match bi.decls.get? k, ni.decls.get? k with
    | some b, some n =>
      unless changed t hb b.total n.total do continue
      let why := if hb then [("why", whyJson (explainDecl bi ni k b n) (down := n.total < b.total))] else []
      rows := rows.push ((n.total - b.total).abs, Json.mkObj ([("key", Json.str k), ("name", Json.str name),
        ("pos", Json.str pos), ("status", Json.str "changed"), ("base", toJson b.total), ("new", toJson n.total),
        ("change", toJson (n.total - b.total)), ("regression", Json.bool (regressed t hb b.total n.total))] ++ why))
    | none, some n =>
      if n.total ≤ 0 then continue
      rows := rows.push (n.total, Json.mkObj [("key", Json.str k), ("name", Json.str name), ("pos", Json.str pos),
        ("status", Json.str "new"), ("base", toJson (0 : Nat)), ("new", toJson n.total), ("change", toJson n.total),
        ("regression", Json.bool false)])
    | some b, none =>
      if failed.contains (splitPos pos).1 || b.total ≤ 0 then continue
      rows := rows.push (b.total, Json.mkObj [("key", Json.str k), ("name", Json.str name), ("pos", Json.str ""),
        ("status", Json.str "gone"), ("base", toJson b.total), ("new", toJson (0 : Nat)), ("change", toJson (-b.total)),
        ("regression", Json.bool false)])
    | none, none => pure ()
  return Json.mkObj [("decls", Json.arr ((rows.qsort fun a b => a.1 > b.1).map (·.2))),
    ("total", Json.mkObj [("base", toJson (jnum bj "wall_ns")), ("new", toJson (jnum nj "wall_ns"))]),
    ("errors", toJson (errors nj)),
    ("threshold", toJson ni.threshold)]

/-- The difference from `bj` to `nj`, two `elab` reports. Other reports, or reports
in different units, are not compared: the result says so (`comparable: false`). -/
def compute (bj nj : Json) (t : Thresholds := {}) : Json :=
  let comparable := isElab bj && isElab nj && heartbeats bj == heartbeats nj
  let head := [("version", toJson version), ("delta", Json.bool true), ("kind", Json.str "elab"),
    ("unit", Json.str (if heartbeats nj then "heartbeats" else "ns")), ("comparable", Json.bool comparable)]
  if !comparable then Json.mkObj (head ++ [("first", Json.bool false)])
  else match elabDelta t bj nj with
    | .obj kvs => Json.mkObj (head ++ [("first", Json.bool false)] ++ kvs.toList.map fun ⟨k, v⟩ => (k, v))
    | j => j

/-- The difference written when there is nothing to compare with yet. -/
def first (nj : Json) : Json :=
  Json.mkObj [("version", toJson version), ("delta", Json.bool true), ("kind", Json.str "elab"),
    ("unit", Json.str (if heartbeats nj then "heartbeats" else "ns")), ("comparable", Json.bool true), ("first", Json.bool true)]

def fmtAmount (hb : Bool) (x : Float) : String :=
  if hb then fmtKHB x else s!"{fmt2 (x / 1e6)} ms"

/-- A few lines saying what changed, for the terminal. -/
def summary (d : Json) (top : Nat := 5) : Array String := Id.run do
  if (d.getObjValAs? Bool "first").toOption.getD false then
    return #["no earlier profile to compare with: the next one is compared with this one"]
  if (d.getObjValAs? Bool "comparable").toOption == some false then
    return #["not compared: the earlier profile is not an elab report in the same unit; the next run is compared with this one"]
  let hb := jstr d "unit" == "heartbeats"
  let decls := jarr d "decls"
  let tot := (d.getObjVal? "total").toOption.getD Json.null
  let mut out := #[s!"{decls.size} {if decls.size == 1 then "declaration" else "declarations"} changed; " ++
    s!"file {fmtAmount hb (jnum tot "base")} -> {fmtAmount hb (jnum tot "new")} ({fmtSigned (fmtAmount hb) (jnum tot "new" - jnum tot "base")})"]
  if jnat d "errors" > 0 then
    out := out.push s!"  ({jnat d "errors"} errors in the file: declarations after the first error are not compared)"
  for e in decls.toList.take top do
    let w := (e.getObjVal? "why").toOption.getD Json.null
    let head := match (w.getObjVal? "headline").toOption.bind (·.getStr?.toOption) with
      | some h => s!"; {h}"
      | none => ""
    let status := jstr e "status"
    out := out.push s!"  {fmtSigned (fmtAmount hb) (jnum e "change")}  {if status == "changed" then "" else s!"({status}) "}{jstr e "key"}{if (jstr e "pos").isEmpty then "" else s!" ({jstr e "pos"})"}{head}"
  return out

end Leanprof.Delta
