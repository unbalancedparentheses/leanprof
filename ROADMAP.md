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
| [lean-source-profiler](https://github.com/Vilin97/lean-source-profiler), `trace.profiler` | elaboration time, source navigation | connect compile-time and runtime diagnosis; refresh comparisons against current native capture |

Status (2026-10-25): M1–M9 are largely done. What remains is in the next
sections: v0.1.0, two bigger bets, from measuring problems to solving them,
v0.2.0, and the work after it. Each item comes from
profiling real projects with leanprof (see [case studies](docs/case-studies/))
or from using it in agent loops. Unchecked items are planned work, not claims
about current capabilities.

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
- [x] Self-check on every run: one known copy must be detected, otherwise
  warn that copies may be undercounted on this Lean version (Lean 4.36
  inlined `lean_string_push` and String copies silently went uncounted).
- [x] The smoke check profiles a project other than leanprof (the release
  package once lacked runtime files and the check, run on leanprof itself,
  passed).
- [x] Times too small to measure are reported as such, never as 0.
- [x] Release binaries for Linux arm64 and macOS x86-64 (smoke-tested at
  release); Windows documented as unsupported.
- [x] Security review of the MCP server, the GitHub Action and the install
  script ([review](docs/reviews/security-review.md)): 12 findings fixed or
  documented, and the MCP path and option bypasses a later code review
  found (default working directories, symbolic links, options among
  `elab`'s files) fixed and checked by
  `scripts/mcp-check.py`. Follow-up: build provenance attestations for
  releases.
- [x] Issue and PR templates, `SECURITY.md`, a Lean version support policy,
  `CONTRIBUTING.md`.
- [x] Easier first run: the installer checks `PATH`, and errors say how to
  fix them.
- [x] CI installs from scratch on projects leanprof has never seen
  (`fresh-install.yml`, on every change and weekly): the packaged command,
  installed by the install script with its source build hidden, runs
  import-graph (a program that loads modules at run time; this found that
  leanprof did not give programs `lake exe`'s environment) and profiles
  lean4-cli's compile time on an older Lean.
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

## Bigger bets (after v0.1.0)

Two changes in reach rather than features: they would help far more Lean
users than the rest of v0.2.0, and take priority over its long tail.

- [ ] **Find copies without running anything.** Today a copy is found only if
  a workload happens to run that path. The compiler already knows the risky
  spots: in its intermediate code, an array push or set on a value whose
  reference count was just increased will copy. A pass reading that code
  flags every likely copy across a whole package, including libraries with no
  executable, and in the editor as you type, at no runtime cost. The runtime
  profiler then confirms which flags matter and how much: "profile, then fix"
  becomes "never write it". The most uncertain bet (compiler internals change;
  false positives) and the biggest. First step: a prototype on one compiler
  intermediate representation, checked against the copies already found at
  run time in lean-compiler-backend and Lake.
- [ ] **Make compile time the main target.** Most Lean users write proofs,
  not programs, and what they wait on is elaboration: Mathlib builds, slow
  `simp` calls, instance search. The compile-time side already works (all of
  Batteries in 17 s). Point the autoresearch loop at Mathlib's slowest files.
  Speedups are easy to verify: the proofs still check and heartbeat counts
  are exact. Results stay local branches until the maintainer decides to
  propose them upstream.

## From measuring problems to solving them

Ranked; the first two are planned next to the gap-closing work, the rest
after v0.2.0.

- [x] **`leanprof fix`.** Apply the fix `explain` prints, then check it:
  identical output, tests pass, `judge` says KEEP. Leave a commit with the
  evidence. For people, not only agents. Done for the three causes whose
  code replaces lines (`nested-array-element`, `map-value-reinserted`,
  `loop-over-updated-array`; [guide](docs/guide/fix.md)). The checks run one
  workload, so they are evidence, not proof: each rewrite is applied only
  where the code shows it computes the same values, in a git worktree that
  an interruption cannot leave in your checkout, with git hooks off. Still open: edits
  for `stored-then-updated` and `multi-threaded-global`, which need the
  code that reads the value or the loop's bounds.
- [ ] **Regressions explained.** When the Action fails a pull request, say
  which declaration got more expensive and which unfold, instance search or
  `simp` lemma caused it, from `elab --heartbeats` on the changed modules
  at base and head (not only "heartbeats +40%").
- [ ] **Feedback on every save.** In the editor, re-profile what changed and
  show the difference inline ("this edit added 2,000 copies", "+30%
  heartbeats in this lemma"); with static copy detection (above), warn
  before anything runs.
- [ ] **Retained memory.** Which allocation site holds the memory at peak,
  and what keeps it alive; for long-running programs and servers.
- [ ] **Why a file is slow in the editor.** Profile the language server
  re-elaborating a file and attribute the delay to declarations.
- [ ] **A heartbeat budget.** `elab --max-heartbeats N` in CI flags any
  declaration above N, so slow lemmas do not accumulate.

## v0.2.0: make any Lean project faster

Released only after real runs show verified speedups. Agents get a dependable
basis for deciding what to change and whether it worked: structured results,
provenance and one complete experiment operation come first.

- [ ] `leanprof` with no arguments in any project: finds the executable (or
  the tests, or compile time for a library), profiles it and prints the top
  three findings with source and fixes. Never picks an ambiguous workload
  silently; handles dependency instrumentation and restores the normal build.
  Done: the workload choice (executables listed, never chosen between), a
  sampled first profile (`stat` without samply or perf events), three
  findings with file:line and the `run`/`explain`/`fix` commands, samply from
  the installer. Left: the fixes themselves in the findings, which today take
  `leanprof run` and `explain` (an exact second pass on the top copy sites).
- [ ] `leanprof autoresearch`: sets the project up (workload, tests, output
  check) and starts the loop in Claude Code, or prints the next steps. The
  loop ships as a Claude Code command.
- [ ] **Stable machine-readable contracts.** Version CLI JSON and MCP
  structured results with shared schemas and contract tests, built on the
  typed report module from the consolidation. Return typed findings, metric
  units, measurement mode, coverage, uncertainty, artifact IDs and verdict
  reasons. Separate a valid DISCARD from a failed measurement; distinguish no
  improvement, insufficient evidence and correctness failure. Supply error
  codes, retryability and recovery instructions, so agents do not parse
  terminal text (MCP results are text today).
- [ ] **Provenance and freshness.** Attach source revision and dirty-tree
  fingerprints, executable hashes (`measure-pair` already records them),
  Lean/tool versions, build flags, platform, workload/input hashes and
  measurement settings to every summary and experiment. Check compatibility
  and source freshness before comparing or advising; link source ranges to the
  exact snapshot measured. (Replaces the earlier "run manifest" item.)
- [ ] **One complete experiment operation.** Baseline capture, candidate
  measurement, correctness checks and the verdict under one experiment ID;
  timing (`measure-pair`) and instrumented counts (`measure`) kept separate but
  linked. Correctness beyond one output file: base and candidate run on many
  inputs and must agree (as the 340-combination check did for
  lean-compiler-backend), several workload sizes, held-out inputs for the
  final check, configured tests and proofs required before KEEP. Returns KEEP,
  DISCARD or an explicit inconclusive/error reason with its evidence.
- [ ] **No KEEP for a change that weakens what it must preserve.** Refuse
  a candidate whose diff touches tests, theorem statements or expected
  outputs, adds `sorry`, an `axiom`, `@[implemented_by]` or `@[extern]`,
  turns a `decide` or a proof into something weaker, or changes the
  project's axioms (`#print axioms` on the declarations it touches). In Lean
  the cheapest "speedup" is deleting a proof obligation; lean-compiler-backend
  needed its own proof-axiom audit to catch that.
- [ ] **Cheaper iterations.** In the lean-compiler-backend run most of each
  experiment was the rebuild (about 90 s), not the measurement: keep the
  base build, rebuild only the candidate's changed modules, and use the
  exact counts as a first filter (if copies, allocations and calls did not
  change, say so before spending seconds on timing).
- [ ] **A compile-time loop for libraries.** For Mathlib-style code with no
  executable, the experiment's measure is `elab --heartbeats` on the
  modules the change touches and their dependents: exact, no timing noise.
- [x] Interleaved plain-binary timing: `measure-pair` alternates AB/BA and
  `judge PAIR.json` uses a paired 95% median interval. Exact allocation
  checks remain in the existing instrumented `measure` workflow.
- [ ] **Calibrate verdicts.** Publish false-positive rates, detection rates for
  seeded 1%, 2% and 5% changes, inconclusive outcomes and total experiment cost
  on quiet and loaded hosts, with fixed protocols (not reruns until KEEP).
  Then adaptive run counts with valid stopping rules, and Linux instruction
  counts.
- [x] `explain` prints the concrete fix for each cause: `Array.modify` or
  swapping out an element held by an outer array, `alter` or erasing a
  value read from a hash map, keeping data out of a shared `IO.Ref` for
  multi-threaded copies; machine-readable ranked suggestions for agents.
- [x] Profiling dependencies rebuilds them with copy counting automatically
  (no deleting compiled files by hand).
- [x] `measure`, `measure-pair` and `judge` (summaries or a paired session)
  through the MCP server.
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
  - [x] Keep instrumented objects apart from the normal build: the next
    plain build after `measure` took 0.18 s on the Mac (it was a 10 s
    rebuild). `measure-pair` is the timing-only mode on plain builds.
  - [ ] Cheaper paired verdicts: `measure-pair` took 7.1 s per verdict at 20
    pairs (2.9 s at 6) against LeanBench's 0.74 s on the same Mac, with 0
    false verdicts in 40 and a 2.4% slowdown caught 9 in 10
    (docs/case-studies/leanbench.md).
  - [x] `measure --scope NAME`: time a `profile!` scope instead of the whole
    process (a 10.4% slowdown read as +10.4%, was 8.2%).
  - [ ] Several named benchmarks per summary, each judged; read LeanBench's
    JSON in `judge`/`report-md` so its users get copies and allocations next
    to its timings. Link each finding to its before/after experiment, and
    report setup, collection and analysis cost separately.
  - [ ] Radar JSONL output.
  - [ ] Support Lean versions before 4.34 where the runtime allows
    (LeanBench, plain Lean, runs from 4.27 to 4.35).

## After v0.2.0

### Diagnosis

- [ ] **Improve attribution.** Validate tiny functions, recursion and
  overlapping tasks against known answers; repair Linux unwinding and sampling
  flags. Separate CPU time, elapsed time, waiting and probe overhead, with
  explicit uncertainty and aggregation rules so concurrent work is not
  double-counted.
- [ ] **Broaden memory coverage.** Identify core-library and precompiled code
  coverage; add RC-operation costs, retained-memory attribution and object
  lifetime analysis beyond allocation counts and peak-live metrics. Report
  unobserved activity as such, never as a measured zero.
- [ ] **Navigate large projects.** Drill from project to module to declaration
  to operation, compare runs at each level, and detect stale source mappings.
  Evaluate the workflow against the current lean-source-profiler viewer.
- [ ] **Repeated elaboration of multi-line terms, by position.** Since
  `elab` through `lean --json` prints descriptions on one line (a 1.74 GB
  message on concrete's `Check.lean` without it), steps cut to
  `term do [...]` are left out of "repeated work". The driver prints whole
  descriptions (measured on the same file: 25.2 s, 1.26 GB; 16.0 s with
  `pp.oneline` too, with identical heartbeats); key repeats by source range
  there, then it can print one line as well.
- [ ] **Copied fields of kept structures: the line.** `explain` names no
  line for concrete's `elabModule` copy (`sp ++ "_"` at `Elab.lean:3356`,
  `sp` a field of the tuple `(ln, dn, di)` in a `filterMap` lambda): text
  matching cannot single out one of the declaration's many `++ "_"`.
  Matching the constant the IR appends (`"_"`) together with the lambda's
  binders would; so would positions from the IR, if Lean emitted them.

### Agents

- [ ] **Discovery without guesswork.** Machine-readable project and capability
  discovery (`doctor --json` or an MCP tool): Lean version, targets and modes,
  instrumentation coverage, required dependencies, actionable setup failures.
- [ ] **Bounded, recoverable jobs.** Job IDs for long builds and profiles,
  status/progress, cancellation, time/resource/output limits and resumable
  artifact retrieval. Literal argument arrays in explicit working directories;
  documented trust boundaries; explicit authorization for destructive or
  external actions. Cleanup tested after failure and cancellation.
- [ ] **Compact, queryable evidence.** A small ranked summary first, then
  filter/page by module, declaration, operation or finding ID; one finding's
  source, causal evidence, confidence and before/after deltas without
  re-reading the whole trace. Full raw artifacts kept; truncation and missing
  data reported, never silently dropped.
- [ ] **Hypotheses tied to evidence.** For each suggested fix: the observed
  cause, supporting locations, expected affected metric, semantic constraints
  and a concrete validation experiment. Observations kept apart from
  hypotheses; improvements verified by measurement, not predicted.

### Evidence

- [ ] **Outside confirmation and end-to-end value** (posting and upstream
  patches are the maintainer's decision): others reproducing the measurements
  (the lean-compiler-backend result first), patches found with leanprof
  accepted upstream, and independent users diagnosing and fixing real issues
  in unfamiliar projects. Publish correctness, time to verified improvement,
  failed diagnoses and reproduction instructions next to current-version
  comparisons.

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
