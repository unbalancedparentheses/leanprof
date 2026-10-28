# Next steps: reviews by Codex and Kimi (2026-10-27)

Two independent read-only reviews of `main` (v0.1.0) and the six branches pending at the time (static-copies-cmd, agent-contracts, compile-time-first, precision, retained-memory, editor-on-save), asked for a critique of the candidate features, a ranked top 10, bugs, and overstated claims. The bugs they found in the branches were sent to the branches' agents to fix before merging. Kept verbatim.

## Codex (codex-cli 0.162.1)

Read-only review of `main` and the six branch diffs; no files changed or tests run. Branch findings below refer to their current tips, before integration.

### A. Critique of the candidates

**1. Whole-project build time: highest-value new capability.** Declaration heartbeats do not answer “why does this build take ten minutes?” `docs/guide/compile-time.md` explicitly distinguishes summed command costs from elapsed time. Capture actual Lake task durations, dependencies, concurrency and cache state before computing critical paths. Import reachability estimates rebuild exposure; it does **not** establish elapsed rebuild cost or that an import is removable. Verify proposed removals through builds and measured incremental rebuilds.

**2. Project-wide compile causes: valuable, but partly implemented.** `LeanprofElab.lean` already aggregates constants and repeated work across files; compile-time-first adds `ElabWhy` and checked `FixElab` edits. The missing contribution is ranking *interventions* across affected consumers and measuring their net benefit. Inclusive unfold costs overlap; “this definition accounts for N heartbeats” is not “changing it saves N heartbeats.”

**3. Runtime IR lints: useful only as hypotheses.** Start with observed hot closure applications and failed reuse, already counted by `Leanprof/Counters.lean`. Blanket specialization can increase code size; non-tail recursion can be appropriate; replacing `Nat` with `UInt64` changes overflow semantics. Static-copies already illustrates the distinction between likely sites and measured costs. Avoid a catalogue of unmeasured warnings.

**4. Toolchain-upgrade diff: useful, later.** Separate compiler changes, dependency changes, generated-code changes and profiler changes. Heartbeats across Lean versions are not a stable unit of equivalent work. Start with plain build/runtime comparisons and artifact provenance; explanations come afterward.

**5. Per-commit history: low priority.** Without controlled workloads and measurement modes, it becomes a graph of incomparable numbers. Existing JSON artifacts plus CI retention cover much of the need. Defer a dedicated command.

**6. Compilation memory: high value at module granularity.** Peak RSS per elaborator process can identify OOM risks and guide concurrency. Per-declaration attribution is substantially harder: imports, shared environments and concurrent elaboration defeat simple RSS subtraction. Do not sell process-wide memory sampled during a declaration as memory owned by it.

**7. Hardware counters: useful second-tier diagnosis.** Begin with process-level instructions/cycles, then sampled attribution. Multiplexing, permissions, architecture differences and sampling skid complicate “per-function exactness.” This should support investigations, not become a universal verdict metric.

Missing priorities are **measurement validity, explicit optimization objectives, multiple performance workloads, and usable long-running jobs**. These matter more than expanding the command list.

### B. Ranked next ten things

| Rank | Work | Why; size; risk; verification |
|---|---|---|
| **1** | Integrate and harden the six branches | Shared CLI, reports and runtime changes need one coherent result. **M.** Risk: individually passing branches produce contradictory contracts. Verify combined CLI/MCP/schema tests, supported toolchains, interrupted runs and sanitizer workloads; retain only the requested CLI portion of editor-on-save. |
| **2** | Close the v0.2.0 evidence gate | The goal is faster real code, not more findings. **M–L.** Risk: selection bias and profiler-induced improvements. Publish reproducible patches, ordinary-build timings, downstream checks and unsuccessful attempts across runtime and proof projects, including previously unseen projects. |
| **3** | Make optimization objectives explicit | `Judge.judge` rejects any allocation increase; `Experiment.combine` can KEEP count improvements with unsettled timing. These are policies, not definitions of “faster.” **M.** Risk: agents exploit a proxy. Add selectable time/heartbeat/memory objectives with correctness and resource constraints; test known time-versus-allocation tradeoffs. |
| **4** | Finish verdict calibration and representative benchmark cases | Performance currently receives narrower workload coverage than correctness. **M.** Risk: drift, repeated testing and fastest-repetition bias. Predeclare independent quiet/loaded trials, report false verdicts, detection, inconclusive rates and total cost; measure several input sizes and named workloads. |
| **5** | Measure Lake builds and incremental rebuilds | Exposes the user-visible compile bottleneck. **L.** Risk: confusing dependency reachability with scheduling or cache effects. Verify critical paths against observed task timelines; measure predicted versus actual rebuild costs after touching selected modules. |
| **6** | Rank and verify project-wide compile interventions | Builds on existing aggregation and compile-time-first. **M–L.** Risk: overlapping attribution and local wins hurting consumers. Verify unchanged obligations, affected downstream builds, heartbeat reductions and ordinary elapsed build improvements. |
| **7** | Add compilation RSS and memory-aware project scheduling | Helps users finish large profiles without swapping or OOM. **M** for modules, **L** for declarations. Risk: profiler overhead contaminates memory. Compare plain/profiled process RSS on known memory-heavy files; report imports and attribution limitations. |
| **8** | Add durable MCP jobs, cancellation and artifact retrieval | Mathlib experiments already take roughly twenty minutes per round. **M.** Risk: orphaned processes and competing worktrees. Verify cancellation during every phase, restart/reconnect behavior, bounded logs and build restoration. |
| **9** | Add measured runtime diagnoses and narrowly justified fixes | Prioritize hot closures, boxing and reuse over generic linting. **M–L.** Risk: specialization regressions and semantic changes. Require runtime confirmation, representative output tests and paired plain-binary timing for each new fix family. |
| **10** | Consolidate measurement/report infrastructure | Extract typed reports, compatibility checks, comparison rules and process lifecycle management from the large command modules. **M**, incremental. Risk: behavior changes hidden in refactoring. Require equivalent CLI/MCP/HTML results on shared fixtures; avoid a wholesale rewrite. |

Defer history, toolchain automation and per-function hardware counters. Pursue Linux’s 23 ns probe cost when profiles show a worthwhile accuracy or end-to-end benefit, rather than treating Mac parity as the objective. Package `autoresearch` after the contracts and verdict policy stabilize; a launcher alone adds little. Use Mathlib-wide runs as scalability and correctness evidence, not merely a publication milestone.

### C. Bugs and weaknesses to address

- **Retained-memory heap walks lack a consistent concurrency guard.** In `c/retained.inc.c`, `lpf_ret_auto_walk` checks `lpf_ret_shared`, but `leanprof_retained_snapshot` and `lpf_ret_finish` call `lpf_ret_walk_now` without that check. The walker releases tracking-table locks before dereferencing objects. Concurrent mutation/free can therefore invalidate its reads; catching SIGSEGV does not make those reads race-free. Require quiescence or refuse unsafe walks.

- **Agent provenance misses changed input contents.** `Contract.gitState` hashes status and tracked diff text, not untracked-file contents. Editing an existing untracked source can preserve its fingerprint. `hashFile` returns only `size:N` above 256 MiB, so same-size input changes also escape detection. Use content hashes or explicitly mark evidence unverifiable.

- **Two incompatible `compare --json` interfaces are pending.** Agent-contracts uses a boolean flag and stdout schema; editor-on-save consumes an output filename and emits `Delta`. `Delta.regressed` hardcodes thresholds, ignoring CLI overrides. Unify parsing, schema, compatibility and regression computation before merging.

- **Precision changes benchmark behavior.** `Leanprof.Bench.bench` repeats arbitrary `IO` actions and returns the last result; automatic repetition depends on load. Stateful regions can measure progressively different work. Fastest-of-N also changes the estimand. Make repetition opt-in with reset/setup semantics and explicit reporting.

- **Malformed summaries fail open.** `Judge.Summary.ofJson` checks the document kind but defaults missing metrics to zero and output stability to true. Missing evidence should yield an error, not a plausible comparison. Add strict consumer validation, beyond validating generated documents.

- **Known compile-time-first failures remain.** Its `docs/case-studies/compile-time-fixes.md` records two Mathlib files failing only under `--why` with `Unknown constant term.pseudo.antiquot`. Fix this and ensure incomplete profiles cannot produce improvement verdicts.

- **Performance coverage is narrower than behavioral coverage.** `Experiment.lean` checks every case’s outputs, but paired timing selects `s.cases[0]`. A KEEP can therefore hide slowdowns on other supplied cases. Separate correctness cases from an explicit performance suite.

### D. Claims needing qualification

- README’s opening “counts … exactly per function,” “names the line,” and “prints the fix” exceed documented coverage and source-matching limits. Put those qualifications near the headline.
- “Each claim wrong at most 2.5%” requires the independence assumptions documented in `Judge.lean`; it is not an unconditional operational guarantee.
- Catching 2.4% where a comparator uses a 5% threshold is not strong superiority evidence. Compare matched detection goals and false-positive rates.
- Heartbeats measure allocation-related elaboration work, not elapsed compile speed; profiling itself changes them.
- ROADMAP’s “No KEEP for a change that weakens what it must preserve” is broader than the scoped audit guarantees in `docs/guide/proof-audit.md`.
- Retained-memory documentation calls persistent growth “in a server, a leak.” Growing caches and legitimate workloads are counterexamples: report **sustained growth requiring investigation**.
- Remove editor-oriented future work from the roadmap to reflect the maintainer’s actual priorities.

## Kimi (k3.1-pro)

### A. Candidate list critique

**Highest value**

1. **Whole-project build time.** This addresses the actual user wait, not merely the sum of elaboration work. Critical path, downstream rebuild closure, and import trimming belong together. Do not derive them directly from current `elab --project`: it builds first, then re-elaborates with tracing (`docs/guide/compile-time.md:214-232`), so its `wall_ns` is not a clean-build measurement. Instrument real Lake builds and validate predicted rebuild savings with clean and incremental builds.

2. **Project-wide compile-time causes, ending in experiments.** Valuable, but aggregation itself already exists: `constants`, cross-file `repeated`, sites and counts are reported (`LeanprofElab.lean`, `docs/guide/compile-time.md:16-28`). The new work is forming cross-file hypotheses and testing them. Attributed costs overlap (`compile-time.md:81-83`), and parallel elaboration makes CPU totals exceed wall time (`:259-264`); do not rank by a naïve sum or claim projected wall-time savings.

3. **Compilation memory.** High value for Mathlib-scale projects and OOM failures. Start with peak RSS/commit per file in real builds. Per-declaration attribution is much harder under parallel proof elaboration; initially require serialized measurement or label it approximate.

**Useful later**

- **Toolchain-upgrade diff** is a good application of existing `compare` plus provenance, but must separate source changes, generated-C changes, runtime changes, and profiler/trace-format changes.
- **Runtime IR lints** should be narrowed to one measured cause first. Closure calls and failed reuse already have counters (`docs/guide/copies-and-allocations.md:278-346`), making missing `@[specialize]` the natural first experiment. Boxing, Nat/UInt64 and non-tail recursion have semantic and measurement traps; a five-lint launch would produce advice, not a performance tool.

**Low value or traps**

- **Per-commit history** adds storage, invalidation and presentation problems while CI comparison and provenance supply most of the value. Make artifacts queryable; do not build a history database yet.
- **Linux hardware counters** are useful later for instruction-based verdicts, but permissions, VMs, counter skid and per-function attribution make them a poor near-term differentiator.
- Missing from the list: hardening/integration of the six branches, the v0.2.0 real-project evidence gate, bounded MCP jobs, core/runtime blind spots, exact IR source positions, and I/O or lock contention.

### B. Ranked top 10

1. **Integrate and harden the six branches — M.** They collectively add roughly 13k lines and conflicting JSON designs. Risk: merging individually green but incompatible implementations. Verify one combined CI run, sanitizers, cross-feature contract tests, and CLI/MCP compatibility before further features.

2. **Satisfy the v0.2.0 evidence gate on real projects — L.** The goal is verified improvements, not more diagnostics. Use `compile-time-first`, static copies and retained memory on unfamiliar projects. Verify kept changes with tests, identical outputs or preserved proofs, repeated measurements, published failures, and independent reproduction where possible.

3. **Repair verdict validity, then calibrate it — M.** Exact-count and coverage bugs undermine every agent loop. Risks include false KEEPs and changing the timed quantity. Verify nondeterministic-count tests, self-check failure tests, and published seeded 1%/2%/5% detection, false-positive, inconclusive and cost rates on quiet and loaded hosts.

4. **Add real-build critical path and rebuild-cost analysis — L.** This is the largest missing compile-time workflow. Risk: confusing traced re-elaboration with build latency and suggesting imports that only work through transitivity. Verify against clean and incremental `lake build` traces; accept each import removal only through a build experiment.

5. **Turn project-wide compile causes into verified rewrites — L.** Extend `elab --why`/`fix --elab` beyond individual declarations. Start with one cross-file instance, unfold or termination cause. Verify measured per-declaration and dependent-module improvements without double-counting overlapping attribution.

6. **Measure compilation memory — M.** Begin with per-file peak RSS and allocator commit during actual builds; add declaration data only where attribution is sound. Risk: profiler-induced allocation and parallel ownership. Verify against external process measurements and known large declarations.

7. **Broaden static copies cautiously; add one closure lint — M/L.** Static coverage is strategically important, but current evidence is examples plus one principal project. Validate false positives and missed copies on unseen code. For closures, verify that specialization removes measured applications and improves or neutrally affects time and allocations.

8. **Implement bounded, cancellable MCP jobs and then `autoresearch` — M.** Mathlib experiments already take many minutes; synchronous calls are inadequate. Verify cancellation, timeout, cleanup, artifact retrieval and recovery after failure. Then test one complete agent improvement loop without adding an agent-evaluation benchmark.

9. **Add toolchain-upgrade comparison — M.** Reuse versioned reports and provenance rather than creating history infrastructure. Verify on pinned adjacent toolchains that regressions are reproducible and correctly separated into elaboration, kernel, compiler and generated-runtime effects.

10. **Reduce core/runtime and source-position blind spots — L.** Precompiled code and declaration-level positions limit diagnosis across all runtime features. Pursue upstream runtime hooks and C line information, or a robust local alternative. Verify known core copies and duplicate source expressions that current text matching cannot distinguish.

### C. Weaknesses to fix

- **Unstable copy counts are judged as exact.** `measure` computes `copies_stable` and says it uses the last run (`LeanprofCli.lean:1661-1672`), but `Judge.Summary` discards that field and compares only totals (`Leanprof/Judge.lean:91-117,195-196`). Record per-run ranges as for allocations; otherwise nondeterministic programs can receive false KEEP/DISCARD verdicts.
- **Measurement coverage does not gate verdicts.** `self_check_warning` is recorded but ignored by `judge`; undercounted copies can therefore support KEEP. Similar ambiguity exists when an empty allocation array means either “counted zero” or “not counted.” Make coverage explicit and fail closed.
- **`editor-on-save` does not really diff per call site.** `Delta.runDelta` keys copies by function/kind/scope, omitting `where`, merging distinct sites. Its global error flag also suppresses “gone” declarations across an entire project. Its `compare --json OUT` contract conflicts with `agent-contracts`’ `compare --json` stdout schema; reconcile rather than shipping both.
- **Precision changes semantics by default.** Automatic repetitions run benchmark regions multiple times, potentially repeating side effects, and fastest-of-N estimates a different quantity from per-process median time. Require an explicit replayable benchmark contract and recalibrate claims. The referenced `bench/verdicts/RESULTS.md` is absent.
- **Retained-memory walks are not safely restricted to quiescent programs.** Automatic peak walks check thread sharing, but `Leanprof.retainedSnapshot` and the exit walk in `c/retained.inc.c` do not. Other threads may mutate or free objects during traversal. Disable or quiesce these walks and exercise snapshot/exit under TSan with active tasks.
- **Provenance is not yet a reliable fingerprint.** `agent-contracts` hashes `git status` plus `git diff HEAD`, omitting untracked-file contents; files over 256 MiB are represented only by size. Include content hashes or explicitly mark provenance incomplete before marking freshness done.

### D. Overstated or unsupported claims

- README says that when threaded counts vary, `judge` compares their ranges (`README.md:352-354`). That is true for allocations, not copies, as the code above shows.
- “Every function with `--auto`” and “Counts are exact in every mode” (`README.md:54`, `docs/guide/run-time.md:169`) need immediate qualification: tiny functions are untimed and uncounted by default, precompiled/runtime paths are invisible, and full tables drop events.
- Heartbeats are repeatedly called “exact,” including `LeanprofElab.lean:1361`, while the documentation reports small run-to-run variation. Prefer “nearly deterministic allocation counts under identical instrumentation.”
- The 2.5% sequential-verdict claim should always carry its independent-pair assumption (`docs/guide/ci-and-regressions.md:411-414`); alternation alone does not establish it, especially under load or fastest-of-N sampling.

