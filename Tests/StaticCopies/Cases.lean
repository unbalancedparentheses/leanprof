import Leanprof

namespace StaticCopyCases

@[noinline] def retained (xs : Array Nat) (n : Nat) : Array Nat × Array Nat :=
  (xs.push n, xs)

@[noinline] def exclusive (xs : Array Nat) (n : Nat) : Array Nat :=
  xs.push n

@[noinline] def stored (xs : Array Nat) (n : Nat) : Array Nat × Array (Array Nat) :=
  let history := #[xs]
  (xs.push n, history)

@[noinline] def moved (state : Array Nat × Nat) : Array Nat :=
  state.1.push state.2

@[noinline] def readHistory (history : Array (Array Nat)) : Nat :=
  history.size + (history[0]?.getD #[]).size

@[noinline] def released (xs : Array Nat) (n : Nat) : Array Nat :=
  let history := #[xs]
  let size := readHistory history
  xs.push (n + size)

@[noinline] def conditional (keep : Bool) (xs : Array Nat) (n : Nat) : Array Nat × Array Nat :=
  if keep then (xs.push n, xs) else (xs.push n, #[])

@[noinline] def nested (xs : Array (Array Nat)) (n : Nat) : Array (Array Nat) :=
  xs.set! 0 (xs[0]!.push n)

@[noinline] def nestedFixed (xs : Array (Array Nat)) (n : Nat) : Array (Array Nat) :=
  xs.modify 0 (·.push n)

@[noinline] def emptyRetained (capacity : Nat) : Array Nat × Array Nat :=
  let xs := Array.mkEmpty capacity
  (xs.push capacity, xs)

-- Cross-function sharing is deliberately outside the prototype's local analysis.
@[noinline] def updateOpaque (xs : Array Nat) (n : Nat) : Array Nat := xs.push n
@[noinline] def interprocedural (xs : Array Nat) (n : Nat) : Array Nat × Array Nat :=
  (updateOpaque xs n, xs)

end StaticCopyCases
