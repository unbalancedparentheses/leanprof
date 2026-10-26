# Autoresearch on a Lean project

You are an agent improving the performance of a Lean 4 project: the run time
of a compiled program, or the compile time of a library. You work in a loop:
change the code, try it, and keep the change only if `leanprof experiment
try` says KEEP. leanprof does the checking, the measuring and the judging;
your job is to choose good experiments and make them correctly.

In the commands below, `leanprof` means `lake exe leanprof` in a project that
depends on leanprof, or `/path/to/leanprof/.lake/build/bin/leanprof` in any
other Lake project (it compiles its runtime for the project's Lean version;
no lakefile changes are needed). The command is described in the
[experiments guide](../docs/guide/experiment.md); over MCP it is the
`experiment_start`, `experiment_try`, `experiment_finish` and
`experiment_status` tools.

## Setup (once)

1. Agree with the human on the **target**:
   - a program: the executable `EXE` and its arguments `ARGS`, a workload
     that runs for at least ~10 ms, so time is measurable;
   - or a library (no `EXE`): the measure is the compile heartbeats of the
     modules each change touches and of their dependents;
   - the **inputs** the program must keep behaving the same on: a directory
     `INPUTS` of input files (each is passed in place of `{}` in `ARGS`, or
     after them), and/or a file `CASES` with one argument list per line
     (several workload sizes, option combinations, malformed inputs:
     diagnostics are behaviour too);
   - a directory `HELDOUT` of further inputs that **you do not read**: they are
     run only at the end, to catch changes tuned to the inputs you saw;
   - the output files to compare besides stdout and stderr (`--check-output
     OUT`, when the program writes its result to a file), and the lines it
     prints that vary between runs, such as its own timings (`--ignore-lines
     TEXT`: lines containing TEXT are not compared);
   - the test command `TEST` (default: `lake test` when the project has a test
     driver), any other paths no change may touch (`--protect GLOB`), and the
     time budget.
2. Create a branch: `git checkout -b autoresearch/<date>-<topic>`, with a clean,
   committed tree (`.lake` ignored).
3. Start the experiment. Its settings are **fixed for the whole session**:

   ```
   leanprof experiment start --exe EXE --inputs INPUTS --cases CASES --heldout HELDOUT \
     --check-output OUT --test TEST -- ARGS
   leanprof experiment start --test TEST          # a library: compile heartbeats
   ```

   It records the baseline in a git worktree: the build, the tests, the
   behaviour on every case (refusing a case whose output varies between runs:
   make it deterministic or compare a file), the held-out results as hashes,
   and `leanprof measure`'s exact counts and time.

4. Create `research/results.tsv` (untracked: add it to `.git/info/exclude`)
   with the header (see below).

## The loop

Repeat until the time budget is spent:

1. **Look.** Read the last report and choose one hotspot:
   - `.lake/leanprof/report.json` (from `leanprof run --json ...`) lists copies
     of shared values per function; each one copies a whole `Array`,
     `ByteArray` or `String`. With allocations counted (`run --allocs`), it
     lists allocations per function too. Each row has `pct_run`, its share of
     the run: pick findings by that, not by counts (20,000 copies at 0.02% of
     the run are not worth an experiment; allocations at 1% rarely are).
   - `leanprof explain --json` reads that report and prints the copy sites
     as ranked findings: `cause` (`nested-array-element`,
     `map-value-reinserted`, `stored-then-updated`, `multi-threaded-global`,
     `loop-over-updated-array`, or a general one), `file` and `lines`, `why`,
     `fix`, and `fix_code`: the rewrite as Lean code with the program's own
     names (alternatives; apply one), plus `copies` and `estimated_cost_ns`
     (time spent copying at that site). A finding with `fix_code` is the
     cheapest experiment to try first; the fixes for the recognised causes
     are tested to remove the copies. For three causes (`nested-array-element`,
     `map-value-reinserted`, `loop-over-updated-array`), `leanprof fix --exe
     EXE -- ARGS` applies the code and checks it on a branch of its own
     ([guide](../docs/guide/fix.md)).
   - `leanprof sample EXE -- ARGS` shows CPU time per Lean declaration and
     what the runtime spent its time on (copying, freeing, allocation, ...).
   - `leanprof elab --heartbeats FILES` shows compile cost per line and
     repeated work (the same instance problem solved many times, ...).
   - `leanprof run --auto EXE -- ARGS` times every function exactly.
2. **Change one thing.** One idea per experiment, as small as possible:
   remove an extra reference so an update happens in place, change a data
   structure, avoid recomputation, add a missing instance, a cheaper proof,
   ... Write down the idea before editing.
3. **Try it**: `leanprof experiment try --working-tree --message "<idea>"`
   (`--json` prints the evidence). It checks the working tree in a worktree
   of its own, each step only after the one before passed: build (the
   library's proofs included), the proof-preservation guard, the tests,
   identical behaviour on every case, then the measure. Its exit code:
   - **0, KEEP**: the change is committed on your branch, with the evidence
     in the commit message, and becomes the base the next try is judged
     against;
   - **1, DISCARD**: `git checkout -- . && git clean -fd` (or `git reset
     --hard`), and log why (the first reason it printed);
   - **3, INCONCLUSIVE**: not kept. Read the reasons: the guard could not
     establish that a theorem statement is preserved (show the change to the
     human; do not rewrite the theorem to get past it), or the time was not
     settled and nothing else changed (discard it, or ask the human for more
     pairs or a quieter machine);
   - **2, ERROR**: stop and ask the human (the base no longer builds, an input
     changed, measuring failed).
4. **Log** one row in `research/results.tsv`, KEEP or not.

At the end, `leanprof experiment finish` runs the held-out inputs on the
final branch. If they differ (exit 1), a kept change preserved behaviour
only on the inputs it was checked on: find it (each KEEP is a commit;
`git bisect` with the program on the held-out input) and revert it.

### What `try` decides

DISCARD when any of these hold:

- the candidate does not build, or its tests fail;
- the guard fails: it changes a test, an expected output or an input; adds
  `sorry`, an `axiom` or a dependency on a new axiom (`native_decide`
  included), `@[implemented_by]`, `@[extern]`, `unsafe` or `partial`; or
  removes a theorem. The guard reads the compiled declarations, so comments
  and strings do not trigger it;
- stdout, stderr, the exit code or a checked output file differ on any case;
- copies of shared or multi-threaded values went up, or allocations by
  compiled Lean code went up (exact counts; then nothing is timed);
- the paired time of the plain binaries is slower (a 95% median interval
  above `--min-change`, default 1%);
- for compile time: heartbeats went up by more than 1% and 1,000;
- nothing improved.

INCONCLUSIVE when the guard cannot establish preservation (a theorem
statement, or a definition one uses, changed; a file outside the Lean
modules, such as a lakefile, changed), or when nothing changed beyond
noise and the time was not settled.

KEEP when nothing above holds and copies went down, allocations went down
by at least 1% and 100, the paired time is faster, or (a library, or a
change after which the generated C is the base's, such as a proof rewrite)
heartbeats went down by more than 1% and 1,000. Call counts are listed but
not judged, since restructuring code changes them legitimately.

## results.tsv

Tab-separated, one row per experiment, never rewritten:

```
commit	verdict	copies	time	description
1001bbb	KEEP	2999 -> 0	-58.1%	keep a running sum instead of every prefix
-	DISCARD	0 -> 0	+0.3%	add each element before counting its prefix
-	DISCARD	-	-	use a HashMap for the memo table (outputs differ on inputs/empty.txt)
```

`commit` is the KEEP commit and `-` otherwise; the numbers come from the
evidence (`leanprof experiment status --json` lists every try and its
evidence file).

## Rules

- **Never weaken tests or proofs** to make a change pass: do not delete or
  loosen tests, add `sorry`, `axiom`, `@[implemented_by]` or `unsafe` shortcuts,
  or `partial` in place of a termination proof. The guard refuses these; do
  not look for ways around it.
- **Never change the experiment**: its settings, the inputs, the output being
  checked, and never read the held-out inputs. If the workload is wrong, stop
  and ask the human.
- **One idea per experiment**, so each verdict says which idea helped.
- **Do not edit** leanprof, `lakefile`, `lean-toolchain` or dependencies
  unless the human asked for it (`try` calls such a change INCONCLUSIVE).
- **Respect the time budget**: stop when it is spent, or after 10
  consecutive DISCARDs, and summarize what was kept, what was tried and
  what you would try next.
- Leave the branch with only KEEP commits and a clean tree, and run
  `leanprof experiment finish`.

## Qualify a kept branch before merging

`experiment finish` reruns the held-out inputs; it does not replace a review.
Build the original baseline and final candidate from clean checkouts. Check the
whole branch on inputs and option combinations beyond the optimization workload,
including malformed inputs: diagnostics and refusal behavior are part of the
contract. Run the full test suite on both under the same pinned toolchain. If a
host-specific baseline failure exists, record it by test name and compare the
candidate's failure and log; do not turn it into an unexplained skipped test.

Review every removed validation against all return paths of the function said
to guarantee it. In the compiler case study, SSA construction validated renamed
functions but returned already-SSA functions unchecked. A focused regression
test caught the missing check even though hundreds of CLI comparisons passed.

Confirm speedups on ordinary binaries without probes on a quiet machine:
`leanprof measure-pair --base BASE_BINARY --candidate NEW_BINARY --out
paired.json -- ARGS`, then `leanprof judge paired.json` (see the
[paired measurement guide](../docs/guide/ci-and-regressions.md#interleaved-timing-of-ordinary-binaries));
`try` does this per experiment, against the previous base. A confidence
interval from one machine does not cover other workloads or platforms. Keep
allocation reductions separate from runtime speedups. The
[LCB qualification scripts](lcb/README.md) provide a concrete example.

## Demo

`research/demo/run.sh` runs the loop's underlying commands (`measure`,
`judge`) with two scripted experiments instead of an agent (one that removes
hidden copies, judged KEEP; one that changes the output, judged DISCARD) on a
copy of `research/demo/project`. `scripts/experiment-check.sh` runs `leanprof
experiment` itself on `Tests/Experiment`, with candidates for each verdict.
CI runs both.
