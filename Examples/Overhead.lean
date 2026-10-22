module

public import Leanprof

/-!
Overhead and accuracy. The same loop runs plain and with a `profile!` scope
around each step: the difference is the cost of profiling, and the report's
total for the steps should match the plain loop's time.
-/

@[noinline] def step (i : Nat) : Nat := i * 3 + 1

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

public def main (args : List String) : IO Unit := do
  let n := (args.head? >>= String.toNat?).getD 10000000
  let n := n + (← IO.monoMsNow) * 0
  let t0 ← IO.monoNanosNow
  let a ← IO.lazyPure fun _ => plainLoop n
  let t1 ← IO.monoNanosNow
  let b ← IO.lazyPure fun _ => profiledLoop n
  let t2 ← IO.monoNanosNow
  let plain := Float.ofNat (t1 - t0)
  let profiled := Float.ofNat (t2 - t1)
  let reported ← Leanprof.totalNs "step"
  IO.println s!"{n} scopes, results agree: {a == b}"
  IO.println s!"  plain loop      {plain / 1e6} ms"
  IO.println s!"  profiled loop   {profiled / 1e6} ms  ({(profiled - plain) / Float.ofNat n} ns per scope)"
  IO.println s!"  reported steps  {reported / 1e6} ms  (calibrated overhead {← Leanprof.overheadNs} ns)"
