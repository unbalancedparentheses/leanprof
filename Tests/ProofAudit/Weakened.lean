def obligation (_ : Nat) : Prop := True

theorem preserved (n : Nat) : obligation n := by
  trivial

def compute (n : Nat) : Nat := n
