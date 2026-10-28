# `leanprof run --retime`: tiny `profile!` scopes compiled out

The `tiny` workload of the suite is two loops of 10M and 20M calls of
one-nanosecond functions, each call wrapped in `profile!`. Under `profile!`
the two phases were 6–11 points off in share (bench/README.md, "Tiny
`profile!` scopes"): the two calls around a nanosecond of work change the
code they sit in by an amount that depends on that code (a pair of calls
that did nothing cost 2.1 ns a call in one loop and 1.5 ns in the other),
so no subtraction is right for both loops, and a sample of the same build is
as far off.

What was measured before `--retime`, and did not fix it:

- **Cheaper probes.** An inlined light probe (thread-local counters, no
  call) in a C model of the two loops ([inline-model](inline-model/),
  [results](inline-model/results.txt)) cost about 1.3 ns a call in the loop
  limited by throughput and 0.05 ns in the one limited by a dependency
  chain: a gap as large as an empty call pair's (1.1 and 0.1 ns), because
  each counter is a read-modify-write chain through memory. A cheaper probe
  moves the error, it does not remove it.
- **Calibrating in place, sampling the `profile!` build, subtracting
  less**: see bench/README.md (all three measured there; none fixes both
  loops).

So the probes have to go. `run --retime` runs the program once; if
`profile!` scopes on pure terms went light (too small to time), it writes
their names and positions to `.lake/leanprof/untimed.txt`, builds again
with `LEANPROF_UNTIMED` set, and the compiler wrapper (`scripts/leanprof-cc`)
rewrites each C file that holds one of those labels
(`scripts/leanprof-untimed.awk`): `leanprof_enter_pure` on that label's
constant becomes token 2 with no call, and `leanprof_exit_pure` on a
constant token 2 becomes the value. The C compiler folds both, so the loop
is the plain program's loop. The second report is the result: the callers
are timed without the probes, and the compiled-out scopes are listed under
`compiled_out` with the first run's exact calls and estimated times. Both
runs' calls are compared, and any difference is reported (a program that
does not do the same work each time).

## Results (Apple M5 Max, shared, 2026-10-27)

Three suites of `tiny`, `tasks` and `rec` (7 runs per cell, interleaved,
under the benchmark lock; [run1](run1.md), [run2](run2.md), [run3](run3.md),
raw numbers beside them). `run --retime` is built by `bench/run.py` from a
run of every workload (`WlPlain`'s `all`), which compiled out `tinyA`,
`tinyB` and `taskStep`. Share error in points, then slowdown; in brackets
each phase's reported time over its true time:

| | `profile!` | `run --retime` | scopes only at the phases | `sample` |
|---|---|---|---|---|
| `tiny`, run 1 (load 10–12) | 8.2, 4.26× [0.83, 0.56] | 1.1, 1.14× [0.94, 0.99] | 0.8, 1.14× | 0.9, 1.03× |
| `tiny`, run 2 (load 5–6) | 9.6, 4.45× [0.91, 0.60] | 0.3, 1.19× [1.00, 1.00] | 0.2, 1.23× | 5.1, 1.33× |
| `tiny`, run 3 (load 5) | 9.0, 4.36× [0.82, 0.53] | 0.8, 1.19× [0.97, 1.01] | 0.4, 1.17× | 4.6, 1.28× |
| `tasks`, runs 1–3 | 0.9 / 2.1 / 1.9, 2.0× | 1.5 / 0.4 / 0.1, 1.14–1.19× | 2.0 / 0.3 / 0.1 | 1.9 / 3.7 / 4.0 |
| `rec`, runs 1–3 | 2.0 / 1.8 / 2.5, 2.1× | 2.2 / 1.4 / 1.6, 2.1× | 0.6 / 0.7 / 0.5 | 0.5 / 0.7 / 2.8 |

- `tiny`: from 8.2–9.6 points to 0.3–1.1, as close as scopes placed only
  at the phases (0.2–0.8), and 1.14–1.19× slower instead of 4.3–4.5×. The
  call counts of `tinyA` and `tinyB` are the first run's (exact).
- `tasks`: the `taskWork` rows, which call `taskStep`, are timed at
  0.98–1.06 of their time instead of 1.06–1.28; the share error, which is
  relative, was already small in run 1, where all three were off by about
  the same factor.
- `rec` has no scope that goes light (recursive scopes never do), so nothing
  is compiled out: the same as `profile!`. Its error is `fib`'s probes, a
  different problem.
- `sample` was 4.6–5.1 points off `tiny` in runs 2 and 3 (0.5–0.9 in other
  runs); not investigated here.

[full-suite.md](full-suite.md) is one run of the whole suite with
`run --retime`, at load 10–23 on the same machine: `tiny` 11.2 points under
`profile!` and 1.0 with `run --retime` (5.4× and 1.26× slower).

Not covered: monadic `profile!` scopes (`scopeM`, an `IO` action) are not
compiled out (the report names them as still timed); a label the awk script
does not find in the C code (characters C escapes) stays timed; and the
second run's report has no rows for the compiled-out scopes, only the
`compiled_out` list.
