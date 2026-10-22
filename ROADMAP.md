# Roadmap

leanprof aims to be the profiler that explains Lean performance, not only
measures it: time per function, plus the copies, allocations and
reference-counting costs specific to Lean's runtime, attributed to source.

Neighbours, and how leanprof should compare with each:

| Tool | Does | leanprof should |
|---|---|---|
| [LeanProfiler](https://github.com/lean-dojo/LeanProfiler) | manual spans, Perfetto, regression comparison | add automatic instrumentation, lower overhead, live traces, paired comparison |
| samply / perf | sampling, no annotations | add Lean-aware names and source lines, merged with exact counts |
| [LeanBench](https://github.com/alok/LeanBench) | benchmark harness, saved baselines | report copies and allocations per bench, compare by interleaved runs |
| [lean-source-profiler](https://github.com/Vilin97/lean-source-profiler), `trace.profiler` | elaboration time | not compete; running programs only |

Claims about overhead and accuracy are only made after M2's head-to-head
benchmark measures them.

## M1: time and copies (done)

- [x] C runtime: per-thread tables, no locks on the hot path, log-bucket
  histograms (p50/p99), inclusive and self time, recursion-aware totals.
- [x] `profile!` for pure terms and monadic actions; closes on exceptions;
  compiles away with `leanprof.enabled = false`.
- [x] Copy detection through compile-time symbol redirection: counts, bytes,
  reason (shared, multi-threaded, persistent), attributed to function and scope.
- [x] Lean symbol demangling, including specializations.
- [x] Report on stderr and as JSON.
- [x] `copies`, `calls`, `depth` and `expectNoCopies` for tests.
- [x] In-process test suite, overhead benchmark, CI on Linux and macOS.

## M2: actionable copies, measured claims

- [x] Time spent copying, per copy site, and its share of the enclosing scope.
- [x] Source positions for `profile!` scopes (file:line).
- [x] Copy sites resolve to their declaration's file:line through Lake's
  `.ilean` files, read by the runtime at exit.
- [x] Head-to-head overhead benchmark against LeanProfiler, single- and
  multi-threaded ([bench/](bench/README.md)).
- [x] Accuracy on a known workload (`Examples/Overhead.lean`).
- [x] `leanprof sample`: samply underneath, Lean names, file:line, merged
  specializations, runtime breakdown, Lean-named flame graph.
- [ ] Overhead comparison table against samply on the same workloads.
- [x] Overhead calibration: measure the cost of a scope (warm-up, fastest of
  many batches, at startup and exit) and subtract it from every enclosing
  scope's times.
- [ ] CPU time next to wall time per scope.

## M3: no setup

- [x] Automatic instrumentation of every function through the compiler
  (`LEANPROF_AUTO=1` with `scripts/leanprof-cc`), only Lean declarations
  reported, positions from the linked modules' `.ilean` files.
- [ ] Elaborator-level variant (`set_option leanprof.auto true`) for finer
  control without the compiler wrapper.
- [ ] `@[profile]` attribute on definitions.
- [x] `scripts/leanprof-cc`: `LEAN_CC` wrapper that adds the copy flags to
  every package, dependencies included.
- [x] `lake exe leanprof run <exe>`: builds with the copy flags (and
  optionally every function timed), runs, and cleans up instrumented objects.
- [x] Library as Lean modules: `profile!` does not link Lean's front end into
  module programs; calibration only runs when profiling is used.
- [ ] Set frame-pointer and debug-info flags automatically for sampling.

## M4: comparisons that do not flake

- [ ] `leanprof compare`: paired, interleaved runs of baseline and candidate
  in one session, with confidence intervals on time.
- [x] `leanprof compare`: copies and calls compared exactly, time with a
  threshold; exits 1 on regressions.
- [ ] Allocations in the exact comparison (after M5).
- [ ] Benchmarks report copies and allocations next to time; LeanBench
  integration.

## M5: allocations

- [ ] Allocations and bytes per scope, via the same symbol redirection on the
  runtime's allocation entry points (to verify which are reachable).
- [ ] Peak live memory per scope.
- [ ] `expectAllocs` for tests.

## M6: explanations

- [ ] For each copy site, read the compiler's IR to show where the extra
  reference comes from ("`acc` is stored in `history` at line 20, so the
  push at line 21 copies").
- [ ] Integrate Lean's linearity markers (`lean_array_mark_linear` and
  friends): report violations instead of panicking; `expectLinear` in tests.
- [ ] Boxing, closure application (`lean_apply_n`) and RC-operation counts.

## M7: traces, tasks and live views

- [ ] Shared-memory ring buffer (as in flux-profiler) read by a separate
  process, for live traces at near-zero cost to the program.
- [x] Timeline export (`LEANPROF_TRACE`): Chrome trace format for Perfetto,
  per thread, with copies as instant markers; bounded per-thread buffers.
- [ ] Export LeanProfiler's summary format.
- [x] Attribute `Task.spawn`/`IO.asTask` work to the spawning scope; queue
  wait (spawn to start); blocking `IO.wait`/`Task.get` per call site; tasks
  on their worker threads in the timeline.
- [ ] `Task.map`/`bind`, `IO.mapTask`/`bindTask`; `Std.Channel` throughput.
- [ ] One Firefox Profiler file merging samply's sampled stacks, exact scope
  timings and copies as markers.
- [ ] Live terminal view and an MCP server so agents can query a running
  program.

## M8: editor

- [ ] Infoview widget: hot scopes and copy sites next to the source, with
  their share of time.

## Upstream

- [ ] Propose optional profiling hooks in the Lean runtime, so copies inside
  the precompiled core library become visible without redirection (or
  rebuild the core library with leanprof's flags).
- [ ] Ask whether the C emitter could carry Lean source lines (`#line`), which
  would give exact lines for copies instead of declarations.
