import LeanprofElab

/-! Tests of `leanprof elab`'s trace reading (LeanprofElab.lean), on traces in
the format `lean --json -Dtrace.profiler=true` prints. -/

open Leanprof.Elab

namespace Tests.Elab

/-- An `isDefEq` that unfolds `Foo.bar` (and inside that, `Foo.bar` again and
`Foo.baz`), an instance tried, and a simp rewrite after its unification. -/
def sample : String := "[Elab.command] [0.010000] ✅️ theorem t : x = y := by simp
  [Meta.isDefEq] [0.006000] ✅️ Foo.bar 1 =?= 2
    [Meta.isDefEq.delta.unfoldLeft] Foo.bar
    [Meta.isDefEq] [0.005000] ✅️ Foo.baz 1 =?= 2
      [Meta.isDefEq.delta.unfoldLeft] Foo.bar
      [Meta.isDefEq] [0.001000] ✅️ 1 =?= 2
      [Meta.isDefEq.delta.unfoldRight] Foo.baz
      [Meta.isDefEq] [0.002000] ✅️ 3 =?= 2
  [Meta.synthInstance.apply] [0.001500] ✅️ apply @instAddNat to Add Nat
  [Meta.isDefEq] [0.000700] ✅️ ?a + ?b =?= x + y
  [Meta.Tactic.simp.rewrite] Nat.add_comm:1000:
        x + y
      ==>
        y + x
  [Meta.whnf] [0.000300] ✅️ Non-easy whnf: ?n + ?m = ?m + ?n"

def diag : String := "[diag] Diagnostics
  [reduction] unfolded declarations (max: 5, num: 2):
    [reduction] Foo.bar ↦ 5
    [reduction] outParam ↦ 2
  [kernel] unfolded declarations (max: 9, num: 1):
    [kernel] Nat.rec ↦ 9
  use `set_option diagnostics.threshold <num>` to control threshold for reporting counters"

def simpDiag : String := "[simp] Diagnostics
  [simp] used theorems (max: 1, num: 1):
    [simp] eq_self ↦ 1
  [simp] tried theorems (max: 3, num: 2):
    [simp] Nat.add_comm ↦ 3, succeeded: 1
    [simp] Nat.add_eq_left ↦ 2 ❌️
  use `set_option diagnostics.threshold <num>` to control threshold for reporting counters"

def near (x y : Float) : Bool := (x - y).abs < 1e-9

def run (check : String → Bool → String → StateT Nat IO Unit) : StateT Nat IO Unit := do
  let nodes := parseTrace sample
  check "elab: untimed unfold and simp lines are part of the tree"
    (nodes.size == 12 && nodes[2]!.cls == "Meta.isDefEq.delta.unfoldLeft" && !nodes[2]!.timed &&
      nodes[2]!.parent == some 1) s!"nodes={nodes.size}"
  check "elab: a description that looks like a timed line is not one"
    ((traceLine "      [x] [6] ++ xs").isNone && (traceLine "  [Meta.whnf] [0.5] ✅️ e").isSome) ""
  check "elab: a simp rewrite's description is one node" (nodes[10]!.text.startsWith "Nat.add_comm:1000:") ""
  let at_ := attributions nodes
  let cost (n : String) : Float := at_.foldl (fun s (c, _, x) => if c == n then s + x.getD 0 else s) 0
  let times (n : String) : Nat := (at_.filter (·.1 == n)).size
  -- unfolding Foo.bar costs the comparison after it (5 ms); its nested unfold of
  -- Foo.bar is counted but not charged again
  check "elab: an unfold is charged the comparison after it, once per nest"
    (near (cost "Foo.bar") 0.005 && times "Foo.bar" == 2) s!"cost={cost "Foo.bar"} times={times "Foo.bar"}"
  check "elab: a nested unfold of another constant is charged too" (near (cost "Foo.baz") 0.002)
    s!"cost={cost "Foo.baz"}"
  check "elab: an instance tried is charged its attempt" (near (cost "instAddNat") 0.0015) ""
  check "elab: a simp rewrite is charged the unification before it" (near (cost "Nat.add_comm") 0.0007)
    s!"cost={cost "Nat.add_comm"}"
  check "elab: whnf of notation names no constant" ((at_.filter (·.2.1 == "whnf")).isEmpty) ""
  let d := parseDiag diag
  check "elab: diagnostics counts" (d == #[("Foo.bar", "unfolds", 5), ("outParam", "unfolds", 2), ("Nat.rec", "kernel", 9)])
    s!"{d}"
  let s := parseDiag simpDiag
  check "elab: simp diagnostics, with failures"
    (s == #[("eq_self", "simp_used", 1), ("Nat.add_comm", "simp_tried", 3), ("Nat.add_comm", "simp_failed", 2),
      ("Nat.add_eq_left", "simp_tried", 2), ("Nat.add_eq_left", "simp_failed", 2)]) s!"{s}"
  check "elab: diagnostics messages are recognized" (isDiagMessage diag && isDiagMessage simpDiag && !isDiagMessage sample) ""
  check "elab: module globs" (globMatch "Batteries.Data.*".toList "Batteries.Data.List.Lemmas".toList &&
    !globMatch "Batteries.Data.*".toList "Batteries.Tactic.Alias".toList && globMatch "*Lemmas".toList "A.Lemmas".toList) ""
  check "elab: private and numeric names" (parseName "_private.Foo.0.Foo.bar" == .str (.str (.num (.str (.str .anonymous "_private") "Foo") 0) "Foo") "bar" &&
    userName "_private.Foo.0.Foo.bar" == "Foo.bar" && parseName "«a.b».c" == .str (.str .anonymous "a.b") "c") ""
  let src := #["theorem t : True := by", "  simp [foo,  bar]", "  omega"].map squash
  check "elab: tactics are found in the source by their text"
    (findTactic src "simp [foo, bar]" 1 == some 2 && findTactic src "omega" 2 == some 3 && findTactic src "decide" 1 == none) ""
  -- `theorem Foo.bar` is elaborated as `namespace Foo theorem bar end`: Lean traces the
  -- inner command, then the outer one (including the inner's time) at the same position
  let msg (data : String) (col : Nat) : Lean.Json := Lean.Json.mkObj [("data", .str data),
    ("pos", Lean.Json.mkObj [("line", (3 : Nat)), ("column", col)])]
  let a := ({} : Acc).addMessage "F.lean" 1 (msg "[Elab.command] [100] ✅️ theorem bar : True := trivial" 0)
  let a := a.addMessage "F.lean" 1 (msg "[Elab.command] [104] ✅️ theorem Foo.bar : True := trivial" 0)
  let a := a.addMessage "F.lean" 1 (msg "[Elab.command] [7] ✅️ def c := 1" 30)
  check "elab: a command and the command it expands into are not counted twice"
    (near a.grand 111 && near ((a.lines.get? "F.lean:3").map (·.total) |>.getD 0) 111) s!"grand={a.grand}"
  check "elab: digit groups" (groupDigits 10000 == "10,000" && groupDigits 1234567 == "1,234,567" && groupDigits 999 == "999") ""
  check "elab: leading constants" (leadingConst "@instFoo to X" == some "instFoo" && leadingConst "inst✝ to X" == none &&
    leadingConst "?m.1 x" == none && leadingConst "Size α" == some "Size") ""

end Tests.Elab
