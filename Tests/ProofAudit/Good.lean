def obligation (n : Nat) : Prop := n + 0 = n

theorem preserved (renamed : Nat) : obligation renamed := by
  rfl

def compute (n : Nat) : Nat := n
