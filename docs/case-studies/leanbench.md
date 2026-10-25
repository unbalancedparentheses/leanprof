# Case study: leanprof and LeanBench on "did this change make it slower?"

[LeanBench](https://github.com/alok/LeanBench) (commit `250d2a8`, version
0.3.0, Apache-2.0) is a benchmark harness for Lean: you register named
actions with `bench "name" do ...`, it times each one in process and keeps
saved baselines. leanprof is a profiler that also has a regression verdict
(`measure` + `judge`, `compare`, `report-md` and the GitHub Action). They are
built for different jobs, so this compares them only on the one both claim:
**telling whether a change made code slower or faster**. Everything here is
reproducible from [`bench/leanbench/`](../../bench/leanbench/).

Short version:

- On a quiet, pinned machine both tools see a 5% or larger slowdown every
  time; leanprof also saw a 2% one in 4 of 5 trials. LeanBench's verdict is a
  fixed threshold on the mean, so what it reports depends on the threshold you
  pick: at 5% it never cried wolf on unchanged code (0/20) but missed half of
  the 4.8% slowdowns; with no threshold it flagged 6 of 20 unchanged runs.
- A hidden array copy per iteration and 2,000 extra allocations changed time
  by less than 1%. LeanBench cannot see them at any threshold that does not
  also flag noise; leanprof reports both exactly (when this was measured,
  `judge` checked copies and allocations went through `report-md`/the Action;
  `judge` now rejects added allocations too).
- leanprof's time verdict, "every new run faster than every base run", is
  not the 1-in-252 event the docs claimed: base and new are measured one after
  the other, and about 1% of drift gave 2 false KEEPs in 20 on unchanged code.
  This branch adds a 1% minimum change (`judge --min-change`); rerun with it,
  20 more unchanged pairs gave 0 false verdicts, and the 2% slowdown was
  caught 5 of 5.
- On a shared Mac at load 20–70, neither tool's time verdict was reliable
  (LeanBench saw −64% to +275% on unchanged code; leanprof judged a 10%
  slowdown KEEP once). leanprof now records the load average and does not
  judge time when the load is above the CPU count.
- **LeanBench is cheaper and more precise about what it times**: 0.6 s per
  verdict against leanprof's 6.5 s, plus 10 s for the rebuild leanprof
  causes, and it times the action itself, so a 10.4% slowdown reads as 10.4%
  where leanprof, timing the whole process, reads 8.2%.
- **Later, on the shared Mac** ([below](#paired-timing-measure-pair-and-measure---scope)):
  `measure-pair` gave 0 false time verdicts in 40 unchanged sessions and
  caught the 2.4% slowdown 9 times in 10 (20 pairs), where sequential
  `measure` gave up to 7 false verdicts in 20. It still costs 7.1 s per
  verdict to LeanBench's 0.74 s (2.9 s at 6 pairs, which caught 2.4% less
  often). The 10 s rebuild after `measure` is gone (0.18 s), and
  `measure --scope` times one `profile!` scope (10.4% read as 10.4%).

## What LeanBench does (from its source)

Read in full before building (`LeanBench/Runner.lean`, `Bench.lean`,
`Config.lean`, `Plan.lean`, `Filter.lean`); it only spawns `git`, `uname`,
`lake --version` and `date` for run metadata, plus your own commands with
`benchCmd`.

| | LeanBench |
|---|---|
| What is timed | each call of the registered `IO Unit` action, in process, with two `IO.monoNanosNow` reads; warm-up calls first (default 2), then `samples` calls (default 20), or until `--min-time-ms` |
| Statistics | mean, population standard deviation, min, max, and (`--format full`) median, p95, p99 by nearest rank; no confidence interval, no test, no outlier handling |
| Baseline | `--save FILE` (or `--format json --json-out`): a JSON file with each bench's stats; `--compare FILE` reads only each bench's `mean_ns` |
| Regression rule | new mean above baseline mean, and (if any are given) at least one of `--regress-pct P`, `--regress-ratio R`, `--regress-abs-ns N`; with no threshold, any increase; `--fail-on-regressions` exits 1 |
| Improvements | the table shows `ratio` and `delta`, but there is no improvement verdict or exit code |
| Output | pretty table, `full`, JSON with a versioned schema and run manifest (git commit, Lake version, OS, arch), JSONL, [radar](https://github.com/leanprover/radar) JSONL |
| Organization | names, suites, tags, a filter DSL (`suite(x) and not tag(slow)`), TOML profiles with per-bench overrides, shuffling and sharding (`--partition`), `lake bench` driver |
| Extras | setup/teardown and per-sample hooks outside the timed region, items/s, GB/s, GFLOP/s, threads, retries, per-sample JSON artifacts, external commands (`benchCmd`); the repository also has LeanObserve (elaboration data) and runtime-collector parsers, not compared here |
| Overhead | none on the code itself: the plain build is timed; per sample, two clock reads and an array push |
| Lean versions | its toolchain is 4.27.0-rc1; it built and ran unchanged on 4.35.0 (macOS arm64 and Linux x86-64), with docstring-linter warnings only |

What the docs say about `timeout-ms`, `priority`, `group` and
`threads-required` is accurate: they are metadata only.

## Setup

One project, [`bench/leanbench/project`](../../bench/leanbench/project/),
holds a workload (`Work.lean`) both tools measure:

- **LeanBench** times `Work.action` per call (`Bench.lean`, `lake exe bench`).
- **leanprof** times the process `work` (`WorkMain.lean`), which runs the
  same action 20 times (LeanBench's default sample count) and prints a
  deterministic result.

One action is 125 passes of a hash over a 40,000-element array (6 ms on the
Linux host; the `work` process takes 150 ms there). The seeded changes are
selected at run time with `LB_VARIANT`, so neither tool rebuilds between
base and new (a real change would cost both a rebuild), and every variant
prints the same result, so `judge` compares like with like:

| variant | change | effect on time |
|---|---|---|
| `copy` | one hidden copy of a 64-element array per round (1,980 per `work` run) | +0.1% |
| `alloc` | a small list per round: exactly +2,000 allocations per `work` run | +0.2% |
| `slow2`, `slow5`, `slow10`, `slow30` | 2.4%, 4.8%, 10.4%, 30.4% more passes of the same work | as stated, per action |
| `fast` | drops a redundant validation (125 → 100 passes) | −20% per action |

### Setup cost

| | LeanBench | leanprof |
|---|---|---|
| Lines added to the project | 12: a 4-line `[[require]]`, a 3-line `[[lean_exe]]`, a 5-line bench module (import, `bench`, `main`); a workload that lives in an executable must first move into a library | 0 |
| Dependencies | LeanBench and lean4-cli (38 MB of sources in `.lake/packages`) | none in the project; the `leanprof` binary (built once, 11 s on the Linux host, or a release download) |
| Commands | `lake exe bench --save base.json`, then `lake exe bench --compare base.json --fail-on-regressions --regress-pct 10` | `leanprof measure --out base.json work`, `leanprof measure --out new.json work`, `leanprof judge base.json new.json` |
| First build (Linux host) | 21.6 s (fetch and build LeanBench, Cli and the workload) | 3.2 s (first `measure`: runtime and copy shims) |
| What you need | the code as an `IO Unit` action | an executable with a deterministic output (or `--check-output FILE`) |

## Method

`bench/leanbench/run.py` runs trials. One trial of variant V, for each tool:
measure base, measure V, get the verdict. Trials alternate which tool goes
first, and every second pair of trials measures V before base. The 1-minute
load average is recorded before every measurement. LeanBench's verdict at
10% is its own exit code (when base was measured first) and, for other
thresholds and the other order, its rule (new mean / base mean) applied to
its JSON; the two never disagreed. leanprof's verdict is `judge`'s, with the
reason (slower, an exact metric, or no evidence); for `alloc` (and the
noise trials) also `run --allocs --json` on both sides and `report-md
--fail-on allocs`.

Two machines:

- **Linux (dedicated)**: AMD Ryzen 9 7950X3D, every command under `flock
  ~/bench.lock taskset -c 0-7` (cores 0–7 only, one measurement on the host
  at a time); governor `powersave` with EPP `balance_performance` and boost
  on (the host default, recorded in `results/machine-linux.txt`); load
  average 1–7. 2026-10-23, 21:53–22:22 CEST.
- **Mac (shared)**: Apple M5 Max, 18 CPUs, shared with other agents' builds;
  load average 20–70, so **every Mac time result is noise-dominated**.
  2026-10-23, 16:41–17:23 local time.

Defaults: LeanBench 20 samples and 2 warm-ups; leanprof 5 runs and 1
warm-up. The sweep repeats noise, `slow5` and `slow10` with 5 samples / 3
runs and 100 samples / 10 runs. Raw records are in
[`bench/leanbench/results/`](../../bench/leanbench/results/) (`*-linux.jsonl`
and the Mac `*.jsonl`); `python3 bench/leanbench/run.py summary` rebuilds
[the full table](../../bench/leanbench/results/summary.md).

## Noise: the same code, 20 times

| | Linux, LeanBench | Linux, leanprof | Mac, LeanBench | Mac, leanprof |
|---|---:|---:|---:|---:|
| load average | 1–2 | 1–2 | 27–68 | 27–68 |
| spread between measurements (CV) | 0.55% | 0.53% | 57% | 18% |
| change, new vs base | −0.9% to +1.1% | −2.4% to +0.3% | −64% to +275% | −35% to +63% |
| false regressions | any increase: 6/20; ≥5%: 0; ≥10%: 0 | 0/20 | any: 6; ≥5%: 3; ≥10%: 2 | 2/20 |
| false improvements | ≤−5%: 0 (no verdict exists) | **2/20 KEEP** | ≤−5%: 11; ≤−10%: 7 | 2/20 KEEP |
| allocation regressions (`report-md --fail-on allocs`) | – | 0/20 | – | 0/20 |

Within one LeanBench run the samples vary by 1.2% (stddev / mean, median of
40 runs) on Linux and 9% on the Mac.

The two false KEEPs on Linux are real and instructive. In both, the five new
runs were 0.7–2.4% faster than the five base runs and did not overlap them
(`151.6–152.8 ms` against `150.2–151.5 ms`). With independent runs that
happens 1 time in 252; but base and new are measured seconds apart, one
after the other, and the machine drifts by about 1% between them. With 3
runs per side the sweep had 1 false KEEP and 1 false DISCARD in 5 (one at a
median change of −0.17%). LeanBench, which needs 5% before it says anything,
does not have this problem at that threshold, and pays for it below.

## Detection

Linux (dedicated), 5 trials each, default settings:

| change | LeanBench at ≥10% | at ≥5% | any increase | leanprof `judge` | leanprof exactly |
|---|---:|---:|---:|---:|---|
| hidden copy per round (+0.1% time) | 0/5 | 0/5 | 3/5 | **5/5** (copies 0 → 1,980) | yes |
| +2,000 allocations (+0.2% time) | 0/5 | 0/5 | 4/5 | 0/5 (`judge` then ignored allocations; it now counts them) | **5/5** with `report-md --fail-on allocs` (46,214 → 48,214) |
| 2.4% slower | 0/5 | 0/5 | 5/5 | **4/5** (+1.7%); 5/5 rerun with `--min-change` | no, by time |
| 4.8% slower | 0/5 | 2/5 | 5/5 | **5/5** (+3.7%) | no, by time |
| 10.4% slower | 4/5 | 5/5 | 5/5 | 5/5 (+8.2%) | no, by time |
| 30.4% slower | 5/5 | 5/5 | 5/5 | 5/5 (+23.9%) | no, by time |
| 20% faster | measured −19.5% in 5/5, no verdict | | | **KEEP 5/5** (−15.7%) | no, by time |

"Any increase" is not usable alone: it also flagged 6 of 20 unchanged runs.

How many runs it takes (Linux, `slow5` and `slow10`, 5 trials each):

| | LeanBench 5 samples | 20 | 100 | leanprof 3 runs | 5 | 10 |
|---|---:|---:|---:|---:|---:|---:|
| 4.8% slower, at ≥5% | 2/5 | 2/5 | 1/5 | 5/5 | 5/5 | 5/5 |
| 10.4% slower, at ≥10% | 3/5 | 4/5 | 5/5 | 5/5 | 5/5 | 5/5 |
| unchanged, false verdicts | 0/5 at ≥5% | 0/20 | 0/5 | **2/5** | 2/20 | 0/5 |

More LeanBench samples make the mean more precise (10.3–10.4% with 100
samples), which settles a slowdown near the threshold, but no sample count
fixes a threshold set above the change. For leanprof, 3 runs per side is too
few for its non-overlap rule.

On the Mac (load 20–70) nothing about time held: LeanBench reported the
10.4% slowdown at 10% in 3 of 5 trials and leanprof judged it slower in 2
of 5, KEEP once in the 3-run sweep (a 10% slowdown judged an improvement);
the 20% speedup was a KEEP in 3 of 5. The exact metrics did not care: copies
5/5 and allocations 5/5, with no false alarm in 20 noise trials. The
complete Mac numbers are in the summary table.

## Cost per verdict

Measured on the Linux host inside one lock ([`cost.sh`](../../bench/leanbench/cost.sh),
5 repetitions, all within 0.1 s):

| | wall time |
|---|---:|
| LeanBench: baseline run + compare run (`lake exe bench`, 20 samples) | **0.62 s** |
| leanprof: two `measure` (5 runs each) + `judge` | 6.5 s |
| the next plain `lake build` after a `leanprof measure` | 10.3 s |

leanprof's `measure` rebuilds the C of every module in the project with copy
shims and, when this was measured, removed those objects afterwards, so each `measure` rebuilt and
the project's next normal build recompiled all of its C, dependencies
included (here LeanBench's `Runner` alone is most of the 10 s). In `run.py`
this showed up as a 15–30 s LeanBench run after every leanprof measurement
on the Mac. The tables' per-verdict figures in `summary.md` use medians to
leave those rebuilds and the lock waits out; `cost.sh` is the clean number.

Measured again on 2026-10-25 on the Mac (M5 Max, 18 CPUs, shared with other
agents; `cost.sh` run whole under the shared benchmark lock, so no other
timing run overlapped it, but other agents' builds did; load average 2.4–4.2
before and after; [`results/cost-mac.txt`](../../bench/leanbench/results/cost-mac.txt)),
after `measure` began setting the normal objects aside and putting them back:

| | wall time (5 repetitions; `--scope` 3) |
|---|---:|
| LeanBench: baseline run + compare run (20 samples) | **0.74 s** (1.59 s the first time) |
| leanprof: two `measure` (5 runs each) + `judge` | 5.0 s |
| the next plain `lake build` after a `leanprof measure` | **0.18 s** (a no-op: the 10 s rebuild is gone) |
| `measure-pair`, 20 pairs (the default) | 7.1 s (7.8 s the first time) |
| `measure-pair`, 10 pairs | 4.0 s |
| `measure-pair`, 6 pairs (the minimum) | 2.9 s |
| two `measure --scope work` + `judge` (`scoped/`, which depends on leanprof) | 9.0 s |
| rebuild after editing `Work.lean`: `work` / `bench` | 0.50 s / 1.02 s the first time, 0.28 s / 0.18 s after a comment-only edit |

So per verdict, with the rebuild a real change costs either tool, LeanBench
needs about 0.7 s + 1 s and `measure-pair` 7.1 s + 0.5 s at its default 20
pairs: **leanprof's most reliable time verdict is still about 4–10× slower
than LeanBench's**, because each of its 46 runs is a whole process doing 20
actions, against LeanBench's 22 in-process calls. Fewer pairs cost less
(2.9 s at 6) but detect less (below). Rebuilds of this tiny project are
cheap for both; a real project pays its own build time, and `measure-pair`
also needs the base built (usually already there in a loop).

## Paired timing: `measure-pair` and `measure --scope`

Two later additions address the two weaknesses above. `measure-pair` runs two
prebuilt plain binaries (no probes, no rebuild) in alternating AB/BA order
and judges a distribution-free 95% interval of the median paired change;
`measure --scope NAME` (added on this branch) times one `profile!` scope's
total from each run's report instead of the whole process. Neither had been
measured against LeanBench before.

Protocol, fixed in `run.py pair` before it was first run: unchanged code 20
trials, then the 2.4%, 4.8% and 10.4% slowdowns 5 trials each; every trial
runs LeanBench (20 samples), `measure` + `judge` (5 runs), `measure-pair`
(20 pairs) and `measure --scope work` + `judge` (5 runs, on
[`scoped/`](../../bench/leanbench/scoped/): the same 20 actions in one
`profile!` scope), tools in rotating order. `measure-pair` compares two real
builds: two copies of the project, the candidate's `Work.lean` edited to
hard-code the variant and rebuilt every trial. Its verdicts at 10 and 6
pairs are `judge` on the first 10 and 6 pairs of the same session. No trial
was rerun. A trial waited until the 1-minute load average was below 9.

Only the Mac was available (the Linux host was unreachable): an M5 Max with
18 CPUs shared with other agents. The protocol ran twice, both on
2026-10-25:

- **locked** (`results/pair-locked.jsonl`, 05:01–05:53): every measured
  command under the machine's shared benchmark lock, so no other agent's
  timing run overlapped a measurement; their builds still ran. Load average
  2.1–17.8 (one trial at 17–18).
- **unlocked** (`results/pair-unlocked.jsonl`, 01:36–02:05): the first run,
  before the lock existed; another agent's benchmarks may have overlapped
  it. Load average 3.3–16.6.

Time verdicts, locked run first, unlocked in parentheses:

| | LeanBench at ≥5% | `measure` + `judge` | `measure --scope` + `judge` | `measure-pair` 20 pairs | 10 pairs | 6 pairs |
|---|---:|---:|---:|---:|---:|---:|
| unchanged, false verdicts | 0/20 (1/20) | **7/20** (1/20): 3 KEEP, 4 slower | 4/20 (3/20) | **0/20 (0/20)** | 0/20 (0/20) | 0/20 (0/20) |
| 2.4% slower, caught | 0/5 (0/5) | 2/5 (4/5) | 3/5, and 1 KEEP (5/5) | **4/5 (5/5)** | 2/5 (5/5) | 2/5 (5/5) |
| 4.8% slower, caught | 0/5 (3/5) | 4/5 (5/5) | 4/5 (5/5) | **5/5 (5/5)** | 5/5 (5/5) | 5/5 (4/5) |
| 10.4% slower, caught | 5/5 (5/5) | 5/5 (5/5) | 5/5 (5/5) | 5/5 (5/5) | 5/5 (5/5) | 5/5 (4/5) |
| inconclusive on a slowdown | – | – | – | 1/15 (0/15) | 3/15 (0/15) | 3/15 (2/15) |
| median reading of the 10.4% slowdown | +11.4% (+10.5%) | +9.1% (+9.2%) | +10.4% (+10.4%) | +10.0% (+10.0%) | | |
| range of the change on unchanged code | −7.4..+1.1% | −6.4..+9.8% | −4.9..+6.1% | **−0.4..+0.4%** (−0.5..+0.6%) | | |
| seconds per verdict (median in the run) | 0.8 | 5.1–5.6 | 9.1–9.7 | 7.5 (0.5 build + 7.0) | | |

On unchanged code every `measure-pair` session ended "inconclusive"
(DISCARD with no reason against it, as it should). Full rows:
[`summary.md`](../../bench/leanbench/results/summary.md).

What this shows, on this shared Mac only:

- **`measure-pair` is the only time verdict here that held up under load.**
  Interleaving cancels the drift that made sequential runs disagree: its
  median paired change on unchanged code stayed within −0.5..+0.6% in all
  40 sessions, it never gave a false verdict, and at 20 pairs it caught the
  2.4% slowdown 9 times in 10 and everything larger every time. The same
  load gave `measure` + `judge` 7 false time verdicts in 20 in the locked
  run (KEEP of unchanged code 3 times), and `--scope` 4.
- **Whole-process dilution is small for a plain binary.** `measure-pair`
  read the 10.4% slowdown as +10.0% (process start-up and setup are about
  4 ms of 214 ms); instrumented `measure` read +9.1–9.2%; `--scope` removes
  that dilution (+10.4%) but not the drift of sequential runs, so it did not
  improve the verdicts here. `--scope` is for programs with expensive
  start-up or setup, not a fix for noise.
- **Fewer pairs are cheaper and weaker on small changes**: 6 or 10 pairs
  caught 4.8% and 10.4% slowdowns as often as 20 in the locked run, but the
  2.4% one only 2 times in 5.
- **It is still slower than LeanBench**: 7.1 s at 20 pairs against 0.74 s
  (`cost.sh`, above), 2.9 s at 6 pairs. LeanBench at its 5% threshold gave
  no false alarm in the locked run but caught 0 of 10 of the 2.4% and 4.8%
  slowdowns.

## What each reports that the other does not

| | LeanBench | leanprof |
|---|---|---|
| Many named benchmarks, suites, tags, filters, profiles, sharding | ✅ | one command per `measure` |
| Mean, stddev, median, p95, p99 per bench | ✅ | median, min, max (this branch adds mean ± stddev) |
| Configurable thresholds (%, ratio, ns) | ✅ | `compare --threshold/--min-ms`; `judge --min-change` (this branch) |
| Time of the action itself, no process start-up or setup | ✅ | whole process (or `profile!` scopes with `run`) |
| Throughput (items/s, GB/s, GFLOP/s), radar JSONL, `lake bench` | ✅ | – |
| Run manifest: git commit, Lake version, OS | ✅ | command and output hash; load average (this branch) |
| Improvement verdict (KEEP) | – | ✅ |
| Output check: the change must not change the result | – | ✅ hash of stdout or a file |
| Exact copies, with function and kind | – | ✅ |
| Exact allocations per call site | – | ✅ (`run --allocs`, `report-md`, Action) |
| Compile heartbeats per declaration | – | ✅ |
| file:line, why a copy happened, the fix | – | ✅ (`run`, `explain`) |
| PR comments on base vs head without a stored baseline | – | ✅ GitHub Action |
| Changes to the project | a dependency and a bench module | none |

## Conclusions

- **For time, on a quiet machine, they are comparable**, with different
  failure modes. LeanBench's fixed threshold gives no false alarms above it
  and no detection below it (a 4.8% slowdown at a 5% threshold: 2/5).
  leanprof adapts to the measured spread and caught 2% and 5% slowdowns, but
  its sequential non-overlap test produced 2 false KEEPs in 20.
- **For copies and allocations, only leanprof can tell**, and exactly; that
  is the case where a change costs under 1% today and more on bigger inputs.
  But `judge`, the command an autoresearch agent uses, still ignores
  allocations.
- **On a loaded machine, neither should judge time.** leanprof now says so
  instead of guessing.
- **LeanBench is 10× cheaper per verdict and does not disturb the build**,
  times what you point it at (no dilution by start-up), handles many
  benchmarks at once and reports richer statistics. Those are leanprof's
  homework below.
- **Later (2026-10-25, shared Mac):** leanprof no longer disturbs the build
  (0.18 s next build), and `measure-pair` gave the most reliable time
  verdict of the four measured (0 false in 40, 2.4% caught 9 in 10), but at
  7.1 s per verdict it is still about 10× slower than LeanBench's 0.74 s;
  at 6 pairs (2.9 s) it is about 4× slower and weaker on a 2% change.

## What leanprof should learn

Done on this branch:

1. `measure` records the 1-minute load average and CPU count, and `judge`
   does not use time when the machine was overloaded (on the recorded Mac
   data this turns the 4 false time verdicts in 20 noise trials, and the
   KEEP of a 10% slowdown, into "not judged"; the exact verdicts remain).
2. `judge --min-change PCT` (default 1%): non-overlapping runs only count
   when the median also moved by PCT. Applied to the recorded Linux runs:
   false time verdicts 2/20 → 1/20 (noise) and 2/5 → 0/5 (3 runs), with no
   detection lost (2%: 4/5, 5% and up: 5/5). Rerun live on the same host
   with the new build (`results/*-linux-v2.jsonl`, load 1.1–2.9): unchanged
   code 0 false verdicts in 20 (changes −0.4% to +0.4%), the 2.4% slowdown
   DISCARDed as slower 5/5 (+1.6% to +2.5%), the 20% speedup KEEP 5/5, and
   no allocation false alarm.
3. `measure` reports mean ± standard deviation next to median, min and max.
4. The "1 time in 252" claim is corrected in the docs.

Proposed (in [ROADMAP.md](../../ROADMAP.md)):

5. **Interleave** base and new runs (two builds side by side, ABAB…), the
   real fix for drift; then a test with a confidence interval on the
   difference. Done since: `measure-pair`, measured [above](#paired-timing-measure-pair-and-measure---scope).
6. **Keep instrumented objects apart** from the normal build so `measure`
   neither rebuilds every time nor forces a full C rebuild afterwards (6.5 s
   + 10.3 s against LeanBench's 0.6 s); a timing-only mode on the plain
   build for time verdicts. Done since: the next build after `measure` took
   0.18 s on the Mac, and `measure-pair` is the timing-only mode; what is
   left is its cost per verdict (7.1 s at 20 pairs against 0.74 s), for
   example by letting a program repeat its work fewer times per process.
7. **Allocations in `judge` and `compare`**, exactly, like copies (already
   planned; this study is another case: +2,000 allocations, invisible to
   `judge`).
8. **Time a scope, not only the process**: `measure --scope NAME` using
   `profile!` timings, so start-up and setup do not dilute the change (8.2%
   measured for a 10.4% slowdown). Done on the `verdict-speed` branch: it
   read the 10.4% slowdown as +10.4%, but its runs are still sequential and
   it gave 4 false verdicts in 20 on the shared Mac; a plain binary under
   `measure-pair` was diluted only to +10.0%.
9. **Many benchmarks per run** with names and per-benchmark verdicts, and
   LeanBench interop: read a LeanBench JSON file as one more input to
   `judge`/`report-md`, so projects that already use LeanBench get copies and
   allocations next to its timings.
10. **Run manifest** in summaries (git commit, Lean version, OS) and a radar
    JSONL output.
11. **Wider Lean version support**: LeanBench, plain Lean, works from 4.27 to
    4.35; leanprof needs 4.34 or later.

## Reproduce

```
export PATH=$HOME/.elan/bin:$PATH
lake build leanprof
python3 bench/leanbench/run.py noise --trials 20
python3 bench/leanbench/run.py detect --trials 5
python3 bench/leanbench/run.py sweep --trials 5
python3 bench/leanbench/run.py summary
sh bench/leanbench/cost.sh
python3 bench/leanbench/run.py pair    # + measure-pair and measure --scope
# on a shared Mac: LB_WRAP=bench-lock LB_MAX_LOAD=9 python3 ... pair --tag=-locked
# on a shared host: LB_WRAP="flock ~/bench.lock taskset -c 0-7" python3 ... --tag=-linux
```
