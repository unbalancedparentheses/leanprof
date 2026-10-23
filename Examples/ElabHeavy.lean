/-!
Elaboration-heavy code for `lake exe leanprof elab`: instance searches that
repeat, `decide`, `simp` and `omega` proofs. Not part of any executable.
-/

/-- A typeclass with a chain of instances, so each search takes several steps. -/
class Size (α : Type) where
  size : α → Nat

instance : Size Nat := ⟨id⟩
instance [Size α] : Size (List α) := ⟨fun xs => xs.foldl (· + Size.size ·) 0⟩
instance [Size α] [Size β] : Size (α × β) := ⟨fun (a, b) => Size.size a + Size.size b⟩
instance [Size α] : Size (Option α) := ⟨fun | none => 0 | some a => Size.size a⟩

/-- Each use searches the same instance again. -/
def total (xs : List (List (Nat × Option (List Nat)))) : Nat :=
  Size.size xs + Size.size xs.reverse + Size.size (xs ++ xs) + Size.size xs.head?.toList

theorem small_decide : (List.range 40).foldl (· + ·) 0 = 780 := by decide

theorem arith (a b c : Nat) (h₁ : a < b) (h₂ : b < c) : a + 2 ≤ c := by
  omega

theorem lists (xs ys : List Nat) : (xs ++ ys).length = ys.length + xs.length := by
  simp [List.length_append, Nat.add_comm]

theorem many_steps (n : Nat) (h : n > 5) : n * 2 > 10 ∧ n + n > 10 ∧ 3 * n > 15 := by
  refine ⟨?_, ?_, ?_⟩ <;> omega
