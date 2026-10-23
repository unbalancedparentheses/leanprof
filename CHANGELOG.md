# Changelog

All notable changes to leanprof. Versions follow [semantic
versioning](https://semver.org); a release is a `vX.Y.Z` tag (see
[RELEASING.md](RELEASING.md)).

## [Unreleased]

### Added

- **GitHub Action** (`action.yml`): profiles a pull request's base and head
  commits (`leanprof run --json`, optionally `--allocs`, and
  `leanprof elab --heartbeats`), compares them, and posts or updates one
  comment per pull request with the changes in copies, allocations, calls,
  compile heartbeats and time, with pass/fail per exact metric. Pull
  requests from forks get the report in the job summary instead.
- `leanprof report-md BASE.json NEW.json [BASE_ELAB.json NEW_ELAB.json]`:
  the comment as Markdown, testable locally; exits 1 when a metric named by
  `--fail-on` regressed.
- Reservoir metadata in the lakefile (description, keywords, license,
  homepage), this changelog, and a release workflow that attaches the
  command for macOS arm64 and Linux x86-64 to version tags.
- Case studies of [lean-regex](docs/case-studies/lean-regex.md),
  [doc-gen4](docs/case-studies/doc-gen4.md),
  [verso](docs/case-studies/verso.md) and
  [concrete](docs/case-studies/concrete.md), and a CI job that runs
  `run --auto`, `--allocs --counters --frees`, `sample` and
  `elab --heartbeats` on lean-regex's benchmark and checks the reports.
- `run`, `stat` and `sample` take `--cwd DIR`, for programs that read the
  current directory (a compiler run in its project); positions still come
  from the project (`LEANPROF_PROJECT`).
- `sample` says which declaration calls a specialization when it is not the
  one it is named after (the compiler reuses specializations), names
  `tlv_get_addr` in libdyld (from `dyld_info`) and counts thread-local
  lookups and Lean's C++ expression and kernel code as their own
  categories.
- The report's JSON has `probe_ns`, the probes' calibrated cost in the wall
  time.
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
- `bench/Main.lean` (the comparison with LeanProfiler) calibrates before
  its timed loops: the one-time calibration (about 10 ms) was counted as
  the cost of the first 1,000 actions (10 µs each).
- `leanprof run` on another checkout of leanprof itself no longer links the
  runtime twice on Linux (`scripts/leanprof-cc` skips `LEANPROF_RUNTIME`
  when the link already has leanprof's runtime library).

Found on real projects (see the case studies):

- `--auto`: a declaration's compiled parts (`f`, `f._redArg`, `f._boxed`,
  lambdas) were separate scopes with one name, nested in each other, and
  their totals were added: 281% of the wall time for doc-gen4's `process`,
  calls counted twice. They are one scope now; a lambda, `_redArg` or join
  point called by its own declaration is not a new call, and `_boxed`
  wrappers are not timed.
- `%wall` divided totals without the probes' cost by a wall time with it
  (`main` at 17.7% of lean-regex's run). It now uses the wall time without
  the probes' calibrated cost, which the header shows.
- `--frees` cleared an 8 KiB table after every freeing cascade that met a
  shared object: lean-regex ran 6.3 times slower (13.0 s), now 1.8 times
  (3.6 s).
- Positions of modules in a `srcDir` (`scripts/Bench.lean`) were given as
  if the module were at the package root (`Bench.lean`).
- A specialization made inside another one
  (`g._at_.(h._at_.f.spec_1).spec_2`) was reported under `h` instead of
  `f`; long symbols (over 96 components or 1,024 characters) were cut
  before demangling. `demangle-check` now passes on concrete's 192,087
  symbols.
- `leanprof elab` ran `lake env lean`, which cannot load plugins or the
  shared libraries of precompiled modules: on Verso's documents Lean
  aborted and the files were reported as nearly free. It runs `lake lean`
  now, and says when Lean fails on a file. Lines are named by their source
  instead of the trace's pretty-printed command (which can be `failed to
  pretty print term`), and the header says what a kHB is.
- `leanprof elab` read each of Lean's messages whole and then parsed it:
  concrete's `Check.lean` prints its whole trace (1.3 to 2.4 GB, depending
  on the Lean version) in one message, and leanprof needed 7.5 to 15.5 GB.
  Messages are now decoded a line at a time as they arrive, and only the
  descriptions the report reads are kept (the command's, repeated
  operations', tactics' and those naming a constant): 57 MB for the same
  report, single files and `--project` alike. (This was first fixed in the
  elab code that the definitions, tactics and `--project` rewrite replaced,
  and lost with it.)
- Building with probes printed a report from every `lean` process that
  loaded an instrumented precompiled module (doc-gen4's dependencies); the
  build now runs with reports off and without the user's `LEANPROF_JSON`
  and `LEANPROF_TRACE`.
- `sample` said "is samply installed?" when the program exited with an
  error; it now reports the profile and exits with the program's code.
  Code the linker outlined (`OUTLINED_FUNCTION_N`) counts in its caller,
  `lean_inc_heartbeat` counts as allocation, and C++ names are shown
  without template arguments instead of cut at 512 characters.
- Memory per scope: a call shorter than the time since the last reading
  before it no longer gets a "max rise" (it included what was allocated
  before the call: 9.5 MiB for a parser of ten characters).
- The scope table was printed with a header and no rows when the only
  scopes were tasks.

## [0.1.0] - 2026-10-23

The first version, not tagged.

### Profiling running programs

- `profile! "label"` scopes on pure terms and monadic actions: calls, total
  and self time, mean, p50/p99, source position. Report on stderr at exit,
  JSON with `LEANPROF_JSON`.
- leanprof measures its own cost per scope (lazily, on first use) and
  subtracts it from every enclosing scope (`LEANPROF_NO_CALIBRATION=1` for
  raw times); about 11 ns per `IO` scope and 15 ns per pure scope.
- **Copies of non-exclusive values**: every `Array`, `ByteArray` or `String`
  copied because another reference was alive, per compiled function and
  scope, with bytes, time, share of the scope, declaration file:line (from
  `.ilean` files) and why (`shared`, `multi-threaded`, `persistent`).
- `Leanprof.expectNoCopies`, `copies`, `calls`, `totalNs`, `overheadNs`,
  `depth` and `whereIs` for tests.
- **Allocations** (opt-in, `--allocs` or `allocFlags`): per scope and call
  site, with `Leanprof.expectAllocsAtMost`.
- **Tasks**: `Task.spawn` and `IO.asTask` linked to their spawning scope
  with run time and queue wait; `IO.wait` and `Task.get` timed per call
  site.
- **Automatic mode** (`LEANPROF_AUTO=1` / `all`): every function timed with
  no annotations, specializations reported under the function that caused
  them.
- **Timeline** for Perfetto (`LEANPROF_TRACE`), with copies as markers.
- `scripts/leanprof-cc`, a `LEAN_CC` wrapper that adds copy detection to
  every package, dependencies included.
- Modules: with `module` and `public import Leanprof`, programs do not link
  Lean's front end.

### The `leanprof` command

- `run`: build any Lake project's executable with probes, run it, clean up.
  Projects need no dependency on leanprof: its runtime is compiled for the
  project's Lean version (4.34 and later).
- `sample`: samply underneath, CPU time per Lean declaration with file:line,
  specializations merged, a breakdown of the Lean runtime's own time, and a
  profile that opens in Firefox Profiler with Lean names.
- `elab`: compile cost per line and declaration from full
  `trace.profiler` trees, by kind of operation, with the costliest nested
  operations and repeated work; `--heartbeats` for exact counts.
- `compare`: exit 1 on regressions; copies and calls exact, compile
  heartbeats above 1% and 1,000, time thresholded.
- `measure` and `judge`: repeated runs into one summary and a KEEP/DISCARD
  verdict, for autoresearch loops (`research/program.md`,
  `research/demo/run.sh`).
- `doctor` and `help`; `scripts/install.sh` puts `leanprof` on `PATH`.

### Editor

- `#leanprof`: the last report as inlay hints (run time, copies, compile
  cost), with details on hover.

### Documentation

- The guide in `docs/guide/`, benchmarks against LeanProfiler in `bench/`,
  and a case study on lean-compiler-backend.
