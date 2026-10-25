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
> followed by collapsible tables of the call sites, scopes and declarations
> that changed.

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
are reused), runs `leanprof run` and `leanprof elab --heartbeats` on each,
logs `leanprof compare`, and renders the comment with `leanprof report-md`.
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
NEW_ELAB.json`), and exits 1 when a `--fail-on` metric regressed.
This repository's own pull requests run the action on `copybug`
([`.github/workflows/action-demo.yml`](../../.github/workflows/action-demo.yml)).

## Measure and judge

For deciding whether one change is an improvement:

```
leanprof measure [--runs N] [--heartbeats-files F.lean...] [--check-output FILE] [--no-allocs] [--out FILE] EXE [-- ARGS]
leanprof judge BASE.json NEW.json
```

`measure` builds with copy detection and allocation counting, runs the
program `N` times (default 5, after a warm-up run) and writes one summary:
median, min and max time, copies and calls per scope, allocations per site
and per run, compile heartbeats of the given files, the exit code, and a
hash of stdout (or of `FILE`). Counting allocations costs about 6 ns each
(lean-compiler-backend, 20 million allocations: 10% slower); both summaries
pay it alike, so time comparisons stay fair. `--no-allocs` turns it off.
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
during any sampled boundary disables the timing verdict.

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
