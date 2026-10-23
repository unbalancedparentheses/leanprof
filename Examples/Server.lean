module

public import Leanprof

/-!
A stand-in for a long-running server, for `leanprof top` and the flight
recorder: it handles `requests` requests (default 200, 0 for forever), about
10 ms each, and every `slowEvery`-th one (default 50) takes 300 ms more.
Each request parses (pure work), copies a shared array, and checks a result
on a task.
-/

def work (n : Nat) : Nat := Id.run do
  let mut acc := 0
  for i in [0:n] do
    acc := acc + i * i % 7
  return acc

def parse (i : Nat) : IO Nat := profile! "parse" do
  IO.lazyPure fun _ => work (20000 + i % 100)

/-- Keeps the old array, so the push copies it. -/
def remember (log : Array Nat) (i : Nat) : IO (Array Nat × Array Nat) := profile! "remember" do
  return (log, log.push i)

def handle (log : Array Nat) (i slowEvery : Nat) : IO (Array Nat) := profile! "handle" do
  let n ← parse i
  let t ← IO.asTask (IO.lazyPure fun _ => work (5000 + n % 10))
  let (_, log) ← remember log n
  if slowEvery > 0 && i % slowEvery == slowEvery - 1 then
    profile! "slowPath" (IO.sleep 300)
  IO.sleep 10
  match ← IO.wait t with
  | .ok _ => pure log
  | .error e => throw e

public def main (args : List String) : IO Unit := do
  let requests := (args[0]? >>= String.toNat?).getD 200
  let slowEvery := (args[1]? >>= String.toNat?).getD 50
  let mut log : Array Nat := #[]
  let mut i := 0
  while requests == 0 || i < requests do
    log ← handle log i slowEvery
    i := i + 1
  IO.println s!"handled {i} requests, log {log.size}"
