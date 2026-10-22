import Leanprof
import LeanProfiler

/-!
Cost of one profiled `IO` action, for leanprof and LeanProfiler.

`bench <tool> <threads> <n>` runs `n` tiny actions on each of `threads`
threads, once plain and once profiled, and prints the extra nanoseconds per
profiled action. Tools: `leanprof`, `leanprofiler` (set `LEAN_PROFILE=1` to
record; unset it to measure the disabled path).
-/

def step (r : IO.Ref Nat) : IO Unit := r.modify (· + 1)

def plain (r : IO.Ref Nat) (n : Nat) : IO Unit := do
  for _ in [0:n] do step r

def withLeanprof (r : IO.Ref Nat) (n : Nat) : IO Unit := do
  for _ in [0:n] do profile! "step" (step r)

def withLeanProfiler (r : IO.Ref Nat) (n : Nat) : IO Unit := do
  for _ in [0:n] do LeanProfiler.span "step" (step r)

/-- Run `body` with its own counter on `threads` dedicated threads at once.
Each thread times its own loop, so thread start-up is not counted; returns
the mean per-thread time in ns. -/
def timed (threads : Nat) (body : IO.Ref Nat → IO Unit) : IO Nat := do
  let tasks ← (List.range threads).mapM fun _ => IO.asTask (prio := .dedicated) do
    let r ← IO.mkRef 0
    let t0 ← IO.monoNanosNow
    body r
    return (← IO.monoNanosNow) - t0
  let mut total := 0
  for t in tasks do
    match ← IO.wait t with
    | .ok ns => total := total + ns
    | .error e => throw e
  return total / threads

def main (args : List String) : IO UInt32 := do
  let [tool, threads, n] := args | IO.eprintln "usage: bench <tool> <threads> <n>"; return 2
  let threads := threads.toNat!
  let n := n.toNat!
  let profiled := match tool with
    | "leanprof" => (withLeanprof · n)
    | "leanprofiler" => (withLeanProfiler · n)
    | _ => (plain · n)
  let base ← timed threads (plain · n)
  let prof ← LeanProfiler.profileFromEnvironment "bench" (timed threads profiled)
  let per := (Float.ofNat prof - Float.ofNat base) / Float.ofNat n
  IO.println s!"{tool} threads={threads} n={n}: {per} ns per action"
  return 0
