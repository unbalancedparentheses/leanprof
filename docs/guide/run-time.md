# Run time

Four ways to see where a program spends its time, from least to most effort
(for a one-screen summary with peak memory, start with `leanprof stat EXE`,
see [memory](memory.md)):

| | command | cost | gives |
|---|---|---|---|
| Sampling | `leanprof sample EXE` | near zero, no probes | CPU per Lean declaration, runtime breakdown, flame graph |
| Every function | `leanprof run --auto EXE` | ~14 ns per call | exact calls and time of every function |
| Marked scopes | `profile!` in your code | ~11–15 ns per scope | exact time, p50/p99 of what you mark |
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
`StateT σ IO`); a monadic scope also closes when the action throws. The
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

About 11 ns per profiled `IO` action and 15 ns per pure `profile!` scope on
an Apple M5 Max ([benchmark](../../bench/README.md)). leanprof measures its
own cost the first time something is profiled and again at exit, and
subtracts it from every enclosing scope: a 24 ms loop of 10 million tiny
steps runs in 190 ms with profiling and is reported as 28–31 ms. Programs
that never profile pay nothing. `LEANPROF_NO_CALIBRATION=1` shows raw times.
The header gives the wall time with and without the probes' calibrated
cost, and `%wall` is against the latter, like the times. The calibration
runs with warm caches: in a large program under `--auto`, where every call
also touches scope tables that do not stay in cache, the real cost per call
can be several times higher (lambdaclass/concrete: 0.98 s normally, 2.47 s
with `--auto`, of which the calibration accounts for 0.24 s). Call counts
stay exact; take absolute times from `leanprof sample`.
On Apple Silicon the clock ticks every 41.7 ns, so percentiles of very short
scopes are coarse; totals and means over many calls are fine.
