import Lean.Data.Json

/-!
# Why a declaration or a copy site got worse

`compare` and `report-md` say *that* a declaration costs more heartbeats or a
call site copies more. This module says *what changed inside it*, from what the
two reports already record:

* `elab` reports (`elab.json`), per declaration: the constants credited with
  work (`causes`: the definitions `isDefEq` unfolded and `whnf` reduced, the
  instances tried, the simp lemmas that rewrote, each with the heartbeats of the
  work it caused and how many times), its repeated operations (`repeated`), and
  with `--counts` Lean's exact `diagnostics` counters (`counts`). The difference
  of each between base and head, largest first, is the explanation.
* `run` reports with `leanprof explain`'s findings (`explain.json`) for the
  head: the cause explain found for each copy site whose count went up.

Everything compared is exact (counts do not vary between runs unless threads
race, heartbeats barely); what a report does not record is said to be not
recorded, never estimated.
-/

namespace Leanprof.Regress
open Lean

def jstr (j : Json) (k : String) : String := (j.getObjVal? k >>= Json.getStr?).toOption.getD ""
def jnum (j : Json) (k : String) : Float :=
  match j.getObjVal? k with
  | .ok (.num n) => n.toFloat
  | _ => 0
def jarr (j : Json) (k : String) : Array Json := (j.getObjVal? k >>= Json.getArr?).toOption.getD #[]
def jnat (j : Json) (k : String) : Nat := (jnum j k).toUInt64.toNat

/-- How many entries `elab` keeps per line in `causes`, and in `repeated` and per
counter in `counts` (half as many): `LeanprofElab.causeLimit`. A list that long
may have left entries out. -/
def causeLimit : Nat := 20

/-! ## Compile time: one declaration's records -/

/-- One declaration of an `elab` report: its lines (elaboration, kernel and
compiler work can sit on different lines of it) merged. -/
structure Decl where
  pos : String := ""
  total : Float := 0
  /-- elaboration, kernel, compiler, linters -/
  parts : Array Float := #[0, 0, 0, 0]
  /-- (kind, constant) ↦ (heartbeats of the work it caused, times credited, file:line) -/
  causes : Std.HashMap (String × String) (Float × Nat × String) := {}
  /-- (class, operation) ↦ (times, heartbeats) -/
  repeated : Std.HashMap (String × String) (Nat × Float) := {}
  /-- (counter, constant) ↦ (count, file:line) -/
  counts : Std.HashMap (String × String) (Nat × String) := {}
  /-- a line's list was cut at the limit: an entry missing from it is unknown, not zero -/
  causesCut : Bool := false
  repeatedCut : Bool := false
  countsCut : Std.HashSet String := {}
  /-- the report records causes per declaration (made by this version of `elab`) -/
  recorded : Bool := false
  deriving Inhabited

/-- What an `elab` report says about how it was made. -/
structure ElabInfo where
  threshold : Nat := 0
  counts : Bool := false
  decls : Std.HashMap String Decl := {}
  deriving Inhabited

def partNames : Array String := #["elaboration", "kernel", "compiler", "linters"]

def scopeKey (s : Json) : String :=
  if (jstr s "key").isEmpty then s!"{jstr s "name"} {jstr s "pos"}" else jstr s "key"

def loadElab (j : Json) : ElabInfo := Id.run do
  let mut decls : Std.HashMap String Decl := {}
  for s in jarr j "scopes" do
    let k := scopeKey s
    let mut d := decls.getD k {}
    if d.pos.isEmpty then d := { d with pos := jstr s "pos" }
    d := { d with total := d.total + jnum s "total_ns",
                  parts := #[d.parts[0]! + jnum s "elab_ns", d.parts[1]! + jnum s "kernel_ns",
                             d.parts[2]! + jnum s "compile_ns", d.parts[3]! + jnum s "lint_ns"] }
    if (s.getObjVal? "causes").toOption.isSome then d := { d with recorded := true }
    let cs := jarr s "causes"
    if cs.size ≥ causeLimit then d := { d with causesCut := true }
    for c in cs do
      let key := (jstr c "kind", jstr c "name")
      let (x, n, w) := d.causes.getD key (0, 0, jstr c "where")
      d := { d with causes := d.causes.insert key (x + jnum c "amount", n + jnat c "count", w) }
    let rs := jarr s "repeated"
    if rs.size ≥ causeLimit / 2 then d := { d with repeatedCut := true }
    for r in rs do
      let key := (jstr r "class", jstr r "op")
      let (n, x) := d.repeated.getD key (0, 0)
      d := { d with repeated := d.repeated.insert key (n + jnat r "count", x + jnum r "total") }
    let ns := jarr s "counts"
    let mut perCounter : Std.HashMap String Nat := {}
    for c in ns do
      let ctr := jstr c "counter"
      perCounter := perCounter.insert ctr (perCounter.getD ctr 0 + 1)
      let key := (ctr, jstr c "name")
      let (n, w) := d.counts.getD key (0, jstr c "where")
      d := { d with counts := d.counts.insert key (n + jnat c "count", w) }
    for (ctr, n) in perCounter do
      if n ≥ causeLimit / 2 then d := { d with countsCut := d.countsCut.insert ctr }
    decls := decls.insert k d
  return { threshold := jnat j "threshold", counts := (j.getObjValAs? Bool "counts").toOption.getD false, decls }

/-! ## Compile time: the difference -/

/-- One thing that changed inside a declaration. `value` is heartbeats for work
credited to a constant (`times`: how often) or to a repeated operation (`times`:
how many times it ran), and a count for a `diagnostics` counter. `none`: not
in that report's list, which was cut (so not known). -/
structure Row where
  /-- `unfold`, `whnf`, `instance`, `simp`, `repeated`, or a counter: `unfolds`,
  `kernel`, `instances`, `simp_used`, `simp_failed` -/
  what : String
  name : String
  loc : String := ""
  base : Option Float
  new : Option Float
  baseTimes : Option Nat := none
  newTimes : Option Nat := none
  deriving Inhabited

def Row.isCount (r : Row) : Bool := ["unfolds", "kernel", "instances", "simp_used", "simp_failed", "grind_instances"].contains r.what

/-- The change, when both sides are known. -/
def Row.delta? (r : Row) : Option Float := do return (← r.new) - (← r.base)

def Row.timesDelta (r : Row) : Int :=
  match r.baseTimes, r.newTimes with
  | some b, some n => (n : Int) - b
  | _, _ => 0

/-- Heartbeats credited to the same constant move by a few hundred between
profiles of the same code (as a declaration's total does by up to about 1 in
10,000): a change this small, with the same number of times, is not counted as
a change, the threshold `compare` uses for a declaration. -/
def hbNoise : Float := 1000

/-- The heartbeats credited went up by more than `hbNoise`, or a count went up. -/
def Row.grew (r : Row) : Bool := r.delta?.any fun d => d > (if r.isCount then 0 else hbNoise)

/-- How the row is ordered: increases first (in heartbeats or counts, then in how
many times), then rows with an unknown side (a list was cut), then changes of
heartbeats within `hbNoise` at the same number of times, then decreases; larger
changes first within each. -/
def Row.weight (r : Row) : Nat × Float :=
  match r.delta? with
  | some d =>
    let group :=
      if r.grew || (d.abs ≤ hbNoise && r.timesDelta > 0) then 3
      else if !r.isCount && d.abs ≤ hbNoise && r.timesDelta == 0 then 1
      else 0
    (group, d.abs)
  | none => (2, max (r.new.getD 0) (r.base.getD 0))

/-- The row says the declaration does more of it in head. -/
def Row.up (r : Row) : Bool := r.weight.1 == 3

def Row.before (x y : Row) : Bool :=
  let (a, b) := x.weight
  let (c, d) := y.weight
  a > c || (a == c && (b > d || (b == d && (x.timesDelta.natAbs > y.timesDelta.natAbs ||
    (x.timesDelta.natAbs == y.timesDelta.natAbs && (x.what < y.what || (x.what == y.what && x.name < y.name)))))))

/-- The order counters are listed in. -/
def counterRank : String → Nat
  | "grind_instances" => 0
  | "simp_used" => 1
  | "simp_failed" => 2
  | "instances" => 3
  | "unfolds" => 4
  | _ => 5

structure Explanation where
  key : String
  pos : String
  base : Float
  new : Float
  /-- elaboration, kernel, compiler and linters, those that changed: (part, base, head) -/
  parts : Array (String × Float × Float)
  /-- heartbeats credited to constants and repeated operations, largest change first -/
  work : Array Row
  /-- exact `diagnostics` counters, largest change first -/
  counts : Array Row
  /-- what the explanation can and cannot say -/
  notes : Array String
  /-- the change to name first: the largest, or one nearly as large of a constant
  declared in the profiled files (`tri` rather than `Decidable.decide` that
  reduced it) -/
  headline : Option Row := none
  deriving Inhabited

/-- Rows of `base` and `new` (keyed maps of `(value, times, location)`), those
that changed. `cutB`/`cutN`: whether a key missing from that side is unknown. -/
def diffRows (what : String × String → String) (name : String × String → String)
    (b n : Std.HashMap (String × String) (Float × Option Nat × String)) (cutB cutN : String × String → Bool) :
    Array Row := Id.run do
  let keys := (b.toList.map (·.1) ++ n.toList.map (·.1)).eraseDups
  let mut out := #[]
  for k in keys do
    let bv := b.get? k
    let nv := n.get? k
    let side (v : Option (Float × Option Nat × String)) (cut : Bool) : Option Float × Option Nat :=
      match v with
      | some (x, t, _) => (some x, t)
      | none => if cut then (none, none) else (some 0, some 0)
    let (bx, bt) := side bv (cutB k)
    let (nx, nt) := side nv (cutN k)
    -- times are only counted where the value has them
    let bt := if (bv.bind (·.2.1)).isNone && (nv.bind (·.2.1)).isNone then none else bt
    let nt := if (bv.bind (·.2.1)).isNone && (nv.bind (·.2.1)).isNone then none else nt
    if bx == nx && bt == nt then continue
    let loc := match nv, bv with
      | some (_, _, w), _ => w
      | none, some (_, _, w) => w
      | none, none => ""
    out := out.push { what := what k, name := name k, loc, base := bx, new := nx, baseTimes := bt, newTimes := nt }
  return out.qsort Row.before

/-- `n` with thousands separators. -/
def groupDigits (n : Nat) : String :=
  if _h : n < 1000 then toString n
  else
    let r := n % 1000
    groupDigits (n / 1000) ++ "," ++ (if r < 10 then "00" else if r < 100 then "0" else "") ++ toString r
termination_by n
decreasing_by omega

def fmtNum (x : Float) : String := groupDigits x.toUInt64.toNat

/-- Why declaration `key` costs `new.total - base.total` more heartbeats. -/
def explainDecl (bi ni : ElabInfo) (key : String) (b n : Decl) : Explanation := Id.run do
  let parts := (List.range 4).toArray.filterMap fun i =>
    if b.parts[i]! == n.parts[i]! then none else some (partNames[i]!, b.parts[i]!, n.parts[i]!)
  let causeMap (d : Decl) : Std.HashMap (String × String) (Float × Option Nat × String) :=
    d.causes.fold (fun m k (x, t, w) => m.insert k (x, some t, w)) {}
  let repMap (d : Decl) : Std.HashMap (String × String) (Float × Option Nat × String) :=
    d.repeated.fold (fun m k (t, x) => m.insert k (x, some t, "")) {}
  let countMap (d : Decl) : Std.HashMap (String × String) (Float × Option Nat × String) :=
    d.counts.fold (fun m k (c, w) => m.insert k (c.toFloat, none, w)) {}
  let work := diffRows (·.1) (·.2) (causeMap b) (causeMap n) (fun _ => b.causesCut) (fun _ => n.causesCut) ++
    -- a repeated operation missing from an uncut list ran at most once there: not
    -- comparable as a count of repetitions, so only listed when both sides have it or a
    -- side is cut
    (diffRows (fun _ => "repeated") (fun (cls, op) => s!"[{cls}] {op}") (repMap b) (repMap n)
      (fun _ => b.repeatedCut) (fun _ => n.repeatedCut)).filter (fun r => r.base != some 0 && r.new != some 0)
  -- a report that records no causes cannot be compared with one that does: every
  -- cause would look new
  let both := b.recorded && n.recorded
  let work := if both then work.qsort Row.before else #[]
  let counts := if !both then #[] else diffRows (·.1) (·.2) (countMap b) (countMap n)
    (fun k => b.countsCut.contains k.1) (fun k => n.countsCut.contains k.1)
  -- what the elaborator chose to do (theorems grind instantiated, simp lemmas, instances)
  -- before what it led to (definitions unfolded, by the kernel last): a kernel count is
  -- usually large and a consequence
  let counts := counts.qsort fun x y =>
    x.weight.1 > y.weight.1 || (x.weight.1 == y.weight.1 &&
      (counterRank x.what < counterRank y.what || (counterRank x.what == counterRank y.what && x.before y)))
  let d := n.total - b.total
  let mut notes : Array String := #[]
  if !b.recorded || !n.recorded then
    notes := notes.push (s!"cause not attributed: the {if !b.recorded && !n.recorded then "reports do" else if !b.recorded then "base report does" else "head report does"} " ++
      "not record what each declaration's work went to (made by an older `leanprof elab`); profile both commits with this version")
  else if work.isEmpty && counts.isEmpty then
    let below := if ni.threshold > 0 then s!" (operations under {fmtNum ni.threshold.toFloat} heartbeats are not recorded: `--threshold` lowers it)" else ""
    let where_ := if parts.isEmpty then "" else
      let (p, x, y) := (parts.qsort fun (_, x1, y1) (_, x2, y2) => (y1 - x1).abs > (y2 - x2).abs)[0]!
      s!"; the change is in {p} ({fmtNum x} → {fmtNum y} heartbeats)"
    notes := notes.push (s!"cause not attributed: no definition unfolded, instance, simp lemma or repeated operation " ++
      s!"recorded for this declaration changed{below}{where_}")
  else if !work.isEmpty then
    let up := (work.filter Row.grew).filterMap (·.delta?)
    let best := up.foldl max 0
    if best > 0 && d > 0 && best < d / 2 then
      notes := notes.push (s!"the largest credited increase is {fmtNum best} of the declaration's {fmtNum d} heartbeats: " ++
        "most of the change is in work not credited to a named constant")
    else if best == 0 then
      notes := notes.push (s!"no constant is credited with more than {fmtNum hbNoise} more heartbeats (what changed is how often each was used): " ++
        s!"the {fmtNum d} heartbeats are in work not credited to a named constant" ++
        (if ni.threshold > 0 then s!" (operations under {fmtNum ni.threshold.toFloat} heartbeats are not timed: `--threshold` lowers it)" else ""))
    if up.size > 1 then
      notes := notes.push ("heartbeats credited to different constants overlap (reducing one can unfold another), " ++
        "so they need not add up to the change")
  if b.recorded && n.recorded && !(bi.counts && ni.counts) then
    notes := notes.push "exact unfold, instance and simp-lemma counts need `leanprof elab --counts` on both commits"
  if bi.threshold != ni.threshold then
    notes := notes.push s!"the reports were made with different thresholds ({bi.threshold} and {ni.threshold} heartbeats): what is recorded differs"
  -- declared in the profiled files: their declarations' names (keys are `File.lean name`)
  let isLocal (c : String) : Bool := ni.decls.toList.any fun (k, _) =>
    match k.splitOn " " with
    | [_, d] => c == d || c.endsWith ("." ++ d)
    | _ => false
  -- more heartbeats credited, else a counter that went up, else more times credited
  let grew := Row.grew
  let headline := work.find? grew <|> counts.find? grew <|> work.find? Row.up
  let headline := match headline with
    | some top =>
      let close (r : Row) : Bool := r.what == top.what && grew r == grew top && 2 * r.weight.2 ≥ top.weight.2 && isLocal r.name
      if isLocal top.name then some top else (work.find? close <|> counts.find? close) <|> some top
    | none => none
  return { key, pos := n.pos, base := b.total, new := n.total, parts, work, counts, notes, headline }

/-! ## Run time: explain's causes for copy sites -/

/-- One finding of `leanprof explain` (`explain.json`). -/
structure Finding where
  function : String
  kind : String
  scope : String
  symbol : String
  cause : String
  why : String
  file : String
  lines : Array Nat
  copies : Nat     -- shared + multi-threaded copies of the site it explains
  deriving Inhabited

def loadExplain (j : Json) : Array Finding :=
  (match j with | .arr a => a | _ => jarr j "findings").map fun f =>
    { function := jstr f "function", kind := jstr f "kind", scope := jstr f "scope", symbol := jstr f "symbol",
      cause := jstr f "cause", why := jstr f "why", file := jstr f "file",
      lines := (jarr f "lines").filterMap fun (l : Json) => l.getNat?.toOption,
      copies := jnat f "shared" + jnat f "multi_threaded" }

/-- The key `compare` and `report-md` give a copy site. -/
def copyKey (function kind scope : String) : String :=
  s!"{if function.startsWith "0x" then "(no symbol)" else function} [{kind}] in {scope}"

/-- explain's findings for copy site `key` of a report that counted `count`
copies there: `.ok` with the findings (none: explain found nothing there),
`.error` when the findings are for another run (their counts differ). -/
def findingsFor (fs : Array Finding) (key : String) (count : Nat) : Except String (Array Finding) := do
  -- explain.json from before findings named their scope: by function and kind
  let mine := fs.filter fun f => copyKey f.function f.kind f.scope == key ||
    (f.scope.isEmpty && key.startsWith (copyKey f.function f.kind ""))
  if mine.isEmpty then return #[]
  -- the sites explained (one per symbol), with their counts
  let sites := mine.foldl (fun (m : Std.HashMap String Nat) f => m.insert f.symbol f.copies) {}
  let explained := sites.fold (fun s _ n => s + n) 0
  if explained != count then
    throw s!"explain.json is not of this report: it explains {explained} copies here, the report has {count}"
  -- one finding per distinct reason
  return mine.foldl (fun acc f => if acc.any (·.why == f.why) then acc else acc.push f) #[]

/-! ## Markdown from untrusted names -/

/-- A name as inline code in a Markdown table. Names come from the profiled
code (a pull request's, in the Action): a backtick, `|` or line break would
end the code span or the row and let the rest be read as Markdown or HTML in
the comment. -/
def mdCode (s : String) : String :=
  let s := ((s.replace "`" "'").replace "|" "\\|").map fun c => if c == '\n' || c == '\r' then ' ' else c
  s!"`{s}`"

/-- Text from the profiled code (explain's prose quotes its names in backticks)
as Markdown that cannot become anything else: code spans through `mdCode`, the
rest with Markdown and HTML punctuation escaped and no `@mention` or `#123`
link. -/
def mdProse (s : String) : String := Id.run do
  let parts := (s.map fun c => if c == '\n' || c == '\r' then ' ' else c).splitOn "`"
  let mut out := ""
  let mut i := 0
  for p in parts do
    -- an unpaired backtick: the rest is prose
    if i % 2 == 1 && i + 1 < parts.length then out := out ++ mdCode p
    else
      for c in p.toList do
        out := out ++ match c with
          | '<' => "&lt;" | '>' => "&gt;" | '&' => "&amp;" | '@' => "&#64;" | '#' => "&#35;"
          | '\\' | '*' | '_' | '[' | ']' | '(' | ')' | '~' | '|' | '!' | '`' => s!"\\{c}"
          | c => c.toString
    i := i + 1
  return out

/-- A name as inline code inside HTML (a `<summary>`, where Markdown is not read). -/
def htmlCode (s : String) : String :=
  let e := s.foldl (fun acc c => acc ++ match c with
    | '<' => "&lt;" | '>' => "&gt;" | '&' => "&amp;" | '"' => "&quot;" | '\n' | '\r' => " " | c => c.toString) ""
  s!"<code>{e}</code>"

end Leanprof.Regress
