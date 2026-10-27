import Lean.Data.Json
import Leanprof.Explain

/-!
# Why a declaration is slow to compile, and what to try

`leanprof elab` records, per declaration, what the elaborator spent its time
(or heartbeats) on: the definitions `isDefEq` and `whnf` unfolded, the
instances tried, instance searches that failed, repeated operations, the
kernel's share, and every term and tactic by its exact source range. With
`--why`, Lean also reports the lemmas each `simp` used
(`tactic.simp.trace`: `Try this: simp only [...]`), and the driver records
each `simp`'s whole range.

This module reads an `elab` report (its JSON) and, for the costliest
declarations, names the causes the data shows and a change to try. Each
finding keeps the two apart:

* `observed`: facts measured in this profile (a cost, a count, a share of
  the declaration);
* `suggestion`: what to try. For `simp` it is Lean's own `simp only` list, an
  edit `leanprof fix --elab` can apply and check (the proof still checks,
  fewer heartbeats, the proof-preservation guard passes). Everything else is a
  hypothesis: nothing here has checked it.

Pure: tested in `Tests/Main.lean`.
-/

namespace Leanprof.ElabWhy
open Lean
open Leanprof.Explain (jstr jnum jarr wrap trim has)

/-! ## Lean's `simp only` suggestions -/

/-- The tactics whose `Try this:` suggestion is an `only` list. -/
def simpHeads : List String := ["simp", "simp_all", "simpa", "dsimp"]

/-- `s` with every run of whitespace (newlines and indentation included) made one space. -/
def collapse (s : String) : String := Id.run do
  let mut out : List Char := []
  let mut space := false
  for c in s.toList do
    if c.isWhitespace then space := true
    else
      if space && !out.isEmpty then out := ' ' :: out
      space := false
      out := c :: out
  return String.ofList out.reverse

/-- The first word of a tactic: `simp`, `simp_all`, `simpa`, `dsimp?`. -/
def headWord (s : String) : String :=
  String.ofList ((collapse s).toList.takeWhile fun c => c.isAlphanum || c == '_' || c == '?' || c == '!')

/-- The tactic a `Try this:` message suggests, on one line (Lean prints it
after `Try this: `, or on the next line after `[apply]`). -/
def suggestionText (msg : String) : String :=
  let t := collapse (if msg.startsWith "Try this:" then (msg.drop 9).toString else msg)
  if t.startsWith "[apply] " then (t.drop 8).toString else t

/-- A suggestion taken apart at its `only [...]` list: the text before ` only [`, the
entries of the list (split at the commas outside brackets) and the text after its `]`. -/
def splitOnly (s : String) : Option (String × Array String × String) := Id.run do
  let parts := s.splitOn " only ["
  if parts.length < 2 then return none
  let head := parts[0]!
  let rest := " only [".intercalate (parts.drop 1)
  let mut out : Array String := #[]
  let mut cur : List Char := []
  let mut depth := 0
  let mut cs := rest.toList
  let mut closed := false
  while !cs.isEmpty do
    let c := cs.head!
    cs := cs.tail!
    if depth == 0 && c == ']' then closed := true; break
    if c == '[' || c == '(' || c == '{' || c == '⟨' then depth := depth + 1
    if c == ']' || c == ')' || c == '}' || c == '⟩' then depth := depth - 1
    if depth == 0 && c == ',' then
      out := out.push (trim (String.ofList cur.reverse)); cur := []
    else cur := c :: cur
  unless closed do return none
  let last := trim (String.ofList cur.reverse)
  return some (head, (if last.isEmpty then out else out.push last), String.ofList cs)

/-- The entries of the first `[...]` list after `only`: the lemmas a suggestion keeps. -/
def onlyLemmas (s : String) : Array String :=
  ((splitOnly s).map (·.2.1)).getD #[]

/-- Whether the source `original` of a `simp` call can be replaced by Lean's
suggestion for it, mechanically: the replacement, or why not. `variants` is the
number of different suggestions Lean made at that position (a tactic run on
several goals by `<;>` can use different lemmas on each). -/
def simpEdit? (original suggestion : String) (variants : Nat := 1) : Except String String := do
  let o := collapse original
  let hw := headWord o
  unless simpHeads.contains hw do
    throw s!"`{hw}` is not simp, simp_all, simpa or dsimp (a macro that expands to one): apply by hand"
  unless headWord suggestion == hw do throw "Lean's suggestion is for another tactic"
  if (o.splitOn " ").contains "only" then throw "it is already restricted with `only`"
  if variants > 1 then
    throw s!"it ran with {variants} different lemma lists (on several goals, `<;>`): one list for all needs a person"
  let words := (o.splitOn " ").filter (· != "")
  if has original "\n" && (words.contains "by" || words.contains "·") then
    throw "it spans lines with a tactic block inside, which one line would change: apply by hand"
  if collapse suggestion == o then throw "Lean's suggestion is the call itself"
  return suggestion

/-- `text`, which starts at column `col` (from 0), laid out within `width`
columns where it can be: the `only [...]` list broken after its commas, and a
` using ...` that does not fit moved to a line of its own, each continued 4 columns
right of the tactic (inside the brackets, and before `using`, a line break means
nothing to Lean). The rest is left as Lean printed it. -/
def layout (text : String) (col : Nat) (width : Nat := 100) : String := Id.run do
  if col + text.length ≤ width then return text
  let some (head, items, tail) := splitOnly text | return text
  let indent := String.ofList (List.replicate (col + 4) ' ')
  let mut out := head ++ " only ["
  let mut lineLen := col + out.length
  let mut first := true
  for p in items do
    let piece := if first then p else ", " ++ p
    -- room for the closing `,` or `]`
    if !first && lineLen + piece.length + 1 > width then
      out := out ++ ",\n" ++ indent ++ p
      lineLen := indent.length + p.length
    else
      out := out ++ piece
      lineLen := lineLen + piece.length
    first := false
  out := out ++ "]"
  lineLen := lineLen + 1
  if tail.startsWith " using " && lineLen + tail.length > width then
    return out ++ "\n" ++ indent ++ (tail.drop 1).toString
  return out ++ tail

/-! ## Reading a report -/

/-- `File.lean:12` as (file, line). -/
def splitPos (k : String) : String × Nat :=
  match k.splitOn ":" with
  | [f, l] => (f, l.toNat!)
  | _ => (k, 0)

/-- `File.lean:12:3-14:5` as (file, start line, start column, end line, end column). -/
def splitRange (k : String) : Option (String × Nat × Nat × Nat × Nat) := do
  let parts := k.splitOn ":"
  guard (parts.length ≥ 4)
  let n := parts.length
  let file := ":".intercalate (parts.take (n - 3))
  let l ← parts[n - 3]!.toNat?
  let (c, el) ← match parts[n - 2]!.splitOn "-" with
    | [c, el] => do pure (← c.toNat?, ← el.toNat?)
    | _ => none
  let ec ← parts[n - 1]!.toNat?
  return (file, l, c, el, ec)

/-- `x` with two decimals. -/
def fmt2 (x : Float) : String :=
  let v := (x.abs * 100).round.toUInt64.toNat
  s!"{if x < 0 && v > 0 then "-" else ""}{v / 100}.{if v % 100 < 10 then "0" else ""}{v % 100}"

def groupDigits (n : Nat) : String :=
  if n < 1000 then toString n
  else
    let r := n % 1000
    groupDigits (n / 1000) ++ "," ++ (if r < 10 then "00" else if r < 100 then "0" else "") ++ toString r

/-- An amount in the report's unit: kHB for heartbeats, ms for time (as `elab` prints them). -/
def fmtAmt (heartbeats : Bool) (x : Float) : String :=
  if heartbeats then s!"{fmt2 (x / 1000)} kHB" else s!"{fmt2 (x / 1e6)} ms"

def pct (x total : Float) : String :=
  if total <= 0 then "?" else
  let p := x / total * 100
  if p < 1 then "<1%" else s!"{(p.round).toUInt64.toNat}%"

/-- Where a constant is defined, as `where` gives it: this project (not Lean's
own sources, not a dependency in `.lake/packages`). -/
def inProject (where_ : String) : Bool :=
  let first := (where_.splitOn "/").head!
  !where_.isEmpty && !where_.startsWith ".lake/" && !where_.startsWith "/" && (where_.splitOn "/").length > 1 &&
    !["Init", "Std", "Lean", "Lake"].contains first

/-- The tactic kinds of `simp` and of the decision procedures, as the driver names them. -/
def simpKinds : List String :=
  ["Lean.Parser.Tactic.simp", "Lean.Parser.Tactic.simpAll", "Lean.Parser.Tactic.simpa", "Lean.Parser.Tactic.dsimp"]

/-! ## Findings -/

/-- One cause of a declaration's cost: what the profile shows, and what to try. -/
structure Finding where
  cause : String
  /-- the cost behind it, in the report's unit -/
  amount : Float
  observed : Array String
  suggestion : String
  /-- `mechanical`: an edit Lean computed (`leanprof fix --elab` applies and checks it: a
  `simp only` list, or the `termination_by` measure it inferred);
  `hypothesis`: a change to try, unchecked. -/
  basis : String := "hypothesis"
  /-- what it is about: a constant (`` `Foo.bar` ``), a tactic -/
  subject : String := ""
  /-- the source range it is about (`file:line:col-line:col`), when there is one -/
  range : String := ""
  /-- the replacement for `range`, for a mechanical edit -/
  replacement : String := ""
  deriving Inhabited

def Finding.toJson (f : Finding) (total : Float) : Json :=
  Json.mkObj ([("cause", Json.str f.cause), ("amount", Lean.toJson f.amount),
    ("share", Lean.toJson (if total > 0 then f.amount / total else 0)),
    ("observed", Lean.toJson f.observed), ("suggestion", Json.str f.suggestion), ("basis", Json.str f.basis)] ++
    (if f.range.isEmpty then [] else [("range", Json.str f.range)]) ++
    (if f.replacement.isEmpty then [] else [("replacement", Json.str f.replacement)]))

/-- A class's parent projection or an instance (`Semiring.toMonoid`, `instAddNat`):
unfolding it is unification comparing two ways of reaching an instance. -/
def instancePath (name : String) : Bool :=
  let last := (name.splitOn ".").getLast!
  last.startsWith "inst" ||
    (last.startsWith "to" && ((last.drop 2).toString.toList.head?.map Char.isUpper).getD false)

/-- What to try for a definition `isDefEq` or `whnf` unfolds at a high cost. -/
def unfoldAdvice (name where_ : String) : String :=
  if instancePath name then
    s!"`{name}` is an instance or a class's parent projection: unification is comparing two ways " ++
      "of reaching the same instance. Find where the term's instance comes from (an argument given " ++
      "explicitly, a coercion), and give the instance the statement expects, or a shortcut instance " ++
      "for the path it takes; making it irreducible is not an option"
  else if name == "Decidable.decide" then
    "`decide` evaluates the proposition by unfolding: see the decide finding, if any, or state the fact as a lemma"
  else if inProject where_ then
    s!"`{name}` is defined in this project: if proofs should not see through it, make it " ++
      s!"`@[irreducible]` and add the lemma that unfolds it; or state a `@[simp]` lemma about `{name}` " ++
      "so that the step that unifies does not need to unfold it"
  else
    s!"`attribute [local irreducible] {name} in` before this declaration stops the unfolding here " ++
      s!"(it fails if the proof needs it); or rewrite with `{name}`'s equations (`rw [{name}]`, " ++
      "`simp only [...]`) before the step that unifies"

/-- What to try for an operation done many times. -/
def repeatedAdvice (cls op : String) : String :=
  if has op "decreasing_tactic" then
    "`decreasing_tactic` runs once per recursive call: `decreasing_by` with a direct proof " ++
      "(`all_goals omega`, `simp_wf; omega`) or a `termination_by` measure it proves at once avoids its search"
  else if cls == "Meta.synthInstance" then
    "the same instance problem is solved again each time: a local instance (`haveI`, `letI`) or an " ++
      "explicit instance argument solves it once; a cheaper instance can be given a higher priority"
  else if cls == "Elab.step" then
    "the same term or tactic is elaborated again each time: a `have` for a term used many times, or one " ++
      "call on all goals instead of one per goal, does it once"
  else
    "the same operation is done again each time: find what triggers it (a coercion, a type ascription, " ++
      "an instance argument) and give it once"

/-- The findings for one declaration (`sc`, a scope of the report), costliest
first. `ranges` and `suggestions` are those inside the declaration. -/
def findingsOf (hb : Bool) (sc : Json) (ranges suggestions : Array Json) (measures : Array Json := #[]) :
    Array Finding := Id.run do
  let total := jnum sc "total_ns"
  if total <= 0 then return #[]
  let amt := fmtAmt hb
  let share (x : Float) := pct x total
  let mut out : Array Finding := #[]
  -- simp: Lean's own list of the lemmas each call used
  let mut simpRanges : Array String := #[]
  for s in (suggestions.qsort fun a b => jnum a "amount" > jnum b "amount").toList.take 3 do
    let a := jnum s "amount"
    -- under 2% of the declaration, a smaller simp set saves too little to list
    if a < total * 0.02 then continue
    let range := jstr s "range"
    simpRanges := simpRanges.push range
    let n := jnum s "count"
    let lemmas := jnum s "lemmas"
    let head := headWord (jstr s "original")
    let obs := #[s!"`{head}` at {range} took {amt a} ({share a} of the declaration){if n > 1 then s!", run {n.toUInt64}×" else ""}",
      s!"Lean's list of the lemmas it used (`simp?`) has {lemmas.toUInt64} {if lemmas == 1 then "entry" else "entries"}"]
    let reason := jstr s "not_applicable"
    -- a list already restricted: dropping unused lemmas from it saves little
    if reason.startsWith "it is already restricted" then continue
    if reason.isEmpty then
      out := out.push {
        cause := "simp-set", amount := a, observed := obs, basis := "mechanical", range := range,
        replacement := jstr s "suggestion",
        suggestion := s!"replace it with `{jstr s "suggestion"}`: simp then tries these lemmas instead of every " ++
          "`@[simp]` lemma whose pattern matches (`leanprof fix --elab` applies it and checks the proof and the heartbeats)" }
    else
      out := out.push {
        cause := "simp-set", amount := a, observed := obs, range := range,
        suggestion := s!"Lean's list: `{jstr s "suggestion"}`; not applied automatically: {reason}" }
  -- simp without Lean's list (no `--why`): the costliest calls
  for r in ranges do
    let a := jnum r "amount"
    if !simpKinds.contains (jstr r "syntax") || a < total * 0.1 || simpRanges.contains (jstr r "range") then continue
    if suggestions.any (jstr · "range" == jstr r "range") then continue
    out := out.push {
      cause := "simp-set", amount := a, range := jstr r "range",
      observed := #[s!"`{headWord (jstr r "text")}` at {jstr r "range"} took {amt a} ({share a} of the declaration)"],
      suggestion := "`leanprof elab --why` gets Lean's list of the lemmas it uses, for `simp only [...]`" }
  -- simp lemmas tried without success (`--counts`)
  let failedSimp := ((jarr sc "counts").filter (jstr · "counter" == "simp_failed")).qsort fun a b => jnum a "count" > jnum b "count"
  if let some top := failedSimp[0]? then
    if jnum top "count" ≥ 50 then
      let names := (failedSimp.toList.take 3).map fun c => s!"`{jstr c "name"}` {(jnum c "count").toUInt64}×"
      out := out.push {
        cause := "simp-failed-lemmas", amount := 0,
        observed := #[s!"simp tried lemmas that did not apply: {", ".intercalate names} (exact counts, `--counts`)"],
        suggestion := "`simp only [...]` with the lemmas that apply skips these attempts; if a lemma " ++
          "should never fire here, `simp [-name]` removes it" }
  -- definitions unfolded at a high cost
  let causes := jarr sc "causes"
  for c in ((causes.filter fun c => (jstr c "kind" == "unfold" || jstr c "kind" == "whnf") && jnum c "amount" ≥ total * 0.1).toList.take 2) do
    let a := jnum c "amount"
    let name := jstr c "name"
    let w := jstr c "where"
    let verb := if jstr c "kind" == "unfold" then "`isDefEq` unfolded" else "`whnf` reduced"
    out := out.push {
      cause := if jstr c "kind" == "unfold" then "unfold" else "whnf", amount := a, subject := s!"`{name}`",
      observed := #[s!"{verb} `{name}`{if w.isEmpty then "" else s!" ({w})"} {(jnum c "count").toUInt64}×, " ++
        s!"and the work that followed cost {amt a} ({share a})"],
      suggestion := unfoldAdvice name w }
  -- instance searches that failed
  -- (a problem with a metavariable, `OfNat ?m 2`, fails while its type is unknown and is
  -- solved later: part of elaboration, not a cause)
  for f in (((jarr sc "instances_failed").filter fun f =>
      jnum f "amount" ≥ total * 0.05 && !has (jstr f "problem") "?").toList.take 2) do
    let a := jnum f "amount"
    let tried := (causes.filter (jstr · "kind" == "instance")).toList.take 3 |>.map (s!"`{jstr · "name"}`")
    out := out.push {
      cause := "instance-failed", amount := a,
      observed := #[s!"instance search for `{jstr f "problem"}` failed {(jnum f "count").toUInt64}×, costing {amt a} ({share a})"] ++
        (if tried.isEmpty then #[] else #[s!"instances tried in this declaration: {", ".intercalate tried}"]),
      suggestion := "a search that fails is done again each time it is needed: if the instance should exist, " ++
        "declare it (or `haveI`/`letI` in the proof); if not, find what asks for it (a coercion, a `Decidable` " ++
        "or `Inhabited` argument, a default instance) and give that term explicitly" }
  -- instances tried at a high cost
  for c in ((causes.filter fun c => jstr c "kind" == "instance" && jnum c "amount" ≥ total * 0.1).toList.take 2) do
    let a := jnum c "amount"
    out := out.push {
      cause := "instance", amount := a,
      observed := #[s!"instance search tried `{jstr c "name"}`{let w := jstr c "where"; if w.isEmpty then "" else s!" ({w})"} " ++
        s!"{(jnum c "count").toUInt64}×, costing {amt a} ({share a})"],
      suggestion := "if another instance is the one that should apply, give it a higher priority " ++
        "(`instance (priority := high)`) or this one a lower one; a local instance (`haveI`) avoids the search here" }
  -- decide (its evaluation is `whnf` work: listed with it, not on its own)
  let decides := ranges.filter fun r =>
    let k := jstr r "syntax"
    (k == "Lean.Parser.Tactic.decide" || k == "Lean.Parser.Tactic.nativeDecide") && jnum r "amount" ≥ total * 0.1
  if let some d := decides[0]? then
    let whnfs := out.filter (·.cause == "whnf")
    out := out.filter (·.cause != "whnf")
    out := out.push {
      cause := "decide", amount := jnum d "amount", range := jstr d "range"
      observed := #[s!"`{collapse (jstr d "text")}` at {jstr d "range"} took {amt (jnum d "amount")} ({share (jnum d "amount")})"] ++
        (if whnfs.isEmpty then #[] else
          #["`whnf` reduced, while evaluating it: " ++ ", ".intercalate (whnfs.toList.map fun f =>
            s!"{f.subject} {amt f.amount}")]) ++
        (if jnum sc "kernel_ns" ≥ total * 0.1 then
          #[s!"the kernel took {amt (jnum sc "kernel_ns")} ({share (jnum sc "kernel_ns")}) checking the result"] else #[])
      suggestion := "`decide` evaluates the proposition in the elaborator, then the kernel checks it again: " ++
        "`decide +kernel` leaves the evaluation to the kernel alone. For an equation between closed terms, " ++
        "`rfl` (by kernel evaluation, with fast `Nat` arithmetic) may be cheaper. `native_decide` is not a fix: " ++
        "it trusts the compiler (the axiom `Lean.ofReduceBool`), and `leanprof experiment`'s guard rejects it" }
  -- the kernel
  let kernel := jnum sc "kernel_ns"
  if kernel ≥ total * 0.3 && !out.any (·.cause == "decide") then
    let kernelUnfolds := ((jarr sc "counts").filter (jstr · "counter" == "kernel")).qsort fun a b => jnum a "count" > jnum b "count"
    let top := (kernelUnfolds.toList.take 3).map fun c => s!"`{jstr c "name"}` {groupDigits (jnum c "count").toUInt64.toNat}×"
    out := out.push {
      cause := "kernel", amount := kernel,
      observed := #[s!"the kernel took {amt kernel} ({share kernel}) to check the proof term"] ++
        (if top.isEmpty then #[] else #[s!"the kernel unfolded {", ".intercalate top} (exact counts, `--counts`)"]),
      suggestion := "the kernel checks the finished term without the elaborator's caches, unfolding definitions " ++
        "itself: proofs by evaluation (`decide`, `rfl` on large terms) and terms that unfold a definition many " ++
        "times cost here. A lemma that states the computed value, used by `rw` or `simp only`, avoids the " ++
        "reduction" ++ (if top.isEmpty then "; `--counts` names what the kernel unfolded" else "") }
  -- a termination measure Lean searched for: `decreasing_tactic` once per measure tried
  let mut measured := false
  if let some m := measures[0]? then
    let a := jnum m "amount"
    let reason := jstr m "not_applicable"
    let runs := (jarr sc "repeated").filter fun rp => has (jstr rp "op") "decreasing_tactic"
    let n := runs.foldl (fun x rp => x + jnum rp "count") 0
    if a ≥ total * 0.1 then
      measured := true
      out := out.push {
        cause := "termination", amount := a, basis := if reason.isEmpty then "mechanical" else "hypothesis"
        range := jstr m "insert", replacement := if reason.isEmpty then jstr m "measure" else ""
        observed := #[s!"`decreasing_tactic` ran {n.toUInt64}× for {amt a} ({share a}): with no `termination_by`, " ++
            "Lean tries measures until one works, proving the recursive calls for each",
          s!"the measure Lean found (`showInferredTerminationBy`): `{jstr m "measure"}`"]
        suggestion := (if reason.isEmpty then
            s!"state it after the proof: `{jstr m "measure"}`; Lean then proves the calls for that measure only " ++
              "(`leanprof fix --elab` adds it and checks the proof and the heartbeats)"
          else s!"state it after the proof: `{jstr m "measure"}`; not added automatically: {reason}") }
  -- repeated operations
  for rp in (((jarr sc "repeated").filter fun rp =>
      jnum rp "count" ≥ 3 && jnum rp "total" ≥ total * 0.1 && !(measured && has (jstr rp "op") "decreasing_tactic")).toList.take 2) do
    let a := jnum rp "total"
    out := out.push {
      cause := "repeated", amount := a,
      observed := #[s!"[{jstr rp "class"}] {String.ofList ((jstr rp "op").toList.take 80)}: done {(jnum rp "count").toUInt64}×, {amt a} ({share a})"],
      suggestion := repeatedAdvice (jstr rp "class") (jstr rp "op") }
  for r in ranges do
    let a := jnum r "amount"
    let n := jnum r "count"
    if n < 3 || a < total * 0.1 || out.any (·.range == jstr r "range") then continue
    out := out.push {
      cause := "repeated", amount := a, range := jstr r "range",
      observed := #[s!"`{String.ofList ((collapse (jstr r "text")).toList.take 60)}` at {jstr r "range"} was elaborated {n.toUInt64}×, {amt a} ({share a})"],
      suggestion := if jstr r "kind" == "tactic" then
          "a tactic run once per goal (after `<;>`, `all_goals`, or in each case): if the goals share a " ++
            "proof, prove it once as a `have` before splitting"
        else "a term elaborated again each time (postponed, or inside a tactic run on several goals): " ++
          "a `have` or a type ascription elaborates it once" }
  -- grind
  for r in ranges do
    let a := jnum r "amount"
    unless jstr r "syntax" == "Lean.Parser.Tactic.grind" && a ≥ total * 0.2 do continue
    if out.any (·.range == jstr r "range") then continue
    out := out.push {
      cause := "grind", amount := a, range := jstr r "range",
      observed := #[s!"`grind` at {jstr r "range"} took {amt a} ({share a})"],
      suggestion := "`grind?` prints a `grind only [...]` call with the theorems this proof used, " ++
        "which limits the search" }
  return out.qsort fun a b => a.amount > b.amount

/-- The costliest `top` declarations of an `elab` report, each with its findings. -/
def analyze (r : Json) (top : Nat := 10) : Array (Json × Array Finding) := Id.run do
  let hb := jstr r "unit" == "heartbeats"
  let scopes := jarr r "scopes"
  -- where each declaration ends: the next one in the same file
  let mut starts : Std.HashMap String (Array Nat) := {}
  for sc in scopes do
    let (f, l) := splitPos (jstr sc "pos")
    starts := starts.insert f ((starts.getD f #[]).push l)
  let owner (pos : String) : String := Id.run do
    let (f, l) := splitPos pos
    let mut best := 0
    for l' in starts.getD f #[] do
      if l' ≤ l && l' > best then best := l'
    return s!"{f}:{best}"
  let mut rangesOf : Std.HashMap String (Array Json) := {}
  for r in jarr r "ranges" do
    let o := owner (jstr r "pos")
    rangesOf := rangesOf.insert o ((rangesOf.getD o #[]).push r)
  let mut suggOf : Std.HashMap String (Array Json) := {}
  for s in jarr r "simp_suggestions" do
    let o := owner (jstr s "pos")
    suggOf := suggOf.insert o ((suggOf.getD o #[]).push s)
  let mut measOf : Std.HashMap String (Array Json) := {}
  for m in jarr r "termination_suggestions" do
    let o := owner (jstr m "pos")
    measOf := measOf.insert o ((measOf.getD o #[]).push m)
  let sorted := scopes.qsort fun a b => jnum a "total_ns" > jnum b "total_ns" ||
    (jnum a "total_ns" == jnum b "total_ns" && jstr a "pos" < jstr b "pos")
  return (sorted.toList.take top).toArray.map fun sc =>
    let pos := jstr sc "pos"
    (sc, findingsOf hb sc (rangesOf.getD pos #[]) (suggOf.getD pos #[]) (measOf.getD pos #[]))

def whyJson (r : Json) (top : Nat := 10) : Json :=
  let hb := jstr r "unit" == "heartbeats"
  Json.mkObj [("unit", Json.str (jstr r "unit")),
    ("note", Json.str "observed: measured in this profile; suggestion: what to try (basis `mechanical`: Lean computed the edit, `leanprof fix --elab` checks it; `hypothesis`: unchecked)"),
    ("declarations", Json.arr ((analyze r top).map fun (sc, fs) =>
      let total := jnum sc "total_ns"
      Json.mkObj [("pos", Json.str (jstr sc "pos")), ("name", Json.str (jstr sc "name")),
        ("key", Json.str (jstr sc "key")), ("total", toJson total), ("elab", toJson (jnum sc "elab_ns")),
        ("kernel", toJson (jnum sc "kernel_ns")), ("unit_label", Json.str (if hb then "heartbeats" else "ns")),
        ("findings", Json.arr (fs.map (·.toJson total)))]))]

/-- The findings as text, for `elab --why` and `explain` on an `elab` report. -/
def text (r : Json) (top : Nat := 10) : String := Id.run do
  let hb := jstr r "unit" == "heartbeats"
  let amt := fmtAmt hb
  let decls := analyze r top
  let mut out := "\n  why the costliest declarations are slow\n" ++
    "  (observed: measured in this profile. suggested: what to try; `mechanical` is an edit Lean computed,\n" ++
    "   which `leanprof fix --elab` applies and checks; the rest are hypotheses nothing has checked)\n"
  let mut k := 0
  let mut any := false
  for (sc, fs) in decls do
    k := k + 1
    let total := jnum sc "total_ns"
    let parts := (if jnum sc "kernel_ns" > 0 then s!", kernel {amt (jnum sc "kernel_ns")}" else "")
    out := out ++ s!"\n  {k}. {amt total}  {jstr sc "pos"}  {String.ofList ((jstr sc "name").toList.take 60)}\n" ++
      s!"     elaboration {amt (jnum sc "elab_ns")}{parts}\n"
    if fs.isEmpty then
      out := out ++ "     no cause stands out in this profile: its cost is spread over many steps\n"
      continue
    any := true
    let ind := "                  "
    for f in fs do
      out := out ++ s!"     {f.cause}\n"
      for o in f.observed do
        out := out ++ "       observed   " ++ ((wrap s!"{ind}{o}" ind).drop ind.length).toString ++ "\n"
      let sg := s!"{f.suggestion}{if f.basis == "mechanical" then " [mechanical]" else ""}"
      out := out ++ "       suggested  " ++ ((wrap s!"{ind}{sg}" ind).drop ind.length).toString ++ "\n"
  if !any && !(jarr r "simp_suggestions").isEmpty then
    out := out ++ "\n  (no `simp` call costs 2% or more of its declaration)\n"
  if !(r.getObjValAs? Bool "why").toOption.getD false then
    out := out ++ "\n  (`leanprof elab --why` adds Lean's own `simp only` list for each `simp`)\n"
  return out

/-! ## A heartbeat budget -/

/-- The declarations of a heartbeat report above `n` (in `maxHeartbeats`' unit, 1,000
heartbeats), costliest first. -/
def overBudget (r : Json) (n : Nat) : Array Json :=
  let limit := n.toFloat * 1000
  ((jarr r "scopes").filter fun sc => jnum sc "total_ns" > limit).qsort fun a b =>
    jnum a "total_ns" > jnum b "total_ns" || (jnum a "total_ns" == jnum b "total_ns" && jstr a "pos" < jstr b "pos")

def budgetText (r : Json) (n : Nat) : String := Id.run do
  let over := overBudget r n
  let amt := fmtAmt true
  if over.isEmpty then
    return s!"\n  heartbeat budget: no declaration above {groupDigits n} (maxHeartbeats' unit: 1,000 heartbeats)\n"
  let mut out := s!"\n  heartbeat budget: {over.size} {if over.size == 1 then "declaration" else "declarations"} above " ++
    s!"{groupDigits n} (maxHeartbeats' unit: 1,000 heartbeats; elab / kernel / compiler / lint)\n"
  for sc in over do
    out := out ++ s!"  {amt (jnum sc "total_ns")}  {amt (jnum sc "elab_ns")} / {amt (jnum sc "kernel_ns")} / " ++
      s!"{amt (jnum sc "compile_ns")} / {amt (jnum sc "lint_ns")}  {jstr sc "pos"}  " ++
      s!"{String.ofList ((jstr sc "name").toList.take 60)}\n"
  return out

end Leanprof.ElabWhy
