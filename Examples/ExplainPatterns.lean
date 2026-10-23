module

public import Leanprof
public import Std.Data.HashMap
public import Std.Sync.Mutex

/-!
The causes of copies that `leanprof explain` recognises, each written the way
it appears in real code, next to the fix `explain` prints for it. The tests
(`Tests/Main.lean`) check that `explain` names the cause and prints that fix
for each copying version, and count copies of both versions: every fix here
removes the copies (`lake exe explainpatterns` prints the counts).

| copying version | cause | fixed version |
|---|---|---|
| `nestedBuckets` | element of an outer array updated while the array holds it | `nestedBucketsFixed` (`Array.modify`) |
| `groupBy`, `groupByOpt`, `addMembers` | value read from a `HashMap`, updated, inserted back | `…Alter`, `…Modify`, `…Erase` |
| `withHistory` | value stored in another array, then updated | `withHistoryLengths` |
| `logGlobal`, `logMutex` | value kept in a global `IO.Ref`/`Std.Mutex` (multi-threaded) | `logLocal`, `logMutexLocal` |
| `bumpAll` | `for x in xs` while the loop updates `xs` | `bumpAllIndexed` |
-/

public section

/-! ## An element of an outer array, updated while the array holds it -/

/-- `buckets[i]!` takes a second reference to the inner array, so the push
copies it (lean-compiler-backend's `CFG.build`). -/
def nestedBuckets (n k : Nat) : Array (Array Nat) := Id.run do
  let mut buckets : Array (Array Nat) := Array.replicate k #[]
  for v in [0:n] do
    let i := v % k
    buckets := buckets.set! i (buckets[i]!.push v)
  return buckets

def nestedBucketsFixed (n k : Nat) : Array (Array Nat) := Id.run do
  let mut buckets : Array (Array Nat) := Array.replicate k #[]
  for v in [0:n] do
    let i := v % k
    buckets := buckets.modify i (·.push v)
  return buckets

/-! ## A value read from a hash map, updated and inserted back -/

/-- The map still holds `members` while it is pushed to (LeanProfiler's
`validateEvents`). -/
def groupBy (n k : Nat) : Std.HashMap Nat (Array Nat) := Id.run do
  let mut groups : Std.HashMap Nat (Array Nat) := {}
  for v in [0:n] do
    let key := v % k
    let members := groups.getD key #[]
    groups := groups.insert key (members.push v)
  return groups

def groupByAlter (n k : Nat) : Std.HashMap Nat (Array Nat) := Id.run do
  let mut groups : Std.HashMap Nat (Array Nat) := {}
  for v in [0:n] do
    let key := v % k
    groups := groups.alter key fun members? => some ((members?.getD #[]).push v)
  return groups

def groupByErase (n k : Nat) : Std.HashMap Nat (Array Nat) := Id.run do
  let mut groups : Std.HashMap Nat (Array Nat) := {}
  for v in [0:n] do
    let key := v % k
    let members := groups.getD key #[]
    groups := (groups.erase key).insert key (members.push v)
  return groups

/-- The same with `m[k]?`. -/
def groupByOpt (n k : Nat) : Std.HashMap Nat (Array Nat) := Id.run do
  let mut groups : Std.HashMap Nat (Array Nat) := {}
  for v in [0:n] do
    let key := v % k
    match groups[key]? with
    | some members => groups := groups.insert key (members.push v)
    | none => groups := groups.insert key #[v]
  return groups

def groupByOptErase (n k : Nat) : Std.HashMap Nat (Array Nat) := Id.run do
  let mut groups : Std.HashMap Nat (Array Nat) := {}
  for v in [0:n] do
    let key := v % k
    match groups[key]? with
    | some members => groups := (groups.erase key).insert key (members.push v)
    | none => groups := groups.insert key #[v]
  return groups

structure Module where
  name : String
  members : Array Nat
  deriving Inhabited

/-- A field of a structure read from a map (doc-gen4's `process`). -/
def addMembers (n k : Nat) (modules : Std.HashMap Nat Module) : Std.HashMap Nat Module := Id.run do
  let mut res := modules
  for v in [0:n] do
    let key := v % k
    let module := res[key]!
    res := res.insert key { module with members := module.members.push v }
  return res

def addMembersModify (n k : Nat) (modules : Std.HashMap Nat Module) : Std.HashMap Nat Module := Id.run do
  let mut res := modules
  for v in [0:n] do
    let key := v % k
    res := res.modify key fun module => { module with members := module.members.push v }
  return res

def addMembersErase (n k : Nat) (modules : Std.HashMap Nat Module) : Std.HashMap Nat Module := Id.run do
  let mut res := modules
  for v in [0:n] do
    let key := v % k
    let module := res[key]!
    res := (res.erase key).insert key { module with members := module.members.push v }
  return res

/-! ## A value stored in another array, then updated -/

/-- `history` keeps every version of `acc`, so each push copies it
(`Examples/CopyBug.lean`). -/
def withHistory (n : Nat) : Array Nat × Array (Array Nat) := Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  let mut history : Array (Array Nat) := #[]
  for i in [0:n] do
    history := history.push acc
    acc := acc.push i
  return (acc, history)

/-- `acc` only grows, so version `k` is `acc.extract 0 history[k]!`. -/
def withHistoryLengths (n : Nat) : Array Nat × Array Nat := Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  let mut history : Array Nat := #[]
  for i in [0:n] do
    history := history.push acc.size
    acc := acc.push i
  return (acc, history)

/-! ## A value kept in a global `IO.Ref` or `Std.Mutex` (multi-threaded) -/

initialize events : IO.Ref (Array Nat) ← IO.mkRef #[]

/-- `events` is created at initialization, so whatever it holds is marked
multi-threaded and never updated in place (LeanProfiler's capture state). -/
def logGlobal (n : Nat) : IO Nat := do
  for v in [0:n] do
    events.modify (·.push v)
  return (← events.get).size

def logLocal (n : Nat) : IO Nat := do
  let buf ← IO.mkRef #[]
  for v in [0:n] do
    buf.modify (·.push v)
  events.set (← buf.get)
  return (← events.get).size

initialize state : Std.Mutex (Array Nat) ← Std.Mutex.new #[]

def logMutex (n : Nat) : IO Nat := do
  for v in [0:n] do
    state.atomically (modify (·.push v))
  state.atomically do return (← get).size

def logMutexLocal (n : Nat) : IO Nat := do
  let mut buf := #[]
  for v in [0:n] do
    buf := buf.push v
  state.atomically (modify (· ++ buf))
  state.atomically do return (← get).size

/-! ## A loop over the array it updates -/

/-- `for x in xs` holds the array the loop started with, so the first
`set!` of each pass copies all of `xs`. -/
def bumpAll (start : Array Nat) (rounds : Nat) : Array Nat := Id.run do
  let mut xs := start
  for _ in [0:rounds] do
    let mut j := 0
    for x in xs do
      xs := xs.set! j (x + 1)
      j := j + 1
  return xs

def bumpAllIndexed (start : Array Nat) (rounds : Nat) : Array Nat := Id.run do
  let mut xs := start
  for _ in [0:rounds] do
    let mut j := 0
    for i in [0:xs.size] do
      let x := xs[i]!
      xs := xs.set! j (x + 1)
      j := j + 1
  return xs

end
