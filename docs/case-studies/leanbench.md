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
shims and removes those objects afterwards, so each `measure` rebuilds and
the project's next normal build recompiles all of its C, dependencies
included (here LeanBench's `Runner` alone is most of the 10 s). In `run.py`
this showed up as a 15–30 s LeanBench run after every leanprof measurement
on the Mac. The tables' per-verdict figures in `summary.md` use medians to
leave those rebuilds and the lock waits out; `cost.sh` is the clean number.

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
   difference.
6. **Keep instrumented objects apart** from the normal build so `measure`
   neither rebuilds every time nor forces a full C rebuild afterwards (6.5 s
   + 10.3 s against LeanBench's 0.6 s); a timing-only mode on the plain
   build for time verdicts.
7. **Allocations in `judge` and `compare`**, exactly, like copies (already
   planned; this study is another case: +2,000 allocations, invisible to
   `judge`).
8. **Time a scope, not only the process**: `measure --scope NAME` using
   `profile!` timings, so start-up and setup do not dilute the change (8.2%
   measured for a 10.4% slowdown).
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
# on a shared host: LB_WRAP="flock ~/bench.lock taskset -c 0-7" python3 ... --tag=-linux
```
