module

public import Leanprof

/-! Tasks: pure `Task.spawn` and `IO.asTask` work, spawned from scopes and
waited on, so the report shows run time, queue wait and blocking waits. -/

def work (n : Nat) : Nat := Id.run do
  let mut acc := 0
  for i in [0:n] do
    acc := acc + i * i % 7
  return acc

def pureTasks (k n : Nat) : Nat := profile! "pureTasks" Id.run do
  let tasks := (List.range k).map fun i => Task.spawn fun _ => work (n + i)
  return tasks.foldl (fun acc t => acc + t.get) 0

def ioTasks (k n : Nat) : IO Nat := profile! "ioTasks" do
  -- `IO.asTask (pure (work x))` would compute `work x` here, before spawning;
  -- `IO.lazyPure` defers it into the task.
  let tasks ← (List.range k).mapM fun i => IO.asTask (IO.lazyPure fun _ => work (n + i))
  let mut acc := 0
  for t in tasks do
    match ← IO.wait t with
    | .ok v => acc := acc + v
    | .error e => throw e
  return acc

public def main (args : List String) : IO Unit := do
  let n := (args.head? >>= String.toNat?).getD 200000
  let n := n + (← IO.monoMsNow) * 0
  let a ← IO.lazyPure fun _ => pureTasks 16 n
  let b ← ioTasks 16 n
  IO.println s!"{a} {b}"
