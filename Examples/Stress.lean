module

public import Leanprof

/-!
Stress test of leanprof's runtime (CI, plain and under sanitizers): many
tasks on the pool and on dedicated threads (a new thread each), recursion
deep enough to grow the scope stack several times, millions of scopes and
copies, while `LEANPROF_LIVE_MS=10` snapshots and flight dumps read the same
tables. Every count is checked exactly at the end; the program exits 1 if
one is off.

`stress [rounds] [tasks] [scopes] [depth] [len]` (defaults 8, 32, 40000,
20000, 200): each round runs `tasks` pool tasks and `tasks / 4` dedicated
ones, each with `scopes` pure scopes, `scopes / 10` monadic ones,
`scopes / len` copying loops (`len - 1` copies each), and two recursions
`depth` deep, one with a scope per level and one allocating per level.
-/

open Leanprof

def leaf (i : Nat) : Nat := profile! "stress.leaf" (i * i % 7)

def leaves (n seed : Nat) : Nat := Id.run do
  let mut acc := seed
  for i in [0:n] do
    acc := acc + leaf (i + acc % 3)
  return acc

def deep : Nat → Nat
  | 0 => 0
  | n + 1 => profile! "stress.deep" (deep n + 1)

/-- Keeps every intermediate array, so each push copies `acc`. -/
def history (n : Nat) : Nat := Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  let mut hist : Array (Array Nat) := #[]
  for i in [0:n] do
    hist := hist.push acc
    acc := acc.push i
  return acc.size + hist.size

def ioStep (i : Nat) : IO Nat := profile! "stress.io" do
  return i + 1

/-- Deep recursion without `profile!`, allocating at every level: under
`leanprof run --auto --allocs` each allocation once looked down the whole
scope stack for a label (quadratic). -/
def pairs : Nat → List (Nat × Nat)
  | 0 => []
  | n + 1 => (n, n) :: pairs n

/-- `len` comes from the command line: a literal would make `history len` a
closed term, computed once at startup. -/
def worker (seed scopes depth len : Nat) : IO Nat := do
  let mut acc ← IO.lazyPure fun _ => leaves scopes seed
  for _ in [0:scopes / len] do
    acc := acc + (← IO.lazyPure fun _ => history len)
  acc := acc + (← IO.lazyPure fun _ => deep depth)
  acc := acc + (← IO.lazyPure fun _ => (pairs depth).length)
  for i in [0:scopes / 10] do
    acc := acc + (← ioStep i)
  return acc

public def main (args : List String) : IO UInt32 := do
  let arg (i d : Nat) := (args[i]? >>= String.toNat?).getD d
  let rounds := arg 0 8
  let tasks := arg 1 32
  let scopes := arg 2 40000
  let depth := arg 3 20000
  let len := max (arg 4 200) 1
  let dedicated := tasks / 4
  -- copies of one copying loop, measured alone
  let c0 ← copies
  let one ← IO.lazyPure fun _ => history len
  let perLoop := (← copies) - c0
  let leaf0 ← calls "stress.leaf"
  let deep0 ← calls "stress.deep"
  let io0 ← calls "stress.io"
  let copies0 ← copies
  let mut sum := one
  for r in [0:rounds] do
    let mut ts := #[]
    for k in [0:tasks] do
      ts := ts.push (← IO.asTask (worker (r + k) scopes depth len))
    for k in [0:dedicated] do
      ts := ts.push (← IO.asTask (worker (r + k) scopes depth len) (prio := .dedicated))
    -- a slow scope under load, for LEANPROF_SLOW_MS
    profile! "stress.slow" (IO.sleep 60)
    for t in ts do
      match ← IO.wait t with
      | .ok v => sum := sum + v
      | .error e => throw e
  let runs := rounds * (tasks + dedicated)
  let want : List (String × Nat × Nat) := [
    ("stress.leaf", (← calls "stress.leaf") - leaf0, runs * scopes),
    ("stress.deep", (← calls "stress.deep") - deep0, runs * depth),
    ("stress.io", (← calls "stress.io") - io0, runs * (scopes / 10)),
    ("copies", (← copies) - copies0, runs * (scopes / len) * perLoop)]
  let mut bad := 0
  for (what, got, expected) in want do
    IO.println s!"{what}: {got} (expected {expected})"
    if got != expected then bad := bad + 1
  IO.println s!"{runs} tasks, checksum {sum}"
  return if bad == 0 && perLoop > 0 then 0 else 1
