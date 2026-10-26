import Leanprof.ElabWhy
import Leanprof.FixElab
import Leanprof.Judge

/-! Tests of the compile-time explanations (`elab --why`, `Leanprof/ElabWhy.lean`),
the heartbeat budget, the `simp only` edits of `fix --elab` (`Leanprof/FixElab.lean`)
and the per-declaration heartbeat verdict (`Leanprof/Judge.lean`). Pure: run by
`Tests/Main.lean`. -/

open Lean Leanprof

namespace Tests.ElabWhy

/-- A report with one declaration of 1,000 kHB: a `simp` with Lean's list (30%),
a `decide` (20%) and the `whnf` work under it, an `isDefEq` unfold of a
definition of this project (15%), and two failed instance searches, one with a
metavariable (not a cause). -/
def report : Json := Json.mkObj [
  ("elab", Json.bool true), ("unit", Json.str "heartbeats"), ("why", Json.bool true),
  ("scopes", Json.arr #[
    Json.mkObj [("pos", Json.str "A.lean:10"), ("name", Json.str "theorem big"), ("key", Json.str "A.lean big"),
      ("total_ns", toJson (1000000 : Nat)), ("elab_ns", toJson (900000 : Nat)), ("kernel_ns", toJson (100000 : Nat)),
      ("causes", Json.arr #[
        Json.mkObj [("name", Json.str "Foo.f"), ("kind", Json.str "unfold"), ("amount", toJson (150000 : Nat)),
          ("count", toJson (40 : Nat)), ("where", Json.str "A/Defs.lean:3")],
        Json.mkObj [("name", Json.str "Decidable.decide"), ("kind", Json.str "whnf"), ("amount", toJson (120000 : Nat)),
          ("count", toJson (1 : Nat)), ("where", Json.str "Init/Prelude.lean:1158")]]),
      ("instances_failed", Json.arr #[
        Json.mkObj [("problem", Json.str "Decidable (P x)"), ("count", toJson (12 : Nat)), ("amount", toJson (80000 : Nat))],
        Json.mkObj [("problem", Json.str "OfNat ?m.n 2"), ("count", toJson (3 : Nat)), ("amount", toJson (70000 : Nat))]]),
      ("repeated", Json.arr #[]), ("counts", Json.arr #[])],
    Json.mkObj [("pos", Json.str "A.lean:30"), ("name", Json.str "theorem small"), ("key", Json.str "A.lean small"),
      ("total_ns", toJson (20000 : Nat)), ("elab_ns", toJson (20000 : Nat)), ("kernel_ns", toJson (0 : Nat))]]),
  ("ranges", Json.arr #[
    Json.mkObj [("range", Json.str "A.lean:12:3-12:20"), ("pos", Json.str "A.lean:12"), ("kind", Json.str "tactic"),
      ("syntax", Json.str "Lean.Parser.Tactic.simp"), ("text", Json.str "simp [h]"), ("amount", toJson (300000 : Nat)),
      ("count", toJson (1 : Nat))],
    Json.mkObj [("range", Json.str "A.lean:14:3-14:9"), ("pos", Json.str "A.lean:14"), ("kind", Json.str "tactic"),
      ("syntax", Json.str "Lean.Parser.Tactic.decide"), ("text", Json.str "decide"), ("amount", toJson (200000 : Nat)),
      ("count", toJson (1 : Nat))]]),
  ("simp_suggestions", Json.arr #[
    Json.mkObj [("pos", Json.str "A.lean:12"), ("range", Json.str "A.lean:12:3-12:20"), ("original", Json.str "simp [h]"),
      ("suggestion", Json.str "simp only [h, Nat.add_zero]"), ("lemmas", toJson (2 : Nat)),
      ("amount", toJson (300000 : Nat)), ("count", toJson (1 : Nat)), ("variants", toJson (1 : Nat)),
      ("not_applicable", Json.str "")]])]

def isOk {α ε} : Except ε α → Bool
  | .ok _ => true
  | .error _ => false

def hb (xs : List (String × Float)) : Judge.Summary := { heartbeats := some (Std.HashMap.ofList xs) }

def kept (a b : List (String × Float)) : Bool := (Judge.judge (hb a) (hb b) (judgeTime := false)).better.size > 0

def worse (a b : List (String × Float)) : Bool := (Judge.judge (hb a) (hb b) (judgeTime := false)).worse.size > 0

/-- (name, passed, detail) for each check. -/
def cases : List (String × Bool × String) :=
  let fs := (ElabWhy.analyze report)[0]!.2
  let causes := fs.map (·.cause)
  let simpF := fs.find? (·.cause == "simp-set")
  let src := "theorem t : x := by\n  simp [h,\n    g]\n  done"
  let e : FixElab.SimpEdit := {
    file := "A.lean", line := 2, col := 2, endLine := 3, endCol := 6
    original := "simp [h,\n    g]", replacement := "simp only [h, g, Nat.add_zero]", amount := 1 }
  [("elab --why: whitespace made one space", ElabWhy.collapse "  simp  [a,\n   b]  at h " == "simp [a, b] at h", ""),
   ("elab --why: the tactic a Try this suggests",
     ElabWhy.suggestionText "Try this: simp only [a, b]" == "simp only [a, b]" &&
       ElabWhy.suggestionText "Try this:\n  [apply] simpa only using h" == "simpa only using h", ""),
   ("elab --why: the lemmas of an only list",
     ElabWhy.onlyLemmas "simp only [a, foo (x := 1), ← b] at h" == #["a", "foo (x := 1)", "← b"] &&
       ElabWhy.onlyLemmas "simp_all only" == #[], toString (ElabWhy.onlyLemmas "simp only [a, foo (x := 1), ← b] at h")),
   ("elab --why: which simp calls are mechanical",
     isOk (ElabWhy.simpEdit? "simp [h]" "simp only [h, Nat.add_zero]") &&
       isOk (ElabWhy.simpEdit? "simpa using h" "simpa only using h") &&
       !isOk (ElabWhy.simpEdit? "simp only [a, b]" "simp only [a]") &&
       !isOk (ElabWhy.simpEdit? "simp_wf" "simp only [x]") &&
       !isOk (ElabWhy.simpEdit? "simp" "simp only [a]" (variants := 2)) &&
       !isOk (ElabWhy.simpEdit? "simpa using by\n    exact h" "simpa only using by exact h"), ""),
   ("elab --why: a long only list laid out within 100 columns",
     ElabWhy.layout "simp only [a]" 4 == "simp only [a]" &&
       (let ls := (ElabWhy.layout ("simp only [" ++ ", ".intercalate ((List.range 12).map (s!"Mathlib.Lemma.number{·}")) ++ "]") 4).splitOn "\n"
        ls.length > 1 && ls.head!.length + 4 ≤ 100 && (ls.drop 1).all fun l => l.length ≤ 100 && l.startsWith "        M"), ""),
   ("elab --why: a source range", ElabWhy.splitRange "A/B.lean:12:3-14:20" == some ("A/B.lean", 12, 3, 14, 20), ""),
   ("elab --why: the causes of a declaration",
     causes.contains "simp-set" && causes.contains "decide" && causes.contains "unfold" &&
       causes.contains "instance-failed" && !causes.contains "whnf" &&
       (fs.filter (·.cause == "instance-failed")).size == 1, toString causes.toList),
   ("elab --why: the simp edit is mechanical, the rest hypotheses",
     (simpF.map (·.basis)) == some "mechanical" && (simpF.map (·.replacement)) == some "simp only [h, Nat.add_zero]" &&
       (fs.filter (·.cause != "simp-set")).all (·.basis == "hypothesis"), ""),
   ("elab --why: observed and suggested apart, in text and JSON",
     let t := ElabWhy.text report
     (t.splitOn "observed").length > 3 && (t.splitOn "suggested").length > 3 &&
       (((ElabWhy.whyJson report).getObjValD "declarations").getArrVal? 0).toOption.isSome, ""),
   ("elab --why: native_decide is not offered as a fix",
     (fs.find? (·.cause == "decide")).any fun f => (f.suggestion.splitOn "`native_decide` is not a fix").length > 1, ""),
   ("heartbeat budget: the declarations above it",
     (ElabWhy.overBudget report 500).size == 1 && (ElabWhy.overBudget report 10).size == 2 &&
       (ElabWhy.overBudget report 2000).isEmpty, ""),
   ("fix --elab: a simp call replaced by its only list",
     (match FixElab.applyEdits src #[e] with
      | .ok t => t == "theorem t : x := by\n  simp only [h, g, Nat.add_zero]\n  done"
      | .error _ => false), ""),
   ("fix --elab: a source that changed is refused",
     !isOk (FixElab.applyEdits src #[{ e with original := "simp [h]" }]), ""),
   ("fix --elab: the edits a build log blames",
     FixElab.errorPositions "error: ././A/B.lean:12:4: unsolved goals\nok" == #[("A/B.lean", 12)] &&
       FixElab.blame #[{ e with file := "A/B.lean", line := 3 }, { e with file := "A/B.lean", line := 11 },
         { e with file := "A/C.lean", line := 1 }] #[("A/B.lean", 12)] == #[1], ""),
   ("fix --elab: declarations that got dearer",
     FixElab.dearer #["compile A.lean t: 1.00 kHB -> 2.50 kHB", "compile A.lean u: 3.00 kHB -> 1.00 kHB",
       "compile heartbeats: 1 kHB"] == #["A.lean t"], ""),
   ("judge: one declaration of a large module made cheaper",
     kept [("a", 10000000), ("b", 50000)] [("a", 10000000), ("b", 30000)] &&
       kept [("a", 10000000), ("b", 50000)] [("a", 10000400), ("b", 30000)] &&
       !kept [("a", 10000000), ("b", 50000), ("c", 100000)] [("a", 10000000), ("b", 30000), ("c", 103000)] &&
       !kept [("a", 10000000), ("b", 50000)] [("a", 10000000), ("b", 30000), ("c", 100)] &&
       !kept [("a", 10000000), ("b", 50000)] [("a", 10000000), ("b", 49500)] &&
       !worse [("a", 10000000), ("b", 50000)] [("a", 10000000), ("b", 30000)], "")]

end Tests.ElabWhy
