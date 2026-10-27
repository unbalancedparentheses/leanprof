# Changelog

All notable changes to leanprof. Versions follow [semantic
versioning](https://semver.org); a release is a `vX.Y.Z` tag (see
[RELEASING.md](RELEASING.md)).

## [Unreleased]

Compile time first: most Lean users wait on elaboration, not on programs.

### Added

- `leanprof elab --why`: for the costliest declarations, the causes the
  profile shows and a change to try, observed facts and suggestions kept
  apart. Causes: a costly `simp` (with Lean's own `simp only [...]` list for
  each call, from `tactic.simp.trace`), a termination measure Lean searched
  for (`decreasing_tactic` run once per measure tried, with the measure it
  found, from `showInferredTerminationBy`), definitions `isDefEq` or `whnf`
  unfolded, instance searches that failed (new in `elab.json`:
  `instances_failed` per declaration), costly instances, `decide` (with
  `decide +kernel` or `rfl`, and why `native_decide` is not a fix), the
  kernel, repeated work and `grind`. Also `leanprof explain --elab` (or
  `--report` an elab report), `--json`, and over MCP (`elab` with `why`,
  `explain` on an elab report). `elab.json` gains `simp_suggestions` and
  `termination_suggestions`.
- `leanprof elab --max-heartbeats N`: every declaration above N thousand
  heartbeats (`maxHeartbeats`' unit), exit 1 if there is one; in
  `elab.json` as `budget`. `report-md --max-heartbeats N`, the Action's
  `max-heartbeats` input and the MCP `elab` tool's `max_heartbeats` do the
  same in CI.
- `leanprof fix --elab [FILE.lean...]`: applies the mechanical edits `--why`
  finds (`simp` → Lean's `simp only` list; Lean's inferred `termination_by`
  after a recursive declaration) as one commit, judged by `leanprof
  experiment`: build, proof-preservation guard, tests, heartbeats of the
  changed modules and their dependents. Edits whose file no longer builds or
  whose declaration got dearer are dropped and the rest tried again. A KEEP
  is a commit with the evidence on a new local branch; the checkout is not
  touched. `scripts/experiment-check.sh` runs it on `Tests/FixElab`.
- [Case study](docs/case-studies/compile-time-fixes.md): Batteries and
  Mathlib, heartbeats before and after.

### Changed

- `judge` and `experiment` keep a change that makes some declarations
  cheaper by more than 1% and 1,000 heartbeats each and none dearer, even
  when that is less than 1% of a large module's total.
- The proof-preservation auditor records symbolic links other than Lean
  sources by their target instead of refusing the project (Batteries has
  one), and imports modules one at a time when they cannot be imported
  together (Batteries' test modules).

## [0.1.0] - 2026-10-26

The first release: a profiler for Lean 4 programs and their compile times,
for Lean 4.27 through 4.35 on macOS (arm64, x86-64) and Linux (x86-64,
arm64). Nothing to change in the profiled project. The detailed log of the
work before this release is under "Development before 0.1.0" below.

### Install and first run

- One command: `curl -sSfL https://raw.githubusercontent.com/unbalancedparentheses/leanprof/main/scripts/install.sh | sh`
  installs the prebuilt command for macOS arm64 or x86-64 and Linux x86-64
  or arm64 from the latest release (checked against `SHA256SUMS`), offers
  to fetch samply for sampling (`--samply`, `--no-samply`), or builds from source
  when there is no release for the platform. `--release VERSION`,
  `--source`, `--bin DIR`; from a clone it builds the clone.
- `leanprof` with no arguments in a Lake project profiles its workload (the
  executable, the test driver, or the libraries' compile time) and prints
  the top findings with the exact command for each next step;
  `leanprof EXE -- ARGS` profiles one executable.
- `leanprof doctor` checks Lean, the C compiler, samply and the project;
  `leanprof help [COMMAND]`.
- Release archives for the four platforms and the VS Code extension as a
  `.vsix`; use as a library with
  `require leanprof from git "https://github.com/unbalancedparentheses/leanprof" @ "v0.1.0"`.

### Any Lake project, unchanged

- `run`, `sample`, `stat`, `top`, `elab` and `measure` work on any Lake
  project with no dependency on leanprof: its runtime is compiled for the
  project's own Lean version and linked in, instrumented objects are
  removed afterwards, and the normal executable is restored. Programs run
  with `lake env`'s environment, so those that load Lean modules work.
- Names are demangled like Lean's own demangler and given `File.lean:line`
  from `.ilean` files.

### Run time

- `leanprof sample`: CPU time per Lean declaration with file:line, through
  samply on macOS and Linux and with no probes; specializations under the
  declaration that caused them; the Lean runtime's own time broken down; a
  profile with Lean names for Firefox Profiler.
- `leanprof run`: time and calls per `profile!` scope, total and self, mean,
  p50/p99. Counts are exact; times are calibrated estimates: leanprof
  measures its probes' cost at startup (about 5–8 ns per scope on the Mac,
  23 ns on Linux) and subtracts it.
- `--auto`: every function timed with no annotations; functions too small
  to time (straight-line code calling only O(1) runtime operations) are
  left untimed and listed, their time in their callers' (`--time-tiny`
  times them). Callers of `profile!` scopes too small to time are marked.
- Tasks linked to the spawning scope, with run time and queue wait;
  Perfetto timelines with copies as markers.

### Copies, allocations, memory

- Copies of non-exclusive `Array`, `ByteArray`, `FloatArray` and `String`
  values: per function and scope, with bytes, time, file:line and why
  (`shared`, `multi-threaded`, `persistent`), on every supported Lean.
- `leanprof explain`: why each copy happened, from the compiler's IR, and
  the fix as code; `--why` confirms it at run time from the reference
  increments.
- `--allocs`, `--counters` (failed constructor reuse, closure applications),
  `--frees`; peak memory per scope and memory over time; `leanprof stat`;
  `--core` for copies inside Lean's own libraries.

### From a finding to a verified change

- `leanprof fix`: applies `explain`'s fix when it is a mechanical rewrite
  whose preconditions the code shows, in an isolated git worktree; builds,
  tests, compares output, measures both versions, and commits only on KEEP,
  with the evidence in the message, on a new branch. Your checkout is never
  touched.
- `leanprof experiment start/try/finish/status`: one experiment operation
  for people and agents. A baseline (build, tests, behaviour on every
  case, held-out cases as hashes, measurements); each candidate is built,
  checked by the proof-preservation guard (a `sorry`, a new axiom, a
  removed theorem or a changed test is a DISCARD; a changed theorem
  statement is INCONCLUSIVE), tested, compared case by case,
  and judged by exact counts first, compile heartbeats for proof-only
  changes, then paired timing. KEEP, DISCARD or INCONCLUSIVE with the
  reason.
- `leanprof measure-pair`: interleaved AB/BA runs with a paired 95% median
  interval, stopping as soon as the verdict is settled (a group-sequential
  sign test); `--scope` times one region, `--base-rev` builds the base
  revision once and caches it. `leanprof judge` turns it into a verdict
  with `--min-change`.

### Compile time

- `leanprof elab FILE...` or `--project`: compile cost per line and
  declaration from Lean's `trace.profiler` trees, by kind (elaboration,
  kernel, compiler, linters), with exact source ranges on every supported
  Lean through a driver built once per toolchain and cached.
- The definitions behind the work, each with file:line: what `isDefEq` and
  `whnf` unfolded, instances tried, simp lemmas used; `--heartbeats` for
  counts that repeat nearly exactly; `--counts` for Lean's exact counters.
- A project view and an interactive viewer in the HTML report.

### Reports, CI and regressions

- `leanprof html`: one self-contained page with a flame graph, sortable
  tables, source lines with the findings, and a comparison.
- `leanprof compare`: exit 1 on regressions (copies, calls and heartbeats
  exact, time thresholded), and why each regression happened: the
  unfolds, instances, simp lemmas and copy sites whose counts changed.
- GitHub Action: profiles a pull request's base and head and posts one
  comment with the changes and their causes.
- Lean API for tests: `Leanprof.expectNoCopies`, `expectAllocsAtMost` and
  others; `Leanprof.bench` for timed regions.

### Live, editors, agents

- `leanprof top`: a running program, refreshed like top; a flight recorder
  (`leanprof dump PID`, or when a scope is slower than `LEANPROF_SLOW_MS`).
- `#leanprof` inlay hints and a VS Code extension.
- `leanprof mcp`: an MCP server exposing run, sample, explain, elab,
  measure, `measure_pair`, judge, fix and the experiment tools, restricted
  to Lake projects (see the security review in `docs/reviews/`).

### Accuracy and evidence

- A benchmark and accuracy suite (`bench/`) against workloads with known
  answers, samply and LeanProfiler, on macOS and a dedicated Linux machine;
  `scripts/reproduce.sh` re-runs each published claim.
- Case studies on lean-compiler-backend, concrete, doc-gen4, verso,
  lean-regex and Batteries, and the known issues found by dogfooding
  (README, "Known issues").

## Development before 0.1.0

The detailed log of the work between the first draft of 0.1.0
(2026-10-23) and its release. The section above is the release notes.

### Lean 4.27 to 4.33

- leanprof supports projects on Lean 4.27 and later (4.34 before): `run`,
  `stat`, `sample`, `measure`/`judge`, `explain`, `elab` and the library
  (`profile!`, `#leanprof`). CI requires 4.27.0 and 4.31.0 besides 4.34.1
  and 4.35.0, on Linux and macOS, and runs 4.28.1, 4.29.1, 4.30.0, 4.32.2
  and 4.33.1 on Linux as advisory jobs.
- Copies: before Lean 4.28, `Array.set!` and the other in-place updates copy
  through `lean_copy_expand_array` (no `_nonlinear` gadget yet), and before
  4.35 `ByteArray.set!`/`FloatArray.set!` through `lean_copy_byte_array`/
  `lean_copy_float_array`: both are shimmed (`scripts/leanprof-cc` and
  `copyFlags`). The `ByteArray.set!` copies were not counted on 4.34 either;
  the self-check now runs all six operations on every version.
- The runtime reads reference counts from the field before Lean 4.33 (no
  `lean_internal_get_rc`).
- `profile!` labels compile on Lean before 4.31, whose C backend wrote their
  `\x1f` separator as a hex escape that swallowed a following hex digit
  (`Examples/...` failed to compile): there the position is written after
  `./`, which the runtime drops.
- `leanprof-elab-driver` builds on each of these versions: the API that
  changed (trace results from 4.29, `processHeaderCore`'s header syntax from
  4.31) is written once per version range with `#lean_since N ... #lean_else
  ... #lean_end`. Before 4.29 a trace node has no stored result; its status
  mark is read from its message, and a node without one is marked ✅️ (the
  traces `lean --json` prints on those versions lack it, which is why
  `elab` without the driver saw only a few operations there).
- `explain` on Lean before 4.30, whose C has no source variable names
  (`x_12`, not `v_buckets_12_`): an element read out of an array is matched
  to its source line again (a placeholder such as "a temporary" was taken
  for a variable name, and `nested-array-element` had no fix), and an array
  updated inside `for x in xs` is reported as `loop-over-updated-array`
  when the compiler keeps the loop's variables in one tuple (it was
  `field-of-kept-structure`).
- Small source changes so that the library, the command and the test suite
  build with Lean 4.27 (types that older elaborators did not infer, an import
  for `String.splitOn`, the hardware thread count through the runtime
  function directly).

### Callers of tiny `profile!` scopes are marked

- A row that calls a light scope (one too small to time, timed on a sample
  of its calls), when that scope's probes cost at least 0.3 of the row's
  time, is marked: `holds_tiny` in the JSON (the light scopes' names), a
  line under the terminal table, and a note in the editor and the HTML
  report saying to remove those `profile!` and use `leanprof sample` for
  its time. The calls around a nanosecond of work change the caller's code
  by an amount that depends on that code (in the `tiny` benchmark an
  empty pair of calls cost 2.1 ns a call in one loop and 1.5 ns in the
  other), so no subtraction is right for every caller, and a sample of the
  same build is as far off; calibrating the probes in place, sampling the
  instrumented program and subtracting less were measured and do not help
  (bench/README.md). The `tiny` workload under `profile!` stays 7.6–9 points
  off in share; counts stay exact.
- `bench/run.py` records each component's `probes_ns` and `holds_tiny`,
  and RESULTS.md marks the rows (`†`).

### One complete experiment operation: `leanprof experiment`

- `leanprof experiment start` records a baseline under an experiment id
  (`.lake/leanprof/experiments/ID/`), in a git worktree of HEAD: the build
  (default targets and the executable), the tests (`--test CMD`, or `lake
  test`), the behaviour on every case (the workload, each file of `--inputs
  DIR`, each line of `--cases FILE`: stdout, stderr, exit code and each
  `--check-output FILE`, the same on two runs), the held-out cases of
  `--heldout DIR` as hashes only, and `measure`.
- `leanprof experiment try [REV | --working-tree]` checks one candidate in a
  worktree of its own, which keeps its build between tries and starts from
  the base's (only what changed is rebuilt): build; the proof-preservation
  guard; tests; identical behaviour on every case; then, when the generated
  C is the base's (a proof-only change), compile heartbeats instead of any
  run; else exact counts first (worse: DISCARD, nothing timed) and paired
  timing of the plain binaries. Without `--exe`, the measure is `elab
  --heartbeats` on the changed modules and their dependents in the package.
  It returns KEEP (0), DISCARD (1), ERROR (2) or INCONCLUSIVE (3) with
  `tries/N/evidence.json` and a summary (`--json` prints the evidence). A
  KEEP becomes the base; from the working tree it is committed on the
  current branch with the evidence in the message (git hooks off), a commit
  gets a git note (`refs/notes/leanprof-experiments`).
- The guard is the proof-preservation auditor (`scripts/proof-audit`),
  compiled into the command, on the changed modules and every module of the
  package importing them: DISCARD for a changed test, expected output or
  experiment input, a `sorry`, a new axiom or axiom dependency, a new
  `@[implemented_by]`, `@[extern]`, `unsafe` or `partial`, a removed
  theorem; INCONCLUSIVE when a theorem statement or a definition one uses
  changed, or a file outside the Lean modules. A candidate changing the
  lakefile, manifest or toolchain is INCONCLUSIVE before it is built.
- `leanprof experiment finish` runs the held-out cases on the final base,
  exit 1 when they differ; `status` lists the tries. MCP tools
  `experiment_start`, `experiment_try`, `experiment_finish` and
  `experiment_status` (tests only through the Lake test driver; paths inside
  the project). `research/program.md` is now the loop built on it.
- The auditor: `--subdir` for a Lake package below the checkout root (as
  lean-regex's `regex/`); no `--module` runs only the file checks;
  declarations Lean generates (a tactic's `_proof_1`, equation lemmas,
  matchers, `_unsafe_rec`) are no longer obligations, so a rewritten proof is
  not a removed declaration; an axiom a proof no longer uses is no longer
  "changed". Its tests run in CI.
- `measure`, `measure-pair` and `experiment start` take `--ignore-lines
  TEXT` (repeatable): stdout's lines containing TEXT are left out of the
  output hash (the experiment's cases also leave them out of stderr). A
  benchmark that prints its own timings, such as lean-regex's `Bench`, can
  then be checked for identical output; the summary's output source says
  which lines were left out, so `judge` compares only summaries hashed alike.
- `judge` (the library): `judge … (judgeTime := false)` judges exact counts
  only, and a verdict says when time was unsettled.
- `scripts/experiment-check.sh` (CI) runs it on `Tests/Experiment`: a
  known-good change (KEEP, committed), a change visible on one input only
  (DISCARD), a `sorry`, a weaker statement and a loosened test (DISCARD,
  INCONCLUSIVE, DISCARD), a proof-only change (heartbeats, nothing timed), a
  held-out difference found by `finish`, and a library experiment.

### Runtime and cleanup fixes from the 2026-10-25 code review

- `--auto`'s tiny-function rule (`scripts/leanprof-tiny.awk`) no longer
  counts `lean_ctor_release` (it can free a whole list or tree) or
  `lean_nat_add`, `lean_nat_sub` and `lean_nat_succ` (big-number code,
  linear in their operands) as O(1); a `Nat` comparison counts only against
  a constant small number. Functions using them are timed again.
- Light scopes count their calls with atomic stores, as the other counters
  are: the live thread reads them while the program runs (a C data race
  before). `scripts/stress.sh` runs again with live snapshots only, so that
  its tiny scopes go light under TSan in CI.
- A light scope's estimate, which its callers subtract from their self time,
  is kept in 1/1024 ticks (on Apple silicon's 24 MHz clock a call of under
  42 ns came out at 0, and nothing was subtracted), and self time is a
  signed sum: a caller of a light scope that has become cheaper than its
  estimate wrapped around, and the report showed all of its time as self.
- A light scope's time keeps its fully timed calls (before it went light)
  apart from the sample timed afterwards, and scales up only the sample.
  Scaling every timed call alike weighed a cheap first phase like a
  costlier later one: a scope whose second phase cost 30 times its first
  was reported at 0.53–0.61 of its time, now 0.80–0.91 (the rest is the
  loop around it). The exit report, live snapshots and `Leanprof.totalNs`
  share the estimate.
- `measure` and `measure-pair` pass INT, TERM and HUP on to the program
  they are running, as `run` does: a TERM to `measure` left a long program
  running and the instrumented build in place until it ended, and a second
  signal then ended leanprof without cleaning up. `scripts/interrupt-check.py`
  covers both commands.
- Every step of preparing an instrumented build (keeping the executable
  aside and removing it, compiling leanprof's runtime, setting objects
  aside) is inside the region that puts the normal build back on a failure
  or a signal. A failed runtime compile (a missing compiler or header) left
  the project's executable deleted.
- `run` and `measure` let Lake fetch missing dependencies (`lake env true`)
  before choosing which packages' objects to set aside. In a fresh clone a
  dependency downloaded during the instrumented build had no stash marker,
  so its instrumented objects stayed after the run. (With `--no-deps`, a
  dependency compiled for the first time during the run is still compiled
  instrumented.)
- `measure --scope` counts the runs in which the scope's time was too small
  to measure (`time_ns.too_small_runs`; the run's 0 used to be recorded as
  a time) and says so, and `judge` gives no time verdict on such a summary:
  a 0 against a nonzero base was a KEEP.
- The HTML project view matches a term or tactic with the base's by its
  declaration and which occurrence of the same text it is there. Matched by
  text alone, two unchanged `simp`s of 10,000 heartbeats were each compared
  with 20,000 and shown as faster, and the same text in other declarations
  of the file was added in too. `scripts/check-html-ranges.py` (CI) compares
  such a report with itself.
### Compile time: exact ranges on every supported Lean

- `leanprof elab` on a project whose Lean is not leanprof's no longer falls
  back to `lean --json` with approximate ranges: the first run builds
  `leanprof-elab-driver` for that Lean, with that Lean (`lean -c`, `leanc`
  against its shared libraries; 2 to 7 s on an M5 Max), from the driver's source
  compiled into the command, and keeps it in `~/.cache/leanprof/drivers/`
  (`LEANPROF_CACHE`, `XDG_CACHE_HOME`) by Lean commit, driver source and
  Lean directory. Later runs reuse it. Terms and tactics then have exact
  source ranges (`"exact_ranges":true`) and the definitions behind the
  work are located by that driver (`--locate`), where leanprof could not
  read that Lean's `.olean` files. `lean --json` is used only when the
  build fails, and `elab` says why.
- The driver's source builds on Lean 4.34.0-rc1, 4.34.0, 4.34.1, 4.35.0,
  4.36.0-rc1 and nightly-2026-10-23 without version checks.
- CI: the Lean versions matrix checks exact ranges on Tests/Smoke for each
  toolchain and the driver cache (`scripts/driver-cache-check.sh`: built
  once, reused, a failed build falls back with its reason); lean-regex
  (4.34.0-rc1) and the installed release on lean4-cli `v4.34.0` (Fresh
  install) expect exact ranges.

### First run: `leanprof` with no arguments, samply from the installer

- `leanprof` with no arguments in a Lake project reads the lakefile and
  profiles the workload: the one `lean_exe`; else the test driver when it is
  an executable; else compile time of the libraries (`elab --project
  --compact`). Several executables are listed with the command for each and
  none is chosen; `leanprof EXE -- ARGS` profiles one. It samples when samply
  can (no rebuild), else runs `stat`, then prints the top three findings
  (the project's functions by CPU, with the library code under them; copies,
  allocation and closure work worth an exact count; the costliest
  declarations for compile time) and the exact `run`/`explain`/`fix`
  commands that go deeper. On a Mac: 8.6 s to the first report on a new
  `lake new` project, after a 4.8 s install.
- The installer offers samply 0.13.1, pinned and checked against its
  SHA256, into `~/.local/share/leanprof/samply` (`--samply` without asking,
  `--no-samply`, `--samply-only` later); leanprof uses it when no samply is on
  `PATH` (`LEANPROF_SAMPLY` overrides). The installed launcher sets
  `LEANPROF_HOME`.
- `doctor` says what `leanprof` with no arguments would profile, where
  samply is (or the command that fetches it), whether Linux perf events allow
  sampling, and, for a missing C compiler, clang or objcopy, the install
  command for the system (macOS, Debian/Ubuntu, Arch, Fedora). `run`, `stat`
  and `--core` print the same when that is what failed.
- `sample`'s report adds `exe`, `exit_code`, `runtime` (the runtime's self
  time by category) and, for the project's own functions, `own_ns` and
  `own_top`.
- CI: Fresh install runs `leanprof` with no arguments on import-graph (three
  executables, then one named) and on lean4-cli (a library), with samply
  from the installer; Release installs samply the same way on all four
  platforms.

### Faster time verdicts: sequential `measure-pair`, `--scope`, `Leanprof.bench`

- `measure-pair` stops as soon as the time verdict is settled — slower or
  faster by more than `--min-change` (default 1%), or within ±1% — looking
  after 6, 8, 10, … pairs, at most `--runs` (now 30). The rule is a
  group-sequential sign test with exact boundaries and linear alpha
  spending, so each of the three claims is wrong at most 2.5% of the time
  however the session stopped (Tests: exact spent error, and by simulation a
  true +1% median called slower 2.1% and within ±1% 2.2% of the time).
  `--fixed` measures exactly `--runs` pairs. Sessions are version 2 and
  record the design; `judge` reads both versions.
- `measure-pair --scope NAME` times one region of a plain build: the program
  wraps it in `Leanprof.bench "NAME" fun _ => ...` (new, `import
  Leanprof.Bench`: two clock reads and a line appended to
  `$LEANPROF_BENCH_OUT`, no probes) or writes the same `NAME<TAB>NS` lines
  itself without the dependency.
- `measure-pair --base-rev REV --exe NAME` builds the base at a git revision
  once, keeps it in `.lake/leanprof/base/` by commit and build settings, and
  builds the candidate with `lake build NAME`, so a loop of verdicts against
  one base pays only the candidate's incremental build. The MCP tool takes
  `base_rev`, `exe`, `scope`, `min_change` and `fixed`.
- Measured on the LeanBench case study's trials (shared Mac, load 4–13):
  sequential `measure-pair --scope` took 0.89 s per verdict end to end
  against LeanBench's 1.09 s (7.1 s for the old 20 fixed pairs), with 0
  false verdicts in 20 and the 2.4% slowdown caught 4 of 5; at load up to
  15 it took 1.9–2.3 s against LeanBench's 1.06 s.
- One warmup pair instead of three; `lake env` for both sides at once, and
  the load average read in process instead of two `sysctl` per pair.

### Compile time: a project view and published profiles

- `leanprof html` on a compile-time report opens on a project view: project,
  folder, module, declaration, term or tactic, each with its cost split into
  elaboration, kernel, compiler and linters, the repeated work and the
  definitions behind the work done there, terms and tactics nested by the
  range that contains them, and the source. Given a base report, every level
  shows the base, the change and what regressed (modules by name,
  declarations by name, terms and tactics by text, declaration and
  occurrence). The place is in the
  address, so links and the back button work. `--ranges N` and `--keep N`
  bound the page for large projects; the page says what it left out.
- `elab.json`: each module lists its 10 costliest repeated operations (with
  what they cost there and in all files) and the definitions behind its
  work (`files[].repeated`, `files[].unfolded`); `repeated[].files` counts
  the modules an operation was done in.
- Published profiles in `docs/profiles` (on the website too): all of
  Batteries `v4.35.0` (1,424 M heartbeats, 195 modules, 15 s) and
  Mathlib `v4.35.0`'s 40 slowest modules by Radar's instructions (16.1 G
  heartbeats, 8.5 minutes 4 at a time, at most 2.9 GB per process), each a
  page and its report, with the commands, versions and machine
  (`scripts/publish-profile.py`).
- CI drives the project view in jsdom (`scripts/check-html-view.js`): every
  level renders, without script errors, and compares with a base.

### Known issues from dogfooding lean-compiler-backend and concrete

- `measure --core` (and MCP `measure` with `core`): copies and allocations
  inside Lean's precompiled libraries count too, as with `run --core`. A
  real lean-compiler-backend speedup (`emitData`) was entirely in such code,
  invisible to `judge`'s allocation rule. Summaries record `core`, and
  `judge` discards a comparison of a `--core` summary with a plain one.
- Live snapshots mark copies of empty or tiny values (`tiny`, the report's
  rule against the time so far), and `top` and MCP `live` summarize them in
  one line as `run` and MCP `hot` do (`SSA.fresh`'s 17,775 9-byte copies
  were second in `top`). `LEANPROF_ALL_COPIES=1` lists them.
  `top --attach` on a program that had already exited now shows its last
  snapshot (it printed nothing).
- The last report is well-defined: `.lake/leanprof/report.json` is what
  `run`, `stat`, `sample` and `measure` leave, also when `--json FILE` saves
  a copy elsewhere (`run --json F` did not update it, so `explain` read an
  older report). `run` and `stat` remove it (and FILE) before they start,
  so a failed build or a killed program leaves no older report passing for
  this one (the MCP `run` tool summarized a stale one after a failed build).
  `run` and `stat` take `--out FILE` as another spelling of `--json FILE`,
  and `sample` takes `--json FILE` (a copy of its report; `--out` is still
  samply's profile).
- `stat` launches the freshly linked binary once without running it
  (`LEANPROF_LAUNCH_ONLY=1`: leanprof's runtime exits as it loads) before
  the measured run, and prints that first launch's time on its own line.
  On macOS a new binary's first launch is slow (1.1 s for `copybug`, 24 ms
  after; 2.3 s for concrete), and "including process start" counted it
  without saying so. That time also no longer includes `lake env`.
- The MCP `explain` tool gives `leanprof explain`'s diagnosis of each copy
  (cause from the IR, fix in the program's names, lines, confidence) instead
  of a generic list of usual causes, which it keeps only for live snapshots
  (no symbols). It refuses sampled reports as the command does; on one it
  had listed scopes "in 0 calls".
- `explain`, for a copied field of a kept structure, cites only structure
  updates (`{ s with … }`) next to the update, not every line with the word
  `with` (`match … with`, comments, docstrings), and no comment text: on
  concrete's `elabModule` it listed 38 lines and quoted a comment as the
  source; it now cites none and says no source line matched (the copy is
  `sp ++ "_"` at `Elab.lean:3356`, which text matching cannot single out
  among the declaration's many `++ "_"`). Comments are stripped before any
  source matching, and quoted lines leave out trailing comments.
- `elab` through `lean --json` (a project on another Lean, or
  `--no-driver`) prints trace descriptions on one line (`pp.oneline`). On
  concrete's `Check.lean` (Lean 4.34.1) `elab --heartbeats` took 61 s and
  10.2 GB against 5.4 s and 0.78 GB for plain `lean`: `Elab.step` prints a
  term's whole syntax at every nesting level, one message was 1.74 GB, and
  `lean` alone needed 28.6 s and 10.3 GB to print it. Now 16.9 s and
  1.36 GB, heartbeats per declaration within 0.03%. Steps whose description
  was cut (`term do [...]`) are not counted as repeated work, a cut command
  is named from the source, and tactics are no longer placed on comment
  lines (`simp` was placed on a comment saying "simply"). The driver (the
  project on leanprof's Lean) was not affected: 25.2 s and 1.26 GB on the
  same file.
- An interrupted `leanprof run` (also `stat`, `measure`) no longer leaves
  instrumented objects that a plain `lake build` keeps (every later binary
  carried the runtime and printed a report, leanprof itself included when
  profiled from its own repository). SIGINT, SIGTERM and SIGHUP are caught
  while a program or build runs (`c/cli.c`): TERM and HUP are passed on,
  the normal build is put back, and leanprof exits with 128 + the signal.
  Against SIGKILL, Lake's records of the instrumented objects are deleted
  once built (0.04 s on concrete), so the next plain `lake build`
  recompiles them normally (14.2 s for concrete's 114 objects, only after
  a kill). `leanprof doctor` puts a stashed normal build back.
  `scripts/interrupt-check.py` (CI) checks every signal.
- `bench/run.py`'s lean-compiler-backend step failed ("input contains no
  functions or data"): current checkouts keep zlib's inputs compressed in
  `docs/benchmarks/arm-scaled-load/private/zlib/ir`, not in `zlib/`, so lcb
  ran with none. The inputs are extracted from there (or taken from `zlib/`
  in older checkouts), the command must succeed once before it is timed,
  and `--lcb pinned` clones lean-compiler-backend at `d828ff3`
  (checked: plain 0.216 s, `run` 1.13×, `--auto` 1.59×, `--allocs` 1.22×,
  2 runs, shared Mac).

### Why a regression happened

- `leanprof compare` and `report-md` (the Action's comment) say what made
  each regressed declaration more expensive: the definitions unfolded and
  reduced, instances, simp lemmas and repeated operations whose credited
  heartbeats or counts changed, and with `elab --counts` Lean's exact
  counters (unfolds, kernel unfolds, instances, simp lemmas used and failed,
  theorems `grind` instantiated), each with `file:line`, increases first.
  What the reports do not record is said to be not attributed, never
  estimated. `--explain HEAD_EXPLAIN.json` adds `leanprof explain`'s cause
  to each copy site that copies more (refused when it is of another run).
- `elab.json` records per declaration `causes`, `repeated` and `counts`,
  and whether `--counts` was on; declarations are keyed by their whole name
  (one longer than the 60 characters kept of its text, as with
  `@[grind =>] theorem …`, no longer appears as removed and added).
  `explain.json` findings carry their scope.
- The GitHub Action names the causes (input `explain`, default `true`: `elab
  --counts` and `leanprof explain` on each commit), in a collapsed block per
  regressed declaration with its top change in the summary line; the comment
  stays under 60,000 characters (`report-md --max-chars`). Names from the
  pull request are escaped in prose too (`mdProse`, `htmlCode`).
- `Tests/Regress` and `scripts/regress-check.py` (in CI): known regressions
  (a lemma joins the simp set, a definition gets more expensive to unfold, an
  array is kept across a push) through the real pipeline, and golden
  `report-md` output. `reproduce/why-batteries.sh` replays Batteries #1880
  undone and prints the comment; `scripts/action-local.sh` runs the
  Action's profiling step on any two commits without posting.

### `leanprof fix`: apply explain's fix, check it, commit it with the evidence

- `leanprof fix [--exe EXE -- ARGS] [--test CMD] [--check-output FILE]
  [--finding N] [--all] [--dry-run]` takes the costliest finding of
  `explain` whose cause has a mechanical edit and applies it. The causes are
  `nested-array-element` (`Array.modify`), `map-value-reinserted` (`alter`
  or `modify` with the read line removed, or erase before inserting) and
  `loop-over-updated-array` (an index loop), each only when the code shows
  it computes the same values (see the review fixes below). Every other
  cause is refused with a reason. The check runs in a git worktree of
  `HEAD`: build, tests, output compared with the original's, `measure` of
  both versions, `measure-pair` of both plain binaries, and `judge`. KEEP
  commits with the counts, verdicts and paired interval in the message and
  gives your repository a new branch at that commit. DISCARD creates no
  branch. The checkout is never touched, and a tree with uncommitted
  changes is refused. See the [guide](docs/guide/fix.md).
- Tests: each edit of `Examples/ExplainPatterns.lean` gives the fixed
  declaration line for line. `scripts/fix-check.sh` (in CI) runs `fix` on
  the `Tests/Fix` fixture: KEEP (19,985 copies -> 1, with git hooks that
  must not run), a loop rewrite refused from the code, DISCARD when a test
  fails or rewrites the file, TERM during the checks, a dry run, and a tree
  with uncommitted changes.
- On lean-compiler-backend `a623acc`, `fix --all` applied `explain`'s
  `Array.modify` to `CFG.build` and DISCARDed it: copies went from 119,516
  to 86,449, but allocations rose by 59,514, the same cost the hand-made fix
  (`8a0d286`) avoided with a second pass. On lean-regex `32af6f3`, no
  finding has a mechanical fix (all are `shared-on-entry`).

### Review fixes: `fix` and the MCP server (review of 2026-10-25)

- `fix` committed rewrites that change what the program computes when the
  one workload it runs did not show it. `xs.set! i (xs[j]!.push v)` became
  `xs.modify i (·.push v)` (it updates `xs[i]`, not `xs[j]`), and every
  `for x in xs` loop became an index loop reading the current array. Now
  `Array.modify` needs the same index on both sides, and the loop rewrite
  needs a body that provably changes no element it has not visited yet: a
  `let mut j := 0` counter, a flat body ending with `j := j + 1`, and `xs`
  assigned only by `set!`/`set`/`modify` at `j` or `push`. Anything else is
  refused with the reason. `Tests/Main.lean` checks 13 refused shapes;
  `fix-check.sh` now expects `smooth` to be refused before any change, and
  covers DISCARD with a test the edit fails.
- `fix` checked out its branch and wrote the candidate into your checkout,
  and a TERM or HUP while it built, tested or measured killed it before its
  cleanup ran: the candidate stayed in the file and the branch stayed
  checked out. Now every step after profiling runs in a git worktree of
  `HEAD` (`.lake/leanprof/fix/worktree`, with your `.lake/packages` linked
  and a copy of `.lake/build`); your repository only gets the branch, on
  KEEP. INT, TERM and HUP are passed on to the running step, then the
  worktree is removed and `fix` exits with 128 + the signal.
  `fix-check.sh` sends TERM during the candidate's tests and checks the
  checkout, the branches and the worktree list.
- `fix`'s `git checkout` and `git commit` ran the repository's hooks: a
  `pre-commit` hook could stage other contents after every check had
  passed, and the commit then carried evidence for code that was never
  measured. `fix` now runs git with `core.hooksPath=/dev/null`, DISCARDs an
  edit whose file changed while it was checked, and refuses to report KEEP
  unless the commit's parent is `HEAD`, it changes only that file, and the
  file's committed content is the measured candidate. `fix-check.sh` installs
  `pre-commit`, `post-checkout` and `post-commit` hooks for the KEEP run and
  adds a test that rewrites the file.
- MCP: the checks on paths the server writes were lexical, so a link in the
  project (`out: "external/result.json"` with `external` pointing
  elsewhere, or a path that is itself a link) wrote outside it. The nearest
  existing directory above the path must now be inside the working
  directory with links resolved, and the path must not be a link. `elab`'s
  `files` went straight into `leanprof elab`'s options, so `--out FILE`
  among them wrote anywhere: files starting with `-` are refused (also
  `compare`'s and `judge`'s report paths). `scripts/mcp-check.py` checks
  all four; see the [security review](docs/reviews/security-review.md).
- MCP: `measure_pair` checked `base_cwd` and `candidate_cwd` only when they
  were given, not their default, the top-level `cwd`. With `cwd` outside
  any project and absolute paths to Lake-built binaries, `check_output` was
  deleted in that directory before the first run. Every directory it runs
  in or writes to, defaults included, must now be a Lake project, and
  `check_output` must be inside both run directories.
- Action: the comment step pasted the `comment-tag` input into its jq
  program. A tag with `"` broke the lookup (the error was suppressed, so
  each run posted another comment), and a tag with jq syntax could match,
  then edit, another comment. The marker is now compared in Python, as
  data. `scripts/comment-check.sh` (in CI) runs the step against a fake
  `gh`; with the old step, both tags fail it.

### Smaller fixes and maintenance

- When one function's self time is half the run or more, `run` says that
  it includes code leanprof does not time (Lean's own libraries, system
  calls) and points to `leanprof sample`. On import-graph, `importGraphCLI`
  showed 84% self time that `sample` puts in opening and mapping `.olean`
  files and `Lean.finalizeImport`.
- `leanprof doctor`'s copy-detection self-check could not run on Linux
  ("fatal error: 'stdio.h'"): its probe was compiled with Lean's own `leanc`,
  whose sysroot has no libc headers. The probe declares `puts` instead.
- `leanprof help` ran `measure-pair` into its description; the command
  column is wider.
- `scripts/leanprof-tiny.awk` (which functions `--auto` leaves untimed)
  treats any function with a `while`, `for` or `do` loop as not tiny. Lean's
  C loops with `goto`, so no real function changed (57 untimed in
  leanprof's own IR before and after), but the rule no longer relies on it.
- The Linux benchmark results behind the README's Linux numbers are in the
  repository (`bench/linux/before` and `after`, a dedicated Ryzen 9
  7950X3D); the README had linked the Mac's results for them.
- README: the compile-time comparison was against lean-source-profiler's
  latest release (0.3.0), whose default is the compact mode it measured;
  per file, full profiles cost 1.3–1.9 times less than its detailed mode and
  compact ones about the same, and the Batteries gap (17 s against 103–152
  s) is mostly parallel elaboration.
- The VS Code extension's build tooling pins `@azure/msal-node` 7.1.1 (an
  advisory on the 6.x that `vsce` pulled in; not part of the `.vsix`).
- The Lean versions workflow retries a toolchain download that timed out.
- Tidy before v0.1.0, no change in behaviour beyond wording: the README
  describes every command on `main` and calls probe times calibrated
  estimates (counts are exact; repeatable unless threads race), and the
  help, hints, HTML report and `report-md` note say the same; ROADMAP
  statuses match `main`;
  `docs/reproduce.md` points at the current benchmark run; the command uses
  `LeanprofHtml`'s symbol-table helpers instead of copies; an unused
  function, stale comments and the TypeScript checker's unused-parameter
  noise in `report.js` are gone.

### Tiny functions

- `run --auto` leaves functions too small to time untimed: straight-line
  code (no loop or join point) that calls only O(1) `lean.h` operations and
  other such functions of its file, and frees nothing but boxed scalars
  (`scripts/leanprof-tiny.awk`, run by the compiler wrapper on the C Lean
  emits; narrowed by the review fixes above, `lean_ctor_release` and `Nat`
  arithmetic are not O(1)). Their probes cost several times their work, in their own time and
  in every function's around them. The report lists them ("too small to
  time left untimed"; `untimed` in the JSON); their time is in their
  callers'. `--time-tiny` times and counts them as before. Mac, `tiny`
  workload: 9.5–10.2 → 0.6–1.2 points off, 7.8–8.2× → 0.98× slower.
- Light scopes: a scope near the probe cost (the `*` rows) that is not
  recursive is, after its first 1,024 calls, timed on about one call in 64
  at random and only counted on the others; its times are the timed calls'
  scaled up, its counts stay exact, and the cheaper untimed pair (4.6 ns
  against 6.6 ns on the M5 Max) is subtracted from its callers.
  `LEANPROF_TIME_ALL=1` times every call. `tiny` under `profile!` 7.7–7.9× →
  6.2× slower, `tasks` 2.8× → 2.4×; share errors unchanged within the noise.
  `timedCalls` says how many calls of a label were timed; percentiles are
  over the timed calls.
- Scope frames are one cache line (64 bytes, from 104): 10,000 levels of
  recursion with three functions each under `--auto` kept 3 MiB of frames.

### Mac accuracy: the runtime is compiled without the machine outliner

- On macOS, times of small scopes were over-reported since enter and exit
  were inlined into every probe (`a009129`): `run --auto` on the `alloc`
  workload was 22 pp off in share of time (`phAllocTree` at 2.4× its time),
  `profile!` on `rec` 7–9 pp (`fib` at 4.2–4.7×). Apple clang outlines
  repeated instruction sequences on arm64 even at -O2, so the program's
  probes became chains of calls to shared outlined pieces (25 in
  `__cyg_profile_func_exit`) that calibration's own copies did not make: a
  real probe cost ~5 ns more than calibrated, and the report kept it. The
  runtime is now built with `-mno-outline` on macOS (by the lakefile, and by
  `leanprof run` for projects that do not depend on leanprof). On the M5
  Max, two alternated suite runs each: `alloc` under `--auto` 22.0–22.1 →
  3.2–3.3 pp, `rec` under `profile!` 7.0–8.6 → 2.3–2.5 pp and under
  `--auto` 5.1–5.2 → 1.7 pp, `tiny` under `--auto` 9.9–11.2 → 4.2–5.3 pp;
  probes are cheaper too (9.3 → 6.3 ns a scope on `tiny`, `rec` under
  `--auto` 4.0–4.2× → 3.2–3.3×). `tasks`' share error rose (`profile!`
  0.4–0.9 → 1.8–2.6 pp) as its times moved from a uniform 1.6× to 1.03–1.27×.
  The tests and the smoke check fail if the runtime contains outlined code.
  Linux builds do not get the flag and are unchanged (not re-measured).

### Time per verdict, measured

- `measure --scope NAME` times one `profile!` scope (its total in each run's
  report) instead of the whole process; the summary records `scope`, and
  `judge` discards a comparison of summaries that timed different things.
- `measure-pair` measured against LeanBench and `measure` on the LeanBench
  case study's workload (`bench/leanbench/run.py pair`, shared Mac, load
  2–18, under the shared benchmark lock): 0 false time verdicts in 20
  unchanged sessions, a 2.4% slowdown caught 4/5 (5/5 in an earlier run
  without the lock), 4.8% and 10.4% 5/5; 7.1 s per verdict at 20 pairs,
  2.9 s at 6, against LeanBench's 0.74 s. `measure` + `judge` took 5.0 s and
  the next plain build 0.18 s (the 10 s rebuild is gone), but gave 7 false
  time verdicts in 20 on the same machine.

### Reproducing the published numbers

- `scripts/reproduce.sh CLAIM` re-runs each measured claim of the README
  from a clean clone (pinned commits, tags and toolchains), prints measured
  against published values and fails on any exact difference or a timing
  outside its stated range: the README example, Tests/Smoke, lean-regex,
  LeanProfiler, LeanBench, Batteries and lean-source-profiler,
  lean-compiler-backend's fixes and autoresearch, the benchmark suite
  ([docs/reproduce.md](docs/reproduce.md)). CI runs the cheap exact ones.

### Dogfooding on lean-compiler-backend and concrete

- `elab`: "definitions behind the work" placed a definition at any
  declaration in the profiled files with the same last name component when
  the project's Lean differs from leanprof's (its modules cannot be loaded,
  so positions come from the source): `Optimize.Algebra.operation` was shown
  at a `private def operation` in `SSA.lean`, `Id.run` at a test's `def run`.
  Declarations in the source are now qualified with the namespace in effect
  on their line, and a name never matches by its last component alone.
- `sample`: hot code outside the project (`List.reverseAux`, `hash_str`,
  `free`, `lean_dec_ref_cold`) is listed with the project's functions it ran
  under (the nearest project frame of each sample, up to three with at least
  5%). On lean-compiler-backend, `List.reverseAux` at 3.9% of CPU was 98%
  under `Assembly.emitData`, a `lines := lines ++ [line]` loop; fixing it made
  compiling crc32 14.6% faster.
- `judge --allow-overloaded PAIR.json` (and `allow_overloaded` for the MCP
  `judge` tool): judges a paired session's time although the load average
  exceeded the CPU count, and says so in the verdict. On the shared Mac the
  load stayed at 18–20 on 18 CPUs, so no paired session could ever be
  judged on time (one gave −5.2%, interval [−7.7%, −2.1%], "not judged").
- `sample --out FILE` in a project where leanprof had not run before ended
  with "no such file or directory (file: .lake/leanprof/report.json)" after
  printing the report (concrete, with `--out` in a scratch
  directory): the directory is now created.
- MCP `hot copies` (and the copies in `run`'s summary) listed copies of
  empty or tiny values first, which `leanprof run` summarizes in one line:
  on lean-compiler-backend, 17,775 9-byte copies in `SSA.fresh`
  (`prefix ++ toString n`) came second, above the copies worth looking at.
  They are now left out and counted in one line.
- `report-md`: each details section read "allocations: 3 changed
  (regression: the total grew)" even when the total fell and the table said
  pass. It now says whether anything regressed, then what a regression is.
- `explain` after `sample`: `sample` writes `.lake/leanprof/report.json` (for
  `#leanprof`) without copy counts, and `explain` then said "the report has no
  copies of shared values". It now says the report is a sampled one and to
  run `leanprof run` or pass `--report`.

### Fresh installs, more platforms

- Release archives for macOS x86-64 and Linux arm64, next to macOS arm64 and
  Linux x86-64; the install script picks them.
- `fresh-install.yml`: on every change and weekly, the packaged command is
  installed with the install script (source build hidden) and run on
  import-graph and lean4-cli at pinned tags, projects with nothing tailored
  to leanprof.

### Programs that load Lean modules at run time

- `run`, `stat`, `sample`, `measure` and `measure-pair` start the program
  with the environment `lake exe` gives it (`LEAN_PATH`, `LEAN_SYSROOT`,
  library paths, from `lake env`). Programs that import modules at run time
  (`importModules`, `supportInterpreter`: import-graph, doc-gen4, linters)
  failed with "unknown module prefix" under leanprof. Found by profiling
  import-graph, a project leanprof had never been run on.

### Security review

- [Review](docs/reviews/security-review.md) of the MCP server, the GitHub
  Action and the install script.
- MCP: `measure_pair` runs only binaries in a `.lake/build/bin/` directory,
  in Lake projects; files the server writes or deletes must be inside the
  project; `live` and `dump` (and `leanprof dump`, `top --pid`) accept only a
  single process id; an option is not taken as the executable; `live` waits
  at most 60 s. `scripts/mcp-check.py` checks each refusal.
- Action: line breaks in names can no longer end the inline code in the
  comment; the verdict step gets its values as environment variables; the
  guide recommends `persist-credentials: false`, minimal permissions and a
  pinned tag.
- Install: the launcher quotes the path it runs; the checksum lookup is an
  exact name match; the download directory is removed on failure.

### Interleaved timing and paired verdicts

- `measure-pair` runs two prebuilt binaries in alternating AB/BA order, with
  separate working directories, warmups, binary fingerprints, output checks
  and machine-load recording. It adds no probes and performs no rebuilds.
- `judge PAIR.json` uses a distribution-free 95% interval for the median paired
  percentage change. Output/diagnostic mismatches, missing output files and
  failed runs prevent KEEP; overload disables the timing verdict.
- Pure tests cover drift, confidence endpoints and failure cases; a CLI test
  verifies process ordering, arguments, working directories and stale output.
- The MCP server has a `measure_pair` tool, and its `judge` tool takes a
  paired session (`pair`) and `min_change`.
- Refresh the competitive priorities and qualify historical compile-time
  comparisons against lean-source-profiler's newer native compact capture.

### Compiler qualification and release preparation

- Reproducible clean-build compiler comparison, 540 output/diagnostic checks,
  full per-stage logs, and plain-binary timing evidence in `research/lcb/`.
  The reviewed compiler optimizations are merged, with a corrected validation
  fast path and 22% less median wall time on the measured workload.
- Contribution and supported-toolchain guidance, security reporting guidance,
  issue/PR templates, and a roadmap reconciled with implemented features.
- Extend the existing TSan allocator-reuse suppression to Lean's inlined fresh
  object header initialization; profiler task functions remain unsuppressed.

### `leanprof explain` prints the fix

- Recognises the causes of copies found in real projects from the compiler's
  IR and prints the fix as Lean code with the program's own names:
  an element of an outer array updated while the array holds it
  (`xs.set! i (xs[i]!.push v)` → `xs.modify i (·.push v)`); a value read
  from a hash map and inserted back (`m.getD k d` / `m[k]!` / `m[k]?` →
  `m.alter`, `m.modify`, or erasing the key first); a value stored in another
  array and then updated (when it only grows, store its length); a value in
  a global `IO.Ref` or `Std.Mutex`, which Lean never updates in place
  (a local buffer published once); a `for x in xs` loop that updates `xs`
  (loop over indices). Other causes keep the general advice.
- Each recognised cause has an example in `Examples/ExplainPatterns.lean`
  (`lake exe explainpatterns`), and `Tests/ExplainFixes.lean` checks that
  `explain` diagnoses it, that the printed code is the fixed version line
  for line, and that the fixed version makes no copies.
- `leanprof explain --json`: ranked findings with cause, location, why, fix,
  fix code, copies and estimated cost, for agents. `explain.json` entries
  carry the same fields; `#leanprof` hovers show the fix code.

### Added

- Self-check on every profiled run: a known copy of each kind
  (`Array.push`, `Array.set!`, `String.push`, `String.append`,
  `ByteArray.push`, `ByteArray.set!`) goes through `c/selfcheck.c`, compiled
  with the copy flags like the program, and must reach a shim. If one does
  not, the report, the JSON (`self_check`), `stat`, `measure` and `doctor`
  warn that copies of that kind may be undercounted with this Lean version
  (as String copies were with Lean 4.36 before the `lean_string_push_cold`
  shim). Its copies are counted apart (no rows); it costs about 20 µs at
  exit.
- `run`, `stat`, `measure` and `top` take `--no-deps`: only the root
  package is rebuilt with probes.
- `scripts/smoke.py` also profiles `Tests/Smoke`, a project that does not
  depend on leanprof, from a copy outside the repository with the command as
  packaged for a release; `--add` adds new facts to the baseline.
- `leanprof sample` takes a path to any program (`leanprof sample
  ~/.elan/toolchains/…/bin/lean -- FILE`). It names Lean code in Lean's
  shared libraries (`libleanshared`, `libInit_shared`, `libLake_shared`),
  and gives positions of Lean's own declarations in the toolchain's sources
  (from its `.ilean` files). `run` passes the toolchain
  (`LEANPROF_CORE_DIR`), so copies and allocations inside Lean's libraries
  (`--core`) get positions too.
- `leanprof doctor` checks for the objcopy that `run --core` needs.
  `run --core` also finds rustup's llvm-objcopy (`rust-objcopy`).
- `leanprof explain` recognizes arrays pushed inside an `IO.Ref` that
  threads share (each push copies the whole array) and says how to fix it.
- [Lake, the language server and `lean`](docs/case-studies/lake-and-server.md)
  case study, and seven candidate patches for Lean with measurements in
  [docs/upstream/lean4](docs/upstream/lean4/README.md) (not sent upstream).
- `measure` records the 1-minute load average and the CPU count, and the
  mean and standard deviation of the run times; `judge` does not judge time
  when either summary was measured on an overloaded machine (load above the
  CPU count), and prints the time change in percent.
- `judge --min-change PCT` (default 1): non-overlapping runs count as faster
  or slower only when the median also moved by PCT percent. On a quiet,
  pinned machine, unchanged code had been judged faster in 2 of 20 pairs;
  with the floor, 0 of 20, and a 2% slowdown is still caught 5 of 5
  ([LeanBench case study](docs/case-studies/leanbench.md)).
- `bench/leanbench/`: leanprof against LeanBench on noise, seeded copies,
  allocations, 2–30% slowdowns and a speedup, with the scripts and raw
  results.
- A `sanitizers` job: tests, examples, the server with live snapshots and
  the flight recorder, `run --allocs --counters --frees`, `explain --why`
  and the stress test, built with ASan and UBSan and with TSan on Linux
  (`LEANPROF_SANITIZE` with `scripts/leanprof-cc`), and plain on Linux and
  macOS.
- `Examples/Stress.lean` and `scripts/stress.sh`: many threads and tasks,
  deep recursion, millions of scopes and copies, snapshots every 10 ms and
  flight dumps under load, with exact counts.
- **`leanprof elab` times every term and tactic by its exact source range**
  (`file:line:col-line:col`). When the project's Lean is the one leanprof
  was built with, files are elaborated by `leanprof-elab-driver`, Lean's
  frontend run in-process (the module's setup file and `LEAN_PATH`, as
  Lake does) with every term and tactic elaborator and every macro
  wrapped to record the syntax it elaborates. The report lists the
  costliest tactics and terms by range, `elab.json` has them (`ranges`;
  `tactics` gain `range`), `#leanprof` lists them in the hover of their
  line, and `leanprof html` in a "Source ranges" tab. Tactics are no
  longer found by their text. With another Lean (or `--no-driver`) `elab`
  runs `lean --json` as before and says why. The driver also formats only
  the descriptions the report reads, so a full profile costs less than
  with `lean --json`.
- `leanprof elab --compact`: only commands, terms and tactics are timed,
  not the operations inside them, within a few percent of plain `lean`
  (needs the driver).
- **Allocations judged exactly.** `measure` counts allocations by default
  (`--no-allocs` turns it off; about 6 ns per allocation, 10% on
  lean-compiler-backend) and records them per site and per run; `judge`
  says DISCARD when they go up (any increase; for counts that vary between
  runs, only beyond their range) and counts a cut of at least 1% and 100
  as an improvement. `compare` reports more allocations in total as a
  regression when both reports counted them. The first `CFG.build` fix in
  lean-compiler-backend cut copies but added 59,514 allocations; `judge`
  kept it before and discards it now (a test checks that case).
- **Each finding states its share of the run.** Copy rows show `%run` and
  are sorted by time; allocation rows show an estimated time (count times
  the calibrated cost of a small allocation and its free, a lower bound)
  and `%run`, sorted by it; `explain`, `stat`, the HTML report, the editor
  hints and the MCP tools show and rank by the same shares. A run without
  `--allocs` says how to count allocations. JSON: `run_ns`,
  `resolution_ns`, `alloc_ns`; `pct_run` on copies and allocations,
  `est_ns` on allocations.
- **Copies of empty or tiny values** (at most 16 bytes per copy, under 1%
  of the run), such as the first push into an empty array slot, are
  grouped into one row; `run --all-copies` (`LEANPROF_ALL_COPIES=1`) lists
  them. The JSON keeps every row, with `"tiny": true`; `explain` and the
  editor skip them.
- **Times too small to measure are never shown as 0**: `< probe` (a
  scope's time after subtracting the probes' cost) and `< 1 ns` / `< 42 ns`
  (a copy, wait or task shorter than a clock tick) in the terminal, and
  `too_small` (the fields concerned) on JSON rows, read as `< probe cost` /
  `< 1 clock tick` by the HTML report, `#leanprof`, `compare` and the MCP
  tools. `compare` shows times in adaptive units instead of `0.00 ms`.

- Rows whose time is near the probes' own cost are marked: `*` after the
  total in the terminal report, `near_probe_cost` (and `probes_ns`) in the
  JSON, in the HTML report and in `#leanprof` hovers ("near the probe cost:
  use `leanprof sample` for this function's time"). The threshold (probes
  at least 0.3 of the time left) is calibrated on `bench/`: see
  bench/RESULTS.md, "Per component".

### Changed

- **The clock on Linux** is the CPU's counter where the kernel keeps time
  with it: the TSC on x86-64 (clocksource `tsc` and the CPU's invariant-TSC
  bit; its rate measured against `CLOCK_MONOTONIC`), `CNTVCT_EL0` on arm64
  (clocksource `arch_sys_counter`). `clock_gettime` through the vDSO cost
  18 ns a read on a Ryzen 7950X3D, two reads per scope.
  `LEANPROF_CLOCK=monotonic` keeps `clock_gettime`.
- **A scope costs less to enter and exit**: the enter and exit code is
  inlined into its callers (no shared function pushing and popping half a
  dozen registers), the scope lookup, the memory-sample check and the
  thread lookup have their common case inline and the rest out of line,
  and allocation counts are kept only once an allocation went through the
  `--allocs` shims (per-thread totals, read at each frame's start and end).
  On a Ryzen 7950X3D (fixed clock, boost off) the `tiny` benchmark went
  from 51 to 23 ns per scope and from 38× to 17.7× slower; on an M5 Max
  calibration measures 7 ns per direct pair instead of 13.
- **`leanprof sample` completes stacks samply cut short on Linux.** perf
  copies at most 64 KiB of a thread's stack per sample, so a sample deep
  in recursion lost its outer frames (10,000 calls deep, the phase that
  started the recursion was missing from 90% of samples). A cut stack now
  takes its outer frames from the thread's last whole stack, from the
  outermost call of the cut stack's outermost function: on the `rec`
  benchmark the share error went from 14.2 to 1.2 percentage points
  (samply itself: 14.8).
- **`scripts/leanprof-cc` builds with Lean's own `leanc` on Linux** (its
  bundled clang, sysroot and linker), so `run` and `--auto` build the
  program the way Lake does. Built by the system's clang and linker, the
  copy benchmark ran 18% faster with no probes at all, and leanprof's
  report then looked like it had subtracted too much (`run --auto` at 0.86
  of the plain time, now 1.05). Sanitizer builds and macOS still use the
  system's clang; `LEANPROF_REAL_CC` overrides.
- `bench/run.py` has a `phases` configuration: leanprof scopes exactly
  where LeanProfiler's spans are (phases and tasks), shown in the headline
  next to LeanProfiler, so the two are compared like with like.
- Profiling no longer deletes the compiled objects of the project and its
  dependencies: they are set aside (`.lake/leanprof/normal-objects`) while
  every package is rebuilt with probes, path dependencies included, and put
  back afterwards, so the next `lake build` recompiles nothing. Copies
  inside dependencies need no manual rebuild.
- An executable that had no normal build is removed after profiling instead
  of being left instrumented.

- **`profile!` on a pure term no longer builds a closure.** It compiles to
  `Leanprof.enterPure` before the term and `Leanprof.exitPure` after it,
  with a variant per scalar type, so nothing is allocated or boxed inside
  the scope (a `UInt64` result was boxed through the closure; that, not the
  probes, was most of what stayed in the times of tiny functions).
  `Leanprof.scope` (the closure) is still there for direct use.
- **The clock on Apple Silicon** is the counter itself (`CNTVCT_EL0`)
  instead of `mach_absolute_time`, which reads a self-synchronizing copy
  that waits for every earlier instruction: in real code that wait was
  most of a probe's cost (`mach_absolute_time` was 40% of an `--auto` run
  of lean-compiler-backend in samply). On an M5 the counter also runs at
  1 GHz, so scopes are timed to the nanosecond instead of in 41.7 ns ticks.
  `-DLEANPROF_SYNC_CLOCK` restores the old clock.
- **Symbols are looked up in a sorted table** of the executable's symbols,
  read once, instead of with `dladdr`, which scans every symbol on each
  call (0.3 ms in an executable with Lean's 450,000 symbols). `--auto`
  called it for every function it saw, inside the scope that called it, and
  the report for every row: on lean-compiler-backend that was 0.2 s of
  time inside the program's own scopes and 0.6 s of report.
- `--frees`: a run of frees from one call site in one scope skips the site
  table, and the "frees seen" flag is no longer written on every free (a
  cache line all threads wrote to).
- The fields of a scope that every enter and exit touches share two cache
  lines.

### Fixed

- `explain` no longer gives the multi-threaded explanation for a copy site
  where only a few copies were multi-threaded (Lake: 12 of 7,420).
- With `LEANPROF_PROJECT` set (`--cwd`), absolute source directories were
  joined onto the project path.
- `leanprof elab --project`, locating definitions in modules that cannot be
  imported together, kept every module's environment loaded: 16.8 GB on
  leanprof's own package once a module imports all of Lean. Each is now
  freed after use (3.2 GB).
- `probe_ns` and the "without the probes" wall time counted 1,024 times
  the probes' cost (descendants are counted in 1/1024 of a pair), so `%wall`
  was taken against a wall time that was far too small: `copybug` showed
  `buildWithHistory` at 100.0% and the column summed to more than 100%. CI
  now checks that scopes that do not overlap add up to at most the wall
  time without the probes.
- A recursive scope's self time could exceed its total (`fib` in copybug:
  self 38.0 µs, total 32.2 µs). Both subtract the same probes, counted two
  ways (self: each call's inner part plus its children's outside parts;
  total: one inner part plus every descendant's whole pair), but the inner
  part came from the calibration at exit and the rest from the weights
  fixed at the first one, rounded separately. All three now come from the
  same weights, with inner + outside = pair exactly, and CI checks that
  `fib`'s self equals its total.
- The test "scope total is reported" failed on busy CI runners: `fib`'s
  calls take about what their probes cost, so what is left after
  subtracting them can be 0. It now checks that the total is never
  negative; a scope with real work checks that its time is inside it.
- `bench/Main.lean` (the comparison with LeanProfiler) calibrates before
  its timed loops: the one-time calibration (about 10 ms) was counted as
  the cost of the first 1,000 actions (10 µs each).

Found hardening the runtime (sanitizers, a review by Codex, a stress test;
see [the review](docs/reviews/runtime-review.md)):

- Data races ThreadSanitizer found between the program's threads and the
  live snapshot thread: thread registration, new scope and copy records
  published with plain stores, counters, open frames and the calibration
  results. Records are now published with release stores and counters
  written with relaxed atomic stores (the same instructions), and one
  calibration runs at a time.
- A task's scope got its spawning scope's kind, and its begin event its
  kind, after both were visible to the live and flight readers; the
  flight recorder copied and compacted events with plain `memcpy` under its
  sequence count. Both are now race-free, and dumps no longer drop the
  newest event of a thread to work around the first.
- Threads that exit (one per dedicated task) kept their tables for good,
  and their flight buffer (8 MiB each): memory grew with every such task.
  An exited thread's records are now reused by the next new thread (83 to
  27 records, 1.0 to 0.47 GB in the stress test).
- Under `--auto`, each copy and allocation looked down the whole scope
  stack for the innermost `profile!` label: quadratic in deep recursion
  (80,000 levels that allocate took 4.5 s, now 6 ms). The label is kept in
  each frame.
- Histogram buckets were 32-bit: a hot scope fills one in about a minute,
  and its percentiles then read 0. They are 64-bit.
- Memory was sampled every millisecond for as long as the program ran (24
  bytes each, up to 400 MB); after the first minute samples are spread over
  the run so far (about 13 MB in a day).
- A huge `LEANPROF_TRACE_MAX` wrapped the flight buffer's size and wrote
  past it; it is capped at 2^28 events.
- A query (`totalNs`, `overheadNs`) inside an open scope charged that
  scope with the calibration it ran.
- Error paths: the report returned with its lock held when out of memory;
  a live snapshot without memory for its rows replaced the last good one
  with broken JSON; the report, timeline, `explain` data and flight marker
  ignored write errors; if the live thread could not start, the flight
  recorder stayed on with nothing to dump it.
- SIGUSR1 requests could be lost between the background thread's test and
  clear, and one arriving just before exit was dropped.
- The counters' table had no fill limit (a full table scanned every slot
  per call), and a thread still running at exit could make the counter
  report write past its array.
- The project's package names were read on the live thread while a
  program thread could read them too; they are read at startup.

Found on Mathlib ([case study](docs/case-studies/mathlib.md)):

- `elab` ran modules without their setup when Lake had not written one,
  which is every module fetched with `lake exe cache get`: Lean ran without
  the package's `leanOptions` (Mathlib's `maxSynthPendingDepth 3`, its
  linters), and 8 of Mathlib's 20 slowest files failed with errors. It now
  asks `lake setup-file` for the setup (saved under `.lake/leanprof/setup`).
- A command wrapped in `variable … in` or `set_option … in` was counted
  twice: Lean traces the inner command at its own position and then the
  wrapper, which includes it, over a range that contains it. Only commands
  at the same position were matched; now any command whose source range
  contains earlier ones counts only what it adds. On the 20 files, 23% of
  all heartbeats were counted twice (11.85 G reported, 9.15 G real), and a
  declaration under three `set_option … in` four times.
- A file with errors was elaborated a second time without its setup, even
  when the error was in a proof, which for a large file (Mathlib's
  `Modules/Sheaf.lean` runs for minutes when profiled) doubles its time.
  Now only for errors in the header, where a stale setup shows.
- "files had errors" now prints each file's first error with its line (and
  `first_error` in `elab.json`), and says when the error is a heartbeat
  limit, which profiling can reach where the build does not.
- Lines were named after the wrong command when several share one
  (`variable (x) in` puts its inner `section` and `variable` where the
  declaration starts) or when a declaration's doc comment was longer than
  the text kept: the declaration became `section` or nameless, so `compare`
  matched it by line. Commands that declare nothing (`variable … in`,
  `attribute …`) are now matched by `compare` by their text and order in the
  file instead of their line, so edits that move lines no longer show them
  as gone and new.
- `compare` printed heartbeats of new and removed scopes as milliseconds,
  listed thousands of scopes in no order, and showed `calls 0 -> 0` for
  compile-time reports. It now lists the largest changes first, uses the
  report's unit, and ends compile-time comparisons with the total.
