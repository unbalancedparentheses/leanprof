# Experiments: `leanprof experiment`

You changed a Lean project to make it faster, or an agent did. Is the change
an improvement, and does it still do what the project promised? The checks
are always the same: it builds, the proofs still prove what they proved,
the tests pass, the program behaves the same on every input, and something
measurable got better while nothing got worse. `leanprof experiment` runs
all of them, in that order, and returns one verdict with its evidence:

```
leanprof experiment start --exe myapp --inputs inputs/ --heldout heldout/ -- ARGS
# change the code
leanprof experiment try --working-tree     # or: leanprof experiment try REV
# ... more changes, more tries
leanprof experiment finish
```

For a library with no executable, leave out `--exe`: the measure is then
the compile heartbeats of the modules a change touches and of their
dependents (exact, no timing noise).

```
leanprof experiment start
leanprof experiment try --working-tree
```

| verdict | exit code | meaning |
|---|---:|---|
| KEEP | 0 | every check passed and something improved beyond noise; the candidate becomes the base |
| DISCARD | 1 | a check failed (build, guard, tests, outputs), something got worse, or nothing improved |
| ERROR | 2 | the experiment could not decide (the base no longer builds, measuring failed, an input changed) |
| INCONCLUSIVE | 3 | no check failed, but the evidence cannot support a KEEP: the guard could not establish that the proofs are preserved, or the time was not settled and nothing else improved |

Every try writes `tries/N/evidence.json` in the experiment's directory
(`.lake/leanprof/experiments/ID/`), with each step's result, and prints a
summary. `--json` prints the evidence instead, for agents.

## `start`: the baseline

`start` records the base (HEAD, or `--base REV`) once. It makes a git
worktree of it in `.lake/leanprof/experiments/ID/base`, never touching your
checkout, and records:

- **the build**: `lake build` (the default targets, so the library and its
  proofs) and `lake build EXE`;
- **the tests**: `--test CMD` (run with `sh -c`), or `lake test` when the
  project has a test driver (`--no-test`: none);
- **the behaviour on every case**: stdout, stderr, exit code, and the hash of
  each `--check-output FILE` (repeatable), each case run twice (a case whose
  output differs between two runs of the base is refused: make it
  deterministic, compare a file instead, or leave out the lines a benchmark
  prints its own timings on with `--ignore-lines TEXT`, repeatable: lines of
  stdout and stderr containing TEXT are not compared, also by `measure` and
  `measure-pair`). The cases are `ARGS` (the timed
  workload), `ARGS` with each file of `--inputs DIR` in place of `{}` (or
  appended when `ARGS` has no `{}`), and each line of `--cases FILE` (one
  argument list per line: several workload sizes, option combinations,
  malformed inputs);
- **the held-out cases**: the files of `--heldout DIR`, recorded as hashes
  only and run by `finish`, so a change cannot be tuned to them;
- **exact counts and time**: `leanprof measure` of the workload (`--runs N`,
  default 3), and a copy of the plain binary for paired timing.

The input files' hashes are recorded; a try refuses to run (ERROR) if one
changed. Input directories inside the repository are protected: a candidate
that edits them is refused.

## `try`: one candidate

`try REV` checks a commit; `try --working-tree` checks your working tree
(tracked changes and untracked files that are not ignored), taken as a commit
with a separate index, so your checkout, index and stash are not touched.
The candidate is checked out in a worktree of its own
(`.lake/leanprof/experiments/ID/candidate`), which keeps its build between
tries and starts from the base's: each try rebuilds only what the candidate
changed. Each step runs only if the one before passed:

1. **Build**: `lake build` and `lake build EXE`, then every built module of
   the package that imports a changed one (a test module whose `#guard`s now
   fail). A failure is a DISCARD.
2. **Guard**: the [proof-preservation audit](proof-audit.md) of the changed
   modules and of every module of the package that imports them (see below).
3. **Tests**: they must pass.
4. **Outputs**: every case must behave byte for byte as the baseline did
   (stdout, stderr, exit code, output files). The verdict names each case
   that differs and its first differing line.
5. **Compiled code**: when every C file Lean generated for the package
   (`.lake/build/ir`) is the base's, the program cannot run any differently,
   so nothing is timed or counted (unless `--time`): the measure becomes the
   compile heartbeats of the changed modules, as for a library. A change to
   proofs only is judged in seconds.
6. **Exact counts**: `leanprof measure` of the workload with probes. If
   copies or allocations went up, it is a DISCARD and no time is spent on
   timing. Call counts are listed, not judged.
7. **Timing**: `leanprof measure-pair` of the two plain binaries, in AB/BA
   pairs, stopping once the time verdict is settled (at most `--pairs N`,
   default 30, given to `start`).

Exact counts and time are measured on the workload, the first case (`ARGS`,
or `ARGS` with the first input), and every verdict says so: "exact counts
and time measured on case 0 only (...); the other N case(s) were checked for
identical behaviour, not timed". A change can therefore be faster on the
workload and slower on another case without a DISCARD. `start
--time-all-cases` times every case in pairs instead: slower on any case is a
DISCARD, an unsettled case leaves the verdict INCONCLUSIVE unless something
else improved, and each reason names its case. It costs one paired session
per case.

The verdict: DISCARD if the paired time is slower; KEEP if copies or
allocations went down (exact) or the paired time is faster; INCONCLUSIVE if
nothing changed beyond noise and the time was not settled (the machine was
overloaded, or more pairs were needed); otherwise DISCARD. Time is judged as
by [`judge`](ci-and-regressions.md#interleaved-timing-of-ordinary-binaries):
a 95% median interval, at least `--min-change` percent (default 1).

A library's verdict comes from heartbeats: KEEP when the total of the
changed modules and their dependents went down by more than 1% and 1,000,
DISCARD otherwise. In a large module 1% can be more than a whole
declaration, so a change is also kept when, declaration by declaration, some
went down by more than 1% and 1,000 each, none went up by as much, none
appeared or disappeared, and the total went down by more than 1,000
(heartbeats are exact, so this needs no noise margin beyond the one for
neighbours that move by a few heartbeats when one declaration is edited).
The base's heartbeats are cached by commit.

The guard imports the audited modules together; modules that cannot be
imported together (Batteries' test modules each declare `foo`) are imported
one at a time and their evidence put together.

### The guard

In Lean the cheapest "speedup" deletes a proof obligation. The guard runs
the proof-preservation auditor (`scripts/proof-audit/audit.py`, compiled into
the command) on the base and candidate worktrees. It compares the compiled
declarations, not the source text, so comments and strings never trigger it.

| the candidate | guard | verdict |
|---|---|---|
| changes a test (`tests/`, `Tests/`, `test/`), an expected output (`expected/`), an input of the experiment, or a `--protect GLOB` | FAIL | DISCARD |
| adds `sorry`, an `axiom`, or a dependency on a new axiom (`native_decide`'s `Lean.ofReduceBool` included) | FAIL | DISCARD |
| adds `@[implemented_by]`, `@[extern]`, `unsafe` or `partial` (also on an imported declaration) | FAIL | DISCARD |
| removes a theorem or changes a declaration's kind | FAIL | DISCARD |
| changes a theorem's statement, or a definition a statement uses | INCONCLUSIVE | INCONCLUSIVE |
| changes a file that is not a Lean module of the package (a script, a lakefile, the toolchain, the manifest) | INCONCLUSIVE | INCONCLUSIVE |
| rewrites proofs, renames binders, changes definitions no statement uses | PASS | (next step) |

Declarations Lean generates (a tactic's `_proof_1` lemma, equation lemmas,
matchers, `_unsafe_rec`) are not obligations: a rewritten proof may remove
them; their axioms are still checked. When the audited modules state no
theorem at all, the auditor's `no_theorems` finding is accepted alone: there
is no statement to weaken, and the other checks still ran.

The guard is conservative. A candidate that optimizes a verified function
whose theorems mention it (`theorem fast_eq_spec : fast = spec`) is
INCONCLUSIVE, since the statement now speaks of the new `fast`: the auditor
cannot tell an implementation from a specification. Review such a change by
hand; the evidence file lists each finding.

It needs `python3`. The auditor runs `lake build` on the audited modules and
`lake env lean --run` with its collector in both worktrees; modules must be
in Lake's default layout (`Foo/Bar.lean` is `Foo.Bar`), and files under an
executable's `srcDir` are not audited (a change to one is INCONCLUSIVE).

### KEEP

The candidate becomes the base: the next try is judged against it, and its
`measure` summary and binary become the base's. Evidence goes into git:

- from `--working-tree`, the tree that was checked is committed on your
  current branch (hooks off), with the summary of every step in the message
  (`--message MSG` for its subject; `--no-commit` to leave it uncommitted).
  It is committed only if HEAD has not moved since the try began;
- for a commit, a note is added (`git notes --ref=leanprof-experiments show
  REV`).

Every candidate stays reachable as `refs/leanprof/experiments/ID/try-N`.

## `finish`: held-out inputs

`finish` builds the final base and runs the held-out cases, which no try
saw, and compares their stdout, stderr, exit code and output files with the
baseline's. Exit 1 if any differs: the kept changes preserve behaviour on
the inputs they were checked on, not beyond them. It then removes the
worktrees (`--keep-worktrees` keeps them) and writes `finish.json`.

`leanprof experiment status [--json]` prints the experiment and its tries.
Several experiments may exist; the last one started is the current one,
`--id ID` picks another.

## On a real project: lean-regex

[lean-regex](https://github.com/pandaman64/lean-regex) at `32af6f3` (the
commit CI pins), a verified library with its Lake package in `regex/` and a
`Bench` executable that prints its own timings, on a fresh clone (Apple M-series,
2026-10-26):

```
cd regex
leanprof experiment start --id regex2 --exe Bench --inputs ../inputs --cases ../cases.txt \
  --heldout ../heldout --ignore-lines "Ran " --ignore-lines "Average time" -- -e '\w+' '{}'
```

Eight cases: `\w+` on three files (1.5 MB of Lean's `Init/Data`, `Prelude.lean`,
a tiny file), and five more lines of `cases.txt` (`_lt`/`_le` names, numbers,
declarations, `x*` with empty matches, and the malformed pattern `(`); one
held-out file. `start` took 12 s. The candidates, each a local commit:

| candidate | verdict | why | time |
|---|---|---|---:|
| `Regex.count` counts the matches instead of building `findAll`'s array | INCONCLUSIVE | guard PASS (5 modules, 144 theorems), tests pass, outputs identical on 8 cases, exact counts unchanged; paired time −1.61%, 95% interval [−2.10%, −0.72%] after 30 pairs: faster, but not settled beyond the 1% `--min-change` | 34 s |
| the same, skipping empty matches | DISCARD | the test module that imports `Regex.count` no longer builds (four `#guard`s on `empty.count`) | 4 s |
| the same, with a `sorry` in `Matches.lt_next?_some` | DISCARD | guard: `sorry_dependency` on the theorem and on `count`, `findAll`, `split`, … (44 findings) | 11 s |
| a comment only | DISCARD | the 50 generated C files are the base's: nothing timed; heartbeats unchanged | 29 s |

An earlier run of the same `count` candidate gave −2.44%, [−4.44%, −1.01%] after
20 pairs, a KEEP: the effect is about 2%, close to the 1% floor, and two runs on
one shared machine landed on either side of it. That is what INCONCLUSIVE is
for; a quiet machine, more pairs, or a larger effect decides it. Candidate
builds took 1–2 s, since the base's build is kept.

## Limits

- One configuration: a candidate that changes `lakefile.*`,
  `lake-manifest.json` or `lean-toolchain` is INCONCLUSIVE before it is built
  (the worktrees share the project's `.lake/packages`).
- The project must be committed in git, and its `.lake` directory ignored.
- Correctness is checked on the cases you give, not proven; give many, of
  several sizes, and keep some held out.
- Time verdicts come from one machine. Run under a quiet machine, or rely on
  the exact counts.

## In an agent loop

[`research/program.md`](../../research/program.md) is the autoresearch
loop built on this command. Through MCP the same operation is
`experiment_start`, `experiment_try`, `experiment_finish` and
`experiment_status` ([MCP server](live.md#mcp-server)); `experiment_start`
takes no shell command for tests (it uses the project's Lake test driver),
and every path it is given must be inside the project.

`scripts/experiment-check.sh` runs the whole operation in CI on
[`Tests/Experiment`](../../Tests/Experiment): a known-good change (KEEP,
committed), a change that alters one input's output (DISCARD), a `sorry`,
a weaker statement and a loosened test (DISCARD, INCONCLUSIVE, DISCARD),
a proof-only change (no timing), a held-out difference found by `finish`,
and a library experiment judged by heartbeats.
