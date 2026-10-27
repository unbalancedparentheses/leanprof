import PF.Defs

theorem useA_1 : double 3 = 6 := rfl
theorem useA_2 : double 4 = 8 := by decide
theorem useA_3 : double 5 = 10 := rfl
theorem useA_4 (x : Nat) : double x + 0 = double x := by simp
theorem useA_5 (x : Nat) : double (x + 1) + 0 = double (x + 1) := by simp
theorem useA_6 (x y : Nat) : double x + double y + 0 = double x + double y := by simp
theorem useA_7 (x : Nat) : 0 + double x = double x := by simp
theorem useA_8 (x : Nat) : double (2 * x) * 1 = double (2 * x) := by simp
theorem useA_9 : double 9 = 18 := by decide
