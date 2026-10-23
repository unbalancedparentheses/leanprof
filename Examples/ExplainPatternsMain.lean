module

public import Examples.ExplainPatterns

/-! Runs every copying version of `Examples/ExplainPatterns.lean` and its
fixes, printing the copies each made. `leanprof run explainpatterns` then
`leanprof explain` diagnoses the copying versions. -/

/-- `n`, unknown to the compiler, so the calls are not evaluated at startup. -/
def opaqueNat (n : Nat) : IO Nat := do return n + (← IO.monoMsNow) * 0

def copiesOf (name : String) (x : IO Nat) : IO Unit := do
  let c0 ← Leanprof.copies
  let r ← x
  IO.println s!"{name}: {(← Leanprof.copies) - c0} copies (result {r})"

public def main (args : List String) : IO Unit := do
  let n ← opaqueNat ((args.head? >>= String.toNat?).getD 1000)
  let k ← opaqueNat 10
  let modules (_ : Unit) : Std.HashMap Nat Module :=
    (List.range k).foldl (fun m i => m.insert i { name := toString i, members := #[] }) {}
  let pure' (x : Unit → Nat) : IO Nat := IO.lazyPure x
  copiesOf "nestedBuckets" (pure' fun _ => (nestedBuckets n k).size)
  copiesOf "nestedBucketsFixed" (pure' fun _ => (nestedBucketsFixed n k).size)
  copiesOf "groupBy" (pure' fun _ => (groupBy n k).size)
  copiesOf "groupByAlter" (pure' fun _ => (groupByAlter n k).size)
  copiesOf "groupByErase" (pure' fun _ => (groupByErase n k).size)
  copiesOf "groupByOpt" (pure' fun _ => (groupByOpt n k).size)
  copiesOf "groupByOptErase" (pure' fun _ => (groupByOptErase n k).size)
  copiesOf "addMembers" (pure' fun _ => (addMembers n k (modules ())).size)
  copiesOf "addMembersModify" (pure' fun _ => (addMembersModify n k (modules ())).size)
  copiesOf "addMembersErase" (pure' fun _ => (addMembersErase n k (modules ())).size)
  copiesOf "withHistory" (pure' fun _ => (withHistory n).2.size)
  copiesOf "withHistoryLengths" (pure' fun _ => (withHistoryLengths n).2.size)
  copiesOf "logGlobal" (logGlobal n)
  copiesOf "logLocal" (logLocal n)
  copiesOf "logMutex" (logMutex n)
  copiesOf "logMutexLocal" (logMutexLocal n)
  copiesOf "bumpAll" (pure' fun _ => (bumpAll (Array.replicate n 0) k).size)
  copiesOf "bumpAllIndexed" (pure' fun _ => (bumpAllIndexed (Array.replicate n 0) k).size)
