# Roadmap

leanprof aims to be the profiler that explains Lean performance, not only
measures it: time per function, plus the copies, allocations and
reference-counting costs specific to Lean's runtime, attributed to source.

What already exists and is not duplicated here:
[LeanProfiler](https://github.com/lean-dojo/LeanProfiler) (manual spans,
Perfetto, regression comparison), [lean-source-profiler](https://github.com/Vilin97/lean-source-profiler)
(elaboration time in VS Code), [LeanBench](https://github.com/alok/LeanBench)
(benchmark harness) and Lean's own `trace.profiler`. Where it helps, leanprof
writes their formats instead of inventing new ones.

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

## M2: less setup, more coverage

- [ ] `@[profile]` attribute on definitions.
- [ ] Module-wide automatic instrumentation from the elaborator
  (`set_option leanprof.auto true`), skipping instances and generated code.
- [ ] Lake integration so users do not copy the flag list by hand.
- [ ] Source positions (file:line) for scopes and copy sites.
- [ ] Export LeanProfiler's summary format and Perfetto traces.

## M3: allocations

- [ ] Allocations and bytes per scope, via the same symbol redirection on the
  runtime's allocation entry points (to verify which are reachable).
- [ ] Peak live memory per scope.
- [ ] `expectAllocs` for tests.

## M4: explanations

- [ ] For each copy site, read the compiler's IR to show where the extra
  reference comes from ("`arr` is retained at line 38 and reused at 42").
- [ ] Boxing, closure application (`lean_apply_n`) and RC-operation counts.

## M5: concurrency and live views

- [ ] Attribute work in `Task`s to the scope that spawned them.
- [ ] Task queue and wait times; `Std.Channel` throughput.
- [ ] Live terminal view and an MCP server so agents can query a running
  program.

## M6: editor and CI

- [ ] Infoview widget: hot scopes and copy sites next to the source.
- [ ] Baseline comparison on exact metrics (copies, allocations) that fails CI
  on regressions; LeanBench integration.

## Upstream

- [ ] Propose optional profiling hooks in the Lean runtime, so copies inside
  the precompiled core library become visible without redirection.
