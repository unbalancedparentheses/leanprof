# Overhead benchmark

Extra cost of one profiled `IO` action (`IO.Ref.modify`), leanprof against
[LeanProfiler](https://github.com/lean-dojo/LeanProfiler) at commit `35e1899`.
Each thread times its own loop of `n` actions, plain and profiled; the
difference divided by `n` is the overhead.

```
cd bench
lake build bench
.lake/build/bin/bench leanprof 1 1000000
.lake/build/bin/bench leanprofiler 1 1000000          # recording off
LEAN_PROFILE=1 .lake/build/bin/bench leanprofiler 1 4000   # recording on
```

## Results

Apple M5 Max, macOS, Lean 4.35.0, 2026-10-22. Three runs each; ranges shown.

| | 1 thread, n=1M | 4 threads, n=1M each |
|---|---|---|
| leanprof (always recording) | 10.2–11.5 ns | 12.1–12.4 ns |
| LeanProfiler, recording off | 22.6–26.0 ns | 363–391 ns |

LeanProfiler with recording on (`LEAN_PROFILE=1`), one thread:

| events | per span |
|---|---|
| 1,000 | 4.6 µs |
| 4,000 | 20.1 µs |
| 16,000 | 88.5 µs |

leanprof over the same event counts: 15.5, 12.2 and 11.5 ns.

## Why LeanProfiler's cost grows

The per-span cost grows with the number of events recorded, so total time is
quadratic. Building the benchmark with leanprof's compiler wrapper
(`LEAN_CC=../scripts/leanprof-cc`, after deleting `.lake/**/*.c.o*` so every
package recompiles) shows why, without any annotations in LeanProfiler:

```
function                                                     copies       bytes    time  why                        where (declaration)
LeanProfiler.Internal.reserveSpan (in Std.DHashMap...insert)  12003   123.0 MiB  14.1 ms  multi-threaded+persistent  .lake/packages/LeanProfiler/LeanProfiler/Runtime/Capture.lean:65
LeanProfiler.Internal.completeSpan                             8002    61.1 MiB  12.0 ms  multi-threaded+persistent  .lake/packages/LeanProfiler/LeanProfiler/Runtime/Capture.lean:94
```

(4,000 spans.) The profiler state lives in a mutex, so its arrays and maps
are marked multi-threaded, and `let state ← get; set { state with events :=
state.events.push e }` keeps a second reference besides. Lean never updates
such values in place, so every span copies every event recorded so far.
