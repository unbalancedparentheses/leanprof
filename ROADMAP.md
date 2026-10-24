# Roadmap

leanprof aims to be the profiler that explains Lean performance, not only
measures it: time per function, plus the copies, allocations and
reference-counting costs specific to Lean's runtime, attributed to source.

Neighbours, and how leanprof should compare with each:

| Tool | Does | leanprof should |
|---|---|---|
| [LeanProfiler](https://github.com/lean-dojo/LeanProfiler) | manual spans, Perfetto, regression comparison | add automatic instrumentation, lower overhead, live traces, paired comparison |
| samply / perf | sampling, no annotations | add Lean-aware names and source lines, merged with exact counts |
| [LeanBench](https://github.com/alok/LeanBench) | benchmark harness, saved baselines | match its cost (0.6 s per verdict against 6.5 s) and per-benchmark precision, keep exact copies and allocations, compare by interleaved runs ([case study](docs/case-studies/leanbench.md)) |
| [lean-source-profiler](https://github.com/Vilin97/lean-source-profiler), `trace.profiler` | elaboration time | not compete; running programs only |

Status (2026-10-23): M1–M9 are largely done; what remains before and after
the first releases is in the next two sections, which come from profiling
real projects with leanprof (see [case studies](docs/case-studies/)).

The [competitive priorities](docs/research/competitive-priorities.md) define
what evidence is still needed to become the best choice across these jobs,
including refreshed comparisons against current alternatives.

## v0.1.0: honest numbers, installable

- [x] Merge the open work: accuracy (probe-cost flags, `%wall`, recursive
  self time), hardening (sanitizers in CI), exact compile-time ranges, Lake
  and language-server and Mathlib case studies, the website.
- [x] Allocations judged exactly: `measure`, `judge` and `compare`
  include allocations by instrumented compiled Lean code. Reports show them
  alongside copies when allocation counting is enabled. Core-library and
  constant-copy coverage remains a limitation (see the autoresearch case study).
- [x] Each finding states its share of the run (`these copies took 0.4% of
  the run`), and reports and `explain` rank by that, not by counts: a 10%
  cut in allocations there did not change wall time.
- [x] Copies of empty or tiny values (the first push into an empty slot)
  grouped or hidden; tables sorted by bytes and time.
- [ ] Self-check on every run: one known copy must be detected, otherwise
  warn that copies may be undercounted on this Lean version (Lean 4.36
  inlined `lean_string_push` and String copies silently went uncounted).
- [x] The smoke check profiles a project other than leanprof (the release
  package once lacked runtime files and the check, run on leanprof itself,
  passed).
- [x] Times too small to measure are reported as such, never as 0.
- [ ] Release binaries for Linux arm64 and macOS x86-64; Windows documented
  as unsupported.
- [ ] Security review of the MCP server, the GitHub Action and the install
  script.
- [x] Issue and PR templates, `SECURITY.md`, a Lean version support policy,
  `CONTRIBUTING.md`.
- [x] Easier first run: the installer checks `PATH`, errors say how to fix
  them, CI installs from scratch on a project leanprof has never seen.
- [ ] Evidence that stands on its own:
  - the benchmark suite rerun on CI's fixed runners (Linux and macOS, on a
    schedule) with the results published, next to a run on an idle machine
    (dedicated Linux results are now recorded in `bench/RESULTS.md`;
    scheduled publication is still outstanding);
  - real programs whose right answer is known (where the time goes, how many
    copies), not only synthetic workloads;
  - [x] A comparison with LeanBench on regression verdicts (noise, seeded
    regressions, cost): see [the case study](docs/case-studies/leanbench.md).
- [x] README states only what was measured: where leanprof is better, where
  it is not (tiny functions in the exact modes; LeanProfiler's hand-placed
  spans are more accurate on some workloads; what lean-source-profiler has
  that leanprof lacks).
- [ ] Consolidation: command modules in `LeanprofCli/`, one typed report
  module, `c/` split behind `c/internal.h`, CI checks as local scripts,
  formatters and linters, `research/` renamed `autoresearch/`.

## v0.2.0: make any Lean project faster

- [ ] `leanprof` with no arguments in any project: finds the executable (or
  the tests, or compile time for a library), profiles it and prints the top
  problems with fixes.
- [ ] `leanprof autoresearch`: sets the project up (workload, tests, output
  check) and starts the loop in Claude Code, or prints the next steps.
- [x] Interleaved plain-binary timing: `measure-pair` alternates AB/BA and
  `judge PAIR.json` uses a paired 95% median interval. Exact allocation
  checks remain in the existing instrumented `measure` workflow.
- [ ] Adaptive sampling with valid stopping rules, and Linux instruction counts.
- [ ] Correctness beyond one output file: base and candidate run on many
  inputs and must agree (as the 160-combination check did for
  lean-compiler-backend); several workload sizes, and a final check of the
  whole branch on inputs the loop never saw.
- [x] `explain` prints the concrete fix for each cause: `Array.modify` or
  swapping out an element held by an outer array, `alter` or erasing a
  value read from a hash map, keeping data out of a shared `IO.Ref` for
  multi-threaded copies; machine-readable ranked suggestions for agents.
- [ ] Profiling dependencies rebuilds them with copy counting automatically
  (no deleting compiled files by hand).
- [x] `measure` and `judge` through the MCP server.
- [ ] The loop shipped as a Claude Code command; the results log used as
  memory of tried ideas.
- [ ] Outside confirmation (the maintainer's decision: posting and
  upstream patches): others reproducing the measurements, and patches found
  with leanprof accepted upstream.
- [ ] Evidence: a benchmark of seeded slowdowns the loop must find, a run on
  leanprof itself, and runs on projects it has never seen.
- [ ] Lessons from LeanBench ([case study](docs/case-studies/leanbench.md)):
  - [x] `judge` does not use time measured on an overloaded machine (load
    average above the CPU count, now recorded by `measure`); on a shared Mac
    at load 20–70 it had judged a 10% slowdown KEEP.
  - [x] `judge --min-change` (1%): sequential base/new runs drift by about 1%
    on a quiet machine, which gave 2 false KEEPs in 20; the "1 in 252" claim
    is corrected.
  - [x] `measure` shows mean ± standard deviation.
  - [ ] Keep instrumented objects apart from the normal build: today each
    `measure` rebuilds the project's C with shims and the next plain build
    recompiles all of it (6.5 s per verdict plus a 10 s rebuild, against
    LeanBench's 0.6 s); a timing-only mode on the plain build.
  - [ ] `measure --scope NAME`: time a `profile!` scope instead of the whole
    process, so start-up does not dilute a change (a 10.4% slowdown read as
    8.2%).
  - [ ] Several named benchmarks per summary, each judged; read LeanBench's
    JSON in `judge`/`report-md` so its users get copies and allocations next
    to its timings.
  - [ ] A run manifest in summaries (git commit, Lean version, OS) and radar
    JSONL output.
  - [ ] Support Lean versions before 4.34 where the runtime allows
    (LeanBench, plain Lean, runs from 4.27 to 4.35).

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
- [x] Allocations in the exact comparison (after M5).
- [ ] Benchmarks report copies and allocations next to time; LeanBench
  integration.

## M4b: autoresearch

leanprof as the measurement and verdict of an agent loop that edits code and
keeps only improvements ([research/program.md](research/program.md)).

- [x] `leanprof measure`: N runs with copy detection; time spread, copies,
  calls, compile heartbeats, exit code and output hash in one summary.
- [x] `leanprof judge`: KEEP/DISCARD from two summaries; exact metrics
  first, time only when the runs do not overlap.
- [x] `research/program.md` for agents, and a scripted demo
  (`research/demo/run.sh`) run in CI.
- [x] Interleave prebuilt baseline/candidate binaries with `measure-pair`;
  judge timing with a paired median interval. Gradual drift is reduced,
  not eliminated; real-world verdict calibration remains to be measured.
- [x] Allocations in the verdict (after M5).
- [ ] Hints in the summary: the top copy sites and sampled hotspots, so the
  agent's next experiment starts from the measurement.
- [x] Run against real projects (Mathlib-free programs, compilers,
  parsers) and publish what the loop found.

## M5: allocations

- [x] Allocations and bytes per scope and per call site, via redirection of
  the runtime's allocation entry points (opt-in `--allocs`).
- [x] Peak live memory per scope.
- [x] `expectAllocsAtMost` for tests.

## M6: explanations

- [x] For each copy site, read the compiler's IR to show where the extra
  reference comes from ("`acc` is stored in `history` at line 20, so the
  push at line 21 copies").
- [ ] Integrate Lean's linearity markers (`lean_array_mark_linear` and
  friends): report violations instead of panicking; `expectLinear` in tests.
- [ ] Boxing and RC-operation counts; closure applications and failed reuse
  are already available through `--counters`.

## M7: traces, tasks and live views

- [ ] Shared-memory ring buffer (as in flux-profiler) read by a separate
  process, for live traces at near-zero cost to the program.
- [x] Timeline export (`LEANPROF_TRACE`): Chrome trace format for Perfetto,
  per thread, with copies as instant markers; bounded per-thread buffers.
- [ ] Export LeanProfiler's summary format.
- [x] Attribute `Task.spawn`/`IO.asTask` work to the spawning scope; queue
  wait (spawn to start); blocking `IO.wait`/`Task.get` per call site; tasks
  on their worker threads in the timeline.
- [x] `Task.map`/`bind`, `IO.mapTask`/`bindTask`.
- [ ] `Std.Channel` throughput.
- [ ] One Firefox Profiler file merging samply's sampled stacks, exact scope
  timings and copies as markers.
- [x] Live terminal view and an MCP server so agents can query a running
  program.

## M8: editor

- [x] `#leanprof`: inlay hints with time per scope/function and copies per
  declaration, from the last report; tooltips with details; checked against
  the language server in CI.
- [ ] Infoview widget with a flame graph of the run.

## M9: compile time

- [x] `leanprof elab`: compile time per declaration from `trace.profiler`
  (elaboration, kernel, compiler, linters), shown by `#leanprof`.
- [x] Full trace trees: self cost by operation kind, costliest lines with
  their heaviest nested operations, repeated identical operations.
- [x] `--heartbeats`: deterministic compile cost; `compare` flags increases
  above 1% and 1,000 heartbeats, matched by declaration name.
- [x] Links from slow operations to the definitions they unfold.
- [x] Whole-project runs (every module of a package) with a summary.

## Upstream

- [ ] Propose optional profiling hooks in the Lean runtime, so copies inside
  the precompiled core library become visible without redirection (or
  rebuild the core library with leanprof's flags).
- [ ] Ask whether the C emitter could carry Lean source lines (`#line`), which
  would give exact lines for copies instead of declarations.
