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
-/

public section
namespace Leanprof

/-- Run `act ()` and, when `LEANPROF_BENCH_OUT` is set (by `leanprof
measure-pair --scope NAME`), append `name`, a tab and the nanoseconds it took
to that file. -/
def bench {α : Type} (name : String) (act : Unit → IO α) : IO α := do
  let t0 ← IO.monoNanosNow
  let r ← act ()
  let t1 ← IO.monoNanosNow
  if let some path ← IO.getEnv "LEANPROF_BENCH_OUT" then
    IO.FS.withFile path .append fun h => h.putStrLn s!"{name}\t{t1 - t0}"
  return r

end Leanprof
