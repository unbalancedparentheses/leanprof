/-!
The project an autoresearch loop optimizes in the demo. It does not depend on
leanprof: `leanprof measure` links leanprof's runtime in by itself.

`buildWithHistory` is the pattern of `Examples/CopyBug.lean`: it keeps every
intermediate array in `history`, so each `push` finds `acc` shared and copies
it (quadratic work in a loop that looks linear). The program only needs the
sum of each prefix, which `experiments/1-fix-copies.patch` keeps as it goes.
-/

def buildWithHistory (n : Nat) : Array Nat × Array (Array Nat) := Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  let mut history : Array (Array Nat) := #[]
  for i in [0:n] do
    history := history.push acc
    acc := acc.push (i * i % 7)
  return (acc, history)

/-- The sum of the sums of every prefix of the data (the empty one included). -/
def prefixTotal (n : Nat) : Nat :=
  let (_, history) := buildWithHistory n
  history.foldl (fun s p => s + p.foldl (· + ·) 0) 0

def main (args : List String) : IO Unit := do
  let n := (args.head? >>= String.toNat?).getD 3000
  IO.println s!"prefix total {prefixTotal n}"
