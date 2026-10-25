/-! The compile-time fixture of scripts/regress-check.py. Against base/Regress.lean,
head/Regress.lean makes two declarations more expensive, each for a known
reason: `step_eq` becomes a simp lemma (the simp set of `simp_case` grows), and
`tri` is defined by recursion instead of a closed form (`decide` in
`unfold_case` has to reduce it 100 times). -/

def step (n : Nat) : Nat := n + 1

@[simp] theorem step_eq (n : Nat) : step n = n + 1 := by unfold step; rfl

def tri : Nat → Nat
  | 0 => 0
  | n + 1 => tri n + n + 1

theorem simp_case : ([step 1, step 2, step 3, step 4, step 5, step 6, step 7, step 8, step 9, step 10,
    step 11, step 12, step 13, step 14, step 15, step 16, step 17, step 18, step 19, step 20,
    step 21, step 22, step 23, step 24, step 25, step 26, step 27, step 28, step 29, step 30,
    step 31, step 32, step 33, step 34, step 35, step 36, step 37, step 38, step 39, step 40].map step).length = 40 := by
  simp

theorem unfold_case : tri 100 = 5050 := by
  decide

/-- Unchanged between the two commits: no regression. -/
theorem unchanged (a b : Nat) : a + b = b + a := Nat.add_comm a b
