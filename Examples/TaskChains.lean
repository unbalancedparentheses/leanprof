module

public import Leanprof

/-! Task chains: `Task.map`, `Task.bind`, `IO.mapTask` and `IO.bindTask`,
each from its own scope, so the report links every continuation task to the
scope that created it. -/

def work (n : Nat) : Nat := Id.run do
  let mut acc := 0
  for i in [0:n] do
    acc := acc + i * i % 7
  return acc

def sources (k n : Nat) : List (Task Nat) :=
  (List.range k).map fun i => Task.spawn fun _ => work (n + i)

def mapped (k n : Nat) : Nat := profile! "mapped" Id.run do
  let ts := (sources k n).map fun t => t.map fun v => v + work n
  return ts.foldl (fun acc t => acc + t.get) 0

def bound (k n : Nat) : Nat := profile! "bound" Id.run do
  let ts := (sources k n).map fun t => t.bind fun v => Task.spawn fun _ => v + work n
  return ts.foldl (fun acc t => acc + t.get) 0

def ioMapped (k n : Nat) : IO Nat := profile! "ioMapped" do
  let ts ← (sources k n).mapM fun t => IO.mapTask (fun v => IO.lazyPure fun _ => v + work n) t
  let mut acc := 0
  for t in ts do
    match ← IO.wait t with
    | .ok v => acc := acc + v
    | .error e => throw e
  return acc

def ioBound (k n : Nat) : IO Nat := profile! "ioBound" do
  let ts ← (sources k n).mapM fun t =>
    IO.bindTask t fun v => IO.asTask (IO.lazyPure fun _ => v + work n)
  let mut acc := 0
  for t in ts do
    match ← IO.wait t with
    | .ok v => acc := acc + v
    | .error e => throw e
  return acc

public def main (args : List String) : IO Unit := do
  let n := (args.head? >>= String.toNat?).getD 100000
  let n := n + (← IO.monoMsNow) * 0
  let a ← IO.lazyPure fun _ => mapped 8 n
  let b ← IO.lazyPure fun _ => bound 8 n
  let c ← ioMapped 8 n
  let d ← ioBound 8 n
  IO.println s!"{a} {b} {c} {d}"
