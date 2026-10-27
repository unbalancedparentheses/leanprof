import Demo.Heavy

/-! Uses only `Demo.Base`, but imports `Demo.Heavy`: it cannot start before
the slow module ends, and is rebuilt whenever that module changes. It is
slow too, so the two make the critical path. -/

set_option maxRecDepth 100000

def leaf : Nat := double base

theorem leaf_eq : leaf = 14 := rfl

theorem rev600 : (List.range 600).reverse.reverse = List.range 600 := by decide
theorem rev610 : (List.range 610).reverse.reverse = List.range 610 := by decide
theorem rev620 : (List.range 620).reverse.reverse = List.range 620 := by decide
theorem rev630 : (List.range 630).reverse.reverse = List.range 630 := by decide
theorem rev640 : (List.range 640).reverse.reverse = List.range 640 := by decide
theorem rev650 : (List.range 650).reverse.reverse = List.range 650 := by decide
