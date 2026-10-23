# Reference

## Commands

Inside a project that depends on leanprof, use `lake exe leanprof …`;
otherwise install the command (`sh scripts/install.sh`) and use
`leanprof …`. `leanprof help COMMAND` prints a command's options.

| command | does |
|---|---|
| `run [--auto \| --auto-all] [--allocs] [--counters] [--frees] [--core] [--trace F] [--json F] [--keep] [--cwd DIR] EXE [-- ARGS]` | build with probes, run, report, clean up; `--core` also probes Lean's own libraries; `--cwd` runs EXE in DIR |
| `stat [--auto \| --auto-all] [--no-allocs] [--no-frees] [--trace F] [--json F] [--keep] [--cwd DIR] EXE [-- ARGS]` | one-screen summary: time, CPU, peak memory, allocations, copies, frees, tasks, top scopes ([memory](memory.md)) |
| `sample [--rate HZ] [--top N] [--out F] [--cwd DIR] EXE [-- ARGS]` | sample with samply, report per Lean declaration; exits with the program's exit code |
| `elab [--heartbeats] [--top N] [--out F] FILE.lean…` | compile cost per declaration and operation |
| `compare [--threshold PCT] [--min-ms MS] BASE.json NEW.json` | exit 1 on regressions |
| `measure [--runs N] [--heartbeats-files F…] [--check-output F] [--out F] EXE [-- ARGS]` | repeated runs into one summary |
| `judge BASE.json NEW.json` | KEEP (exit 0) or DISCARD (exit 1) |
| `report-md [--fail-on M,… \| none] [--title T] BASE.json NEW.json [BASE_ELAB.json NEW_ELAB.json]` | Markdown comparison for a pull-request comment; exit 1 if a `--fail-on` metric regressed |
| `doctor` | check the tools and project setup leanprof needs |

Reports go to `.lake/leanprof/`: `report.json` (run and sample),
`elab.json`, `measure.json`, and samply's profile `EXE.json`.

## Environment variables

For programs that link leanprof:

| variable | effect |
|---|---|
| `LEANPROF_JSON=path` | also write the report as JSON |
| `LEANPROF_QUIET=1` | no table on stderr |
| `LEANPROF_ALL=1` | include copies of compile-time constants and non-Lean functions |
| `LEANPROF_TRACE=path` | also write a Perfetto timeline |
| `LEANPROF_TRACE_MAX=n` | timeline events kept per thread (default 1,048,576) |
| `LEANPROF_NO_CALIBRATION=1` | raw times, leanprof's own cost not subtracted |
| `LEANPROF_ILEAN_DIR=dir` | where to find `.ilean` files for positions |
| `LEANPROF_STAT=1` | write the report even when nothing was recorded (set by `stat`) |
| `LEANPROF_PROJECT=dir` | the project, when the program runs elsewhere (set by `--cwd`): where `.ilean` files and packages are found |

For `leanprof run --core`:

| variable | effect |
|---|---|
| `LEANPROF_OBJCOPY=path` | objcopy used to rewrite Lean's libraries (default: `llvm-objcopy` on `PATH`, then Homebrew's and Debian's LLVM directories, then GNU `objcopy` on Linux) |

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
| `LEANPROF_REAL_CC=cc` | compiler to forward to (default: the first `clang` on `PATH` that is not Lean's own) |

## JSON report

`report.json` (version 3) has `wall_ns`, `probe_ns` (the probes' calibrated
cost in it, on the busiest thread), `overhead_ns` (per scope) and arrays:

- `scopes`: `name`, `pos`, `auto` (a function, not a `profile!` label),
  `calls`, `total_ns`, `self_ns`, `min_ns`, `max_ns`, `mean_ns`, `p50_ns`,
  `p99_ns`, `allocs`, `alloc_bytes`, `allocs_self`, `alloc_bytes_self`;
- `copies`: `function`, `symbol`, `scope`, `where`, `kind`, `copies`,
  `bytes`, `copy_ns`, `shared`, `multi_threaded`, `persistent`;
- `allocations`: `function`, `scope`, `where`, `allocs`, `bytes`;
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

Sampled reports add `"sampled": true`; compile reports from `elab` have
`"elab": true`, `"unit": "ns"` or `"heartbeats"`, per-line `elab_ns`,
`kernel_ns`, `compile_ns`, `lint_ns`, `top` operations, and `repeated`.

## GitHub Action and releases

The GitHub Action (`uses: unbalancedparentheses/leanprof@main`) is
described in [CI and regressions](ci-and-regressions.md#github-action).
Prebuilt commands for macOS arm64 and Linux x86-64 are attached to each
[release](https://github.com/unbalancedparentheses/leanprof/releases);
[RELEASING.md](../../RELEASING.md) says how to make one and what the
archives contain.
