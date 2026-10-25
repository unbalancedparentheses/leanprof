# CI, regressions and autoresearch

## Compare two reports

```
leanprof compare [--threshold PCT] [--min-ms MS] BASE.json NEW.json
```

exits 1 on a regression:

- **copies**: any increase (exact, so no noise);
- **allocations** (when both reports counted them, `run --allocs`): an
  increase of the total (exact; per-site changes are listed, but inlining
  and refactoring move allocations between sites);
- **calls**: any change;
- **compile heartbeats** (reports from `leanprof elab --heartbeats`): an
  increase above 1% and 1,000 heartbeats;
- **time**: slower by more than `PCT` percent (default 10) and `MS`
  milliseconds (default 1).

A CI job can keep a baseline report and fail when a change makes the program
copy more or a proof more expensive to check:

```
leanprof run --json new.json myapp -- bench-input
leanprof compare baseline.json new.json
```

### Why it got worse

For each declaration whose heartbeats regressed, `compare` (and the
Action's comment) also says what changed inside it, from what the two
`elab` reports record about that declaration:

- the constants credited with its work: definitions `isDefEq` unfolded and
  `whnf` reduced, instances tried, simp lemmas that rewrote, each with the
  heartbeats of the work it caused and how many times;
- its repeated operations (the same instance search or unification done
  more than once);
- with `elab --counts` on both commits, Lean's exact `diagnostics` counters
  for it: declarations unfolded by the elaborator and by the kernel,
  instances used, simp lemmas used and failed, theorems `grind`
  instantiated.

Each comes with its `file:line` and its base and head values, increases
first. Counts do not vary between runs; heartbeats nearly so (in the
Batteries example below, four profiles of the same commit gave the
regressed declaration totals up to 370 heartbeats apart, in about 876,000),
so a constant credited with less than 1,000 heartbeats more, as often as
before, is listed after the real changes and never named as the cause. When
nothing recorded changed, the explanation says so ("cause not attributed")
and names where the change is (elaboration, kernel, compiler, linters);
operations under the profiler's threshold (10,000 heartbeats by default,
`--threshold` lowers it) are not timed, so their heartbeats count in the
operation around them, but `--counts` still counts them. Heartbeats
credited to different constants overlap (reducing `Decidable.decide`
reduces the definition it evaluates), so they need not add up to the
change. Each list keeps the 20 largest entries per declaration (10 per
counter); a constant missing from a full list is shown as "not listed",
never as 0.

```
leanprof elab --heartbeats --counts --out base-elab.json Foo.lean   # on the base commit
leanprof elab --heartbeats --counts --out head-elab.json Foo.lean   # on the change
leanprof compare base-elab.json head-elab.json
```

```
why (what changed inside each declaration that got more expensive; counts are exact, heartbeats nearly so)
  Regress.lean unfold_case (Regress.lean:21): 6.95 kHB -> 57.47 kHB  [elaboration +50.53 kHB]
    whnf reduces Decidable.decide (Init/Prelude.lean:1158): 0.00 kHB, 0× -> 46.40 kHB, 1×  (+46.40 kHB)
    whnf reduces tri (Regress.lean:11): 0.00 kHB, 0× -> 46.16 kHB, 162×  (+46.16 kHB)
    unfolded (count) Add.add (Init/Prelude.lean:1638): 1 -> 144  (+143)
    unfolded (count) tri (Regress.lean:11): 1 -> 72  (+71)
    …
```

(`Tests/Regress`: `tri` went from a closed form to a recursive definition,
so `decide` in `unfold_case` reduces it 72 times.)

For copies, `--explain HEAD_EXPLAIN.json` adds `leanprof explain`'s cause
to each call site that copies more (run `leanprof explain --report
head.json --top 1000 --out head-explain.json` in the head checkout, where
its emitted C is). An `explain.json` of another run is refused (its counts
do not match). Allocation sites that allocate more are listed without a
cause: explain explains copies, and says only whether the same function
also copies more.

### Worked example: Batteries

[Batteries #1880](https://github.com/leanprover-community/batteries/pull/1880)
("perf: make a List.filter grind annotation less aggressive") replaced
`@[grind =>]` on `List.getElem_filter_eq_getElem_getElem_findIdxs` by a
narrower `grind_pattern`: with the old annotation, `grind` turns any
indexing into a filtered list into reasoning about `findIdxs`.
[`reproduce/why-batteries.sh`](../../reproduce/why-batteries.sh) undoes it
on Batteries 66e46918 (the last commit on Lean v4.35.0, the version leanprof
is built with): base is 66e46918, head is a local commit with the old
annotation back, so this is the known regression replayed on a pinned
commit, not a commit from Batteries' history. It runs the Action's
profiling step on both (`scripts/action-local.sh`, which posts nothing) with
`elab-files: Batteries/Data/List/Lemmas.lean`. The comment (first block):

> ### leanprof: compile cost: ❌ regression
>
> | metric | base | head | change | check |
> |---|---:|---:|---:|---|
> | compile heartbeats | 96.35 MHB | 96.41 MHB | +65.20 kHB (+0.07%) | ❌ fail |
>
> <details><summary>why <code>Batteries/Data/List/Lemmas.lean getElem_getElem_findIdxs_sub</code> got more expensive: +90.23 kHB; top change: grind instantiated (count) <code>getElem_filter_eq_getElem_getElem_findIdxs</code> +1</summary>
>
> | what changed | | defined at | base | head | change |
> |---|---|---|---:|---:|---:|
> | grind instantiated (count) | `getElem_filter_eq_getElem_getElem_findIdxs` | `Batteries/Data/List/Lemmas.lean:539` | 0 | 1 | +1 |
> | … | | | | | |
>
> </details>

That is the cause: `getElem_getElem_findIdxs_sub`'s `grind` now instantiates
the re-annotated theorem, and its proof grows (kernel +34.71 kHB, with
`Int.rec` unfolded by the kernel 245 → 315 times). The heartbeats of that
extra work are not credited to a constant (the operations are under the
10,000-heartbeat threshold), and the comment says so. The other regressed
declaration, the re-annotated theorem itself (+8.69 kHB, the attribute now
elaborated with it), shows only small changes in how often things were
used and a note that the heartbeats are not credited to a named constant.

## GitHub Action

The action in this repository does that for every pull request, with no
baseline to keep: it profiles the pull request's base and head commits on
the same runner and comments the difference.

```yaml
# .github/workflows/leanprof.yml
name: leanprof
on: pull_request
permissions:
  contents: read
  pull-requests: write   # to comment
jobs:
  profile:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0               # base and head without fetching again
          persist-credentials: false   # the pull request's code runs in this job
      - uses: unbalancedparentheses/leanprof@main   # or a release tag
        with:
          executable: myapp              # a lean_exe target
          args: bench-input --size 1000
          allocs: true                   # also count allocations
          elab-files: MyApp/Basic.lean MyApp/Proofs.lean
          fail-on: copies,heartbeats
```

The comment (one per pull request, updated on each push) looks like this:

> ### leanprof: copybug 2000: ❌ regression
>
> | metric | base | head | change | check |
> |---|---:|---:|---:|---|
> | copies | 1,999 | 2,000 | +1 (+0.05%) | ❌ fail |
> | allocations | 10,959 | 10,960 | +1 (+0.01%) | ⚠️ worse (not enforced) |
> | calls | 10,948 | 10,948 | 0 | ✅ pass |
> | compile heartbeats | 2.18 MHB | 2.36 MHB | +181.41 kHB (+8.34%) | ❌ fail |
> | time (wall, noisy) | 18.56 ms | 18.46 ms | −0.10 ms (−0.51%) | noisy, not checked |
>
> followed by a collapsed "why" block per regressed declaration (its top
> cause in the summary line), explain's cause per copy site that copies
> more, and collapsible tables of the call sites, scopes and declarations
> that changed.

The comment stays under 60,000 characters (GitHub's limit is 65,536): the
summary and tables first, then as many explanations as fit, then a line
saying how many were left out (`leanprof compare` in the job log has them
all).

Copies, allocations, calls and heartbeats are exact, so any regression is
real; time varies between runs and is shown but never fails the job. The
job fails when a metric named in `fail-on` regresses (after commenting):

| metric | regression |
|---|---|
| `copies` | more copies of shared or multi-threaded values at any call site |
| `allocs` | more allocations in total (needs `allocs: true`) |
| `calls` | a different call count for a scope present in both commits |
| `heartbeats` | a declaration of `elab-files` costs more than 1% and 1,000 heartbeats more |

| input | default | |
|---|---|---|
| `executable` | | `lean_exe` target for `leanprof run --json` |
| `args` | | its arguments (shell quoting is honored) |
| `allocs` | `false` | `leanprof run --allocs` |
| `elab-files` | | files for `leanprof elab --heartbeats` (globs allowed) |
| `fail-on` | `copies` | comma-separated from `copies`, `allocs`, `calls`, `heartbeats`; or `none` |
| `explain` | `true` | say why: `elab --counts` (elaboration up to twice as slow) and `leanprof explain` on each commit |
| `working-directory` | `.` | the Lake project, relative to the repository root |
| `setup` | | command run in each checkout first, e.g. `lake exe cache get` for Mathlib projects |
| `base-ref`, `head-ref` | the pull request's base and head | commits to compare (for other events) |
| `comment` | `true` | comment on the pull request |
| `comment-tag` | `default` | tell comments apart when the action runs more than once per pull request |
| `title` | `leanprof: EXE ARGS` | heading of the report |
| `github-token` | `github.token` | only the workflow's own token is needed |

Outputs: `report` (path of the Markdown file) and `regressed` (`true` or
`false`).

How it works: the action installs elan (each commit then uses its own
`lean-toolchain`), builds leanprof's command once per version and caches it,
checks out base and then head in one extra worktree (so dependency builds
are reused), runs `leanprof run` and `leanprof elab --heartbeats` on each
(with `explain: true`, also `elab --counts` and `leanprof explain` in that
commit's checkout, which only reads its emitted C), logs `leanprof compare`,
and renders the comment with `leanprof report-md`.
The project does not need to depend on leanprof. The report also goes to
the job summary.

**Pull requests from forks** get a read-only token, so they cannot comment;
the action then leaves the report in the job summary (open the workflow
run) and says so in a notice. Use `pull_request`, not `pull_request_target`,
for such workflows: the action builds and runs the pull request's code.
For the same reason, check out with `persist-credentials: false` (otherwise
`actions/checkout` leaves the job's token in `.git/config`, where that code
can read it) and give the workflow only `contents: read` and
`pull-requests: write`. The comment step is the only one that receives the
token. Pin the action to a release tag rather than `@main` so a later change
to this repository cannot change what your workflow runs.

### Rendering the comment locally

```
leanprof run --json base.json myapp -- input      # on the base commit
leanprof run --json head.json myapp -- input      # on your change
leanprof report-md --fail-on copies base.json head.json > comment.md
```

`report-md` takes one pair of `run --json` reports, one pair of
`elab --heartbeats` reports, or both (`BASE.json NEW.json BASE_ELAB.json
NEW_ELAB.json`), and exits 1 when a `--fail-on` metric regressed;
`--explain head-explain.json` adds explain's causes for copies.
`scripts/action-local.sh REPO BASE HEAD FILES [EXE [ARGS]]` runs the
action's profiling step on two commits of any checkout and prints the
comment, without posting it.
This repository's own pull requests run the action on `copybug`
([`.github/workflows/action-demo.yml`](../../.github/workflows/action-demo.yml)).

## Measure and judge

For deciding whether one change is an improvement:

```
leanprof measure [--runs N] [--scope NAME] [--heartbeats-files F.lean...] [--check-output FILE] [--no-allocs] [--core] [--out FILE] EXE [-- ARGS]
leanprof judge BASE.json NEW.json
```

`measure` builds with copy detection and allocation counting, runs the
program `N` times (default 5, after a warm-up run) and writes one summary:
median, min and max time, copies and calls per scope, allocations per site
and per run, compile heartbeats of the given files, the exit code, and a
hash of stdout (or of `FILE`). Counting allocations costs about 6 ns each
(lean-compiler-backend, 20 million allocations: 10% slower); both summaries
pay it alike, so time comparisons stay fair. `--no-allocs` turns it off.
Copies and allocations are those of the project's compiled code; `--core`
also counts those inside Lean's precompiled libraries (as `run --core`, with
llvm-objcopy), where a change's effect can be entirely: lean-compiler-backend's
`emitData` fix removed quadratic work done in Lean's `List` code, which
`measure` without `--core` does not see. `judge` refuses to compare a `--core`
summary with one measured without it.
`judge` prints KEEP or DISCARD with reasons and exits 0 or 1:

- **DISCARD** if the exit code or output changed, copies or allocations
  grew (exact: any increase; when a threaded program's count varies between
  runs, only when every new run allocated more than every base run),
  compile heartbeats grew by more than 1% and 1,000, or every new run was
  slower than every base run;
- **KEEP** if nothing got worse and copies went down, allocations went down
  by at least 1% and 100, heartbeats went down by more than 1% and 1,000,
  or every new run was faster than every base run.

Allocations matter because a change can trade one cost for another: the
first fix of `CFG.build` in lean-compiler-backend removed its copies but
added 59,514 allocations, and a judge that only counted copies kept it. A
smaller cut than 1% is exact but saves less than timing can see (each
allocation costs a few ns), so it is listed but is not an improvement on
its own.

Time counts only when the runs do not overlap **and** the median moved by
at least `--min-change PCT` percent (default 1): base and new are measured
one after the other, and on a quiet, pinned machine drift of about 1%
between the two separated the runs of unchanged code in 2 of 20 pairs.

`measure` also records the 1-minute load average and the number of CPUs
(and the mean and standard deviation of the run times). When either summary
was measured on an overloaded machine (load average above the number of
CPUs), `judge` reports the time change but does not use it: on such a
machine whole runs drift together, and on a shared 18-core Mac at load 30–68,
"every new run faster than every base run" held for 2 of 20 comparisons of
unchanged code ([LeanBench case study](../case-studies/leanbench.md)).
Copies, heartbeats and the output are still judged.

`--scope NAME` times one `profile! "NAME"` scope instead of the whole
process: each run's time is that scope's total from the run's report (over
every position with that name), so start-up and setup do not dilute a
change. The project must depend on leanprof for `profile!`; a name that is
not in the report is an error, and `judge` discards a comparison of
summaries that timed different things (the process, or another scope).

### Interleaved timing of ordinary binaries

Build baseline and candidate in separate checkouts, then measure the existing
binaries together. This avoids rebuilding or adding probes between timing runs:

```sh
leanprof measure-pair \
  --base ../base/.lake/build/bin/myapp \
  --candidate ../candidate/.lake/build/bin/myapp \
  --base-cwd ../base --candidate-cwd ../candidate \
  --runs 20 --out paired.json -- INPUT
leanprof judge paired.json
leanprof judge --min-change 2 paired.json
```

Binary paths resolve relative to the directory where you invoke leanprof.
Both programs receive the same argument vector, without shell interpretation;
their working directories may differ. Build both normally first and let build
and test jobs finish. `measure-pair` does not modify either build.

The default is three warmup pairs followed by 20 measured pairs, alternating
baseline/candidate and candidate/baseline order. `--runs` accepts 6–1000 pairs;
`--warmup` accepts 0–1000. The session records every duration, exit status,
stdout/stderr fingerprint, working directory and per-pair machine load. Binary
fingerprints are checked before and after collection to detect rebuilds during
the session; these FNV fingerprints are not cryptographic attestations.

For file output, use `--check-output result.dat` (relative to each program's
working directory). The old file is removed before each run, and a missing new
file prevents KEEP. Stdout and stderr must also remain stable across both
programs and all measured runs. Nonzero exits prevent KEEP. Warmup failures
abort collection. `measure-pair` exits 0 after collecting a complete session,
even for DISCARD; use `judge`'s exit status (0 KEEP, 1 DISCARD, 2 invalid input).

`judge paired.json` computes each pair's percentage change and reports a
distribution-free 95% confidence interval for its population median, using
binomial order statistics. A timing improvement counts only when the entire
interval is below `-min-change` (default 1%); a regression counts when the entire
interval is above `+min-change`. Otherwise timing is inconclusive. Overload
during any sampled boundary disables the timing verdict, unless you pass
`--allow-overloaded`: on a machine that is never below its CPU count (the
shared 18-core Mac of the [dogfooding study](../case-studies/dogfood-lcb-concrete.md)
sat at load 18–20 for hours), pairs still cancel the drift common to both
sides, and the verdict then says it was judged on an overloaded machine.
Run more pairs there; the interval is only as trustworthy as the pairs are
independent.

The interval assumes independent pairs. Alternation reduces gradual drift; it
does not eliminate periodic interference, thermal effects or systematic bias.
Choose the run count before measurement; repeatedly rerunning until KEEP is
not a valid 95% procedure. Timing includes process startup and output capture.
There is no automatic early stopping or per-scope timing in this command.

This is a timing-only session: it does not count copies, allocations or compile
heartbeats. Keep the existing `measure`/`judge BASE NEW` checks for exact metrics,
and require both correctness/metric checks and the paired timing result before
accepting an optimization. Two standalone summaries are never silently treated
as an interleaved session.

## Autoresearch

`measure` and `judge` are the measurement and verdict of an
[autoresearch](https://github.com/karpathy/autoresearch)-style loop, where an
AI agent edits the code, measures, and keeps a change only if it is better.
Exact metrics (copies, heartbeats, output hash) keep the loop from being
fooled by timing noise, and for proofs the kernel guarantees a cheaper proof
is still a proof.

[`research/program.md`](../../research/program.md) is the loop for the agent
to follow. [`research/demo/run.sh`](../../research/demo/run.sh) runs it with
scripted experiments:

```
KEEP
  + copies: 2,999 -> 0
  + compile heartbeats: 667.00 kHB -> 422.93 kHB
  + time: median 29.02 ms -> 12.33 ms (every new run faster than every base run)

DISCARD
  - output changed (stdout): fnv1a64:c87964b7295693c6 -> fnv1a64:7385830f7dd13aef
```
