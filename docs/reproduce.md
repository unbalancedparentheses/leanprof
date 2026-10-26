# Reproducing the published numbers

Every headline number in the [README](../README.md) that comes from a
measurement can be checked with one command from a clean clone:

```
git clone https://github.com/unbalancedparentheses/leanprof && cd leanprof
scripts/reproduce.sh list          # the claims
scripts/reproduce.sh copybug       # one claim
scripts/reproduce.sh exact         # every cheap exact claim (what CI runs)
```

Each claim pins what it measures (commits, tags, toolchains), clones and
builds it under `.lake/reproduce/` (or `$LEANPROF_REPRO_WORK`), prints every
measured value next to the published one, and ends with `PASS` or `FAIL`:

```
          check                                       measured  published                    result
   exact  copies in buildWithHistory (all)               2,001  2,001                        ok
   range  copy time as % of the scope (timing)           99.4%  99.1% (accept 90.0%–100.5%)  ok
   info   lean-regex toolchain           leanprover/lean4:v4.34.0-rc1
```

- `exact` rows are copies, allocations, calls, heartbeats, counts and output
  hashes. Any difference is a failed reproduction (exit code 1).
- `range` rows are timings and other measurements that vary. Each has a
  stated range, usually half to twice the published value: machines differ,
  and a shared or loaded machine can fall outside it. Outside the range also
  exits 1, so read the load printed at the start and end before calling it a
  failure.
- `info` rows are printed for comparison and never fail.
- Exit code 2 is a setup error (a build or download failed), not a result.

On a machine shared with other timing jobs, set `LEANPROF_BENCH_LOCK` to a
lock file every job uses (for example `~/.leanprof-bench.lock`): each timed
part then holds an exclusive `flock` on it, while builds and exact counts run
outside it.

Needs: elan (`~/.elan/bin` is put on `PATH`), git, Python 3 (standard
library only); `samply` for `bench-suite`; Node 20 and npm for
`batteries --lsp`. Times below are for an Apple M5 Max with the clones
already in place; a first run downloads and builds the projects (add a few
minutes each, 15 for lean-compiler-backend's three checkouts).

## Where the published numbers came from

- **Mac**: an Apple M5 Max (18 cores, macOS 26.6) shared with other jobs.
  Every timing on the Mac was taken under load (stated per claim).
- **Linux**: a dedicated, idle AMD Ryzen 9 7950X3D (frequency fixed, the
  suite pinned to cores 0–7). It is not reachable for these scripts; the
  Linux-only timings are listed as such below and were not re-run.

Exact counts do not depend on the machine. They do depend on the leanprof
that measured them where leanprof's own work is part of the number
(heartbeats): those claims build the leanprof commit that published them and
check against it, and print this leanprof's values as `info`.

## The claims

### `copybug`: the README example

`scripts/reproduce.sh copybug` (about 15 s). `leanprof run copybug` and
`leanprof explain` on `Examples/CopyBug.lean`, n = 2000.

| | published | kind |
|---|---|---|
| copies in `buildWithHistory` (`Examples/CopyBug.lean:17`) | 2,001 (1,999 of a shared value, 2 persistent), 15.3 MiB | exact |
| calls: `buildWithHistory`, `fib` | 1, 10,945 | exact |
| `explain`: stored in `history` at line 21, updated at line 22, fix `history.push acc.size` | | exact |
| copy time as a share of the scope | 99.1% (accept 90–100.5%) | range |

Failed reproduction: any count differs or `explain` names other lines.

### `smoke`: a project that does not depend on leanprof

`scripts/reproduce.sh smoke` (about 15 s). Tests/Smoke copied out of the
repository, built with `lake build`, then `leanprof run` and `run --auto`
with n = 2000. Published in `scripts/smoke-baseline.json`.

| | published | kind |
|---|---|---|
| shared copies: `buildWithHistory` Array (`Main.lean:10`), `strings` String (`Main.lean:19`), nothing else | 1,999, 999 | exact |
| `--auto` calls: `fib` (`Main.lean:5`), `main`, `buildWithHistory`, `strings` | 242,785, 1, 1, 1 | exact |

### `lean-regex`: [case study](case-studies/lean-regex.md)

`scripts/reproduce.sh lean-regex` (about 2 min; `--exact-only` for the CI
subset). lean-regex at `32af6f3` (Lean 4.34.0-rc1, its own toolchain), the
input every `Init/Data/*/*.lean` of Lean 4.35.0 (4.58 MB),
`Bench -e '[a-zA-Z_]+_(lt|le)\b' -n 3`. Published on the Mac.

| | published | kind |
|---|---|---|
| matches | 4,878 | exact |
| copies: `Regex.BufferStrategy`, `SparseSet.insert` | 13,376,304, 43,911 | exact |
| allocations: total, `εClosure`, `stepChar`, `captureNext.go` | 204,911,040, 117,325,311, 74,087,541, 13,347,033 | exact |
| closure applications (all `εClosure` → `BufferStrategy`) | 13,702,767 | exact |
| objects freed, reuse checks in `εClosure`, failed | 131.8 M, 158.6 M, 9.4% | exact |
| `--auto` calls: `BufferStrategy`, `eachStepChar.go` | 13.7 M, 13,376,301 | exact |
| heartbeats (with leanprof `8caf3fd`): `eachStepChar` 13.5 M; `i < nfa'.size =?= i < nfa'.size` 76 times, 25.7 M; whnf of `nfa'` 5,766, of `inst.toProofData` 13,560; `decreasing_tactic` 25.2 M | | exact |
| three uninstrumented searches, best of 3 | 2.0 s (accept 1.4–3.0 s) | range |

### `leanprofiler`: [bench/README.md](../bench/README.md), LeanProfiler's span cost

`scripts/reproduce.sh leanprofiler` (about 30 s; `--exact-only` for CI).
LeanProfiler `35e1899`, Lean 4.35.0. Published on the Mac at load 25.

| | published | kind |
|---|---|---|
| copies with 4,000 spans: `reserveSpan` (in `DHashMap.insert`, `Capture.lean:65`), `completeSpan` (`Capture.lean:94`), all of multi-threaded or persistent values | 12,003, 8,002 | exact |
| leanprof per scope, 1 / 4 threads, n = 1M | 7.3–8.9 / 8.2–11.8 ns | range (half to twice) |
| LeanProfiler recording off, 1 / 4 threads | 24.7–26.8 / 419–495 ns | range |
| LeanProfiler recording on, per span at 1,000 / 4,000 / 16,000 events | 4.6 / 20.1 / 88.5 µs | range |
| its growth, 16,000 over 1,000 events | 19× (accept at least 8×) | range |
| leanprof at those counts, worst | 17.8 ns (accept under 50 ns) | range |

The Linux figures (23 ns per scope) are from the dedicated host and are not
re-run here.

### `leanbench`: [case study](case-studies/leanbench.md)

`scripts/reproduce.sh leanbench` (about 40 s): the exact part.
`--timing` adds the detection trials (about 15 minutes), only meaningful on a
quiet machine. LeanBench `250d2a8`, the workload `bench/leanbench/project`.

| | published | kind |
|---|---|---|
| copies per `work` run, base / `copy` variant; `judge` DISCARDs on copies | 0 / 1,980 | exact |
| allocations per `work` run, base / `alloc` variant; `report-md --fail-on allocs` fails, passes on base vs base | 46,214 / 48,214 | exact |
| `--timing`: leanprof catches the 2.4% slowdown | 5/5 (accept 4–5) | range |
| `--timing`: leanprof false time verdicts on unchanged code | 0/20 (accept 0–1) | range |
| `--timing`: LeanBench at 5% catches the 2.4% / 4.8% slowdowns | 0/5 / 2/5 (accept 0–1 / 0–4) | range |
| `--timing`: LeanBench at 5% false regressions | 0/20 (accept 0–1) | range |

The timing figures were measured on the dedicated Linux host. On a machine
whose load exceeds its CPU count leanprof refuses to judge time, so the
detection checks fail there by design.

### `batteries`: [case study](case-studies/batteries.md), [vs lean-source-profiler](case-studies/compile-time-vs-lean-source-profiler.md)

`scripts/reproduce.sh batteries` (about 2 min; `--lsp` adds
lean-source-profiler CLI 0.3.0, downloaded from its release and checked
against its `SHA256SUMS`, about 3.5 min more). Batteries `v4.35.0`, Lean
4.35.0, 195 modules. Published on the Mac, load 20–30.

| | published | kind |
|---|---|---|
| `lake build` from clean | 13.3 s | range |
| `elab --project`, whole library (README: "17 s") | 16.8 s (accept 8.4–34 s) | range |
| with leanprof `a69f32a`: 195 modules, 1,504 M heartbeats; `List/Lemmas` 98.3 M, `BinaryHeap/WF` 94.6 M, `RBTree/Lemmas` 83.2 M, `RBTree/WF` 83.0 M, `String/Lemmas` 79.6 M; `decreasing_tactic` 193× 216.5 M, `get_elem_tactic` 187× 145.2 M, `grind` 99× 26.4 M; `compare` of two runs finds no regression | | exact |
| two `--heartbeats` runs differ by | 2.3 per million (accept up to 3) | range |
| unfolds of `Std.Iterator.IsPlausibleStep` from declarations (README: 24,369) | 24,369 from 69 (accept ±1%, ±5) | range, see below |
| unfolds of `Std.IterM` / `Std.Iter.IsPlausibleStep` | 24,371 / 12,180 (±1%) | range |
| `--lsp`: lean-source-profiler compact / detailed, whole project (README: "103–152 s") | 102.9 / 152.3 s (accept half to twice) | range |
| `--lsp`: its time over `elab --project` | 6.1× / 9.1× (accept at least 3×) | range |

The unfold counts come from the timed profile, which keeps only operations
above its 1 ms threshold, so they depend on timing and are checked within a
range (`--threshold 0` gives 24,493 from 71). The instance tried "66 times
from 21 declarations" is likewise timing-dependent (45–66 seen here) and is
printed as `info`.

### `lcb-fixes`: [lean-compiler-backend case study](case-studies/lean-compiler-backend.md)

`scripts/reproduce.sh lcb-fixes` (about 40 s once built). lean-compiler-backend
at `a25c541` and `854fcc2`, Lean 4.34.1 through elan, the zlib units archived
in the compiler's repository at `854fcc2`; `lcb --target aarch64-macos
--optimize --allocate deflate inflate trees crc32`.

| | published | kind |
|---|---|---|
| allocations `a25c541` → `854fcc2` (README: 11.95M → 7.72M) | 11,946,202 (266.6 MiB) → 7,719,273 (200.1 MiB) | exact |
| `Parser.tokenize` allocations at `a25c541` | 4,066,775 | exact |
| `CFG.build` copies (README: 121,054) → after the fix; `Optimize.function` | 121,054 → 43,899; 46,633 | exact |
| copies of shared values at `854fcc2` | 86,449 | exact |
| assembly byte-identical with and without leanprof | | exact |

The case study's "160 input/target/option combinations" identity check was
not recorded and has no script; `lcb-autoresearch` runs the 540-case one.

### `lcb-autoresearch`: [case study](case-studies/autoresearch-lean-compiler-backend.md), [qualification](../research/lcb/results/README.md)

`scripts/reproduce.sh lcb-autoresearch` (about 2 min once built; most of it
`research/lcb/compare.py`'s 33 timing pairs and 540 comparisons;
`--no-timing` for the exact part only).

| | published | kind |
|---|---|---|
| allocations `854fcc2` → `f9ed557` | 7,719,273 → 6,460,575 (167.7 MiB) | exact |
| copies of shared values `854fcc2` → `f9ed557` | 86,449 → 38,911 | exact |
| output/diagnostic comparisons `854fcc2` vs `ac8324e`, all identical, malformed inputs rejected by both | 540 | exact |
| median wall time, 30 alternating runs each, `854fcc2` → `ac8324e` (README: −22%) | 810.85 → 630.76 ms, −22.21% (accept −11% to −44%) | range |

The counts belong to `f9ed557`, the experiment's head, as the case study
says; the timing to the reviewed `ac8324e`. The published timing used the
compiler's Nix environment (Lean 4.34.1); these scripts use elan's Lean
4.34.1, so binaries differ: their build identities (the compiler's source
hash), the 17 input hashes and the benchmark's output signature match the
published `benchmark.json`, the binary hashes do not. Built this way both
sides ran about 2.5 times faster than published (319 and 237 ms medians,
against 811 and 631), while the reduction reproduced (25.6%). Only the
reduction is checked.

### `bench-suite`: [the accuracy table](../bench/RESULTS.md)

`scripts/reproduce.sh bench-suite` (about 5 minutes). `bench/run.py --reps 7
--check`, reports written under `.lake/reproduce/`, compared with
`bench/results.json`: the Mac, 2026-10-26, load 3.1–3.9, leanprof `043ebf0`
(the run [bench/RESULTS.md](../bench/RESULTS.md) shows; its "before" column
is `38205d5`, load 3.6–5.1). The results further down were checked against
earlier tables (leanprof `575ba1c`, then `4bdc762` after the outliner fix).

| | published | kind |
|---|---|---|
| call and copy counts exact in every leanprof mode and workload, for the functions it instruments (those `run --auto` leaves untimed have no count, and the check skips them) | | exact |
| reported totals within 0.75–1.35 of plain where scopes do real work | | range |
| each headline cell, share error for `profile!`, `--auto`, `sample`, samply, LeanProfiler (README: `sample` 0.1–1.9 pp, samply 0.1–2.0; `tiny` under `profile!` 6.1, `--auto` 0.7) | RESULTS.md headline | range: up to max(2×, +1 pp) |
| cost per scope, `tiny`, `profile!` (README: "about 5–8 ns", 4.7 ns on `tiny`) | 4.7 ns (accept 4–17 ns) | range |

The Linux accuracy figures (README "Sampling deep recursion on Linux",
"`--auto` on Linux", "Like-for-like with LeanProfiler") need the dedicated
host and were not re-run.

## Not covered

- Mathlib, Lake and the language server, doc-gen4, verso and concrete case
  studies: large builds or patches to other projects; no script yet.
- Everything measured only on the Linux host (see above).

## Results on the Mac, 2026-10-25

Run from a clean clone of the `reproduce` branch (leanprof `main` at
`c60adf2` plus these scripts), on the same kind of machine as the published
Mac numbers, an Apple M5 Max shared with other agents' builds (load 3 to 12
during the runs). Timed parts held a lock shared with the other timing jobs.
After merging `main` at `79ee65d` (no runtime changes), `exact` and
`lcb-fixes` were run again and passed.

| claim | result | notes |
|---|---|---|
| `copybug` | PASS, 10 checks | |
| `smoke` | PASS, 8 checks | |
| `lean-regex` | PASS, 22 checks | every copy, allocation, closure, free and reuse count exact; heartbeats exact with leanprof `8caf3fd`; 1.9 s for three searches |
| `leanprofiler` | PASS, 16 checks | 12,003 and 8,002 copies exact; LeanProfiler 4.7 / 20.3 / 95.8 µs per span, leanprof 10–18 ns |
| `leanbench` | PASS, 7 checks | 0 → 1,980 copies, 46,214 → 48,214 allocations |
| `leanbench --timing` | FAIL, 3 of 6 timing checks | shared Mac, not the dedicated Linux host the numbers are from: leanprof judged 6 of 20 unchanged pairs (published 0), caught the 2.4% and 4.8% slowdowns 2 of 5 times each (published 5/5); LeanBench as published (0/20, 0/5, 2/5) |
| `batteries --lsp` | FAIL, 1 of 48 | all heartbeats exact with `a69f32a`; the run-to-run variation, see below; `elab --project` 11.8 s, lean-source-profiler 77.5 / 115.6 s (6.6× / 9.8×) |
| `lcb-fixes` | PASS, 11 checks | 11,946,202 → 7,719,273 allocations, 121,054 copies, all exact |
| `lcb-autoresearch` | PASS, 9 checks | 7,719,273 → 6,460,575 allocations, 86,449 → 38,911 copies, 540 cases identical; −25.6% median wall time (paired −25.8%) |
| `bench-suite` | FAIL, 7 of 34 | counts exact everywhere; accuracy regression, see below |

What did not reproduce:

- **The benchmark-suite accuracy table, with today's leanprof.** Call and
  copy counts are exact in every mode, but on the Mac `run --auto` on
  `alloc` is 20.8 pp off (published 3.1; `phAllocTree` reported at 2.39
  times its true time) and `profile!` on `rec` 8.0 pp (published 1.9; `fib`
  at 4.7 times). The same subset run with leanprof `575ba1c`, the commit
  that published the table, reproduces it (1.9 and 3.1 pp), and so does
  `8d9f807` (0.3 and 1.7 pp). It changes with `a009129` ("Runtime on Linux:
  read the TSC ...; hot path inlined, allocation bookkeeping only once the
  alloc shims run"): 20.8 and 7.4 pp, and stays through `main`. The
  `runtime-checks` side (`34b0c9b`) is fine. So the published Mac table is
  right for the leanprof that measured it, and `main` has a regression on
  the Mac that the table does not show. The other out-of-range cells
  (`sample` and samply on `rec`, `mix`, `copy`, 1.3 to 2.4 pp against 0.1 to
  0.7) include samply itself, which leanprof does not change: those are
  this machine's noise.

  Cause and fix (branch `mac-accuracy`): since `a009129` inlined enter and
  exit into every probe, Apple clang's machine outliner (on for arm64 at
  -O2) turned the program's probes into chains of calls to shared outlined
  pieces while calibration's copies stayed straight-line, so each real
  probe cost ~5 ns more than calibrated. With `-mno-outline` on macOS,
  `--auto` on `alloc` is 3.2–3.3 pp and `profile!` on `rec` 2.3–2.5 pp
  (bench/README.md, "Mac: probes outlined by the compiler"); the table and
  `bench/results.json` were re-published from that run.
- **Heartbeats "within 2 in a million" across runs** (Batteries). Pairs of
  whole-project `--heartbeats` runs differed by 0.4 to 5.1 per million in
  nine pairs here (3.1 in the final run), so the README's "compile
  heartbeats are the same on every run" holds per declaration only to a few
  hundred heartbeats, and the case study's "2 in a million" is not a bound.
  The README now says "nearly the same", with the 5 per million.
- **The four-file 108.5M total** of the lean-regex case study: the files are
  not named, and no fourth file of lean-regex makes the total with the three
  named ones (checked with leanprof `8caf3fd` on every file), so only the
  per-declaration and repeated-work figures are checked.
- **Counts from the timed compile profile** are not exact: unfolds of
  `Std.Iterator.IsPlausibleStep` came out at 24,368 from 68 declarations in
  every re-run (published 24,369 from 69, also in the README), and the
  instance "tried 66 times" at 32 to 66. Both only count operations over the
  1 ms threshold.
- **Absolute wall times of lean-compiler-backend** were about 2.5 times
  shorter than published (319 / 237 ms against 811 / 631), with the same
  source identity, inputs and output; the binaries were built with elan
  rather than the compiler's Nix environment. The reduction (−25.6%)
  reproduced.
- **The lean-regex heartbeats with today's leanprof**: 12.0M for
  `eachStepChar` instead of 13.5M, 44 instead of 76 repeated checks. They
  reproduce exactly with `8caf3fd`; later `elab` traces less (not
  bisected). The case study now names the commit.
- **LeanBench detection timings.** They are from the dedicated Linux host;
  on the shared Mac leanprof's time verdicts were wrong 6 times in 20 on
  unchanged code and caught each slowdown 2 times in 5. This says the Mac
  is too noisy for time verdicts (as the case study says of its own Mac
  runs), not that the Linux figures are wrong; they need that host.

Also seen while running these: interrupting `leanprof run` (here, killing
the reproduction of `copybug` part-way) left the instrumented objects of the
leanprof package in `.lake/build`, with the normal ones still in
`.lake/leanprof/normal-objects`; `lake build` did not rebuild them, and the
leanprof command itself then printed a runtime report on stderr at exit.
Removing `.lake/build` and `.lake/leanprof` fixed it. This is fixed since:
INT, TERM and HUP put the normal build back, after `kill -9` the next
`lake build` recompiles the instrumented objects, and `leanprof doctor`
restores a stashed build ([CHANGELOG](../CHANGELOG.md)).
