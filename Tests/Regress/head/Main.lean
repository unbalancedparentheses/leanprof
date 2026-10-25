/-! The run-time fixture of scripts/regress-check.py. In base/Main.lean `collect`
pushes onto an array that nothing else references, so no push copies. In
head/Main.lean it also keeps each array before the push (`history`), so every
push copies it, and each kept array costs a list cell. -/

def collect (n : Nat) : Array Nat × Nat := Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  let mut history : List (Array Nat) := []
  for i in [0:n] do
    history := acc :: history
    acc := acc.push i
  return (acc, history.length)

def main (args : List String) : IO Unit := do
  let n := (args.head? >>= String.toNat?).getD 300
  let (acc, s) := collect n
  IO.println s!"{acc.size} {s}"
