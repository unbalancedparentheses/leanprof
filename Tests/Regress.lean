import Leanprof.Regress

/-! Tests of `Leanprof.Regress` (why a declaration or copy site got worse), run
by `Tests/Main.lean`. The end-to-end check, from real Lean files through
`elab`, `run` and `explain` to the comment, is scripts/regress-check.py. -/

namespace Tests.Regress
open Lean Leanprof.Regress

/-- An `elab.json` with one declaration `F.lean d` on line 1. -/
def report (causes repeated counts : Array Json) (threshold : Nat := 10000) (withCounts := true) (total : Nat := 1000) : Json :=
  Json.mkObj [("elab", true), ("unit", "heartbeats"), ("threshold", toJson threshold), ("counts", Json.bool withCounts),
    ("scopes", Json.arr #[Json.mkObj [("key", "F.lean d"), ("pos", "F.lean:1"), ("name", "theorem d"),
      ("total_ns", toJson total), ("elab_ns", toJson total), ("kernel_ns", toJson (0 : Nat)),
      ("compile_ns", toJson (0 : Nat)), ("lint_ns", toJson (0 : Nat)),
      ("causes", Json.arr causes), ("repeated", Json.arr repeated), ("counts", Json.arr counts)]])]

def cause (name kind : String) (amount count : Nat) : Json :=
  Json.mkObj [("name", Json.str name), ("kind", Json.str kind), ("amount", toJson amount), ("count", toJson count),
    ("where", "G.lean:3")]

def counter (name ctr : String) (n : Nat) : Json :=
  Json.mkObj [("name", Json.str name), ("counter", Json.str ctr), ("count", toJson n), ("where", "")]

def explainOf (b n : Json) : Explanation :=
  let bi := loadElab b
  let ni := loadElab n
  explainDecl bi ni "F.lean d" (bi.decls.getD "F.lean d" {}) (ni.decls.getD "F.lean d" {})

def has (s pat : String) : Bool := (s.splitOn pat).length > 1

def run (check' : String → Bool → String → StateT Nat IO Unit) : StateT Nat IO Unit := do
  let check (n : String) (ok : Bool) := check' n ok ""
  -- a definition reduced in head only: named, with its exact change, first
  let e := explainOf (report #[cause "g" "whnf" 10 1] #[] #[]) (report #[cause "f" "whnf" 5000 30, cause "g" "whnf" 10 1] #[] #[] (total := 6000))
  check' "regress: the constant credited with the increase is named first"
    (e.work.size == 1 && e.work[0]!.name == "f" && e.work[0]!.delta? == some 5000 && e.work[0]!.baseTimes == some 0 &&
      e.work[0]!.newTimes == some 30 && e.work[0]!.loc == "G.lean:3") s!"{e.work.size}"
  check "regress: an unchanged constant is not listed" (!e.work.any (·.name == "g"))
  -- exact counters
  let e := explainOf (report #[] #[] #[counter "lem" "simp_used" 0]) (report #[] #[] #[counter "lem" "simp_used" 41] (total := 5000))
  check "regress: a counter that went up is listed with its exact change"
    (e.counts.size == 1 && e.counts[0]!.delta? == some 41 && e.counts[0]!.isCount)
  -- nothing recorded changed: said so, with the threshold
  let e := explainOf (report #[cause "g" "unfold" 10 1] #[] #[]) (report #[cause "g" "unfold" 10 1] #[] #[] (total := 9000))
  check' "regress: no change recorded is 'cause not attributed', naming the threshold"
    (e.work.isEmpty && e.counts.isEmpty && e.notes.any fun n => has n "cause not attributed" && has n "10,000 heartbeats")
    s!"{e.notes}"
  -- a list cut at the limit: a missing entry is unknown, not zero
  let full := (List.range causeLimit).toArray.map fun i => cause s!"c{i}" "instance" (1000 + i) 1
  let e := explainOf (report full #[] #[]) (report #[cause "new" "instance" 500 2] #[] #[])
  check "regress: an entry missing from a cut list is 'not listed', never 0"
    ((e.work.find? (·.name == "new")).any fun r => r.base.isNone && r.delta?.isNone)
  -- reports from before causes were recorded
  let old := Json.mkObj [("elab", true), ("unit", "heartbeats"), ("scopes", Json.arr #[Json.mkObj [("key", "F.lean d"),
    ("total_ns", toJson (1 : Nat))]])]
  let e := explainOf old (report #[cause "f" "whnf" 5000 30] #[] #[])
  check "regress: an old report is not attributed, and says why"
    (e.work.isEmpty && e.notes.any fun n => has n "base report does not record")
  -- most of the change not credited
  let e := explainOf (report #[] #[] #[]) (report #[cause "f" "simp" 100 3] #[] #[] (total := 100000))
  check "regress: a small credited share says most of the change is not credited"
    (e.notes.any fun n => has n "most of the change is in work not credited")
  -- repeated operations: compared when both sides list them
  let rep (n x : Nat) := Json.mkObj [("class", "Meta.synthInstance"), ("op", "Add Nat"), ("count", toJson n), ("total", toJson x)]
  let e := explainOf (report #[] #[rep 2 4000] #[]) (report #[] #[rep 9 20000] #[] (total := 20000))
  check "regress: repeated work that grew is listed"
    ((e.work.find? (·.what == "repeated")).any fun r => r.baseTimes == some 2 && r.newTimes == some 9 && r.delta? == some 16000)
  -- the headline prefers a constant declared in the profiled files when nearly as large
  let two (x y : Nat) := report #[cause "Decidable.decide" "whnf" x 1, cause "d" "whnf" y 99] #[] #[]
  let e := explainOf (two 0 0) (two 5000 4900)
  check' "regress: the headline names the profiled file's own constant"
    (e.headline.any (·.name == "d")) s!"{e.headline.map (·.name)}"
  -- explain's findings for a copy site
  let f := Json.arr #[Json.mkObj [("function", "f"), ("kind", "Array"), ("scope", "s"), ("symbol", "l_f"),
    ("cause", "stored-then-updated"), ("why", "it is stored"), ("file", "M.lean"), ("lines", Json.arr #[toJson (3 : Nat)]),
    ("shared", toJson (299 : Nat)), ("multi_threaded", toJson (0 : Nat))]]
  let fs := loadExplain f
  check "regress: explain's cause is found for its site"
    ((findingsFor fs (copyKey "f" "Array" "s") 299).toOption.any fun xs => xs.size == 1 && xs[0]!.cause == "stored-then-updated")
  check "regress: explain.json of another run is refused"
    ((findingsFor fs (copyKey "f" "Array" "s") 300).toOption.isNone)
  check "regress: a site explain did not explain has no finding"
    ((findingsFor fs (copyKey "g" "Array" "s") 5).toOption.any (·.isEmpty))
  -- names from the pull request cannot become Markdown, HTML or mentions
  let p := mdProse "a <img src=x> @user #12 [l](u) *b* `x|y`"
  check' "regress: mdProse escapes HTML, mentions, links and emphasis"
    (!has p "<img" && !has p "@user" && !has p "#12" && !has p "[l]" && !has p "*b*" && has p "`x\\|y`") p
  let c := htmlCode "a<b>&\"c"
  check' "regress: htmlCode escapes HTML" (c == "<code>a&lt;b&gt;&amp;&quot;c</code>") c

end Tests.Regress
