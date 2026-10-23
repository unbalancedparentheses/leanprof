# CI, regressions and autoresearch

## Compare two reports

```
leanprof compare [--threshold PCT] [--min-ms MS] BASE.json NEW.json
```

exits 1 on a regression:

- **copies**: any increase (exact, so no noise);
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

## Measure and judge

For deciding whether one change is an improvement:

```
leanprof measure [--runs N] [--heartbeats-files F.lean...] [--check-output FILE] [--out FILE] EXE [-- ARGS]
leanprof judge BASE.json NEW.json
```

`measure` builds with copy detection, runs the program `N` times (default 5,
after a warm-up run) and writes one summary: median, min and max time,
copies and calls per scope, compile heartbeats of the given files, the exit
code, and a hash of stdout (or of `FILE`). `judge` prints KEEP or DISCARD
with reasons and exits 0 or 1:

- **DISCARD** if the exit code or output changed, copies or compile
  heartbeats grew, or every new run was slower than every base run;
- **KEEP** if nothing got worse and copies or heartbeats went down, or every
  new run was faster than every base run.

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
  + copies: 2999 -> 0
  + compile heartbeats: 667.00 kHB -> 422.93 kHB
  + time: median 29.02 ms -> 12.33 ms (every new run faster than every base run)

DISCARD
  - output changed (stdout): fnv1a64:c87964b7295693c6 -> fnv1a64:7385830f7dd13aef
```
