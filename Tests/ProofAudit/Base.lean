def obligation (n : Nat) : Prop := n + 0 = n

theorem preserved (n : Nat) : obligation n := by
  unfold obligation
  exact Nat.add_zero n

def compute (n : Nat) : Nat := n + 0
