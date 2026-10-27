import Lean.Data.Json
import Leanprof.Regress

/-!
# The difference of two reports, per declaration and per call site

`elab --since-last` writes it (`FILE.delta.json` next to the report): what an
edit did to a file's compile time, for a person or an agent ("+12.3 kHB in
`foo`, from unfolding `bar`").

For two `elab` reports: each declaration whose cost changed, at its first line
in the newer report, with what changed inside it when both reports have it
(`Regress.explainDecl`: the definitions unfolded, instances and simp lemmas
whose credited work or counts changed). For two `run` or `stat` reports: copy
sites and allocation sites whose counts changed, and scopes whose calls changed
or whose time changed by more than the time thresholds.

Counts are exact and heartbeats nearly so, so a declaration counts as changed
when its heartbeats moved by more than `Regress.hbNoise` (1,000), and as a
regression above 1% and 1,000 heartbeats, as in `compare`. Time (an `elab`
report without `--heartbeats`, a run's scopes) counts when it moved by more
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
  -- a file with errors stops being elaborated at the first: what follows is not gone
  let partial_ := errors nj > 0
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
      if partial_ || b.total ≤ 0 then continue
      rows := rows.push (b.total, Json.mkObj [("key", Json.str k), ("name", Json.str name), ("pos", Json.str ""),
        ("status", Json.str "gone"), ("base", toJson b.total), ("new", toJson (0 : Nat)), ("change", toJson (-b.total)),
        ("regression", Json.bool false)])
    | none, none => pure ()
  return Json.mkObj [("decls", Json.arr ((rows.qsort fun a b => a.1 > b.1).map (·.2))),
    ("total", Json.mkObj [("base", toJson (jnum bj "wall_ns")), ("new", toJson (jnum nj "wall_ns"))]),
    ("errors", toJson (errors nj)),
    ("threshold", toJson ni.threshold)]

/-- Counts per key of a run report's `field` array: (count, bytes, where, entry). -/
def sites (j : Json) (field : String) (key : Json → String) (count bytes : Json → Float) :
    Std.HashMap String (Float × Float × String × Json) := Id.run do
  let mut out : Std.HashMap String (Float × Float × String × Json) := {}
  for e in jarr j field do
    let k := key e
    let (c, b, w, _) := out.getD k (0, 0, jstr e "where", e)
    out := out.insert k (c + count e, b + bytes e, if w.isEmpty then jstr e "where" else w, e)
  return out

/-- The sites whose counts differ, largest change first. -/
def siteDelta (b n : Std.HashMap String (Float × Float × String × Json)) (fields : Json → List (String × Json)) :
    Array Json :=
  let keys := (b.toList.map (·.1) ++ n.toList.map (·.1)).eraseDups.toArray
  let rows := keys.filterMap fun k =>
    let (bc, bb, bw, be) := b.getD k (0, 0, "", Json.null)
    let (nc, nb, nw, ne) := n.getD k (0, 0, "", Json.null)
    if bc == nc then none
    else some ((nc - bc).abs, Json.mkObj ([("key", Json.str k), ("where", Json.str (if nw.isEmpty then bw else nw)),
      ("base", toJson bc), ("new", toJson nc), ("change", toJson (nc - bc)),
      ("base_bytes", toJson bb), ("new_bytes", toJson nb)] ++ fields (if ne.isNull then be else ne)))
  (rows.qsort fun x y => x.1 > y.1).map (·.2)

def runDelta (t : Thresholds) (bj nj : Json) : Json :=
  let copyKey (c : Json) := s!"{jstr c "function"} [{jstr c "kind"}] in {jstr c "scope"}"
  let copyCount (c : Json) := jnum c "shared" + jnum c "multi_threaded"
  let copies := siteDelta (sites bj "copies" copyKey copyCount (jnum · "bytes")) (sites nj "copies" copyKey copyCount (jnum · "bytes"))
    fun c => [("function", Json.str (jstr c "function")), ("kind", Json.str (jstr c "kind")), ("scope", Json.str (jstr c "scope"))]
  -- code without a symbol is named by its address, which moves between runs
  let allocKey (a : Json) :=
    let f := jstr a "function"
    s!"{if f.startsWith "0x" then "(no symbol)" else f} in {jstr a "scope"}"
  let counted (j : Json) := !(jarr j "allocations").isEmpty
  let allocs := if counted bj && counted nj then
      siteDelta (sites bj "allocations" allocKey (jnum · "allocs") (jnum · "bytes"))
        (sites nj "allocations" allocKey (jnum · "allocs") (jnum · "bytes"))
        fun a => [("function", Json.str (jstr a "function")), ("scope", Json.str (jstr a "scope"))]
    else #[]
  let scopeKey' (s : Json) := s!"{jstr s "name"} {jstr s "pos"}"
  let scopeMap (j : Json) : Std.HashMap String Json :=
    (jarr j "scopes").foldl (fun m s => m.insert (scopeKey' s) s) {}
  let bs := scopeMap bj
  let ns := scopeMap nj
  let scopes := ((ns.toList.filterMap fun (k, n) => do
    let b ← bs.get? k
    let (bt, nt) := (jnum b "total_ns", jnum n "total_ns")
    let (bc, nc) := (jnat b "calls", jnat n "calls")
    guard (bc != nc || t.moved bt nt)
    return ((nt - bt).abs, Json.mkObj [("key", Json.str k), ("name", Json.str (jstr n "name")), ("pos", Json.str (jstr n "pos")),
      ("base_ns", toJson bt), ("new_ns", toJson nt), ("base_calls", toJson bc), ("new_calls", toJson nc)])).toArray.qsort
    fun a b => a.1 > b.1).map (·.2)
  let total (j : Json) (f : String) (count : Json → Float) := (jarr j f).foldl (fun a e => a + count e) 0
  Json.mkObj [("copies", Json.arr copies), ("allocations", Json.arr allocs), ("scopes", Json.arr scopes),
    ("allocations_counted", Json.bool (counted bj && counted nj)),
    ("total", Json.mkObj [("base_copies", toJson (total bj "copies" copyCount)), ("new_copies", toJson (total nj "copies" copyCount)),
      ("base_allocs", toJson (total bj "allocations" (jnum · "allocs"))),
      ("new_allocs", toJson (total nj "allocations" (jnum · "allocs")))])]

/-- The difference from `bj` to `nj`. Reports of different kinds (or units)
are not compared: the result says so (`comparable: false`). -/
def compute (bj nj : Json) (t : Thresholds := {}) : Json :=
  let kind := if isElab nj then "elab" else "run"
  let comparable := isElab bj == isElab nj && heartbeats bj == heartbeats nj
  let head := [("version", toJson version), ("delta", Json.bool true), ("kind", Json.str kind),
    ("unit", Json.str (if heartbeats nj then "heartbeats" else "ns")), ("comparable", Json.bool comparable)]
  if !comparable then Json.mkObj (head ++ [("first", Json.bool true)])
  else match (if isElab nj then elabDelta t bj nj else runDelta t bj nj) with
    | .obj kvs => Json.mkObj (head ++ [("first", Json.bool false)] ++ kvs.toList.map fun ⟨k, v⟩ => (k, v))
    | j => j

/-- The difference written when there is nothing to compare with yet. -/
def first (nj : Json) : Json :=
  Json.mkObj [("version", toJson version), ("delta", Json.bool true), ("kind", Json.str (if isElab nj then "elab" else "run")),
    ("unit", Json.str (if heartbeats nj then "heartbeats" else "ns")), ("comparable", Json.bool true), ("first", Json.bool true)]

def fmtAmount (hb : Bool) (x : Float) : String :=
  if hb then fmtKHB x else s!"{fmt2 (x / 1e6)} ms"

/-- A few lines saying what changed, for the terminal. -/
def summary (d : Json) (top : Nat := 5) : Array String := Id.run do
  if (d.getObjValAs? Bool "first").toOption.getD false then
    return #["no earlier profile to compare with: the next one is compared with this one"]
  let hb := jstr d "unit" == "heartbeats"
  if jstr d "kind" == "elab" then
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
  else
    let mut out := #[]
    for (field, what) in [("copies", "copies"), ("allocations", "allocations")] do
      let rows := jarr d field
      if rows.isEmpty then continue
      out := out.push s!"{what}: {rows.size} {if rows.size == 1 then "site" else "sites"} changed"
      for e in rows.toList.take top do
        out := out.push s!"  {fmtSigned (fun x => groupDigits x.toUInt64.toNat) (jnum e "change")}  {jstr e "key"}{if (jstr e "where").isEmpty then "" else s!" ({jstr e "where"})"}"
    for s in (jarr d "scopes").toList.take top do
      if jnat s "base_calls" != jnat s "new_calls" then
        out := out.push s!"  calls {jnat s "base_calls"} -> {jnat s "new_calls"}  {jstr s "name"} ({jstr s "pos"})"
    if out.isEmpty then out := #["no copies, allocations or calls changed"]
    return out

end Leanprof.Delta
