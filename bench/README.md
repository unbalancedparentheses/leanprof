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
the runtime before the first round of fixes below in [results-before.json](results-before.json); RESULTS.md ends with a before/after table against `main` before the second round.

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

The program is built four times from the same file: plain (the baseline,
also what `run --auto`, `sample` and samply run), with `profile!` around
every function (`WlProf.lean`, a symbolic link; `run`, `--allocs`,
`--counters` and `--frees` run this one), with LeanProfiler spans around
phases and tasks (`WlSpans.lean`), and with leanprof scopes in exactly
those places (`WlPhases.lean`, the `phases` configuration, so that leanprof
and LeanProfiler are also compared like with like: the per-function
configurations time every call, LeanProfiler only phases); see
`BenchScope.lean`. Functions are called
through closures from another module (`BenchKernels.lean`) so that the C
compiler cannot inline them: an inlined function has no frame for samply and
no hooks for `--auto`, which would make the comparison about inlining.

For each configuration (plain; `profile!`; `leanprof run`; `run --auto`;
`--allocs`; `--counters`; `--frees`; `leanprof sample`; `samply record`
directly at its default 1 kHz; `phases`; LeanProfiler) and workload, the runs are
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
  workload (see the first round of fixes below).
- **Where scopes do real work, leanprof's totals match the plain program**:
  `mix`, `alloc`, `copy` are reported at 0.92–1.03 of plain time, with share
  errors of 0.4–0.5 pp for `profile!`, as good as samply (0.5–1.0 pp).
- **Where scopes do a few nanoseconds of work, the report says so.** A
  scope costs about 8 ns (`profile!`, pure or monadic, and `--auto`). What
  the subtraction gets wrong is now a nanosecond or two per scope, either
  way: loops of 1 ns functions (`tiny`) come out at 0.5–1.4 of their time,
  `fib` at 0.5–1.7, steps of a few ns on 2–8 threads at 1.2–1.5. Those rows
  are flagged "near the probe cost" (`*`), and RESULTS.md's "Flag
  calibration" line checks the threshold: unflagged component rows within
  14% of the truth (median 3%), flagged ones off by 22% in the median.
  `leanprof sample` is within 2 pp everywhere, at 1.0–1.3× slowdown.
- **lean-compiler-backend** (0.39 s): `run` 1.10×, `--counters` 1.18×,
  `--allocs` 1.23×, `--frees` 1.40×, `--auto` 1.52× (before this round:
  1.21×, 1.72×, 2.12×, 2.27×, 3.69×). `sample` agrees with samply within
  1.1 pp on the top declarations, `--auto` within 4.0 pp. samply's own
  start and finish take about a second, so its 4× there is not the
  program's slowdown (on the workloads, 1.0–1.1×).
- `--allocs` and `--frees` add time they do not subtract (an allocation or
  a free is counted and timed): use them for counting.

### Linux: AMD Ryzen 9 7950X3D (2026-10-23)

A dedicated idle machine (Arch Linux, kernel 7.2, `performance` governor,
boost off, the suite pinned to cores 0–7) run with
`servers/leanprof-bench-run.sh` from the dotfiles. Before (`8d9f807`) and
after this round, 7 runs each:

| | before | after |
|---|---|---|
| cost per scope (`tiny`, `profile!` / `--auto`) | 50.9 / 50.0 ns | 22.8 / 22.6 ns |
| `tiny` slowdown (`profile!`) | 38.3× | 17.7× |
| `rec` slowdown (`profile!` / `--auto`) | 6.8× / 11.7× | 3.5× / 5.9× |
| `rec` share error, `leanprof sample` (samply) | 14.2 pp (13.8) | 1.2 pp (14.8) |
| `alloc` share error, `--auto` (samply) | 8.2 pp (1.2) | 2.6 pp (0.5) |
| `copy` share error, `--auto` (samply) | 6.5 pp (0.5) | 3.2 pp (0.5) |
| `copy` reported total, `--auto` | 0.86 | 1.05 |
| `tasks` share error, `--auto` (samply) | 2.1 pp (1.4) | 0.5 pp (1.6) |
| `phases` against LeanProfiler (worst workload) | – | 0.6 against 0.7 pp (`rec`) |

What was slow or wrong, and what changed:

1. **The clock.** `clock_gettime(CLOCK_MONOTONIC)` through the vDSO is
   18 ns a read on this CPU, and a scope reads twice: 52% of a `tiny` run
   in perf. leanprof now reads the TSC (7 ns in a loop, ~4.5 ns in place)
   when the kernel's clocksource is `tsc` and the CPU reports an invariant
   TSC, its rate measured against `CLOCK_MONOTONIC`; `CNTVCT_EL0` on arm64
   Linux. Still the larger part of what is left: `RDTSC` is microcode on
   Zen 4, about 9 of the 23 ns. That is why a scope costs about three times
   what it costs on the M5 Max, where reading the counter is one
   instruction; at or below the M5's cost is out of reach on this CPU.
2. **The enter and exit code** was a shared function (six registers
   pushed and popped, a stack-protector check from an inlined
   `clock_gettime` buffer), with every frame zeroing and summing allocation
   counts that only `--allocs` builds use. Inlined, with the slow paths
   out of line and allocation bookkeeping only once the alloc shims have
   run, the bookkeeping went from about 14 to 10 ns (perf: the clock reads
   are now 40–50% of the probe).
3. **Sampled recursion.** perf copies at most 64 KiB of stack per sample,
   so samply's stacks stop a few hundred frames from the leaf: 10,000 calls
   deep, `phDeep10k` got 0.08–0.13 of its time from samply and from
   `leanprof sample`. Frame pointers would not change that (the limit is on
   the bytes copied; Lean's bundled clang already keeps frame pointers);
   `sample` now completes a cut stack from the thread's last whole one, and
   gets 1.00.
4. **`run`/`--auto` on `copy`** were built by the system's clang and
   linker, and that program's copy phase was 18% faster than the plain
   build with no probes at all (55 against 67 ms, an uninstrumented build
   through the same wrapper). The wrapper now uses Lean's own `leanc` on
   Linux, so the instrumented program is built like the plain one. What is
   left is code placement: a probe moves Lean's precompiled runtime to
   other addresses, and the alignment of `lean_copy_expand_array` and
   `lean_del_core_other` alone moves the copy phase by up to 18% on this
   CPU (the plain and `profile!` builds share it; builds that place them
   elsewhere ran 55 ms). In-place pushes also pay the `Array.push` shim's
   check, which nothing subtracts: `phPushExclusive` at 1.10 (`run`) and
   1.20 (`--auto`).
5. **`--auto` on `alloc`** was mostly probe cost: with the probes at half
   the cost the error is a third of what it was.

Still worse than an alternative here: `run --auto` against samply on
`alloc` (2.6 against 0.5 pp) and `copy` (3.2 against 0.5 pp), and the
probe-cost-bound rows (`tiny`, `rec` with `--auto`: 4.2 and 10.4 pp; the
rows are flagged, and `leanprof sample` gets 0.1 and 1.2 pp). With scopes
where LeanProfiler's spans are, leanprof is within 0.5 pp of LeanProfiler
or better everywhere, but the program is 1.1–1.4× slower against
LeanProfiler's 1.0–1.05×: leanprof calibrates its probes for 10–15 ms
at the first scope, inside the first phase, which these 40–120 ms
workloads see.

### Second round: accuracy and overhead (2026-10-23)

What the first round left (pure `profile!` 21 ns and 3–12 ns per scope left
in the report, `--auto` 3.8× and `--frees` 16× on lean-compiler-backend,
time growing with threads) came from five places, found with samply on the
instrumented programs:

1. **Boxing through `profile!`'s closure.** A pure `profile!` applied a
   closure, whose boxed wrapper allocated a `UInt64` result inside the
   timed region (and freed it, which `--frees` then timed: 33× on `tiny`).
   It now compiles to `enterPure` before the term and `exitPure` after it,
   with a variant per scalar type; nothing is allocated. The compiler's
   `floatLetIn` moved a plain token `let` past the term into the branch
   that used it (even a structure projection is one), so the term ran
   before the scope opened; `enterPure` takes the label twice, owned then
   borrowed, which that pass never moves. A test checks the work stays
   inside.
2. **The clock.** `mach_absolute_time` reads `CNTVCTSS_EL0`, which waits
   for every earlier instruction to finish: 4 ns in a loop, but 40% of an
   `--auto` run of lean-compiler-backend in samply, two reads per scope.
   leanprof reads `CNTVCT_EL0` directly; on the M5 it also runs at 1 GHz
   instead of 24 MHz.
3. **`dladdr`** scans all 450,000 symbols of a Lean executable on every
   call (0.3 ms). `--auto` called it for each new function inside the
   running scope (0.2 s of lean-compiler-backend's reported time) and the
   report for every row (0.6 s). A sorted table of the executable's symbols
   is read once instead. This was the "underestimate" of `--auto`'s cost on
   large programs: calibration was right about the probes, but this time
   was not probe time.
4. **`probe_ns` counted the probes 1,024 times** (descendants are counted
   in 1/1024 of a pair), which made the "wall without probes" and `%wall`
   wrong.
5. **`--frees`** wrote a flag shared by all threads on every free and looked
   up the site table each time; the remaining cost is the counting walk.

**Per-thread calibration does not work, and why.** Every 16,384 scopes a
thread timed a batch of 16 empty pairs (after 4 to warm up) and the report
scaled the thread's subtracted cost by the batch's mean over the
calibration's. Under load the factor came out 1.4–4, and subtracting that
much took `tiny` to 0.00 of its time, `rec`/`--auto` to 0.12 and
`alloc`/`--auto` to 0.71. Empty pairs back to back cost more than pairs
spread through real code, whose instructions overlap with the program's
own; so a measured pair cost, per thread or not, is an upper bound on what
the probes add, and the error left for tiny scopes is a nanosecond or two
either way. That is what the near-probe-cost flag is for. The growth with
threads the first round saw (1.6×, 2.5×, 3.1×) is gone without it
(1.2–1.4×, the same on 2, 4 and 8 threads): it went with the boxed
allocations (which contend between threads) and the synchronizing clock.

### First round: runtime fixes (`c/leanprof.c`)

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
   (`overhead_by_path_ns` in the JSON report shows the costs.)

In that round's before/after table counts went from wrong to exact; for tiny pure scopes the share error halved (`tiny`, `profile!` 4.6 →
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
difference divided by `n` is the overhead. leanprof calibrates itself once,
at its first scope (about 10 ms); the benchmark has it do that before the
timed loops (`Leanprof.overheadNs`), since that is a cost per program, not
per action. Before it did, the calibration landed in the first loop: about
10 µs per action at n = 1,000.

```
cd bench
lake build bench
.lake/build/bin/bench leanprof 1 1000000
.lake/build/bin/bench leanprofiler 1 1000000          # recording off
LEAN_PROFILE=1 .lake/build/bin/bench leanprofiler 1 4000   # recording on
```

## Results

Apple M5 Max, macOS, Lean 4.35.0, 2026-10-23, shared with other jobs (load
average 25). Three runs each; ranges shown.

| | 1 thread, n=1M | 4 threads, n=1M each |
|---|---|---|
| leanprof (always recording) | 7.3–8.9 ns | 8.2–11.8 ns |
| LeanProfiler, recording off | 24.7–26.8 ns | 419–495 ns |

LeanProfiler with recording on (`LEAN_PROFILE=1`), one thread
(2026-10-22):

| events | per span |
|---|---|
| 1,000 | 4.6 µs |
| 4,000 | 20.1 µs |
| 16,000 | 88.5 µs |

leanprof over the same event counts: 15.9–17.8, 8.9–17.0 and 10.0–11.6 ns
(the first actions of a thread also pay for its tables).

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
