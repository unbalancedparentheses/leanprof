# Benchmarks

This package (kept out of the main one, so users of leanprof do not download
LeanProfiler) has two benchmarks: the accuracy and overhead suite, and the
older head-to-head overhead benchmark against LeanProfiler below it.

## Accuracy and overhead suite

```
python3 bench/run.py                    # full: 7 runs, ~8 min on an M5 Max; writes RESULTS.md, results.json
python3 bench/run.py --quick --check    # CI: 30% inputs, 3 runs, ~4 min, exits 1 on a failed check
python3 bench/run.py --lcb DIR          # also the real program (a lean-compiler-backend checkout; or LCB_DIR)
python3 bench/run.py --before OLD.json  # adds a before/after table against an earlier results file
```

Options: `--reps N`, `--scale PCT`, `--workloads tiny,rec`, `--configs
plain,profile,auto`, `--no-build`, `--noisy` (says in RESULTS.md that the
machine was shared), `--md`/`--json` (output paths). It needs `lake` (elan)
and `python3`; `sample` and `samply` need [samply](https://github.com/mstange/samply)
and are skipped, with the reason in RESULTS.md, when it cannot record (on
Linux it needs `kernel.perf_event_paranoid` ≤ 1; CI lowers it with `sudo
sysctl`).

**Results: [RESULTS.md](RESULTS.md)** (the table at its top is the
headline), raw numbers in [results.json](results.json), the same suite with
the runtime before the fixes below in [results-before.json](results-before.json).

### What it measures

`WlPlain.lean` is one program with six workloads whose ground truth is
known: each runs a few phases one after another and times each phase itself
(two clock reads per phase, nothing inside), and prints the exact number of
calls of every function or scope, and where known, of copies and
allocations.

| workload | ground truth |
|---|---|
| `tiny` | loops of 10M and 20M calls of functions of a few instructions |
| `rec` | non-tail recursion 100, 1,000 and 10,000 deep (the same number of calls each), and `fib 32` (7M calls) |
| `mix` | four functions running the same kernel 600, 250, 100 and 50 rounds per call: 60:25:10:5 |
| `alloc` | lists of structures (2 allocations per element) and complete trees (one per node) |
| `copy` | an array pushed while an old version is kept (one hidden copy per push) against the same pushes in place |
| `tasks` | the same work split over 2, 4 and 8 dedicated threads, a tiny scope per step; truth is the sum of the tasks' own durations |

The program is built three times from the same file: plain (the baseline,
also what `run --auto`, `sample` and samply run), with `profile!` around
every function (`WlProf.lean`, a symbolic link; `run`, `--allocs`,
`--counters` and `--frees` run this one) and with LeanProfiler spans around
phases and tasks (`WlSpans.lean`); see `BenchScope.lean`. Functions are called
through closures from another module (`BenchKernels.lean`) so that the C
compiler cannot inline them: an inlined function has no frame for samply and
no hooks for `--auto`, which would make the comparison about inlining.

For each configuration (plain; `profile!`; `leanprof run`; `run --auto`;
`--allocs`; `--counters`; `--frees`; `leanprof sample`; `samply record`
directly at its default 1 kHz; LeanProfiler) and workload, the runs are
interleaved in shuffled order and the report gives the median and range of:

- **error in share of time**: each phase's (or task function's) reported
  inclusive time as a share of the workload's total, against the plain
  build's shares; mean absolute error in percentage points;
- **reported total over plain time**: for leanprof, after it subtracts its
  own overhead (1.00 is a report that matches the uninstrumented program),
  and the **residual per scope** that is left;
- **exact call counts** (and copy counts) against the program's own;
- **slowdown** of the program, and its **cost per scope**.

The real program is [lean-compiler-backend](../docs/case-studies/lean-compiler-backend.md)
compiling zlib (on a copy of the project; `leanprof run` rebuilds it): slowdown
per configuration, and how `run --auto` and `sample` agree with samply on the
inclusive time of its top declarations (there is no ground truth there).

### Findings (Apple M5 Max, shared with other jobs; see RESULTS.md)

- **Call and copy counts are exact** in every leanprof mode on every
  workload, after two fixes (below). Before them, recursion deeper than 512
  scopes lost every deeper call (deepRec: 3.1M of 6.0M counted), and
  `--auto` counted a call through a boxed wrapper twice (`taskWork2`: 4 of 2).
- **Where scopes do real work, leanprof's totals match the plain program**:
  `mix`, `alloc`, `copy` are reported at 0.98–1.06 of plain time, with share
  errors of 0.2–0.7 pp for `profile!`, as good as samply (0.4–0.9 pp).
- **Where scopes do a few nanoseconds of work, leanprof is less accurate
  than samply**, and RESULTS.md lists where. A pure `profile!` scope costs
  ~21 ns on this machine (the ~11 ns figure below is a monadic `IO` scope);
  after subtracting its calibrated cost, 3–12 ns per scope stay in the
  report, mostly the boxing of scalars that cross the closure `profile!`
  builds (a `UInt64` argument or result is allocated), which depends on the
  program. So a 1 ns function wrapped in `profile!` is reported 3–4× too
  slow (`tiny`), and `fib` 5×. `--auto` costs ~15 ns per call and its
  residual is ±1–2 ns per call, either way: tiny functions come out 1.5–2×
  too slow, deep recursion of small functions 0.6× (the hook's cost overlaps
  the function's own work, so subtracting the isolated cost removes too
  much). `leanprof sample` is within 1 pp everywhere but `tasks` (1.7 pp), at 1.03–1.3× slowdown.
  For functions under ~100 ns per call, use `sample` for time and
  `run`/`--auto` for counts.
- **Threads**: with a tiny `profile!` scope per step, the reported time of
  the same work grows with the number of threads (1.6×, 2.5×, 3.1× of plain
  on 2, 4, 8 threads), and the cost per scope measured from the program's own
  timings grows the same way (23 to 31 ns). On this machine (6 + 12 cores of
  two speeds, under load from other jobs) that could not be told apart from
  contention and threads landing on the slower cores; a per-thread
  calibration was tried and did not change it, so it was left out.
- `--frees` is expensive where many objects die: 16× on lean-compiler-backend,
  33× on `tiny`, and the time it adds is not subtracted. `--allocs` adds
  ~4 ns per allocation (7 ns per `tiny` scope, which boxes twice), also not subtracted. Both are for counting, not
  timing.
- On lean-compiler-backend (0.37 s): `run` 1.3×, `--counters` 1.75×,
  `--allocs` 2.1×, `--auto` 3.8×, `--frees` 16×; `sample` agrees with samply
  within 0.7 pp on the top declarations, `--auto` within 4.4 pp. samply's own
  start and finish take about a second, so its 3.9× there is not the
  program's slowdown (on the workloads, 1.0–1.1×).

### Runtime fixes made from these measurements (`c/leanprof.c`)

1. **The scope stack grows** (it was fixed at 512 frames, and frames past it
   were not recorded): deep recursion now has exact counts, and its
   overhead is subtracted from the right scopes.
2. **`--auto` keeps one scope per Lean declaration**: `f`, `f___boxed`,
   `f___redArg` and `f`'s lambdas used to be separate scopes merged by name
   in the report, so a call through a wrapper counted twice and a lambda's
   time inside `f` was added twice. A function entering another function of
   the same declaration now continues the same call.
3. **Calibration measures each way of entering a scope** through the code
   the program runs: the `--auto` hooks, `leanprof_enter`/`leanprof_exit`
   (monadic `profile!`), and a pure `profile!`'s closure (allocated, applied
   and freed). It used to measure only the inlined enter/exit pair.
   (`overhead_by_path_ns` in the JSON report shows the four costs.)

The before/after table is at the end of RESULTS.md: counts went from wrong to
exact; for tiny pure scopes the share error halved (`tiny`, `profile!` 4.6 →
2.1 pp; `run` 3.3 → 1.2 pp); recording every frame of deep recursion costs
~3 ns more per scope there, and other differences are within the noise.

### CI

The `bench` job runs `python3 bench/run.py --quick --check` on Linux and
macOS and uploads the results. `--check` fails unless, in every leanprof
mode, call counts (and copy counts) are exact on every workload, and the
reported total is within 0.75–1.35 of the plain program's time where every
timed scope does at least a microsecond of work (`profile!`: `mix`, `alloc`,
`copy`; `run`: `mix`, `alloc`; `--auto`: `mix`). The band is wide for CI's
shared virtual machines; on the M5 Max those are within 0.98–1.06. On Linux
the job lowers `kernel.perf_event_paranoid` to 1 for samply; if that fails,
`sample` and `samply` are skipped and RESULTS.md says why.

## Overhead benchmark against LeanProfiler

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
