# Changelog

All notable changes to leanprof. Versions follow [semantic
versioning](https://semver.org); a release is a `vX.Y.Z` tag (see
[RELEASING.md](RELEASING.md)).

## [Unreleased]

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
