# Case study: autoresearch on leanprof itself

leanprof's own autoresearch loop ([research/program.md](../../research/program.md))
was run on leanprof's Lean code: one idea per experiment, a fixed measure
command, `leanprof judge` deciding KEEP or DISCARD, and the tests and smoke
facts as the oracle. It ran on 2026-10-23 on an 18-core Apple Silicon Mac
shared with other agents (load average 10–98 during the session), with Lean
4.35.0. It kept 7 of 11 changes: `leanprof elab`'s trace processing uses about
30% less CPU, and `leanprof html` on large reports uses 46% less. This page
also lists what made the loop hard to run, as input for a one-command
autoresearch in v0.2.0.

## Setup

**Tool and subject are separate checkouts of the same commit** (`ed10f92`):

- the *measurer*, a detached worktree whose `.lake/build/bin/leanprof` ran
  every `measure`, `judge`, `sample`, `run` and `explain`, and was never
  rebuilt during the session;
- the *subject*, the branch's worktree, whose own `leanprof` executable was
  the program being measured and changed.

They did not interfere. The subject links leanprof's runtime (as every
`lean_exe` of this package does), and `measure` rebuilt it with the
measurer's copy shims and put the normal build back each time. Reports were
written by the subject's runtime, from the unchanged `c/`.

A third worktree held the **base** commit. Base and new were measured back to
back for every experiment, instead of once at the start: with other agents
starting and stopping builds, a summary measured an hour earlier says nothing
about the machine now (see friction 7). It must have the same directory name as
the subject (friction 5).

### Workloads

**W1: `leanprof elab --heartbeats` on 77 files without running Lean.** The
input is
[lean-compiler-backend](https://github.com/unbalancedparentheses/lean-compiler-backend)
(77 modules, 12.7k lines), rebuilt with Lean 4.35. For each file, the
output of `lean --json` with elab's trace options was recorded once (45 MB in
total, 661,200 trace lines). A fake toolchain on `PATH` replays it: a copy of
`lake`, a `lean` script that `cat`s the saved trace when the arguments contain
`-Dtrace.profiler=true` and the file has one, and runs the real `lean`
otherwise. A symlink `LeanCompilerBackend -> lcb/LeanCompilerBackend` in each
worktree (excluded from git), plus `LEAN_PATH` and `LEAN_SRC_PATH` pointing at
the copy's build, makes the module names and the definition lookup
(`locate`) the same as in a real run. The workload is then leanprof's own
work: reading the messages, parsing traces, aggregating, importing the
modules to find definitions, and printing. It takes about 3.7–4.2 s on a
quiet machine.

```
leanprof measure --runs 5 --heartbeats-files LeanprofElab.lean LeanprofHtml.lean LeanprofCli.lean \
  --check-output .lake/research/w1-unchecked --out .lake/research/TAG-w1.json \
  leanprof -- elab --heartbeats --no-build --jobs 1 --out .lake/research/w1-elab.json LeanCompilerBackend/....lean (77 files)
```

elab's output contains wall times, so the measure's output check points at a
file that never exists (its hash is `missing` on every run, which is stable). An
external oracle checks the output instead: on every experiment it runs the
subject once and compares its JSON (without `timing` and `wall_ns`) and stdout
(with times masked) with the baseline's. Every experiment that reached
measurement matched.

**W2: `leanprof html` comparing two large elab reports.** The inputs are two
elab reports of the same project, 0.9 MB (threshold 10,000) and 2.7 MB
(threshold 1,000). The page is 3.7 MB, written byte-identically on every run.

```
leanprof measure --runs 5 --check-output .lake/research/w2.html --out .lake/research/TAG-w2.json \
  leanprof -- html -o .lake/research/w2.html lcb-elab-a.json lcb-elab-t1000.json
```

**TEST**: `lake build tests && LEANPROF_QUIET=1 .lake/build/bin/tests && python3
scripts/smoke.py --check` (all 20 smoke facts must match), plus the W1 oracle.

**Supplemental evidence.** On a loaded machine the wall-time verdicts were
often load drift (see friction 7). Every experiment therefore also ran both
binaries alternately, base, new, base, new (5 each), and compared their user+sys
CPU time. That number is reported but did not override the judge, with one
exception: when the judge's KEEP rested only on time, a CPU median that did not
improve meant no keep.

## Results

Every experiment, in order (times are the judge's medians for the new
summary; `compile` is the heartbeats of the three measured files):

| commit | verdict | W1 ms | W1 copies | W2 ms | W2 copies | compile kHB | change | interleaved CPU |
|---|---|---:|---:|---:|---:|---:|---|---|
| `ed10f92` | baseline | 4,203 | 16,771 | 184 | 1,414 | 144,521 | | |
| `89c7d25` | KEEP | 4,206 | 16,771 | 200 | 1,414 | 144,629 | `traceLine` on slices instead of `List Char` | W1 −24% |
| `f394c0c` | KEEP | 6,795 | 16,771 | 351 | 1,414 | 144,624 | a trace node's description stays a slice, copied only when read | W1 −1.3% (judge's wall gain was mostly drift) |
| – | DISCARD | 5,298 | 16,771 | 341 | 1,414 | 144,626 | leak the jointly imported environment in `locate` | W1 −3%, within noise |
| `d09f643` | KEEP | 5,111 | 16,771 | 204 | 1,414 | 144,625 | html: escape `<` in the page's data a byte at a time, not `String.replace` | W2 −46% |
| `079df3e` | KEEP | 4,523 | 16,771 | 154 | 1 | 144,711 | html `sources`: `HashMap.alter` instead of `getD` + `insert` | unchanged |
| `2366b31` | KEEP | 4,515 | 14,195 | 150 | 1 | 145,138 | `Acc.addConst`/`addDiag`: `alter` instead of `getD` + `insert` | unchanged |
| `638afaf` | KEEP | 3,749 | 14,195 | 150 | 1 | 145,433 | `traceLine`: count the indentation a byte at a time, return unless `[` follows | W1 −4% |
| – | DISCARD | 4,403 | 14,195 | 285 | 1 | 145,746 | `findTactic`: `String.contains` instead of `splitOn` | W1 +6.5%, noisy (load 20) |
| – | DISCARD | 7,224 | 14,195 | 201 | 1 | 145,386 | `normalizeOp`: build a `String` instead of appending to a list | W1 −10.9%, judged within noise (load 30) |
| – | DISCARD | 8,566 | 14,195 | 238 | 1 | 145,436 | continuation lines: `dropWhile` on the string, no list round trip | W1 −4.6%, within noise (load 45) |
| `b74e10a` | KEEP | 7,396 | 13,328 | 275 | 1 | 145,664 | elab `main`: `alter` for the per-file map of named lines | noisy (load 25–35) |

The KEEPs at `079df3e`, `2366b31` and `b74e10a` come from exact copy counts.
Their time did not change measurably. The DISCARDs of `findTactic`,
`normalizeOp` and the continuation lines were all judged at load averages of
20–45: their CPU times suggest two of them help (the list append in
`normalizeOp` is quadratic), and they are worth measuring again on a quiet
machine. The loop stopped after about 2 hours of active time, when an hour of
load 25–55 made wall-time verdicts noise.

### Before and after

Original baseline (`ed10f92`) against the final commit (`b74e10a`), measured
back to back at the end (load average 40–51):

| workload | judge | wall median (5 runs each) | copies | CPU user+sys (5 interleaved runs each) |
|---|---|---|---|---|
| W1 elab | KEEP (copies) | 7,875 → 7,711 ms, within noise (5,980–9,332 vs 5,781–9,672) | 16,771 → 13,328 | 5.45 → 3.82 s (**−30%**; ranges 5.41–5.99 vs 3.41–4.04) |
| W2 html | KEEP (copies and time) | 589 → 200 ms (every run faster) | 1,414 → 1 | 0.28 → 0.15 s (**−46%**) |

On the quieter stretch of the session (load about 10), W1's wall median went
from 3,925 to 3,749 ms for the last `traceLine` change alone. Before the first
change, `traceLine` was 36% of W1's CPU. After both, the parser's own time is
small next to `Lean.importModules` (reading the 77 modules' `.olean` files to
find definitions, about a quarter of the run) and UTF-8 validation of the
trace text.

## Friction in the loop

What made this hard, roughly in order of cost:

1. **elab cannot replay saved output.** Every elab workload runs Lean, which
   dwarfs leanprof's own processing. `lake env` ignores `LEAN`, so the only way
   to substitute `lean` was a fake toolchain (a copied `lake` plus a wrapper
   `lean`). Its `clang` symlink then made `leanprof-cc` pick the toolchain's
   clang, which has no system headers, until `LEANPROF_REAL_CC=/usr/bin/clang`
   was set. A `--replay DIR` or `LEANPROF_LEAN` override would make elab
   measurable.
2. **No way to check output that contains times.** `--check-output` hashes
   whole files. elab's stdout and JSON both carry wall times, so the judge would
   reject every change. The workaround (a check file that never exists, plus an
   external normalised diff) loses the judge's output check. Needed:
   `--check-output FILE --ignore-json-keys timing,wall_ns` or `--check-cmd`.
3. **`measure` has no `--cwd` and needs a Lake target.** EXE must be a
   `lean_exe` of the current directory, run in that directory. A program cannot
   be measured on another project's files from that project, which forced the
   symlink and `LEAN_PATH` arrangement above.
4. **elab on files outside the project falls off a cliff.** Given absolute
   paths, module names become `«».Users.…`, the joint import in `locate` fails
   and it imports the 77 modules one at a time: 25 s instead of 0.55 s. With a
   project on a different Lean, `.olean` files fail with "incompatible header".
5. **Output depends on the directory name.** `html` puts the current directory's
   name in the title and data, so the same code in `base/` and `autoresearch-self/`
   hashed differently. The judge reported "output changed" until the base
   worktree had the same name.
6. **Relative symlinks break under `git worktree move`.** Moving the base
   worktree turned `../lcb` into a dangling link. The W1 output changed silently
   (different copy sites, no source lines in the page); only the oracle caught it.
7. **Wall time on a shared machine.** Base and new are measured minutes apart,
   five runs each. Load drift then decides "every new run faster/slower":
   `html`, which a change had not touched, was judged slower by 28–65% three times
   and faster by 15% once. A W1 change worth 1.3% of CPU was judged a
   40% wall-time gain. The fixes are interleaving runs (base, new, base, new)
   inside one `measure` invocation, judging CPU time from `rusage` (or
   instructions) beside wall time, and reporting the load average with every
   summary.
8. **A stale base.** program.md measures the base once. Under changing load
   it has to be measured again before each experiment, which needs a second
   worktree at the base commit, rebuilt after every KEEP.
9. **Copies are counted, not weighed.** Three KEEPs here rest on copy counts
   whose total cost was under a millisecond, while two changes with 5–11% CPU
   gains were DISCARDed for noise. Copies "of a constant" (the first insert
   into an empty `HashSet` literal: 2,769 here) are expected, yet they count in
   `copies_total`. The judge should weigh copies by bytes or time, and leave out
   constant copies.
10. **Heartbeat files are fixed up front.** `LeanprofHtml/Assets.lean` turned
    out to hold the html hot spot, but adding it to `--heartbeats-files` would
    have changed the experiment, so its compile cost was not checked. A default
    of "the files the diff touches" (judged per file) would fit.
11. **Specialization names mislead.** The `String.replace` on the page data
    showed as `LeanprofHtml.escapeHtml (in WellFounded.opaqueFix₃)`, and the
    copies in html's `sources` as `LeanprofHtml.traceTree (in …insertIfNew)`,
    named after the first function that needed the specialization (`sample`
    notes this; `run` and `measure` do not).
12. **Each experiment takes about 4–5 minutes** for 25 s of workload.
    `measure` rebuilds the subject with shims each time (the fake toolchain's
    sysroot also invalidates Lake's traces), and compile heartbeats re-elaborate
    the three files.
13. **Concurrent runs collide.** `scripts/smoke.py` writes fixed
    `/tmp/smoke-*.json` paths. The tests failed once under load ("1 failed")
    and passed when rerun.
14. **`sample` is not a workload.** It always reruns samply, so its
    post-processing (symbolication, aggregation) cannot be measured
    deterministically. A mode that reprocesses a saved profile would allow it.
15. **Small setup snags.** The branch name program.md suggests,
    `autoresearch/<date>-<topic>`, cannot be created while a branch named
    `autoresearch` exists (git refuses the nested ref). macOS has no `timeout`.
    results.tsv has one time column, so two workloads needed custom columns and
    a rule for combining their verdicts.

## Reproducing

The scripts lived outside the repository, next to the worktrees:
`measure.sh` (the two fixed commands), `oracle.sh` (W1's normalised output),
`exp.sh` (TEST, oracle, base and new measured back to back, both judges,
interleaved CPU), `record.sh` (saves the traces) and the fake toolchain's
`lean`. Most of them would become unnecessary with fixes 1–3 and 7.
