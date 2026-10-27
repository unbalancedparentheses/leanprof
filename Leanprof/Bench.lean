module

/-!
# `Leanprof.bench`: time one region of a plain build

`leanprof measure-pair --scope NAME` times only the region a program wraps in
`Leanprof.bench "NAME" fun _ => ...`, not the whole process, so start-up and
setup no longer dilute a change and each run can be short. Nothing else is
instrumented: the region runs as written, and the only extra work is two
clock reads and, when `LEANPROF_BENCH_OUT` is set, one appended line.

The protocol is that line, so a program can also do it without depending on
leanprof: after the region, if `LEANPROF_BENCH_OUT` names a file, append
`NAME<TAB>NANOSECONDS<LF>` to it. A region that runs several times in one
process is summed.

Repetitions, only when asked for: when `LEANPROF_BENCH_REPEAT` is a number
`N` above 1 (set by `measure-pair --scope NAME --repeat N`), the region runs
`N` times in a row and each run appends `NAME<TAB>NANOSECONDS<TAB>K` with `K`
from 0 to `N - 1`. `measure-pair` sums each `K` over the process and takes
the fastest sum (or, `--repeat-stat median`, the median). The region must
then be repeatable: no state carried from one repetition to the next (a
cache filled by the first, input consumed by it), or the repetitions time
different work; put such setup outside the region. Its result is the last
repetition's. A program that writes the lines itself may ignore the
variable: lines without `K` are one repetition.
-/

public section
namespace Leanprof

/-- How many times `bench` runs its region: `LEANPROF_BENCH_REPEAT` when
results are being collected (`LEANPROF_BENCH_OUT` set), else 1. -/
def benchRepeat : IO Nat := do
  if (← IO.getEnv "LEANPROF_BENCH_OUT").isNone then return 1
  match (← IO.getEnv "LEANPROF_BENCH_REPEAT").bind String.toNat? with
  | some n => return Nat.max 1 (Nat.min n 1000)
  | none => return 1

/-- Run `act ()` and, when `LEANPROF_BENCH_OUT` is set (by `leanprof
measure-pair --scope NAME`), append `name`, a tab and the nanoseconds it took
to that file. With `LEANPROF_BENCH_REPEAT=N` (N > 1) it runs `act ()` N times,
each line tagged with its repetition, and returns the last result. -/
def bench {α : Type} (name : String) (act : Unit → IO α) : IO α := do
  let n ← benchRepeat
  let once (k : Nat) : IO α := do
    let t0 ← IO.monoNanosNow
    let r ← act ()
    let t1 ← IO.monoNanosNow
    if let some path ← IO.getEnv "LEANPROF_BENCH_OUT" then
      let tag := if n > 1 then s!"\t{k}" else ""
      IO.FS.withFile path .append fun h => h.putStrLn s!"{name}\t{t1 - t0}{tag}"
    return r
  for k in [:n - 1] do discard <| once k
  once (n - 1)

end Leanprof
