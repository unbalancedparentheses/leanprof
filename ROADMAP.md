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
- [ ] Same against samply, and accuracy on known workloads.
- [ ] Overhead calibration: measure the cost of a scope at startup and
  subtract it from self time.
- [ ] CPU time next to wall time per scope.

## M3: no setup

- [ ] Module-wide automatic instrumentation from the elaborator
  (`set_option leanprof.auto true`), skipping instances and generated code.
- [ ] `@[profile]` attribute on definitions.
- [x] `scripts/leanprof-cc`: `LEAN_CC` wrapper that adds the copy flags to
  every package, dependencies included.
- [ ] `lake exe leanprof run <exe>`: builds with the copy flags and
  instrumentation, runs, and shows the report, with no lakefile edits.
- [ ] Set frame-pointer and debug-info flags automatically for sampling.

## M4: comparisons that do not flake

- [ ] `leanprof compare`: paired, interleaved runs of baseline and candidate
  in one session, with confidence intervals on time.
- [ ] Exact metrics (copies, allocations, calls) compared without statistics;
  fail CI on any increase.
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
- [ ] Export Perfetto traces and LeanProfiler's summary format.
- [ ] Attribute `Task` work to the spawning scope; measure queue wait
  (spawned to started) and `IO.wait` time; `Std.Channel` throughput.
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
