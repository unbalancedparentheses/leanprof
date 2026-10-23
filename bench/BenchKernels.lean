/-!
Leaf functions of the workloads. They live in their own module (so their own
C file) and are `@[noinline]`, so neither Lean nor the C compiler inlines them
into the code that calls them: every call is a real call, and call counts in
`leanprof run --auto` are known exactly.
-/

namespace K

/-- `k` rounds of a 64-bit mix: a unit of CPU work with no allocation. -/
@[noinline] def spin (k : Nat) (x : UInt64) : UInt64 := Id.run do
  let mut h := x
  for _ in [0:k] do
    h := (h ^^^ (h >>> 33)) * 0xff51afd7ed558ccd
  return h

/-- Tiny functions, a few instructions each. -/
@[noinline] def tinyA (i : UInt64) : UInt64 := i * 3 + 1
@[noinline] def tinyB (i : UInt64) : UInt64 := (i ^^^ (i >>> 7)) * 5 + 2

/-! Drivers. The C compiler inlines a function into a caller in the same
C file, and an inlined function has no frame for samply and no hooks for
`run --auto`. The workloads therefore call their functions through these,
from another module, as closures: each call stays a real call in every build. -/

/-- `f r` for `r < reps`, summed. -/
@[noinline] def repeatU (reps : Nat) (f : UInt64 → UInt64) : UInt64 := Id.run do
  let mut acc : UInt64 := 0
  for r in [0:reps] do
    acc := acc + f (acc + r.toUInt64)
  return acc + 1

/-- `f (n + r % 2)` for `r < reps`, summed. -/
@[noinline] def repeatN (reps : Nat) (f : Nat → Nat) (n : Nat) : Nat := Id.run do
  let mut acc := 0
  for r in [0:reps] do
    acc := acc + f (n + r % 2)
  return acc + 1

/-- `f n`, as a real call. -/
@[noinline] def call (f : Nat → UInt64) (n : Nat) : UInt64 := f n + 1

structure Pt where
  x : UInt64
  y : UInt64

/-- A tree of boxed nodes, for the allocation workload. -/
inductive Tree where
  | leaf
  | node (l : Tree) (v : UInt64) (r : Tree)

end K
