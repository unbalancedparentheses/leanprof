import Leanprof.Regress
import Leanprof.Delta

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
  let e := explainOf (report #[] #[] #[]) (report #[cause "f" "simp" 5000 3] #[] #[] (total := 100000))
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
  -- what went down is listed after what went up, and never the headline
  let e := explainOf (report #[cause "down" "instance" 9000 3] #[] #[counter "up" "grind_instances" 2])
    (report #[cause "down" "instance" 100 3] #[] #[counter "up" "grind_instances" 40] (total := 20000))
  check' "regress: a decrease is not the headline; a counter that went up is"
    (e.headline.any (·.name == "up") && e.work[0]!.name == "down") s!"{e.headline.map (·.name)}"
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
  -- the difference per declaration and call site (`compare --json`, `--since-last`)
  let d := Leanprof.Delta.compute (report #[cause "g" "whnf" 10 1] #[] #[])
    (report #[cause "f" "whnf" 5000 30, cause "g" "whnf" 10 1] #[] #[] (total := 7000))
  let decls := jarr d "decls"
  check' "delta: a declaration that costs more is listed at its line, with the change"
    (decls.size == 1 && jstr decls[0]! "pos" == "F.lean:1" && jnum decls[0]! "change" == 6000 &&
      (decls[0]!.getObjValAs? Bool "regression").toOption == some true) d.compress
  let why := (decls[0]!.getObjVal? "why").toOption.getD Json.null
  check' "delta: what changed inside it, from compare's explanation"
    ((jarr why "rows").any (fun r => jstr r "name" == "f" && jstr r "change" == "+5.00 kHB") &&
      (jstr why "headline").startsWith "whnf reduces f") why.compress
  check "delta: a change within 1,000 heartbeats is not listed"
    (jarr (Leanprof.Delta.compute (report #[] #[] #[]) (report #[] #[] #[] (total := 1900))) "decls").isEmpty
  let down := Leanprof.Delta.compute (report #[cause "f" "whnf" 9000 3] #[] #[] (total := 20000))
    (report #[cause "f" "whnf" 100 3] #[] #[] (total := 2000))
  let w := ((jarr down "decls")[0]!.getObjVal? "why").toOption.getD Json.null
  check' "delta: a cheaper declaration names what fell, without the notes for increases"
    ((jstr w "headline").startsWith "whnf reduces f" && (jarr w "notes").isEmpty) w.compress
  let withFile (j : Json) (errors : Nat) : Json :=
    j.setObjVal! "files" (Json.arr #[Json.mkObj [("file", "F.lean"), ("errors", toJson errors)]])
  let other := Json.mkObj [("key", "F.lean e"), ("pos", "F.lean:9"), ("name", "theorem e"), ("total_ns", toJson (50000 : Nat))]
  let twoDecls := (report #[] #[] #[]).setObjVal! "scopes" (Json.arr ((jarr (report #[] #[] #[]) "scopes").push other))
  check "delta: a declaration after an error is not reported gone"
    (jarr (Leanprof.Delta.compute (withFile twoDecls 0) (withFile (report #[] #[] #[]) 1)) "decls").isEmpty
  check "delta: a declaration removed from a file without errors is reported gone"
    ((jarr (Leanprof.Delta.compute (withFile twoDecls 0) (withFile (report #[] #[] #[]) 0)) "decls").any
      (jstr · "status" == "gone"))
  -- a project report: an error in another file does not hide what was removed from this one
  let twoFiles (errors : Nat) : Json := (withFile (report #[] #[] #[]) 0).setObjVal! "files" (Json.arr #[
    Json.mkObj [("file", "F.lean"), ("errors", toJson (0 : Nat))], Json.mkObj [("file", "G.lean"), ("errors", toJson errors)]])
  check "delta: an error in another file does not keep this file's removed declarations"
    ((jarr (Leanprof.Delta.compute (withFile twoDecls 0) (twoFiles 1)) "decls").any (jstr · "status" == "gone"))
  let d := Leanprof.Delta.compute (report #[] #[] #[]) (report #[cause "f" "whnf" 5000 30] #[] #[] (total := 7000))
  check' "delta: the summary names the declaration and its top change"
    ((Leanprof.Delta.summary d).any (has · "+6.00 kHB  F.lean d (F.lean:1); whnf reduces f"))
    (toString (Leanprof.Delta.summary d))
  check "delta: a run report is not compared"
    (((Leanprof.Delta.compute (Json.mkObj [("scopes", Json.arr #[])]) (report #[] #[] #[])).getObjValAs? Bool "comparable").toOption == some false)
  -- time moved by 20% and 5 ms: changed at compare's defaults, not with --threshold 50
  let timed (ns : Nat) : Json := (report #[] #[] #[] (total := ns)).setObjVal! "unit" "ns"
  check "delta: a time change counts above compare's default thresholds"
    ((jarr (Leanprof.Delta.compute (timed 25000000) (timed 30000000)) "decls").size == 1)
  check "delta: the time thresholds can be raised"
    (jarr (Leanprof.Delta.compute (timed 25000000) (timed 30000000) { pct := 50 }) "decls").isEmpty

end Tests.Regress
