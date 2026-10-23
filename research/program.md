# Autoresearch on a Lean project

You are an agent improving the performance of a compiled Lean 4 program. You
work in a loop: change the code, measure, and keep the change only if
`leanprof judge` says KEEP. leanprof does the measuring and the judging; your
job is to choose good experiments and make them correctly.

In the commands below, `leanprof` means `lake exe leanprof` in a project that
depends on leanprof, or `/path/to/leanprof/.lake/build/bin/leanprof` in any
other Lake project (it compiles its runtime for the project's Lean version;
no lakefile changes are needed).

## Setup (once)

1. Agree with the human on the **target**: the executable `EXE`, its
   arguments `ARGS` (a workload that runs for at least ~10 ms, so time is
   measurable), the test command `TEST` (for example `lake test`), the files
   whose compile cost counts (`FILES`, usually the ones you will edit), and
   the time budget.
2. If the program writes its result to a file instead of stdout, or prints
   anything that varies between runs (timings, addresses, dates), agree on a
   deterministic output file `OUT` and pass `--check-output OUT` to every
   `measure`. `judge` rejects every change while the output is not the same
   on every run.
3. Create a branch: `git checkout -b autoresearch/<date>-<topic>`.
4. Make sure the tree is clean, then build and test: `lake build && TEST`.
5. Measure the baseline. The **measure command is fixed for the whole
   session**; never change its runs, arguments or files:

   ```
   leanprof measure --runs 5 --heartbeats-files FILES --out .lake/research/base.json EXE -- ARGS
   ```

   `measure` counts allocations (about 6 ns each; both sides of every
   comparison pay it). Only if that makes the workload too slow, add
   `--no-allocs`, for the whole session: `judge` then cannot see them.

6. Create `research/results.tsv` (untracked: add it to `.git/info/exclude`)
   with the header and the baseline row (see below).

## The loop

Repeat until the time budget is spent:

1. **Look.** Read the last report and choose one hotspot:
   - `.lake/leanprof/report.json` (from `measure`, or
     `leanprof run --json ...`) lists copies of shared values per function;
     each one copies a whole `Array`, `ByteArray` or `String`. With
     allocations counted (`measure` does; `run --allocs`), it lists
     allocations per function too. Each row has `pct_run`, its share of the
     run: pick findings by that, not by counts (20,000 copies at 0.02% of
     the run are not worth an experiment; allocations at 1% rarely are).
   - `leanprof explain --json` reads that report and prints the copy sites
     as ranked findings: `cause` (`nested-array-element`,
     `map-value-reinserted`, `stored-then-updated`, `multi-threaded-global`,
     `loop-over-updated-array`, or a general one), `file` and `lines`, `why`,
     `fix`, and `fix_code`: the rewrite as Lean code with the program's own
     names (alternatives; apply one), plus `copies` and `estimated_cost_ns`
     (time spent copying at that site). A finding with `fix_code` is the
     cheapest experiment to try first; the fixes for the recognised causes
     are tested to remove the copies.
   - `leanprof sample EXE -- ARGS` shows CPU time per Lean declaration and
     what the runtime spent its time on (copying, freeing, allocation, ...).
   - `leanprof elab --heartbeats FILES` shows compile cost per line and
     repeated work (the same instance problem solved many times, ...).
   - `leanprof run --auto EXE -- ARGS` times every function exactly.
2. **Change one thing.** One idea per experiment, as small as possible:
   remove an extra reference so an update happens in place, change a data
   structure, avoid recomputation, add a missing instance, ... Write down
   the idea before editing.
3. **Build and test.** `lake build && TEST`. If either fails, fix the
   change (still the same idea) or abandon it with `git reset --hard`, and
   log it as `crash`.
4. **Measure** with the fixed command, into `.lake/research/new.json`.
5. **Judge.** `leanprof judge .lake/research/base.json .lake/research/new.json`
   prints KEEP or DISCARD with the reasons, and exits 0 for KEEP.
6. **Keep or discard.**
   - KEEP: `git commit -am "<idea>"`, then
     `cp .lake/research/new.json .lake/research/base.json`.
   - DISCARD: `git reset --hard` (the base summary stays).
7. **Log** one row in `research/results.tsv`, KEEP or not.

### What `judge` decides

DISCARD when any of these hold:

- the command, the exit code or the output hash changed, or the output was
  not the same on every run;
- copies of shared or multi-threaded values went up (they are exact counts);
- allocations by compiled Lean code went up (exact counts; if a threaded
  program's count varies between runs, only when every new run allocated
  more than every base run). A change that removes copies by allocating
  more elsewhere is not an improvement: fix the allocations too, or drop it;
- compile heartbeats of `FILES` went up by more than 1% and 1,000
  (heartbeats are exact, but an edit moves neighbouring declarations by a
  few);
- every new run was slower than every base run.

Time is not judged at all when the machine was overloaded (1-minute load
average above the number of CPUs) during either `measure`; run the loop on
a quiet machine, or rely on the exact metrics.

Otherwise KEEP when copies went down, allocations went down by at least 1%
of the base count and 100 (a smaller cut is exact but too small to show in
time; it is listed, not counted), heartbeats went down by more than 1% and
1,000, or every new run was faster than every base run (new max below base
min) and the median moved by at least 1% (`--min-change`). Base and new are
measured one after the other, so a quiet machine's drift of about 1% can
separate the runs by itself: unchanged code gave 2 such verdicts in 20 before
the 1% floor. A change within
the noise is DISCARDed: it has to show that it helps. Call counts are
listed but not judged, since restructuring code changes them legitimately.

## results.tsv

Tab-separated, one row per experiment, never rewritten:

```
commit	verdict	median_ms	copies	compile_khb	description
de5877c	baseline	29.022	2999	667.0	baseline
1001bbb	KEEP	12.333	0	422.9	keep a running sum instead of every prefix
-	DISCARD	12.340	0	419.3	add each element before counting its prefix
-	crash	-	-	-	use a HashMap for the memo table (test failed)
```

`commit` is the new commit for KEEP and `-` otherwise; the numbers are
`time_ns.median` / 1e6, `copies_total` and `heartbeats_total` / 1000 from the
new summary.

## Rules

- **Never weaken tests or proofs** to make a change pass: do not delete or
  loosen tests, add `sorry`, `axiom`, `@[implemented_by]` or `unsafe` shortcuts,
  or `partial` in place of a termination proof.
- **Never change the experiment**: the measure command, its arguments,
  `--runs`, the files measured or the output being checked. If the workload
  is wrong, stop and ask the human.
- **One idea per experiment**, so each verdict says which idea helped.
- **Do not edit** leanprof, `lakefile`, `lean-toolchain` or dependencies
  unless the human asked for it.
- **Respect the time budget**: stop when it is spent, or after 10
  consecutive DISCARDs, and summarize what was kept, what was tried and
  what you would try next.
- Leave the branch with only KEEP commits and a clean tree.

## Demo

`research/demo/run.sh` runs this loop with two scripted experiments instead
of an agent (one that removes hidden copies, judged KEEP; one that changes
the output, judged DISCARD) on a copy of `research/demo/project`. CI runs it.
