# Changelog

All notable changes to leanprof. Versions follow [semantic
versioning](https://semver.org); a release is a `vX.Y.Z` tag (see
[RELEASING.md](RELEASING.md)).

## [Unreleased]

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
- Rows whose time is near the probes' own cost are marked: `*` after the
  total in the terminal report, `near_probe_cost` (and `probes_ns`) in the
  JSON, in the HTML report and in `#leanprof` hovers ("near the probe cost:
  use `leanprof sample` for this function's time"). The threshold (probes
  at least 0.3 of the time left) is calibrated on `bench/`: see
  bench/RESULTS.md, "Per component".

### Changed

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
||||||| parent of a9e2e63 (Docs: explain's recognised causes with fixes and measured copies, explain --json for agents (guide, research/program.md, CHANGELOG))

## [0.1.0] - 2026-10-23

The first release: a profiler for Lean 4 programs and their compile times,
for Lean 4.34 and later on macOS arm64 and Linux x86-64.

### Install

- One command: `curl -sSfL https://raw.githubusercontent.com/unbalancedparentheses/leanprof/main/scripts/install.sh | sh`
  installs the prebuilt command for macOS arm64 or Linux x86-64 from the
  latest release (checked against `SHA256SUMS`), or builds from source when
  there is none for the platform. `--release VERSION`, `--source`, `--bin
  DIR`; from a clone it builds the clone.
- Release archives of the command for both platforms, and the VS Code
  extension as a `.vsix`, attached to each version tag.
- `leanprof doctor` checks Lean, the C compiler, samply and the project;
  `leanprof help [COMMAND]`.
- Reservoir metadata in the lakefile (description, keywords, homepage,
  license); use as a library with
  `require leanprof from git "https://github.com/unbalancedparentheses/leanprof" @ "v0.1.0"`.

### Any Lake project, unchanged

- `leanprof run`, `sample`, `stat`, `top`, `elab` and `measure` work on any
  Lake project with no dependency on leanprof: its runtime is compiled for
  the project's own Lean version and linked in, instrumented objects are
  removed afterwards, and the normal executable is restored.
- `--cwd DIR` for programs that read the current directory; positions still
  come from the project.
- Names are demangled like Lean's own demangler (checked against it by
  `demangle-check` on hundreds of thousands of symbols: escapes, private and
  hygienic names, nested specializations, package names), and given
  `File.lean:line` from `.ilean` files, including modules in a `srcDir`.

### Run time

- `leanprof sample`: CPU time per Lean declaration with file:line, through
  samply and with no probes; specializations reported under the declaration
  that caused them (and their real caller when the compiler reuses one); a
  breakdown of the Lean runtime's own time (copying, freeing, allocation,
  thread-local lookups, Lean's C++ code); a profile with Lean names for
  Firefox Profiler.
- `leanprof run`: exact time and calls per `profile!` scope, total and self,
  mean, p50/p99. leanprof measures its own cost per scope and per path
  (about 11 ns per `IO` scope, 21 ns per pure one) and subtracts it.
- `--auto`: every function timed with no annotations (about 15 ns per call),
  a declaration's compiled parts (`_redArg`, `_boxed`, lambdas) counted as
  one; exact counts in deep recursion.
- `profile! "label"` on pure terms and monadic actions; report on stderr at
  exit, JSON with `LEANPROF_JSON`. With `module` and
  `public import Leanprof`, programs do not link Lean's front end.
- Tasks: `Task.spawn`, `IO.asTask`, `Task.map/bind`, `IO.mapTask/bindTask`
  linked to the spawning scope with run time and queue wait; `IO.wait` and
  `Task.get` timed per call site.
- Timelines for Perfetto (`--trace FILE`, `LEANPROF_TRACE`), with copies as
  markers.

### Copies, allocations, memory

- Copies of non-exclusive `Array`, `ByteArray`, `FloatArray` and `String`
  values: per function and scope, with bytes, time, share of the scope,
  file:line and why (`shared`, `multi-threaded`, `persistent`).
- `leanprof explain`: why each copy happened (where the second reference
  comes from, from the compiler's IR) and how to fix it; `--why` confirms it
  at run time from the reference increments.
- `--allocs`: allocations per scope and call site; `--counters`: failed
  constructor reuse and closure applications per function; `--frees`:
  freeing pauses per call site.
- Peak memory per scope and memory over time; `leanprof stat`, a one-screen
  summary (time, memory, allocations, copies, frees, tasks, top scopes).
- `--core`: copies, tasks and allocations inside Lean's own libraries, by
  linking against copies rewritten with llvm-objcopy (cached).
- `scripts/leanprof-cc`, a `LEAN_CC` wrapper that adds the probes to every
  package, dependencies included.

### Compile time

- `leanprof elab FILE...`: compile cost per line and declaration from
  Lean's full `trace.profiler` trees, by kind of operation (elaboration,
  kernel, compiler, linters), repeated work, and tactic lines.
- The definitions behind the work, each with its own file:line: what
  `isDefEq` and `whnf` unfolded, instances tried, simp lemmas used.
- `--heartbeats` for exact counts that repeat across runs; `--counts` for
  Lean's exact unfold counts; `--project` (or `--module-glob`) for every
  module of a package, in parallel.
- Lean's messages are decoded a line at a time as they arrive (57 MB of
  memory for a 2.4 GB trace); files Lean fails on are reported.

### Live

- `leanprof top`: a running program, refreshed like top: hottest scopes,
  copy and allocation sites, tasks and waits, with rates per second, memory,
  CPU and what each thread is inside. `--attach FILE` and `--pid PID` for
  programs started with `LEANPROF_LIVE`.
- Flight recorder: the last seconds as a Perfetto trace when a scope is
  slower than `LEANPROF_SLOW_MS`, or on demand with `leanprof dump PID`.
- `leanprof mcp`: an MCP server with profiling tools for AI agents.

### Reports, CI and regressions

- `leanprof html`: one self-contained page (no network) with a flame graph,
  sortable tables, source lines with the findings, and a base-versus-new
  comparison.
- `leanprof compare`: exit 1 on regressions; copies, calls and compile
  heartbeats exact, time thresholded; per declaration and per module.
- GitHub Action (`action.yml`): profiles a pull request's base and head,
  and posts one comment with the changes in copies, allocations, calls,
  compile heartbeats and time, pass/fail per exact metric; `leanprof
  report-md` makes the comment locally.
- `leanprof measure` and `judge`: repeated runs into one summary and a
  KEEP/DISCARD verdict, for autoresearch loops (`research/`).
- Lean API for tests: `Leanprof.expectNoCopies`, `expectAllocsAtMost`,
  `expectNoReuseFailures`, `expectClosureApplicationsAtMost`, and
  `copies`, `calls`, `totalNs`, `overheadNs`, `depth`, `whereIs`.

### Editors

- `#leanprof`: the last reports as inlay hints next to the code (run time,
  sampled time, copies, compile cost, tactic steps), with details on hover
  and in the infoview.
- VS Code extension (`editors/vscode`, `.vsix` on the release): **Run…**,
  **Sample…**, **Compile cost of this file**, **Open report** (the HTML
  report in a tab) and **Live view** (`leanprof top` in a panel), all
  through the command; `leanprof.path` setting.

### Lean versions

- Lean 4.34 and later. CI runs the test suite and `run`, `sample` and
  `elab` on a project with Lean 4.34.1 and 4.35.0, and daily with the
  newest release candidate and the latest nightly.
- Copies of `String` values on Lean 4.36, where `String.push` is inline
  and copies in `lean_string_push_cold`.

### Accuracy and real projects

- A benchmark and accuracy suite (`bench/`) against workloads with known
  answers, samply and LeanProfiler: call and copy counts exact in every
  mode, sampled time within 0.1 to 1.7 points of the true share.
- Case studies, each with the fixes leanprof needed to handle the project:
  [lean-compiler-backend](docs/case-studies/lean-compiler-backend.md),
  [doc-gen4](docs/case-studies/doc-gen4.md),
  [verso](docs/case-studies/verso.md),
  [lean-regex](docs/case-studies/lean-regex.md),
  [concrete](docs/case-studies/concrete.md) and
  [Batteries](docs/case-studies/batteries.md) at compile time; CI profiles
  leanprover-community/repl and lean-regex from outside.

### Documentation

- The guide in [docs/guide](docs/guide/getting-started.md): getting
  started, run time, copies and allocations, memory, compile time, editor,
  VS Code, HTML report, CI and regressions, live view, Lean API, reference,
  how it works and its limits.
