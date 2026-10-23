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
