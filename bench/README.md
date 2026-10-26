# Benchmarks

This package (kept out of the main one, so users of leanprof do not download
LeanProfiler) has two benchmarks: the accuracy and overhead suite, and the
older head-to-head overhead benchmark against LeanProfiler below it.

## Accuracy and overhead suite

```
python3 bench/run.py                    # full: 7 runs, ~8 min on an M5 Max; writes RESULTS.md, results.json
python3 bench/run.py --quick --check    # CI: 30% inputs, 3 runs, ~4 min, exits 1 on a failed check
python3 bench/run.py --lcb pinned       # also the real program: lean-compiler-backend cloned at a pinned commit
python3 bench/run.py --lcb DIR          # ... or a checkout of it (copied first; or LCB_DIR)
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
the runtime before the first round of fixes below in [results-before.json](results-before.json); RESULTS.md (2026-10-26, with the `holds_tiny` marks, `†`) ends with a before/after table against the previous RESULTS.md (run at `38205d5`, 2026-10-25; neither run has a lean-compiler-backend section: the suite's `lcb` invocation fails against the current lean-compiler-backend, before and after alike, so its figures below are from the second round).

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

### Findings (Apple M5 Max, shared with other jobs, 2026-10-23 at `575ba1c`; RESULTS.md now holds the third round's run)

- **Call and copy counts are exact** in every leanprof mode on every
  workload (see the first round of fixes below).
- **Where scopes do real work, leanprof's totals match the plain program**:
  `mix`, `alloc`, `copy` are reported at 0.98–1.02 of plain time under
  `profile!`, with share errors of 0.2–0.4 pp (samply 1.0–2.1 pp on this
  run).
- **Where scopes do a few nanoseconds of work, the report says so.** A
  scope costs 6–7 ns (`tiny`; `--auto` on `rec`, where every recursive
  function is timed, 14 ns a counted call). What the subtraction gets wrong
  is a nanosecond or two per scope: loops of 1 ns functions (`tiny`) come
  out at 0.6–1.4 of their time, `fib` at 1.1–1.7, steps of a few ns on 2–8
  threads at 1.0–1.6. Those rows are flagged "near the probe cost" (`*`),
  and RESULTS.md's "Flag calibration" line checks the threshold: unflagged
  component rows within 14% of the truth (median 2%), flagged ones off by
  12% in the median. `leanprof sample` is within 3 pp everywhere.
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
after this round, 7 runs each (raw results in [linux/](linux/README.md)):

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

### Tiny `profile!` scopes: what is left, and what was tried (Apple M5 Max, 2026-10-26)

The last inaccurate case: `tiny` under `profile!`, 7.6–9.0 points off in
share, with `phTinyA` at 0.80–0.93 of its time and `phTinyB` at 0.52–0.63
(the per-component rows of the pairs below). Sampling the plain build
(`sample`) is 0.5 points off.

**The cause.** Each phase's own wall time under `profile!`, against the
plain build (`tiny 100`, 7 runs each, medians; calibration, ~8 ms inside
the first phase, taken out), gives what a pair of probes really costs in
each loop:

| | calibrated | in `phTinyA` | in `phTinyB` |
|---|---|---|---|
| light pair (`profile!`, pure) | 4.7 ns | 4.66 ns | 4.17 ns |
| timed pair (`LEANPROF_TIME_ALL=1`) | 7.0 ns | 7.05 ns | 6.58 ns |

So calibration is right for `phTinyA`, whose loop (`tinyA i`) is limited by
throughput, and 0.4–0.55 ns a call too high for `phTinyB`, whose loop is a
chain of dependent operations (`acc := acc + tinyB (acc + i)`): there the
probe runs while the chain waits, and hides that much of the phase's own
1.6 ns a call. Over 20M calls that is 9–11 ms of 33, which is the 0.6. The
gap is the same for light and timed pairs, and the same 0.6 shows with
every call timed.

**Negative results**, each measured:

1. **Calibrating light probes in place.** What the runtime can measure in
   place is how the cost changes between kinds of probe: light against
   timed is 2.39 ns in `phTinyA`'s loop and 2.41 ns in `phTinyB`'s, against
   2.3 ns in calibration. The hidden part is the same for both kinds, so no
   difference between probes shows it; it would take a run of the loop
   without probes. Serializing the light probe (`isb` at both ends, so that
   nothing overlaps it, calibrated the same way) made `tiny` 14.8× slower
   and the phases 14.2× and 8.5× their time (10.0 points).
2. **Sampling alongside.** samply at 4 kHz on the `profile!` build,
   dropping every sample whose leaf is leanprof's code, puts `phTinyA` at
   34.4–39.5% of the two phases against 24.5% (leanprof's report: 33.5%).
   The sample is as wrong as the subtraction, for the same reason: where
   the probe and the chain overlap, the sample lands in the probe and the
   phase's work looks smaller. With the probes reduced to returning at once
   (a prototype `LEANPROF_OFF`, not kept), the phases still ran 32 and
   64 ms against 10.5 and 32.9 plain (an empty pair: 2.1 ns a call in
   `phTinyA`'s loop, 1.5 ns in `phTinyB`'s) and the sample gave 31.5–35.5%.
   The two calls change the program; only a build without them gets the
   shares, which is what `sample` on the plain build does.
3. **Subtracting less.** `phTinyA` needs the calibrated cost and
   `phTinyB` about 12% less. A correction proportional to the probes moves
   `phTinyA` (4.6 ns of probes per ns of work) more than `phTinyB` (2.9):
   adding back 6% of the probes, for example, gives 36% for a 24.5% share.

**What changed: the report says which rows these are.** A light scope keeps
the scope it was first sampled under, and when the light calls' probes
cost at least 0.3 of that caller's time the caller's row gets `holds_tiny`
(the JSON), a line under the terminal table, and a note in the editor and
HTML report: its time is off whatever is subtracted, and so is a sample of
this build; remove those `profile!` (or `set_option leanprof.enabled
false`) and use `leanprof sample`. Before, these rows had only the generic
`*` ("use `leanprof sample`"), which for a `profile!` build sends the
reader to a sample that is off too. In the suite `phTinyA`, `phTinyB` and
the three `taskWork` rows (which call `taskStep`) are marked (`†` in
RESULTS.md), off by 10–19% in the median and 37–48% at most.

Interleaved pairs (before: `origin/main` at `474033e`; after: this change;
the same `bench/run.py`), every workload × `plain`, `profile`, `auto`, 7
runs a cell, three pairs under the shared lock, load average 3.5–4.8 on 18
CPUs; each value is one suite's median, the three pairs in order:

| | before | after |
|---|---|---|
| `tiny` `profile!` share error | 9.0 / 8.3 / 7.6 pp | 9.0 / 8.5 / 7.6 pp |
| `tiny` `profile!` `phTinyA` / `phTinyB` | 0.93/0.62, 0.91/0.59, 0.91/0.63 | 0.80/0.52, 0.86/0.59, 0.90/0.63 |
| `tiny` `--auto` share error | 0.7 / 0.6 / 0.7 pp | 0.7 / 0.6 / 0.5 pp |
| `rec` `profile!` / `--auto` share error | 2.7–3.2 / 1.3–1.5 pp | 1.2–1.7 / 1.2–1.4 pp |
| `mix` `profile!` / `--auto` | 0.4–0.5 / 0.4 pp | 0.5 / 0.4 pp |
| `alloc` `profile!` / `--auto` | 0.3–0.5 / 4.3–4.4 pp | 0.2–0.5 / 4.3–4.8 pp |
| `copy` `profile!` / `--auto` | 0.2–0.4 / 1.7–2.2 pp | 0.2–0.4 / 1.5–2.2 pp |
| `tasks` `profile!` / `--auto` | 1.0–1.9 / 1.6–2.6 pp | 1.3–1.8 / 1.6–2.1 pp |
| `tiny` slowdown, `profile!` | 4.22–4.31× | 4.28–4.33× |
| `rec` slowdown, `profile!` / `--auto` | 2.07–2.17× / 2.77–2.88× | 2.07–2.12× / 2.88–2.91× |

Counts are exact in every cell. The change only adds a pointer store on a
light scope's sampled calls (one in 64) and work at report time, and the
times are the same within the noise; `rec` under `profile!` came out better
in all three after-runs (no light scope there, nothing in the change that
touches it: likely code placement, not claimed).

Also seen, not acted on: on macOS a thread-local variable is reached
through `_tlv_get_addr`, a call; `leanprof sample` of the `profile!` build
puts 6.4% of its time there, about 0.45 ns of each probe pair.

### Review fixes: tiny classifier and light scopes (Apple M5 Max, 2026-10-25)

After the 2026-10-25 code review, `--auto` times again the functions that
use `lean_ctor_release` or `Nat` arithmetic (`scripts/leanprof-tiny.awk`),
and a light scope keeps its fully timed calls apart from its sample, carries
its estimate in 1/1024 ticks and reads self time signed (`c/leanprof.c`).
`alloc`, `rec` and `tiny` under `profile!` and `--auto`, `main` (`0c16f45`)
against the branch (`a9c3dc0`), three interleaved pairs under the shared
lock, load average 2–6 on 18 CPUs (7 runs a cell; each value is one suite's
median, the three pairs in order):

| | `main` | branch |
|---|---|---|
| `alloc` `profile!` share error | 0.2 / 0.6 / 0.3 pp | 0.5 / 0.2 / 0.4 pp |
| `alloc` `--auto` share error | 3.9 / 3.4 / 4.0 pp | 3.2 / 3.9 / 3.7 pp |
| `alloc` `--auto` reported/plain | 1.06 / 1.04 / 1.04 | 1.08 / 1.07 / 1.05 |
| `rec` `profile!` share error | 2.8 / 1.9 / 2.8 pp | 3.4 / 2.7 / 2.9 pp |
| `rec` `profile!` cost per scope | 7.4 / 7.2 / 7.3 ns | 7.9 / 7.9 / 8.0 ns |
| `rec` `--auto` share error | 1.7 / 1.7 / 1.9 pp | 1.4 / 1.3 / 0.9 pp |
| `rec` `--auto` reported/plain | 1.24 / 1.20 / 1.23 | 1.27 / 1.26 / 1.25 |
| `tiny` `profile!` share error | 11.0 / 10.3 / 10.6 pp | 9.2 / 8.6 / 9.5 pp |
| `tiny` `profile!` reported/plain | 0.61 / 0.78 / 0.59 | 0.82 / 0.64 / 0.64 |
| `tiny` `--auto` share error | 1.1 / 1.1 / 0.9 pp | 0.6 / 1.1 / 0.3 pp |

Counts are exact in every cell. The costs: a timed scope pays about half a
nanosecond more (`rec` under `profile!`, where no scope is light: the frame
records whether it is a sample, and children's time is kept in 1/1024
ticks), and `--auto` reports a little more of its own cost on `rec` and
`alloc`, where functions that were left untimed are timed again. `tiny`
`profile!` stays the inaccurate case (its phases are 0.5–0.7 of their time:
the light pairs' cost subtracted from them is overestimated, which the
estimator change does not touch). An earlier pair at load 7–10 agreed.

### Third round: tiny functions (Apple M5 Max, 2026-10-25)

These numbers were measured before the outliner fix in the next section,
which removed most of the probe cost the paragraph "Negative results" below
could not account for; the combined code is measured in
[RESULTS.md](RESULTS.md). Against `main` with the outliner fix and without
these changes (`67c07ec`), two interleaved pairs on the same machine (load
about 5, share error in points, `main` / combined):

| | pair 1 | pair 2 |
|---|---|---|
| `tiny` `--auto` | 5.2 / 0.6 (5.75× / 1.00× slower) | 4.3 / 0.8 |
| `tiny` `profile!` | 9.0 / 11.2 (5.41× / 4.30× slower) | 8.3 / 10.3 |
| `rec` `--auto` | 2.2 / 3.1 | 1.7 / 1.7 |
| `alloc` `--auto` | 2.9 / 5.7 | 4.5 / 3.7 |

So: `--auto` times the tiny workload as well as sampling and without
slowing it down; light scopes make tiny `profile!` scopes cheaper but about
two points less accurate; `rec` and `alloc` under `--auto` show no
consistent difference (the two pairs disagree).

The dedicated Linux host was unreachable, so these are Mac numbers: the
machine was shared (load average 3–10), every suite run held a lock that
kept other agents' benchmarks off it, and before (`b94b0f4`) and after ran
interleaved, twice each (7 runs per cell; the two values are the two
suites' medians; the second after-run is `bench/RESULTS.md` at `1169b32`, and
[results-tiny-before.json](results-tiny-before.json) the second before-run):

| | before | after |
|---|---|---|
| `tiny` share error, `--auto` | 9.5 / 10.2 pp | 0.6 / 1.2 pp |
| `tiny` slowdown, `--auto` | 7.8× / 8.2× | 0.98× / 0.98× |
| `tiny` share error, `profile!` | 9.4 / 10.6 pp | 9.6 / 8.9 pp |
| `tiny` slowdown, `profile!` | 7.7× / 7.9× | 6.2× / 6.2× |
| `rec` share error, `profile!` / `--auto` | 7.9 / 5.2, 8.3 / 5.4 pp | 7.9 / 6.2, 8.4 / 6.4 pp |
| `rec` slowdown, `--auto` | 4.1× / 4.3× | 3.7× / 3.6× |
| `rec` reported total, `--auto` | 2.21 / 2.33 | 2.09 / 2.04 |
| `tasks` slowdown, `profile!` / `--auto` | 2.8× / 4.5×, 2.8× / 4.5× | 2.4× / 3.3×, 2.5× / 3.5× |
| `mix`, `alloc`, `copy` | | the same within the noise |

What changed:

1. **`--auto` leaves tiny functions untimed.** A function that takes a
   nanosecond costs several times that in probes, and what the subtraction
   gets wrong lands in it and in every function around it. The compiler
   wrapper now marks, in the C that Lean emits, straight-line functions that
   call only O(1) `lean.h` operations and other such functions of the file
   and free nothing but boxed scalars (`scripts/leanprof-tiny.awk`)
   `no_instrument_function`. `K.tinyA` and `K.tinyB` (and their boxed
   wrappers) have no probes, so `phTinyA`/`phTinyB` are timed as they run
   (0.93–1.00 of their time). The report lists such functions, and their
   calls are not counted (the suite's count check skips them and says so);
   `--time-tiny` puts them back. The rules are conservative: nothing with a
   loop, a closure call, a call to another file or a `lean_dec` of an
   object qualifies, so `K.spin`, `deepRec`, `fib`, `mkTree` keep their
   probes, and `rec` and `alloc` under `--auto` do not change.
2. **Light scopes.** A scope near the probe cost that is not recursive is,
   after its first 1,024 calls, timed on about one call in 64 at random and
   only counted on the others (no clock reads, no histogram); its times are
   the timed calls' scaled up and its counts stay exact. The untimed pair is
   calibrated like the others (4.6 against 6.6 ns for a pure `profile!`)
   and subtracted from the callers. Tiny loops run about 1.25× faster under
   `profile!` and `tasks` 1.2–1.35× faster.
3. **Frames are one cache line** (64 bytes, from 104 over two lines), for
   the deep-recursion case below.

**Negative results.** Light scopes do not make tiny scopes' share more
accurate: on the same binary, interleaved, `tiny` under `profile!` was 7.9
against 9.0 points off with and without them (ranges overlapping), `rec`
under `--auto` 9.8 against 8.9. What is left is not the probes' measured
cost but what a probe costs in the program beyond it (the caller saving
registers around the call, the core it runs on): on this Mac `profile!`
reports `tiny` at 2.0–3.4 and `fib` at 4.7–5.7 times their time whatever is
subtracted, about 3 ns per scope left over. In `rec` under `--auto` the deep
phases now come out closer to their time (1.67–1.88 against 1.85–2.18) but
`phFib` (recursive, so never light) does not, and the share error, which is
relative, went up by a point.

**`rec` under `--auto` on Linux (10.4 points, from 7.1).** The per-component
rows in [linux/](linux/README.md) show what moved: `phDeep10k` was 1.63
before and 1.73 after, but `phDeep100` and `phDeep1k` went from 0.95 and
1.11 to 0.74 and 0.82 (cheaper probes, still subtracted as measured in a
loop, so slightly too much), and `phFib` from 0.00 to 0.48. The shares
recomputed from those ratios give 7.3 and 10.3 points: the error grew
because the shallow phases moved down while the deepest stayed up. The
deepest is over-reported only under `--auto` (0.98 with `profile!`): at
10,000 levels with three probed functions each the frames were 3 MiB, three
times the 7950X3D's 1 MiB L2, against about 1 MiB with `profile!`'s one
scope per level. The 64-byte frames bring that to 1.9 MiB; whether that is
enough was not measured (the host was unreachable), and on the M5 Max,
whose L2 holds all of it, depth changes nothing either way.

### Mac: probes outlined by the compiler (2026-10-25)

From `a009129` (enter and exit inlined into every probe, for the Linux
round above) the Mac's accuracy fell: `run --auto` on `alloc` 22 pp share
error (`phAllocTree` at 2.4× its time), `profile!` on `rec` 7–9 pp (`fib`
at 4.2–4.7×), while calibration reported cheaper probes than before (4.7
against 8.2 ns direct). Apple clang runs its machine outliner on arm64 even
at -O2: the inlined copies of enter and exit in the program's probes became
chains of calls to shared outlined pieces (25 in `__cyg_profile_func_exit`,
26 in `leanprof_exit`), while calibration's copies, specialized for its
internal scopes, stayed straight-line. A real probe cost ~5 ns more than
calibration measured, and that stayed in the report. The runtime is now
compiled with `-mno-outline` on macOS (the lakefile, and the runtime
`leanprof run` compiles for projects that do not depend on leanprof); the
tests and the smoke check fail if the runtime has outlined code. The flag
is passed on macOS only, so Linux builds are unchanged.

Same machine, 7 runs each, `main` (`79ee65d`) then the fix, alternated
under the benchmark lock (load 2.3–3.9 on 18 cores; RESULTS.md has the
full before/after table):

| | before | after |
|---|---|---|
| `alloc` share error, `--auto` | 22.0 / 22.1 pp | 3.3 / 3.2 pp |
| `rec` share error, `profile!` / `--auto` | 7.0–8.6 / 5.1–5.2 pp | 2.3–2.5 / 1.7 pp |
| `tiny` share error, `--auto` | 9.9–11.2 pp | 4.2–5.3 pp |
| `rec` reported/plain, `profile!` / `--auto` | 1.41–1.53 / 2.13–2.21 | 1.04–1.06 / 1.18–1.27 |
| cost per scope (`tiny`, `profile!`) | 9.3 ns | 6.3 ns |
| `rec` slowdown, `--auto` | 4.03–4.15× | 3.19–3.26× |

`tasks` gets worse in share error (`profile!` 0.4–0.9 → 1.8–2.6 pp) while
its times get better: before, every task function was over-reported by the
same ~1.6×, so the shares happened to be right; after, they are at
1.03–1.07 on 2 and 4 threads and 1.23–1.27 on 8, where the probes cost more
than calibration measures on one thread. Still left: calibration's copies
are specialized for its internal kind of scope (no forwarding check, no
tracing check), 13–17 instructions fewer at enter than the program's;
that is likely part of the 1.2–1.7 ns per call `--auto` still leaves on
`rec` (not measured separately).

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
quadratic. `leanprof run` shows why, without any annotations in LeanProfiler:
it rebuilds the benchmark and its dependencies (LeanProfiler included) with
the copy probes, runs it, and puts the normal build back:

```
cd bench
LEAN_PROFILE=1 lake exe leanprof run bench -- leanprofiler 1 4000
```

```
function                                                     copies       bytes    time  why                        where (declaration)
LeanProfiler.Internal.reserveSpan (in Std.DHashMap...insert)  12003   123.0 MiB  14.1 ms  multi-threaded+persistent  .lake/packages/LeanProfiler/LeanProfiler/Runtime/Capture.lean:65
LeanProfiler.Internal.completeSpan                             8002    61.1 MiB  12.0 ms  multi-threaded+persistent  .lake/packages/LeanProfiler/LeanProfiler/Runtime/Capture.lean:94
```

(4,000 spans.) The profiler state lives in a mutex, so its arrays and maps
are marked multi-threaded, and `let state ← get; set { state with events :=
state.events.push e }` keeps a second reference besides. Lean never updates
such values in place, so every span copies every event recorded so far.
