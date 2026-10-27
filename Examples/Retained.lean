import Leanprof

/-! A program with known retention, for `leanprof run --retained`
(docs/guide/memory.md). The test executable runs it as a child with
`LEANPROF_RETAINED=1` and checks the report (Tests/Main.lean); the `retained`
executable (Examples/RetainedMain.lean) runs it on its own. Every object here is a pair or a
list cell: a constructor with two object fields, 24 bytes. -/

namespace RetainedTest

initialize cache : IO.Ref (Array (Nat × Nat)) ← IO.mkRef #[]
initialize hook : IO.Ref (Nat → Nat) ← IO.mkRef id
/-- Lean before 4.28 has no `Nonempty (Thunk α)`, which an `initialize` of a Ref needs. -/
instance : Nonempty (Thunk (List Nat)) := ⟨Thunk.pure []⟩
initialize lazy : IO.Ref (Thunk (List Nat)) ← IO.mkRef (Thunk.pure [])
initialize log : IO.Ref (List (Nat × Nat)) ← IO.mkRef []

/-! Each site is a recursive function: the C compiler inlines small
functions into their callers, and an allocation is charged to the compiled
function it is in. -/

/-- `n` pairs kept in a global `IO.Ref`'s array. -/
@[noinline] def keepPairs : Nat → Nat → IO Unit
  | 0, _ => pure ()
  | n + 1, i => do
    cache.modify (·.push (i, i + 1))
    keepPairs n (i + 1)

/-- A list a closure captures. -/
@[noinline] def hookCells : Nat → List Nat
  | 0 => []
  | n + 1 => n :: hookCells n

/-- A list a thunk computes, and keeps once forced. -/
@[noinline] def lazyCells : Nat → List Nat
  | 0 => []
  | n + 1 => (n + 7) :: lazyCells n

/-- A temporary list of pairs: alive at the snapshot, gone at exit. -/
@[noinline] def tempPairs : Nat → List (Nat × Nat)
  | 0 => []
  | n + 1 => (n, n) :: tempPairs n

/-- `n` pairs appended to a global log: called over the run, leak-like growth. -/
@[noinline] def logPairs : Nat → Nat → IO Unit
  | 0, _ => pure ()
  | n + 1, i => do
    log.modify ((i, 2 * i) :: ·)
    logPairs n (i + 1)

/-- The scenario: `n` is 1 (an argument, so nothing is a compile-time constant). -/
def scenario (n : Nat) : IO Unit := do
  -- 100 pairs in a global IO.Ref's array
  keepPairs (100 * n) 0
  -- 300 list cells captured by a closure kept in a global IO.Ref
  let xs := hookCells (300 * n)
  hook.set fun i => xs.length + i
  -- 200 list cells computed by a thunk, which keeps them once forced
  let t : Thunk (List Nat) := Thunk.mk fun _ => lazyCells (200 * n)
  let len := t.get.length
  lazy.set t
  -- 5000 pairs and 5000 cells alive at a snapshot only
  let tmp ← IO.lazyPure fun _ => tempPairs (5000 * n)
  Leanprof.retainedSnapshot
  IO.println s!"{tmp.length} {len}"
  -- 40 rounds of 1000 pairs logged, 3 ms apart
  for r in [0:40] do
    logPairs (1000 * n) (r * 1000)
    IO.sleep 3

/-- With a task running: no heap walk may run (the report says they were skipped). -/
def taskScenario (n : Nat) : IO Unit := do
  let t := Task.spawn fun _ => (tempPairs (1000 * n)).length
  let xs := hookCells (300 * n)
  Leanprof.retainedSnapshot
  IO.println s!"{t.get} {xs.length}"

end RetainedTest
