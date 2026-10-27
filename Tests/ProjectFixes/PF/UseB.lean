import PF.Defs

theorem useB_1 : double 6 = 12 := rfl
theorem useB_2 : double 7 = 14 := by decide
theorem useB_3 : double 8 = 16 := rfl
theorem useB_4 (x : Nat) : double x * 1 = double x := by simp
theorem useB_5 (x : Nat) : double (x + 2) + 0 = double (x + 2) := by simp
theorem useB_6 (x y : Nat) : double y + double x + 0 = double y + double x := by simp
theorem useB_7 (x : Nat) : 0 + double (x + 3) = double (x + 3) := by simp
theorem useB_8 (x : Nat) : double (3 * x) + 0 = double (3 * x) := by simp
theorem useB_9 : double 10 = 20 := by decide
