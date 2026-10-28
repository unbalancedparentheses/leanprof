# Autoresearch review (2026-10-27)

Read-only reviews of the ROADMAP section on autoresearch (seven items at the time: differential testing, start from evidence, several candidates at once, compile-time autoresearch on Mathlib, wins that combine, a budget and a stop rule, one command), against `main` at 1cc351b. Kept verbatim. The ROADMAP section "Autoresearch that earns its KEEPs" merges the two orders.

## Codex (codex-cli 0.162.1)

### Review: autoresearch that earns its KEEPs

**Prioritize stronger qualification and cheaper experiments before parallel search or a launcher.** “Never keeps a wrong change” is not achievable for arbitrary programs through finite testing. It can mean: never promote a candidate with failed or incomplete required evidence, preserve audited proof obligations, and state the remaining correctness limits.

Read-only review; no files changed or tests run.

### A. The seven proposals

1. **Differential testing — high value, but generic random inputs are a trap.**  
   The hard part is generating meaningful inputs and defining observable behavior. Thousands of parser rejections provide little coverage; baseline agreement also preserves baseline bugs. Extend `Experiment.runCase` with project-supplied, seeded generators, structured valid inputs, malformed variants, option combinations, and counterexample shrinking. Freeze generators and comparators before search; retain seeds and minimized failures. Compare diagnostics, exit status and declared files, with isolated per-case state. Report coverage categories alongside counts. The [compiler study](docs/case-studies/autoresearch-lean-compiler-backend.md) demonstrates why: 340 comparisons missed the already-SSA validation omission.

2. **Start from evidence — highest immediate search improvement.**  
   The hard part is ranking *actionable interventions*, not attractive counters. Static flags have no measured cost; several flags can inherit the same function-level counts. Include sampled inclusive CPU and caller context: repeated validation produced most of the compiler win, beyond local copy fixes. Rank by plausible benefit, confidence, edit scope and verification cost; refresh after each accepted change. Generate mechanical patches through `fix`, but judge them through the full experiment contract: [standalone `fix`](docs/guide/fix.md) has narrower checking and lacks the proof auditor. Never interpret “97% of copies occur in flagged functions” as 97% precise site attribution.

3. **Several candidates at once — useful later; presently unsafe as a straightforward extension.**  
   `tryCmd` uses one candidate directory, derives attempt numbers from mutable state, and updates the base; `saveState` provides no transaction. `ensureWorktree` shares `.lake/packages`. Parallel calls can overwrite evidence or interfere with dependency builds. Use immutable candidate IDs, isolated writable artifacts, bounded CPU/RSS scheduling, and one serialized promotion transaction. Candidates against an old base must be rechecked after integration. Pause competing builds during timing. Exact counters avoid some timing noise, not nondeterministic execution or OOM.

4. **Compile-time autoresearch on Mathlib — strong opportunity, not inherently safe.**  
   Checking a proof establishes its current proposition; the audit must preserve the original proposition and assumptions. Start with local explicit types/arguments and cheaper proofs before global instance or simp changes. Measure the complete affected closure, report individual regressions, and confirm ordinary build latency and RSS. The [Mathlib study](docs/case-studies/mathlib.md) found large wins, but also profiling-induced heartbeat exhaustion and expensive trace formatting. Reject incomplete profiles; distinguish kernel, elaboration and tracing costs. Do not require all project-wide machinery before trying local improvements.

5. **Wins that combine — necessary for parallel search, partly present already.**  
   Sequential `tryCmd` already advances the base, so later KEEPs include earlier changes. The missing work is integrating independently tested patches and qualifying the final series against the original baseline. Recheck every integrated prefix, preserve its exact base/candidate identities, then run full final qualification. No textual conflict does not imply independence. Ordinary bisection assumes a sufficiently stable, monotone failure; use repeated measurements and subset minimization for performance interactions. Never add individual speedup percentages.

6. **A budget and stop rule — essential, mostly enforcement rather than invention.**  
   [The current instructions](research/program.md) already specify a time budget and ten consecutive DISCARDs. Move enforcement into a supervisor: deadlines, subprocess termination, concurrency caps, provider-reported token usage, and reserved final-qualification time. Count INCONCLUSIVE attempts toward lack of progress; repeated infrastructure errors should stop separately. Avoid stopping while a qualifying job is still running or declaring unfinished candidates accepted. Verify crash recovery and cleanup, not merely that the agent says it stopped.

7. **One command — useful packaging, dangerous if it invents the contract.**  
   Finding an executable is easier than finding representative workloads, adequate tests and observable outputs. Build a preflight that presents a concrete manifest and refuses ambiguous workloads or missing required checks. Pin it for the session; invoke a replaceable agent adapter and existing experiment operations. Provide resume/status/cancel and a final evidence bundle. A launcher that silently selects a trivial workload would manufacture cheap, misleading wins.

Implementation references: [`Leanprof/Experiment.lean`](Leanprof/Experiment.lean), especially `runCase`, `tryCmd`, `ensureWorktree`, `saveState`, `finishCmd`.

### B. Missing ideas, ranked

These are absent from the seven-item list; some already appear elsewhere in the roadmap.

1. **Transactional qualification.** Separate “promising candidate” from final KEEP. Run cheap rejection checks first; expensive full suites may run asynchronously, but promotion waits for every required result. This directly addresses the compiler study’s 26–38-minute suites. Record named baseline failures and skips explicitly; never blanket-waive tests.

2. **Explicit objectives and representative performance suites.** Declare runtime, compile latency or resource reduction as the goal, with per-workload regression limits. Count reductions are useful evidence, not automatically speedups. Measure sizes and modes that expose algorithmic regressions.

3. **Selection-aware confirmation.** Searching many candidates and retrying borderline ones selects lucky measurements. Reserve fresh final measurements, predeclare stopping rules, and calibrate the complete selection procedure with null and seeded changes. This is judge validation, not an agent benchmark.

4. **Proof-backed executable transformations.** Let candidates discharge equivalence against frozen reference definitions and assumptions. For repeated validation, use validated values or explicit preconditions rather than an agent’s assertion that an earlier pass checked everything. Extend the conservative audit narrowly; never weaken it to improve acceptance rates.

5. **Immutable experiment inputs and complete measurement contracts.** Fingerprint source, dependencies, tools, configuration, workloads and measurement modes; validate report completeness and cache compatibility. This supports safe reuse within a session without adding memory of past experiments.

### C. Recommended implementation order

Sizes describe implementation scope, not promised calendar time.

| Order | Work | Size | Evidence it worked |
|---|---|---|---|
| 1 | B5: fail-closed reports, fingerprints and cache checks | M | Missing metrics, partial profiles, changed dependencies and unstable counters cannot KEEP. |
| 2 | B1: transactional qualification; unify fix/experiment checks | L | A late test/held-out failure prevents promotion; interruption preserves a recoverable qualified head. |
| 3 | B2: objectives and performance suites | M | Fixtures distinguish count-only wins, real speedups and secondary-workload regressions. |
| 4 | A6: enforced budgets and cancellation | M | Hung builds/tests terminate; finalization reserve and total spending limits hold. |
| 5 | A1: differential adapters and shrinking | L | Seeded semantic bugs, including omitted validation paths, produce reproducible minimized failures. |
| 6 | B3: independent confirmation and calibration | M | Publish false-KEEP, detection, inconclusive and cost rates across whole searches. |
| 7 | A2: evidence-ranked proposals | M | Real sessions spend fewer model tokens and build minutes per qualified win; publish failed attempts too. |
| 8 | A4: focused Mathlib campaign | M | Preserved obligations, affected-module builds, repeatable plain-build improvements and RSS measurements. |
| 9 | B4: narrow equivalence support | L | Valid implementation changes pass; weakened specifications and added assumptions fail. |
| 10 | A5: series integration and qualification | M | Interacting fixtures identify the failing subset; final series passes original-baseline checks. |
| 11 | A3: bounded parallel candidates | L | Serial/parallel verdict agreement, race tests, isolation, and lower cost per qualified win. |
| 12 | A7: launcher | M | An unfamiliar runtime project and proof library complete setup, interruption/resume and qualification. |

### D. Current risks these features must not worsen

- **Fail-open measurements:** `Judge.Summary.ofJson` defaults missing numeric fields to zero and output stability to true; it ignores copy stability and self-check warnings. `Experiment.heartbeatsOf` accepts missing scopes as an empty map. Incomplete evidence can resemble improvement.
- **Proxy wins:** `Experiment.combine` can KEEP reduced counts with unsettled timing. Timing covers only `s.cases[0]`; heartbeat judgment uses totals, allowing local regressions.
- **Qualification is advisory:** `finishCmd` reports held-out failure but leaves KEEP commits intact. It does not revalidate input hashes, rerun full tests, or establish a clean original-to-final speedup.
- **Evidence can become stale:** tests execute after the audit without a final source-fingerprint check. Shared dependencies, retained builds and package-C equality do not establish complete artifact identity.
- **Audit scope is limited:** dependent selection uses handwritten import parsing and requires existing build artifacts. The [audit](docs/guide/proof-audit.md) does not establish executable equivalence or cover every downstream consumer.
- **Behavioral checks have blind spots:** ignored output lines, undeclared side effects and weak workloads can hide changes. Held-out secrecy is an instruction to the agent, not enforced isolation.
- **Claims must track revisions:** the corrected compiler result is **22.21% lower median wall time**; original allocation counts concern the earlier candidate. Neither that result nor near-repeatable heartbeats warrants universal correctness or speed claims.

## Kimi (k3.1-pro)

### Autoresearch review

“Never keeps a wrong change” is not obtainable from finite testing. The achievable design is conservative automatic KEEP, explicit evidence limits, and mandatory final qualification. The seven items are directionally good, but scaling candidates before fixing verdict validity would scale false confidence.

### A. The seven items

1. **Differential testing — worth doing, with domain-specific generators.**  
   The hard part is reaching meaningful behavior: random bytes mostly exercise parsers’ rejection paths, while equal stdout misses unlisted files, hangs, external effects, and removed validation. Generators and the corpus must be immutable and created before candidates; compare exit status, stdout/stderr, declared outputs, and resource bounds, with per-case timeouts. Reuse `Experiment.runCase` and `CaseSig` rather than creating another comparator (`Leanprof/Experiment.lean:237`, `:413`). Run a cheap corpus per try and larger generated/held-out corpora before final acceptance. Reusing `research/lcb/compare.py`’s malformed-input model is more credible than claiming generic fuzzing. Report cases and coverage, never “thousands passed, therefore correct.”

2. **Start from evidence — highest value per dollar.**  
   The hard part is turning overlapping attribution into interventions: static flags are possibilities, inclusive sampled costs overlap, and a mechanical copy fix can increase allocations or time, as `docs/guide/fix.md` demonstrates. Produce typed targets containing observation, source fingerprint, expected metric, semantic constraints, and validation cost. Rank measured `Explain.findingsOf` results first, sampled inclusive CPU for repeated cross-pass work, then unconfirmed static flags. Route only `Fix.plansFor`-supported rewrites through the no-model path (`Leanprof/Fix.lean:236`). **Do not accept `leanprof fix` alone:** its guide admits only one workload, and the proof audit is not wired into it. Every resulting patch still needs `experiment try`.

3. **Several candidates at once — useful only after isolation.**  
   Current `tryCmd` is not concurrent-safe: it shares the candidate worktree, mutable base, try numbering, and refs (`Leanprof/Experiment.lean:589`, `:759`). Shared `.lake/packages` and unbounded Lake parallelism add further interference. Use an external scheduler with one immutable base revision, separate experiment IDs/worktrees, bounded build jobs, and no KEEP directly from racing branches. Reapply promising patches to the latest base and serially rerun the complete gate. Only paired timing must be exclusive. “Exact” does not mean universally stable: threaded counts vary, heartbeats vary slightly, and instrumentation coverage can be incomplete.

4. **Compile-time autoresearch on Mathlib — best near-term source of real wins.**  
   Lean checking plus the audit is a strong combination, and the two documented Mathlib patches show large reductions. The traps are enormous dependent closures, ten-minute traced elaborations, overlapping costs, and confusing heartbeats with elapsed build time. Start with declaration-local transformation families such as explicit numeral types and auto-parameter annotations. `Experiment.heartbeats` already selects changed modules and dependents (`Leanprof/Experiment.lean:936`), but `Judge.judge` totals them, allowing one module’s win to hide another’s regression (`Leanprof/Judge.lean:216`). Require per-module non-regression, unchanged proof obligations, clean ordinary `lake build` timing, and reviewable patches. Do not predict savings by summing overlapping `elab` attribution.

5. **Wins that combine — necessary, but avoid combinatorial search.**  
   Parallel candidates against one base can interact semantically and mechanically; individually significant timing wins also accumulate selection bias. Keep immutable per-candidate evidence, test the series against the original baseline, and retain per-commit relative-to-parent evidence. Use a greedy series, bisecting only when the combination fails—never enumerate subsets. `Experiment.keep` already advances the base (`Leanprof/Experiment.lean:818`), but `finish` only adds held-out behavior checks; it is not a complete original-base/final-head performance and correctness qualification.

6. **A budget and stop rule — small, essential, external to leanprof.**  
   Put wall-time, candidate, token, and per-stage process-group limits in the runner; leanprof cannot observe an agent’s token spend. Stop immediately on ERROR, after N consecutive non-KEEPs, and reserve time for `finish` and final qualification. Count all generation, rejected builds, tests, timing, and qualification in cost per verified win. The existing ten-DISCARD instruction (`research/program.md:156`) should become enforced runner policy, with run-local state only—not persistent memory inside leanprof.

7. **`leanprof autoresearch` as one command — package it last.**  
   The trap is pretending an unseen project reveals its semantic contract automatically. Executable choice, meaningful inputs, output files, expected failures, and baseline test failures require discovery or explicit confirmation; ambiguity must stop, not select `--no-test`. The command should orchestrate existing `experiment start|try|finish`, enforce budgets/cancellation, and optionally launch the external `research/program.md` agent. It should contain neither an LLM nor experiment history. A setup-only/dry-run mode and stable typed JSON contracts are prerequisites.

### B. Missing additions, ranked

1. **A valid optimization contract:** explicit primary objective and resource limits, fail-closed coverage, and timing of every declared performance workload—not merely correctness-checking every case.
2. **Selection-aware measurement:** predeclared trial protocols, no rerun-until-KEEP, and false-KEEP/inconclusive/cost measurements across the whole search, not just one paired session.
3. **Independent final qualification:** clean original-base/final-head builds, complete tests and corpora, plus adversarial semantic review. The LCB removed-validation bug survived 540 output comparisons.
4. **Equivalence discharge for conservative INCONCLUSIVEs:** accept verified implementation changes when a preserved theorem proves equality with the original specification; otherwise remain INCONCLUSIVE. This expands usable wins without weakening the audit.

### C. Recommended implementation order

| # | Work | Size | Verification |
|---|---|---:|---|
| 1 | Valid objectives, coverage, multi-workload verdicts | L | Malformed/missing metrics cannot KEEP; nondeterministic counts fail closed; seeded regressions on every performance case are rejected. |
| 2 | Evidence-ranked targets and mechanical routing | M | Fixtures order measured mechanical fixes first; every fix still passes the experiment guard; record agent calls saved. |
| 3 | Differential testing | L | Seeded wrong changes on unseen valid/malformed inputs are caught; corpus hashes, timeouts, and compared channels appear in evidence. |
| 4 | Enforced budget/stop runner | S | Fake-clock/token tests stop correctly; cancellation leaves no jobs/worktrees; reports include total cost per qualified win. |
| 5 | Selection-aware verdict protocol | M | Fixed seeded trials publish false-KEEP and detection rates; repeated sessions cannot be silently presented as independent confirmation. |
| 6 | Final qualification and semantic review | M | Clean base/head fixture reproduces full checks; an LCB-style validation removal is rejected despite matching sampled outputs. |
| 7 | Combined-win validation/bisection | M | An A-good/B-good/A+B-bad fixture is bisected; final series evidence refers to the original baseline. |
| 8 | Mathlib loop | L | Reproduce known heartbeat wins, show no dependent-module regression, and confirm ordinary-build wall improvement on clean checkouts. |
| 9 | Parallel candidate scheduler | M | Stress tests show no shared-state races; stale-base winners are revalidated; timings never overlap. |
| 10 | Equivalence discharge | L | Proven-equivalent implementations pass; unequal or unproved implementations cannot KEEP. |
| 11 | One-command packaging | M | Fresh unfamiliar-project runs test discovery, ambiguity refusal, one complete improvement, cancellation, and cleanup. |

### D. Existing risks these features must not worsen

- **Fail-open evidence:** `Judge.Summary.ofJson` defaults missing metrics to zero, `outputStable` to true, and overload to false (`Leanprof/Judge.lean:91`). Copy stability and self-check/coverage warnings are not verdict gates.
- **Proxy “speedups”:** `Experiment.combine` can KEEP an exact-count improvement while timing is unsettled (`Leanprof/Experiment.lean:208`). Only `s.cases[0]` is timed (`:1012`), and compile heartbeats are totaled across modules. These are not universal runtime improvements.
- **Scoped correctness:** the audit preserves selected proof obligations, not executable equivalence or validation branches. `no_theorems` can pass modules whose behavior rests entirely on tests; `fix` lacks the audit.
- **Statistical selection:** the paired interval assumes independent pairs and one valid sequential session. Parallel experimentation, optional retries, and choosing the best of many candidates invalidate naïve per-trial confidence claims.
- **Incomplete behavior observation:** checks cover supplied cases, declared files, and non-ignored output lines only. Held-out success is still evidence, not proof. Claims must retain the LCB distinction between reviewed results, clean-build qualification, and independent replication.

