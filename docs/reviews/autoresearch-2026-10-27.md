# Autoresearch review (2026-10-27)

Read-only reviews of the ROADMAP section on autoresearch (seven items at the time: differential testing, start from evidence, several candidates at once, compile-time autoresearch on Mathlib, wins that combine, a budget and a stop rule, one command), against `main` at 1cc351b. Kept verbatim. The ROADMAP section "Autoresearch that earns its KEEPs" follows the order below.

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