# Run time

Four ways to see where a program spends its time, from least to most effort
(for a one-screen summary with peak memory, start with `leanprof stat EXE`,
see [memory](memory.md)):

| | command | cost | gives |
|---|---|---|---|
| Sampling | `leanprof sample EXE` | near zero, no probes | CPU per Lean declaration, runtime breakdown, flame graph |
| Every function | `leanprof run --auto EXE` | ~8 ns per call (M5 Max), ~23 ns (Ryzen 7950X3D) | exact calls and time of every function |
| Marked scopes | `profile!` in your code | ~8 ns per scope (M5 Max), ~23 ns (Ryzen 7950X3D) | exact time, p50/p99 of what you mark |
| Timeline | `--trace FILE` / `LEANPROF_TRACE` | one event per scope | Perfetto timeline per thread, with copies as markers |

Start with sampling to find where to look, then use exact counts.

## Sampling

```
leanprof sample [--rate HZ] [--top N] EXE [-- ARGS]
```

builds `EXE` normally and runs it under [samply](https://github.com/mstange/samply),
then reports CPU time per Lean declaration with file:line, merging lambdas
and specializations into the function that owns them, plus where the Lean
runtime's own time went:

```
  where the Lean runtime's time went (self time)
  63.92 ms     43.70%   copying non-exclusive values
  51.96 ms     35.53%   freeing objects (reference counts reaching zero)
  10.76 ms     7.36%    allocation

  top 3 Lean declarations by inclusive CPU time
  134.09 ms    91.67%   main  (Examples/CopyBug.lean:31)
  75.92 ms     51.90%   buildWithHistory  (Examples/CopyBug.lean:17)
```

`samply load .lake/leanprof/EXE.json` opens the flame graph in Firefox
Profiler, with Lean names instead of mangled C names.

On Linux, perf gives samply at most 64 KiB of a thread's stack per sample,
so a sample deep in recursion (a few hundred Lean frames) arrives without
its outer frames, and samply's own profile charges none of that time to the
function that started the recursion. `sample` completes such a stack with
the outer frames of the thread's last whole stack, from the outermost call
of the cut stack's outermost function; the report's inclusive times are
then right (on the `rec` benchmark, 10,000 calls deep: 1.2 percentage
points of error against samply's 14.8). The flame graph `samply load`
shows is samply's own, with the cut stacks.

The runtime breakdown also separates Lean's C++ code for expressions and the
kernel (`instantiate`, `replace`, type checking: most of the time of programs
that run `MetaM`) and thread-local variable lookups (`tlv_get_addr` on macOS,
which the allocator and the heartbeat counter go through). Code the linker
outlined (`OUTLINED_FUNCTION_N`) counts in its caller, and C++ names are
shown without template arguments.

A specialization is named after the first function that needed it
(`Foo.helper (in List.elem)`), but the compiler reuses it for every caller
with the same arguments, and inlined callers disappear from the stack. When
most of its time comes from another declaration, `sample` says so under it:

```
  30.79 ms     5.88%    Concrete.Symbols.isRuntimeHelperName (in List.elem)  (Concrete/Backend/Symbols.lean:51)
                        90.73% of it called from Concrete.ensurePtrOp  (Concrete/Backend/EmitSSA.lean:632)
```

Hot code outside your project (Lean's library, the runtime, the C library)
is listed with the functions of your project it ran under: for each sample,
the nearest frame below it that is declared in your package. Up to three are
shown, each with at least 5% of its time:

```
  9.96 ms      3.90%    List.reverseAux  (…/src/lean/Init/Data/List/Basic.lean:555)
                        97.75% of it under LeanCompilerBackend.Assembly.emitData (in Array.forIn'Unsafe.loop)  (LeanCompilerBackend/Assembly.lean:57)
```

That line found a `lines := lines ++ [line]` loop in lean-compiler-backend.

A program that reads its current directory can run elsewhere with
`--cwd DIR` (also for `run` and `stat`); positions still come from the
project.

## Every function

`leanprof run --auto EXE` times every function compiled from your package
(`--auto-all` includes dependencies), using clang's
`-finstrument-functions-after-inlining`: calls are counted exactly, and
functions inlined away cost nothing. `profile!` labels appear in quotes next
to function names. Every call pays the bookkeeping cost (subtracted in the
report, but the program runs slower), so switch to `profile!` for hot loops
once you know where to look. One declaration is often several compiled
functions (`f`, `f._redArg`, `f._boxed`, its lambdas): they are timed as one,
and a lambda or `_redArg` called by its own declaration is not a new call.

## Marked scopes

`profile! "name" e` times `e`. It works on pure terms and on monadic actions
(any monad with `MonadFinally` and a `BaseIO` lift, such as `IO` or
`StateT σ IO`); a monadic scope also closes when the action throws. On a
pure term it compiles to a call before the term and one after it, with no
closure, and a value of a scalar type (`UInt64`, `Float`, `Bool`, ...)
passes through unboxed. The
report shows each scope's file:line. With `set_option leanprof.enabled false`
(for example in `leanOptions`), `profile!` elaborates to the bare term.

Two things to know about Lean's compiler:

- **Closed terms run once, at startup.** `profile! "x" (fib 20)` measures
  nothing if `fib 20` was computed as a constant before `main`.
- **Pure work in `do` blocks can run early.** In `IO.asTask (pure (work x))`
  or `let y := work x; pure y`, `work x` may be computed before the action
  runs. Use `IO.lazyPure fun _ => work x`.

## Tasks

Every `Task.spawn`, `IO.asTask`, `Task.map`, `Task.bind`, `IO.mapTask` and
`IO.bindTask` is linked to the scope that created it:

```
tasks (run on worker threads; wait is spawn to start)
spawned by                                  tasks  run total   run mean  wait mean   wait max
pureTasks                                      16     6.2 ms  384.7 µs  163.7 µs  348.0 µs

blocking waits (IO.wait, Task.get)
function                                    waits    blocked       mean  in scope             where (declaration)
pureTasks (in List.foldl)                      16  653.3 µs   40.8 µs  pureTasks            Examples/Tasks.lean:12
```

A task that finishes in microseconds while its spawning scope takes
milliseconds usually ran its work before the spawn (see above).

A continuation (`Task.map`, `Task.bind`, `IO.mapTask`, `IO.bindTask`) counts
as a task of the scope that called `map` or `bind`. Its run time is the
function given to `map` or `bind`. For `bind`, that does not include the task
the function returns, which is counted where it is spawned. Its wait runs
from the call to the start, so it includes waiting for the input task, not
only for a free worker. In [`Examples/TaskChains.lean`](../../Examples/TaskChains.lean),
`bound` has 24 tasks: 8 sources, 8 `bind` continuations and the 8 tasks
they spawn. Tasks that Lean's own libraries create are seen only with
`leanprof run --core` (see [copies and allocations](copies-and-allocations.md)).

## Timeline

`leanprof run --trace out.json EXE` (or `LEANPROF_TRACE=out.json` for a
program that links leanprof) writes a timeline in Chrome trace format: open
it in [ui.perfetto.dev](https://ui.perfetto.dev). Each thread is a track,
tasks appear on their worker threads as `task <- scope`, and copies are
markers inside the scope that made them. A `memory (MiB)` counter track shows
committed and resident memory, and with `--frees` freeing cascades of 100 µs
or more are slices ([memory](memory.md)). At most 1,048,576 events are kept
per thread (`LEANPROF_TRACE_MAX`).

## Overhead and accuracy

Measured in [`bench/`](../../bench/RESULTS.md) on an Apple M5 Max (shared
with other jobs), and on an idle AMD Ryzen 9 7950X3D under Linux (fixed
clock, boost off; see [bench/README.md](../../bench/README.md)):

- **Cost per scope:** about 8 ns for `profile!` (pure or monadic) and per
  call with `--auto` on the M5 Max (`Leanprof.scope`, which builds a
  closure, 11 ns); about 23 ns on the 7950X3D, of which reading the
  clock twice (`RDTSC`, which Zen 4 runs as microcode) is about 9 ns.
  leanprof measures each kind of entry when profiling starts and again at
  exit, and subtracts it from every enclosing scope; programs that never
  profile pay nothing. On lean-compiler-backend, `--auto` makes the whole
  process 1.52 times slower, `--frees` 1.40 times (both 3.7 and 2.3 times
  before the changes in [the changelog](../../CHANGELOG.md)).
- **Counts are exact** in every mode, including deep recursion.
- **Times match the uninstrumented program** when each scope does real work
  (0.95–1.03× on the allocation, copy and mixed workloads). When a scope
  does only a few nanoseconds of work, what the subtraction gets wrong (a
  nanosecond or two per scope, depending on what surrounds the probes and
  on how busy the machine is) is a large part of its time: loops of 1 ns
  functions are reported at 0.5–1.4 times their time, and steps of a few
  ns on 2 to 8 threads at 1.2–1.5 times.
- **`--auto` leaves tiny functions untimed.** Straight-line functions of
  a few operations (no loop, no call but O(1) runtime operations and other
  such functions, nothing freed but boxed scalars) get no probes; the report
  lists them under "too small to time left untimed" (`untimed` in the
  JSON), and their time is in their callers'. On the `tiny` benchmark that
  takes `--auto` from 9.5–10.2 to 0.6–1.2 points off and from 8× to 0.98×
  slower. `--time-tiny` times (and counts) them.
- **Tiny scopes are timed on a sample.** A scope near the probe cost that
  is not recursive is, after its first 1,024 calls, timed on about one call
  in 64 (at random) and only counted on the others, which costs less (4.6
  against 6.6 ns on the M5 Max). Its counts stay exact; its times are
  those of its first, fully timed calls plus the sample's scaled up to the
  calls it stands for (an estimate); `LEANPROF_TIME_ALL=1` times every call. This
  makes such loops about 1.25× faster; it does not make their share more
  accurate (see below).
- **Such rows are marked.** A row whose probes (its own and those of the
  scopes inside it) cost at least 0.3 of the time left after subtracting
  them gets a `*` after its total, `"near_probe_cost": true` in the JSON,
  and the note "near the probe cost: use `leanprof sample` for this
  function's time" in the HTML report and the editor. That is a function
  of about three probe pairs per call (~25 ns) or less; in the benchmark,
  unflagged rows were within 14% of the truth (median 3%), flagged ones
  off by 22% in the median.
- **Callers of tiny scopes are marked too.** A row that calls a light
  scope, when that scope's probes cost at least 0.3 of the row's time,
  gets `holds_tiny` (the light scopes' names) in the JSON, a line under
  the terminal table, and a note in the editor and the HTML report. Two
  calls around a nanosecond of work change the code they sit in, by an
  amount that depends on that code: in the `tiny` benchmark a pair of
  calls that did nothing at all cost 2.1 ns a call in one loop and 1.5 ns
  in the other, so no subtraction is right for both (one phase comes out
  at 0.80–0.93 of its time, the other at 0.52–0.63), and a sample of the same
  build is just as far off (34–40% for a phase whose true share is 24.5%).
  For such a row's time, remove those `profile!` (or `set_option
  leanprof.enabled false` in their file) and use `leanprof sample`; keep
  them for the exact counts.
- **`leanprof sample`** slows programs down 1.0–1.3× and is within 0.1–1.9
  percentage points of each function's true share of time, like samply.

So: take counts, copies, allocations and causes from the exact modes, and
the time of starred rows from `sample` (of a build without the tiny
scopes, for rows marked as holding them). What is left for those rows is
what a probe costs inside the program beyond what calibration measures
(register spills around the call, work of the caller that the probe hides
or that hides it, the core it runs on): on the shared M5 Max in October
2026 the `tiny` workload under `profile!` was 7.7–10 points off in share
whatever leanprof subtracted ([bench/README.md](../../bench/README.md)
has what was tried). `LEANPROF_NO_CALIBRATION=1` shows
raw times. On Apple Silicon leanprof reads the CPU's counter directly: it
runs at 1 GHz on an M5 and at 24 MHz (41.7 ns per tick) on earlier chips,
where percentiles of very short scopes are coarse. On Linux it reads the
TSC (x86-64) or `CNTVCT_EL0` (arm64) when the kernel itself keeps time with
it, and otherwise, or with `LEANPROF_CLOCK=monotonic`, `clock_gettime`
(about twice the cost per scope).
