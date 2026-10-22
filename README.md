# leanprof

An instrumentation profiler for compiled Lean 4 programs. It reports time per
scope and, unlike general-purpose profilers, the **hidden copies** that make
Lean code slow: every time an `Array`, `ByteArray` or `String` is updated while
another reference to it is alive, Lean copies the whole value.

```
leanprof: 4 scopes, wall 42.6 ms

scope                         calls      total       self  %wall       mean        p50        p99  where
buildWithHistory                  1     2.8 ms     2.8 ms   6.6%     2.8 ms     2.7 ms     2.7 ms  Examples/CopyBug.lean:15
report                            1  241.5 µs   35.2 µs   0.6%  241.5 µs  234.7 µs  234.7 µs  Examples/CopyBug.lean:33
fib                           10945  206.2 µs  206.2 µs   0.5%     230 ns      42 ns    2.7 µs  Examples/CopyBug.lean:13
build                             1   15.5 µs   15.5 µs   0.0%   15.5 µs   15.3 µs   15.3 µs  Examples/CopyBug.lean:23

copies of non-exclusive values (each one copied the whole value)
function                                 kind           copies       bytes       time  %scope  why             in scope             where (declaration)
buildWithHistory (in Std.Legacy.Range.forIn'.loop) Array            2001    15.3 MiB     2.3 ms   98.5%  shared+persistent buildWithHistory     Examples/CopyBug.lean:15
```

That is [`Examples/CopyBug.lean`](Examples/CopyBug.lean): `buildWithHistory`
keeps each intermediate array alive, so every `push` copies (quadratic work in
a loop that looks linear). The report says those copies are 99% of the
function's time. `build`, the same loop without the extra reference, copies
nothing.

## How it compares

| | leanprof | [LeanProfiler](https://github.com/lean-dojo/LeanProfiler) | samply / perf | [LeanBench](https://github.com/alok/LeanBench) |
|---|---|---|---|---|
| Time per annotated scope, p50/p99, self time | ✅ | ✅ (p95) | – | per benchmark |
| Source positions | ✅ scopes (line), copies (declaration) | – | C lines with debug info | – |
| **Copies of shared values, per function** | ✅ count, bytes, time, share of scope | – | – | – |
| **Copy assertions in tests** (`expectNoCopies`) | ✅ | – | – | – |
| Overhead per event, recording | **~11 ns**, flat; 4 threads ~12 ns; measured and subtracted from reported times | 4.6 µs at 1k events, 88 µs at 16k (grows with events) | sampling, very low | – |
| Overhead, recording off | compiles away | ~23 ns; 4 threads ~370 ns | – | – |
| No annotations needed | ✅ `LEANPROF_AUTO=1`, exact call counts | – | ✅ sampled | – |
| Timeline | ✅ Perfetto, with copies as markers | ✅ Perfetto | ✅ Firefox Profiler | – |
| Regression comparison | ✅ exact for copies and calls; thresholded for time | ✅ thresholded | – | ✅ thresholded |
| Task-aware | ✅ run time and queue wait per spawning scope; blocking waits per call site | ✅ parent links | – | – |
| Lean-readable names | ✅ | ✅ (you name spans) | mangled | ✅ |

Elaboration (compile-time) profiling is out of scope: use `trace.profiler` or
[lean-source-profiler](https://github.com/Vilin97/lean-source-profiler).
Overhead numbers are from [`bench/`](bench/README.md) (Apple M5 Max). The
same page shows leanprof finding the cause of LeanProfiler's growing cost:
its event array is copied on every span.

Status: early. Tested with Lean 4.35.0 on macOS arm64; CI also runs Linux.
See [ROADMAP.md](ROADMAP.md).

## Use

Add the dependency to your `lakefile.lean`:

```lean
require leanprof from git "https://github.com/unbalancedparentheses/leanprof" @ "main"
```

Mark the code to time with `profile!`. It works on pure terms and on monadic
actions (any monad with `MonadFinally` and a `BaseIO` lift, such as `IO` or
`StateT σ IO`); a monadic scope also closes when the action throws.

```lean
import Leanprof

def solve (xs : Array Nat) : Nat := profile! "solve" (xs.foldl (· + ·) 0)

def main : IO Unit := profile! "main" do
  IO.println (solve #[1, 2, 3])
```

The report goes to stderr when the program exits.

| Variable | Effect |
|---|---|
| `LEANPROF_JSON=path` | also write the report as JSON |
| `LEANPROF_QUIET=1` | no table on stderr |
| `LEANPROF_ALL=1` | include copies of compile-time constants (hidden by default) |
| `LEANPROF_TRACE=path` | also write a timeline (Chrome trace format: open in [ui.perfetto.dev](https://ui.perfetto.dev)), with copies as markers |
| `LEANPROF_TRACE_MAX=n` | keep at most `n` timeline events per thread (default 1,048,576) |
| `LEANPROF_NO_CALIBRATION=1` | report raw times, without subtracting leanprof's own cost |
| `LEANPROF_ILEAN_DIR=dir` | where to find `.ilean` files for copy positions (default `.lake/build/lib/lean`) |

To turn the annotations off without removing them, set
`leanprof.enabled` to `false` (for example in `leanOptions`): `profile!` then
elaborates to the bare term.

### Counting copies

Copy and task tracking need your executable's C code compiled with these
flags, which route the runtime's copy, task-spawn and blocking-wait paths
through leanprof (or use `lake exe leanprof run`, which needs no lakefile
changes):

```lean
lean_exe myapp where
  root := `Main
  moreLeancArgs := #[
    "-Dlean_copy_expand_array_nonlinear=leanprof_copy_expand_array_nonlinear",
    "-Dlean_copy_sarray_nonlinear=leanprof_copy_sarray_nonlinear",
    "-Dlean_copy_string_nonlinear=leanprof_copy_string_nonlinear",
    "-Dlean_array_push=leanprof_array_push",
    "-Dlean_byte_array_push=leanprof_byte_array_push",
    "-Dlean_float_array_push=leanprof_float_array_push",
    "-Dlean_string_push=leanprof_string_push",
    "-Dlean_string_append=leanprof_string_append",
    "-Dlean_string_utf8_set=leanprof_string_utf8_set",
    "-Dlean_task_spawn_core=leanprof_task_spawn_core",
    "-Dlean_io_as_task=leanprof_io_as_task",
    "-Dlean_io_wait=leanprof_io_wait",
    "-Dlean_task_get=leanprof_task_get"]
  moreLinkArgs := #["-rdynamic"]  -- so the report can name functions
```

Each copy is attributed to the compiled function that made it and to the
innermost `profile!` scope, with the time the copying call took, its share of
that scope, the declaration's file:line (read from the `.ilean` files Lake
writes under `.lake/build/lib/lean`; set `LEANPROF_ILEAN_DIR` to point
elsewhere), and the reason the value was not exclusive:
`shared` (another reference is alive), `multi-threaded` (the value was shared
with another task, so Lean never mutates it in place) or `persistent` (a
compile-time constant).

### One command

```
lake exe leanprof run [--auto | --auto-all] [--trace FILE] [--json FILE] EXE [-- ARGS]
```

builds `EXE` with copy detection in every package (and, with `--auto`,
every function timed), runs it, and removes the instrumented objects again
so a later plain `lake build` does not reuse them.

```
lake exe leanprof compare [--threshold PCT] [--min-ms MS] BASE.json NEW.json
```

compares two `--json` reports and exits 1 on a regression: any increase in
copies or change in call counts (both exact, so no noise), or a scope slower
by more than `PCT` percent (default 10) and `MS` milliseconds (default 1).

### Every function, no annotations

Set `LEANPROF_AUTO=1` when building through the compiler wrapper (below) and
every function compiled from your package is timed, with its declaration's
file:line; `LEANPROF_AUTO=all` includes dependencies. It uses clang's
`-finstrument-functions-after-inlining`, so calls are counted exactly
(unlike sampling) and functions inlined away cost nothing. Specializations
are reported under the function that caused them
(`build (in Std.Legacy.Range.forIn'.loop)`), and `profile!` labels are shown
in quotes next to them.

```
find .lake -name '*.c.o*' -delete
LEANPROF_AUTO=1 LEAN_CC=$PWD/.lake/packages/leanprof/scripts/leanprof-cc lake build
```

Every function call then pays the ~14 ns bookkeeping cost (subtracted in the
report, but the program runs slower), so prefer `profile!` for hot loops once
you know where to look.

### Without editing the lakefile

[`scripts/leanprof-cc`](scripts/leanprof-cc) is a C compiler wrapper that adds
the copy flags to every package, dependencies included:

```
find .lake -name '*.c.o*' -delete    # Lake does not notice a new LEAN_CC
LEAN_CC=$PWD/.lake/packages/leanprof/scripts/leanprof-cc lake build
```

It forwards to the system `clang` (or `cc`; override with
`LEANPROF_REAL_CC`), since `leanc` stops passing its bundled clang's sysroot
once `LEAN_CC` is set.

### Tasks

With the same flags (or the wrapper), every `Task.spawn` and `IO.asTask` is
linked to the scope that spawned it: the report lists, per spawning scope,
how many tasks ran, their run time, and how long they waited between spawn
and start. `IO.wait` and `Task.get` are timed per call site as blocking
waits. In the timeline, each task appears on its worker thread as
`task <- <scope>`. `Task.map`, `Task.bind`, `IO.mapTask` and `IO.bindTask`
are not tracked yet.

A task that finishes in microseconds while its spawning scope takes
milliseconds usually means the work ran before the spawn:
`IO.asTask (pure (work x))` computes `work x` in the parent; use
`IO.lazyPure fun _ => work x` (see [`Examples/Tasks.lean`](Examples/Tasks.lean)).

### In tests

```lean
-- fails if `x` copies a shared or multi-threaded value
Leanprof.expectNoCopies x
```

`Leanprof.copies`, `Leanprof.calls "name"`, `Leanprof.totalNs "name"`,
`Leanprof.overheadNs`, `Leanprof.depth` and `Leanprof.whereIs "decl"` expose
the counters and positions while the program runs.

## Caveats

- **Only your executable's code is observed.** Copies made inside the
  precompiled core library are not counted unless the code is specialized
  into your module, which loops over ranges and arrays usually are.
- **The compiler may move pure work.** Closed terms such as `fib 20` are
  computed once at startup, and in `do` blocks a pure `let` can run before the
  action. Profile the pure expression itself, or use `IO.lazyPure`.
- **Labels must be string literals.** The runtime keys its tables by the
  literal's address.
- **Timer resolution.** On Apple Silicon the clock ticks every 41.7 ns, so
  percentiles of very short scopes are coarse. Means and totals over many
  calls are fine.
- **Task combinators.** Tasks from `Task.spawn` and `IO.asTask` are linked to
  their spawning scope; `Task.map`/`bind` and `IO.mapTask`/`bindTask` are not
  yet.

Overhead: about 11 ns per profiled `IO` action and 15 ns per pure
`profile!` scope (which allocates a closure) on an Apple M5 Max; see
[`bench/`](bench/README.md). leanprof measures its own cost at startup and
again at exit (fastest of many batches, after a warm-up) and subtracts it
from every enclosing scope, so the report shows the program's time, not the
profiler's: in `lake build overhead && .lake/build/bin/overhead`, a 24 ms
loop of 10 million tiny steps runs in 190 ms with profiling and is reported
as 28–31 ms. Set `LEANPROF_NO_CALIBRATION=1` to see raw times.

## Development

```
lake test                         # in-process tests
lake build copybug && .lake/build/bin/copybug
```

The runtime is [`c/leanprof.c`](c/leanprof.c); the Lean side is
[`Leanprof/`](Leanprof).

## License

MIT
