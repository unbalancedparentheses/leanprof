import Leanprof

/-!
A program with a classic hidden copy. `buildWithHistory` keeps every
intermediate array in `history`, so each `push` finds `acc` shared and copies
it: quadratic work that looks linear. `build` is the same loop without the
extra reference.
-/

def fib : Nat → Nat
  | 0 => 0
  | 1 => 1
  | n + 2 => profile! "fib" (fib n + fib (n + 1))

def buildWithHistory (n : Nat) : Array Nat × Array (Array Nat) := profile! "buildWithHistory" Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  let mut history : Array (Array Nat) := #[]
  for i in [0:n] do
    history := history.push acc
    acc := acc.push i
  return (acc, history)

def build (n : Nat) : Array Nat := profile! "build" Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  for i in [0:n] do
    acc := acc.push i
  return acc

def main (args : List String) : IO Unit := do
  let n := (args.head? >>= String.toNat?).getD 2000
  let (a, h) := buildWithHistory n
  let b := build n
  profile! "report" do
    IO.println s!"sizes {a.size} {h.size} {b.size}"
    IO.println s!"fib 20 = {fib 20}"
