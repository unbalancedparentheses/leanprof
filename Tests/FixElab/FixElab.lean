/-!
For `scripts/experiment-check.sh`: `leanprof fix --elab` replaces these `simp`
calls by Lean's own `simp only` lists and keeps the change only if the proofs
still check, with fewer heartbeats, and the proof-preservation guard passes.
-/

theorem max_right (a b : Nat) (h : a ≤ b) : max a b = b := by
  simpa using Nat.max_eq_right h

theorem apply_twice (f : Nat → Nat) (h : ∀ x, f x = x) : f (f 2) = 2 := by
  simp_all

theorem append_length (xs ys : List Nat) : (xs ++ ys ++ []).length = ys.length + xs.length := by
  simp [Nat.add_comm]
