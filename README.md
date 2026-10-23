# leanprof

An instrumentation profiler for compiled Lean 4 programs. It reports time per
scope and, unlike general-purpose profilers, the **hidden copies** that make
Lean code slow: every time an `Array`, `ByteArray` or `String` is updated while
another reference to it is alive, Lean copies the whole value.

```

leanprof: 4 scopes, wall 14.9 ms, 14.8 ns overhead per scope subtracted

scope                         calls      total       self  %wall       mean        p50        p99  where
buildWithHistory                  1     2.5 ms     2.5 ms  16.8%     2.5 ms     2.5 ms     2.5 ms  Examples/CopyBug.lean:17
report                            1   76.0 µs   20.7 µs   0.5%   76.0 µs   74.7 µs   74.7 µs  Examples/CopyBug.lean:35
fib                           10945   55.4 µs   55.4 µs   0.4%      61 ns      42 ns     708 ns  Examples/CopyBug.lean:15
build                             1    7.3 µs    7.3 µs   0.0%    7.3 µs    7.0 µs    7.0 µs  Examples/CopyBug.lean:25

copies of non-exclusive values (each one copied the whole value)
function                                 kind           copies       bytes       time  %scope  why             in scope             where (declaration)
buildWithHistory (in Std.Legacy.Range.forIn'.loop) Array            2001    15.3 MiB     2.5 ms   98.5%  shared+persistent buildWithHistory     Examples/CopyBug.lean:17
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
| No annotations needed | ✅ sampled (`leanprof sample`) or exact (`--auto`) | – | ✅ sampled | – |
| No rebuild, near-zero overhead | ✅ `leanprof sample` (samply underneath) | – | ✅ | – |
| Lean names and file:line in sampled profiles | ✅ incl. specializations merged; runtime breakdown | – | mangled C names | – |
| Startup cost when linked but unused | none (lazy calibration); modules don't link Lean's front end | small | none | – |
| Timeline | ✅ Perfetto, with copies as markers | ✅ Perfetto | ✅ Firefox Profiler | – |
| Regression comparison | ✅ exact for copies and calls; thresholded for time | ✅ thresholded | – | ✅ thresholded |
| Task-aware | ✅ run time and queue wait per spawning scope; blocking waits per call site | ✅ parent links | – | – |
| Lean-readable names | ✅ | ✅ (you name spans) | mangled | ✅ |
| Results inline in the editor | ✅ run time, copies and compile time (`#leanprof`) | – | – | – |
| Compile-time profile | ✅ per line and operation kind, repeated work, exact heartbeat regressions | – | – | – |

For compile time, [lean-source-profiler](https://github.com/Vilin97/lean-source-profiler)
also links slow operations to the imported definitions involved and has
profiled all of Mathlib; `leanprof elab` adds the operation-kind breakdown,
repeated-work detection and exact heartbeat regression checks.
Overhead numbers are from [`bench/`](bench/README.md) (Apple M5 Max). The
same page shows leanprof finding the cause of LeanProfiler's growing cost:
its event array is copied on every span.

Real use: [lean-compiler-backend case study](docs/case-studies/lean-compiler-backend.md),
profiled without adding a dependency: where its run time goes, 121,054 array
copies in one loop, and one function that is a quarter of its compile cost.

Status: early. Tested with Lean 4.35.0 on macOS arm64; CI also runs Linux.
See [ROADMAP.md](ROADMAP.md).

## Use

Add the dependency to your `lakefile.lean`:

```lean
require leanprof from git "https://github.com/unbalancedparentheses/leanprof" @ "main"
```

Make your files modules (`module` at the top, `public import Leanprof`):
`profile!`'s elaborator is then only used while compiling, so programs do
not link or initialize Lean's front end (a minimal program is 1 MB and starts
in 10 ms, against 177 MB and ~30 ms of initialization from a plain
`import`). Without the module system, `import Leanprof.Core` gives the same
runtime API (`Leanprof.scope`, `scopeM`, ...) without `profile!`.

Mark the code to time with `profile!`. It works on pure terms and on monadic
actions (any monad with `MonadFinally` and a `BaseIO` lift, such as `IO` or
`StateT σ IO`); a monadic scope also closes when the action throws.

```lean
module

public import Leanprof

def solve (xs : Array Nat) : Nat := profile! "solve" (xs.foldl (· + ·) 0)

public def main : IO Unit := profile! "main" do
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
  moreLinkArgs := #["-rdynamic"]  -- so the report can name functions (larger binary)
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
so a later plain `lake build` does not reuse them. The project does not need
to depend on leanprof: `run` compiles leanprof's runtime for the project's
own Lean version and links it in (tested with Lean 4.34.1 and 4.35.0), so
`/path/to/leanprof/.lake/build/bin/leanprof run EXE` works in any Lake
project.

```
lake exe leanprof compare [--threshold PCT] [--min-ms MS] BASE.json NEW.json
```

compares two `--json` reports and exits 1 on a regression: any increase in
copies or change in call counts (both exact, so no noise), or a scope slower
by more than `PCT` percent (default 10) and `MS` milliseconds (default 1).

### In the editor

Add `#leanprof` anywhere in a file (it needs `import Leanprof`):

```lean
#leanprof                         -- reads .lake/leanprof/report.json
#leanprof "reports/before.json"   -- or any report
```

Each line the last run mentions gets an inlay hint at its end, for the
running program, not for compilation:

```
def buildWithHistory (n : Nat) ... := profile! "buildWithHistory" Id.run do   ⏱ 2.7 ms · 13.7% · 1×   ⚠ 1999 copies · 15.3 MiB · 2.7 ms
  | n + 2 => profile! "fib" (fib n + fib (n + 1))                              ⏱ 132.9 µs · 0.7% · 10945×
```

Hover a hint for self time, mean, p50/p99, or why the copy happened. Both
`lake exe leanprof run` and `lake exe leanprof sample` write that default
report (sampled reports show `≈ CPU` instead). The hints describe the code
as it was when the program ran, so rerun after edits.

### Compile time

```
lake exe leanprof elab [--heartbeats] [--top N] FILE.lean...
```

elaborates the files with Lean's `trace.profiler`, parses the full trace
trees (every `isDefEq`, `whnf`, instance search, tactic step, kernel check
and compiler pass, with its self and total cost) and reports:

- **where compile time went**: self cost by kind of operation (instance
  search, `isDefEq`, `whnf`, tactic steps, kernel, compiler, linters);
- **the costliest lines**, each with its most expensive nested operations
  (`omega`, a `decide` that has to `whnf` a whole `foldl`, ...);
- **repeated work**: the same operation done many times, such as one instance
  problem solved 16 times, which points at a missing instance, a cache miss
  or a definition that should be reducible.

```
  repeated work (the same operation done more than once)
  1.39 ms      16×    [Meta.synthInstance] HAdd Nat Nat Nat  (first at Examples/ElabHeavy.lean:11)
  0.99 ms      2×     [Meta.synthInstance] Decidable (Lean.Omega.Coeffs.isZero [1] ∨ ...)  (first at Examples/ElabHeavy.lean:27)
```

With `--heartbeats` the numbers are Lean heartbeats instead of time. They
are the same on every run, so `leanprof compare` can check compile cost in
CI without noise: a declaration whose cost grows by more than 1% (and 1,000
heartbeats; editing one declaration moves its neighbours by a few) is a
regression. Declarations are matched by name, so edits that move lines
still compare.

The report goes to `.lake/leanprof/elab.json`, which `#leanprof` shows as
`⚙ 17.3 kHB to compile` hints; hovering lists the line's costliest
operations.

### Sampling: no rebuild, near-zero overhead

```
lake exe leanprof sample [--rate HZ] [--top N] EXE [-- ARGS]
```

builds `EXE` normally and runs it under [samply](https://github.com/mstange/samply)
(`brew install samply` or `cargo install samply`), then reports CPU time per
Lean declaration with file:line, merging lambdas and specializations into
the function that owns them, plus where the Lean runtime's own time went:

```
  where the Lean runtime's time went (self time)
  63.92 ms     43.70%   copying non-exclusive values
  51.96 ms     35.53%   freeing objects (reference counts reaching zero)
  10.76 ms     7.36%    allocation
  0.49 ms      0.33%    leanprof itself
  0.40 ms      0.28%    marking objects multi-threaded/persistent

  top 3 functions by self CPU time
  63.92 ms     43.70%   lean_copy_expand_array
  51.96 ms     35.53%   lean::lean_del_core_other(lean_object*, unsigned char, lean_object*)
  10.30 ms     7.04%    mi_page_free_list_extend(mi_page_s*, unsigned long, unsigned long)

  top 3 Lean declarations by inclusive CPU time
  134.09 ms    91.67%   main  (Examples/CopyBug.lean:31)
  75.92 ms     51.90%   buildWithHistory (in Std.Legacy.Range.forIn'.loop)  (Examples/CopyBug.lean:17)
  75.92 ms     51.90%   buildWithHistory  (Examples/CopyBug.lean:17)
```

It also rewrites samply's symbol file, so `samply load .lake/leanprof/EXE.json`
opens the flame graph in Firefox Profiler with Lean names instead of
mangled ones. Use sampling to find where to look; use `profile!`, `--auto`
and copy detection for exact counts and causes.

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
[`bench/`](bench/README.md). leanprof measures its own cost the first time
something is profiled and again at exit (fastest of many batches, after a
warm-up; programs that never profile pay nothing) and subtracts it
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
