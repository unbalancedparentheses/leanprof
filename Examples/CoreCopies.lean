module

public import Leanprof

/-! Copies that happen inside Lean's precompiled core library. `xs ++ ys`
calls `Array.append`, compiled into `libInit.a`, which pushes onto `xs`; when
`xs` is still referenced, the first push copies it, inside libInit. Without
`leanprof run --core` those copies are invisible. -/

/-- `base` stays alive across the loop, so every `base ++ extra` copies it. -/
def appendShared (base extra : Array Nat) (k : Nat) : Nat := profile! "appendShared" Id.run do
  let mut total := 0
  for _ in [0:k] do
    total := total + (base ++ extra).size
  return total + base.size

/-- Same loop on a fresh array each time: no copies. -/
def appendFresh (n : Nat) (extra : Array Nat) (k : Nat) : Nat := profile! "appendFresh" Id.run do
  let mut total := 0
  for i in [0:k] do
    total := total + (Array.replicate (n + i * 0) 0 ++ extra).size
  return total

public def main (args : List String) : IO Unit := do
  let n := (args.head? >>= String.toNat?).getD 1000
  let base := Array.range n
  let extra := #[1, 2, 3]
  let a ← IO.lazyPure fun _ => appendShared base extra 500
  let b ← IO.lazyPure fun _ => appendFresh n extra 500
  IO.println s!"{a} {b}"
