import Demo.Base

/-! The slow module: proofs by `decide` over lists, which take the elaborator
and the kernel a while. -/

set_option maxRecDepth 100000

theorem rev400 : (List.range 400).reverse.reverse = List.range 400 := by decide
theorem rev410 : (List.range 410).reverse.reverse = List.range 410 := by decide
theorem rev420 : (List.range 420).reverse.reverse = List.range 420 := by decide
theorem rev430 : (List.range 430).reverse.reverse = List.range 430 := by decide
theorem rev440 : (List.range 440).reverse.reverse = List.range 440 := by decide
theorem rev450 : (List.range 450).reverse.reverse = List.range 450 := by decide
theorem map500 : (List.range 500).map (· + 1) = (List.range 500).map (1 + ·) := by decide
theorem map510 : (List.range 510).map (· + 1) = (List.range 510).map (1 + ·) := by decide
theorem map520 : (List.range 520).map (· + 1) = (List.range 520).map (1 + ·) := by decide
theorem map530 : (List.range 530).map (· + 1) = (List.range 530).map (1 + ·) := by decide
theorem map540 : (List.range 540).map (· + 1) = (List.range 540).map (1 + ·) := by decide
theorem map550 : (List.range 550).map (· + 1) = (List.range 550).map (1 + ·) := by decide

def heavy : Nat := base + 100
