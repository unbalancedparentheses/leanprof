# Reference

## Commands

Inside a project that depends on leanprof, use `lake exe leanprof …`;
otherwise install the command (`sh scripts/install.sh`) and use
`leanprof …`. `leanprof help COMMAND` prints a command's options.

| command | does |
|---|---|
| (none) `[-- ARGS]`, or `EXE [-- ARGS]` | in a Lake project: pick the workload (the one `lean_exe`; else the test driver when it is an executable; else compile time of the libraries, as `elab --project --compact`; several executables are listed, never chosen between), profile it the cheapest way (`sample` when samply can sample, else `stat`), print the top findings and the `run`/`explain`/`fix` commands that go deeper. `EXE` names one of the project's executables. Exit 2 when it lists executables instead |
| `run [--auto \| --auto-all] [--time-tiny] [--retime] [--allocs] [--counters] [--frees] [--core] [--all-copies] [--no-deps] [--trace F] [--json F \| --out F] [--keep] [--cwd DIR] EXE [-- ARGS]` | build with probes (dependencies included, unless `--no-deps`; their normal build is put back afterwards), run, report, clean up; `--core` also probes Lean's own libraries; `--all-copies` lists copies of constants and tiny values row by row; `--cwd` runs EXE in DIR; `--retime` runs a second time with the `profile!` scopes the first run found too small to time compiled out (their calls and estimates under `compiled_out`) |
| `stat [--auto \| --auto-all] [--no-allocs] [--no-frees] [--no-deps] [--trace F] [--json F \| --out F] [--keep] [--cwd DIR] EXE [-- ARGS]` | one-screen summary: time, CPU, peak memory, allocations, copies, frees, tasks, top scopes ([memory](memory.md)) |
| `sample [--rate HZ] [--top N] [--out F] [--json F] [--cwd DIR] EXE [-- ARGS]` | sample with samply (`--out`: samply's profile), report per Lean declaration (`--json`: a copy of the report); exits with the program's exit code. `EXE` is a target of the project, or a path to any program (`~/.elan/toolchains/…/bin/lean`): Lean code in Lean's shared libraries gets Lean names, and Lean's own declarations positions in the toolchain's sources |
| `elab [--heartbeats] [--project \| --module-glob G] [--jobs N] [--counts] [--threshold N] [--no-defs] [--top N] [--out F] [FILE.lean…]` | compile cost per file, declaration, tactic line and operation, and the definitions behind it ([compile time](compile-time.md)) |
| `compare [--threshold PCT] [--min-ms MS] BASE.json NEW.json` | exit 1 on regressions |
| `measure [--runs N] [--scope NAME] [--heartbeats-files F…] [--check-output F] [--ignore-lines TEXT…] [--no-allocs] [--core] [--no-deps] [--out F] EXE [-- ARGS]` | repeated runs into one summary (copies, allocations, calls, time of the process or, with `--scope`, of one `profile!` scope, output; `self_check_warning`, empty unless copies may be undercounted) |
| `measure-pair --base BIN --candidate BIN [--base-cwd DIR] [--candidate-cwd DIR] [--runs N] [--fixed] [--min-change PCT] [--scope NAME [--repeat N [--repeat-stat fastest\|median]]] [--warmup N] [--check-output F] [--ignore-lines TEXT…] [--out F] [-- ARGS]` | alternating AB/BA runs of prebuilt binaries until the time verdict is settled (at most N pairs, default 30); `--scope` times one `Leanprof.bench` region; `--repeat N` (opt-in) repeats it N times per run and counts the fastest (`--repeat-stat median`: the median), so the region must be repeatable; `--ignore-lines TEXT` leaves stdout's lines containing TEXT out of the output hash (in `measure` too: a benchmark's own timings); no builds or added probes |
| `judge [--min-change PCT] BASE.json NEW.json` or `judge [--min-change PCT] PAIR.json` | KEEP (exit 0) or DISCARD (exit 1); paired sessions use a 95% median interval |
| `explain [--report F] [--out F] [--top N] [--all] [--json] [--why EXE [-- ARGS]]` | why each copy of a shared value happened, with the fix as Lean code when the cause is recognised ([copies](copies-and-allocations.md#why-it-was-shared-leanprof-explain)) |
| `fix [--exe EXE [-- ARGS]] [--test CMD] [--check-output F] [--finding N] [--all] [--dry-run] [--report F] [--runs N] [--pairs N] [--no-deps] [--branch NAME] [--allow-overloaded]` | apply the fix `explain` prints for the costliest mechanically fixable copy. In a git worktree of HEAD, it builds, tests, compares the output, measures, times the plain binaries in pairs and judges. KEEP commits with the evidence on a new branch (exit 0); DISCARD creates no branch (exit 1). The checkout is never touched, also when interrupted; a tree with uncommitted changes is refused ([fix](fix.md)) |
| `experiment start [--exe EXE [--inputs DIR] [--cases F] [--heldout DIR] [--check-output F]… [-- ARGS]] [--test CMD \| --no-test] [--protect GLOB]… [--runs N] [--pairs N] [--min-change PCT] [--no-deps] [--base REV] [--id ID]`, `experiment try [REV \| --working-tree] [--time] [--no-commit] [--message MSG] [--allow-overloaded] [--json] [--id ID]`, `experiment finish [--keep-worktrees] [--json] [--id ID]`, `experiment status [--json] [--id ID]` | one experiment from baseline to verdict: `start` records the base in a git worktree (build, tests, behaviour on every case, held-out hashes, `measure`); `try` checks a commit or the working tree in its own worktree (build, proof-preservation guard, tests, identical behaviour on every case, then heartbeats if the generated C is unchanged, else exact counts and paired timing; without `--exe`, heartbeats of the changed modules and their dependents). Exit 0 KEEP, 1 DISCARD, 2 ERROR, 3 INCONCLUSIVE, evidence in `tries/N/evidence.json`; a KEEP becomes the base and is committed (working tree) or noted (commit). `finish` runs the held-out cases ([experiments](experiment.md)) |
| `report-md [--fail-on M,… \| none] [--title T] BASE.json NEW.json [BASE_ELAB.json NEW_ELAB.json]` | Markdown comparison for a pull-request comment; exit 1 if a `--fail-on` metric regressed |
| `html [-o F] [--trace F] [--profile F] [REPORT.json…]` | one self-contained HTML page: summary, flame graph, tables, source, comparison of two reports ([HTML report](html-report.md)) |
| `top [--interval MS] [--rows N] [--frames N] [--plain] [--flight DIR] [--slow-ms MS] [run options] EXE [-- ARGS] \| --attach F \| --pid PID` | live view of a running program, refreshed like `top` ([live](live.md)) |
| `dump [--timeout S] PID` | Perfetto trace of a running program's last seconds (flight recorder) |
| `mcp` | Model Context Protocol server on stdio for AI agents ([live](live.md#mcp-server)) |
| `doctor` | check the tools and project setup leanprof needs, and that copy detection works with this Lean ([self-check](how-it-works.md#self-check-is-copy-detection-working)) |

Reports go to `.lake/leanprof/`: `report.json` (run, stat, sample and
measure), `elab.json`, `measure.json`, samply's profile `EXE.json`, and the
page of `leanprof html`, `report.html`.

`report.json` is always the last report: `run`, `stat` and `sample` remove
it before they start (so a failed build or a killed program leaves none,
rather than an older one) and write it at the end, also when `--json FILE`
(`--out FILE` in `run` and `stat`) saves a copy elsewhere. `explain`,
`html`, `#leanprof` and the MCP `report`, `hot` and `explain` tools read it
unless given another file.

## Environment variables

For programs that link leanprof:

| variable | effect |
|---|---|
| `LEANPROF_JSON=path` | also write the report as JSON |
| `LEANPROF_QUIET=1` | no table on stderr |
| `LEANPROF_ALL=1` | include copies of compile-time constants and non-Lean functions |
| `LEANPROF_ALL_COPIES=1` | list copies of compile-time constants and of empty or tiny values row by row (set by `run --all-copies`) |
| `LEANPROF_TRACE=path` | also write a Perfetto timeline |
| `LEANPROF_TRACE_MAX=n` | timeline events kept per thread (default 1,048,576; with the flight recorder, the ring's size, default 262,144) |
| `LEANPROF_NO_CALIBRATION=1` | raw times, leanprof's own cost not subtracted |
| `LEANPROF_TIME_ALL=1` | time every call of scopes too small to time (by default timed on one call in about 64, and counted on all) |
| `LEANPROF_AUTO_TINY=1` | what `--time-tiny` sets: `--auto` also instruments functions too small to time |
| `LEANPROF_CLOCK=monotonic` | on Linux, time with `clock_gettime(CLOCK_MONOTONIC)` instead of the CPU's counter (TSC or `CNTVCT_EL0`) |
| `LEANPROF_ILEAN_DIR=dir` | where to find `.ilean` files for positions |
| `LEANPROF_STAT=1` | write the report even when nothing was recorded (set by `stat`) |
| `LEANPROF_LIVE=path` / `1` | rewrite a live snapshot every 250 ms (`1`: `$TMPDIR/leanprof-<pid>.live.json`) ([live](live.md)) |
| `LEANPROF_LIVE_MS=ms` | snapshot interval (default 250, at least 10) |
| `LEANPROF_LIVE_WINDOW_MS=ms` | recent percentiles cover the last one to two windows (default 1000) |
| `LEANPROF_LIVE_ROWS=n` | rows per snapshot section (default 100) |
| `LEANPROF_FLIGHT=dir` / `1` | flight recorder: timeline in bounded per-thread rings, dumped on `SIGUSR1` into `dir` (`1`: the current directory) |
| `LEANPROF_FLIGHT_SECS=s` | seconds a dump covers (default 10) |
| `LEANPROF_SLOW_MS=ms` | also dump when a scope takes `ms` or more (turns the recorder on) |
| `LEANPROF_SLOW_SCOPE=name` | only scopes with this name trigger slow dumps |
| `LEANPROF_SLOW_MAX=n` | at most `n` slow dumps (default 10) |
| `LEANPROF_PROJECT=dir` | the project, when the program runs elsewhere (set by `--cwd`): where `.ilean` files and packages are found |
| `LEANPROF_CORE_DIR=prefix` | a Lean toolchain (`lean --print-prefix`) whose `lib/lean/*.ilean` and `src/lean` give positions of Lean's own functions (set by `run`) |
| `LEANPROF_BENCH_OUT=file` | `Leanprof.bench "NAME"` appends `NAME<TAB>NANOSECONDS` to this file after each region (set by `measure-pair --scope`; any program may write the same lines without the dependency) |
| `LEANPROF_BENCH_REPEAT=N` | `Leanprof.bench` runs its region N times, each line ending in `<TAB>K`, its repetition (set by `measure-pair --scope NAME --repeat N`) |
| `LEANPROF_UNTIMED=file` | the compiler wrapper compiles out the pure `profile!` scopes listed in the file, `name<TAB>position` per line (set by `run --retime`) |

For `leanprof run --core`:

| variable | effect |
|---|---|
| `LEANPROF_HOME=dir` | where the installer put releases, the source checkout and samply (default `~/.local/share/leanprof`; the installed launcher sets it) |
| `LEANPROF_SAMPLY=path` | samply to run (default: `samply` on `PATH`, then `$LEANPROF_HOME/samply/samply`); `none` acts as if there were none |
| `LEANPROF_OBJCOPY=path` | objcopy used to rewrite Lean's libraries (default: `llvm-objcopy` on `PATH`, then Homebrew's and Debian's LLVM directories, then GNU `objcopy` on Linux, then rustup's `rust-objcopy`) |

For builds through the compiler wrapper `scripts/leanprof-cc` (set as
`LEAN_CC`):

| variable | effect |
|---|---|
| `LEANPROF_AUTO=1` / `all` | time every function of this package / of all packages |
| `LEANPROF_ALLOCS=1` | count allocations |
| `LEANPROF_COUNTERS=1` | count failed constructor reuse and closure applications (force-includes `c/counters.h`) |
| `LEANPROF_FREES=1` | time freeing cascades, count atomic decrements ([memory](memory.md)) |
| `LEANPROF_RUNTIME=file.o` | link this leanprof runtime (set by `run` for projects without the dependency) |
| `LEANPROF_CORE_LIB=dir` | search `dir` first for `-lInit`, `-lStd`, ... (set by `run --core` to the rewritten copies) |
| `LEANPROF_REAL_CC=cc` | compiler to forward to (default: Lean's own `leanc` on Linux, so instrumented builds compile and link like Lake's; elsewhere, and for sanitizer builds, the first `clang` on `PATH` that is not Lean's own) |

## JSON report

`report.json` (version 3) has `wall_ns`, `probe_ns` (the probes' calibrated
cost in it, on the busiest thread), `overhead_ns` (per scope),
`overhead_by_path_ns` (the calibrated cost of one scope entered each way:
`direct`, `auto` (the `--auto` hooks), `pure` (`profile!` on a pure term),
`closure` (`Leanprof.scope`), `monadic`), `run_ns` (the wall time without
the probes' cost, what every `pct_run` is a share of), `resolution_ns` (one
clock tick), `alloc_ns` (with allocations counted: the calibrated cost of a
small allocation and its free), `self_check` (`ok`, `lean` (the
version), `checked` (the operations run), `warning`: empty, or which kinds of
copies may be undercounted; see
[self-check](how-it-works.md#self-check-is-copy-detection-working)) and arrays:

- `scopes`: `name`, `pos`, `auto` (a function, not a `profile!` label),
  `calls`, `total_ns`, `self_ns`, `min_ns`, `max_ns`, `mean_ns`, `p50_ns`,
  `p99_ns`, `allocs`, `alloc_bytes`, `allocs_self`, `alloc_bytes_self`,
  `probes_ns` (the probes' cost in and around its outermost calls, which
  was subtracted from `total_ns`) and `near_probe_cost` (true when
  `probes_ns` is at least 0.3 of `total_ns`: take this row's time from
  `leanprof sample`, see [run time](run-time.md#overhead-and-accuracy)),
  `timed_calls` (a light scope: the calls actually timed) and `holds_tiny`
  (the light scopes it calls, when their probes cost at least 0.3 of its
  `total_ns`: those probes change its code, so its time is off whatever is
  subtracted; remove them and use `leanprof sample`);
- `copies`: `function`, `symbol`, `scope`, `where`, `kind`, `copies`,
  `bytes`, `copy_ns`, `shared`, `multi_threaded`, `persistent`, `pct_run`
  (`copy_ns` as a percentage of `run_ns`), `tiny` (true when the copies
  averaged at most 16 bytes and took under 1% of the run: grouped into one
  row of the terminal report, not hinted in the editor);
- `allocations`: `function`, `scope`, `where`, `allocs`, `bytes`, `est_ns`
  (`allocs` times `alloc_ns`, an estimate), `pct_run`;
- `tasks`: `spawned_by`, `tasks`, `run_total_ns`, `run_sum_ns`, `wait_ns`,
  `wait_max_ns`;
- `waits`: `function`, `scope`, `where`, `waits`, `blocked_ns`;

- `reuse` (with counters, else empty): per function, `function`, `where`,
  `checks`, `failures` (all failed checks), `shared`, `multi_threaded`,
  `persistent`, `fields` (total fields of the cells that failed), `sites`;
- `closures` (with counters, else empty): per call site and target,
  `function` and `where` (the call site), `target`, `target_where`,
  `target_symbol` (the closure's C function), `applications`, `exact`,
  `partial`, `over`.

and objects:

- `memory`: `peak_rss` and `peak_commit` (bytes), `start_commit`,
  `end_commit`, `wall_ns`, `user_ns`, `sys_ns` (the program from start to
  exit), `samples`, and `scopes`: `name`, `pos`, `sampled_calls`,
  `peak_commit`, `max_rise`;
- `frees` (only in builds with free tracking): totals `cascades`,
  `objects`, `free_ns`, `p50_ns`, `p99_ns`, `max_ns`, `mt_decrements`, and
  the same per site in `sites` (`function`, `scope`, `where`) and per scope
  in `scopes` (`scope`, `pos`).

`scopes`, `copies`, `tasks` and `waits` rows have `too_small` (only when it
is not empty): the names of their time fields too small to measure, written
as 0. For a scope that is what is left after subtracting the probes' cost
(shown as `< probe` in the terminal and `< probe cost` in the HTML report,
the editor, `compare` and the MCP tools); for a copy, wait or task, less
than one clock tick (`< 1 ns` on an M5, `< 42 ns` on earlier Apple chips;
`< 1 clock tick` outside the terminal). Read a field listed there as
"below what leanprof can measure", never as 0.

Sampled reports add `"sampled": true`, `exe`, `exit_code`, `runtime`
(the Lean runtime's self time by category: `category`, `self_ns`) and, for
the project's own functions, `own_ns` (their self time plus that of code
outside the project they called directly) and `own_top` (that code's three
costliest functions: `name`, `ns`). Compile reports from `elab` have
`"elab": true`, `"project"` (true with `--project`), `"unit": "ns"` or
`"heartbeats"`, `threshold`, `timing` (`build_ns`, `profile_ns`,
`report_ns`, `jobs`) and arrays:

- `scopes`, per line: `name`, `pos`, `key` (`file declaration`, what
  `compare` matches), `total_ns`, `elab_ns`, `kernel_ns`, `compile_ns`,
  `lint_ns`, `top` operations (`amount`, `op`) and `unfolded`: the
  definitions behind the line's work (`name`, `kind`: `unfold`, `whnf`,
  `instance` or `simp`, `amount`, `count`, `sites`, `where`, `path`);
- `files`: `file`, `module`, `key` (`module M`), `total_ns`, `elab_ns`,
  `kernel_ns`, `compile_ns`, `lint_ns`, `wall_ns` (the `lean` process,
  imports included), `errors`;
- `tactics`: `pos`, `tactic`, `amount`, `count`;
- `repeated`: `class`, `op`, `count`, `total`, `first_at`;
- `constants`: as in `unfolded`, plus `module` and the exact counts
  `unfolds`, `kernel`, `instances`, `simp_used`, `simp_tried`,
  `simp_failed` when nonzero.

Compile reports also have `kinds`: self cost per operation kind (`class`,
`total`), for `leanprof html`.

## Measure summary

`measure.json` (`"leanprof": "measure"`, version 1), what `judge` reads:
`command`, `runs`, `scope` (the `--scope` name, or null: `time_ns` is the
whole process), `exit_code`, `output` (`source`, `hash`, `stable`),
`time_ns` (`median`, `min`, `max`, `runs`; with `--scope`, `too_small_runs`:
runs whose scope time was too small to measure, which `judge` does not
judge on time), `copies_total`,
`copies_stable`, `copies` (`key`, `copies` per site), `calls` (`key`,
`calls` per scope), `allocs_total` (the last run's allocations by compiled
Lean code), `allocs_runs` (each run's total), `allocs_stable`,
`alloc_bytes_total`, `allocs` (`key` "function in scope", `allocs`), and
`heartbeats_total` and `heartbeats` (`key`, `heartbeats`) with
`--heartbeats-files`. The allocation fields are `null` with `--no-allocs`;
`judge` then does not compare allocations.

## Live snapshot

The file `LEANPROF_LIVE` names (rewritten atomically) has `leanprof_live`
(1), `pid`, `seq`, `exited` (the final snapshot, written at exit),
`interval_ms`, `ts_ns` (since start), `overhead_ns`, `threads`, objects
`memory` (`rss`, `commit`, `peak_rss`, `peak_commit`), `cpu` (`user_ns`,
`sys_ns`), `flight` (`dir`, `secs`, `slow_ms`, `dumps`, `last`, or null),
and arrays, each with `name` and `where` (file:line), cumulative since
start:

- `scopes`: `auto`, `calls`, `total_ns`, `self_ns`, `max_ns`, `p50_ns`,
  `p99_ns`, `allocs`, `alloc_bytes`, and `recent` (`calls`, `p50_ns`,
  `p99_ns` of the calls in the last one to two windows);
- `tasks` (`name` is the spawning scope): `tasks`, `run_ns`, `wait_ns`,
  `wait_max_ns`;
- `copies` (`name` is the function): `scope`, `kind`, `copies`,
  `persistent`, `bytes`, `copy_ns`, `tiny` (as in the report, against the
  time so far; `top`, MCP `live` and `hot` summarize such rows in one line,
  and `LEANPROF_ALL_COPIES=1` turns the mark off);
- `allocations`: `scope`, `allocs`, `bytes`; `waits`: `scope`, `waits`,
  `blocked_ns`;
- `stacks`: per busy thread, `thread` and `frames` (`name`, `elapsed_ns`),
  outermost first.

Rates are differences between two snapshots over their `ts_ns`.

## GitHub Action and releases

The GitHub Action (`uses: unbalancedparentheses/leanprof@main`) is
described in [CI and regressions](ci-and-regressions.md#github-action).
Prebuilt commands for macOS arm64 and x86-64 and Linux x86-64 and arm64 are
attached to each
[release](https://github.com/unbalancedparentheses/leanprof/releases);
[RELEASING.md](../../RELEASING.md) says how to make one and what the
archives contain.

### Paired measurement sessions

`paired.json` (`"leanprof": "measure-pair"`, version 2) stores one chronological
session. `samples` contains `pair`, `side`, `time_ns`, `exit_code`,
`stdout_hash`, `stderr_hash`, `output_hash`, and `output_present` for every run
(with `--scope`, `time_ns` is the region's time and `process_ns` the whole run's).
`design` records the sequential rule (`max_runs`, `first_look`, `look_every`,
`alpha`), `runs` the pairs measured, and `scope` and `min_change` what was
asked; `judge` also reads version 1 sessions (one look after all pairs).
The file also records resolved binary paths, before/after-checked binary
fingerprints, per-side working directories, common arguments, warmup/run counts
and per-pair machine load. No exact runtime metrics are inferred from plain
binaries. See [interleaved timing](ci-and-regressions.md#interleaved-timing-of-ordinary-binaries)
for the confidence interval, exit codes and assumptions.
