import Leanprof

/-! Measures the cost of one `profile!` scope around trivial work. -/

def step (i : Nat) : Nat := i * 3 + 1

def plainLoop (n : Nat) : Nat := Id.run do
  let mut acc := 0
  for i in [0:n] do
    acc := acc + step i
  return acc

def profiledLoop (n : Nat) : Nat := Id.run do
  let mut acc := 0
  for i in [0:n] do
    acc := acc + profile! "step" (step i)
  return acc

def main (args : List String) : IO Unit := do
  let n := (args.head? >>= String.toNat?).getD 10000000
  let n := n + (← IO.monoMsNow) * 0
  let t0 ← IO.monoNanosNow
  let a ← IO.lazyPure fun _ => plainLoop n
  let t1 ← IO.monoNanosNow
  let b ← IO.lazyPure fun _ => profiledLoop n
  let t2 ← IO.monoNanosNow
  let per := (Float.ofNat ((t2 - t1) - (t1 - t0))) / Float.ofNat n
  IO.println s!"{n} scopes: {per} ns overhead per scope (results {a == b})"
