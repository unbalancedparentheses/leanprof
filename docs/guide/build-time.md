# Build time: `leanprof build`

`leanprof elab` says what each declaration costs to elaborate. What a
project's users wait on is `lake build` as a whole: many modules elaborated
in parallel, each waiting for the modules it imports, then C compiles and
links. `elab --project` cannot answer that: it builds first and then
re-elaborates every module with tracing, so its wall time is not a build's
([compile time](compile-time.md#whole-projects)). `leanprof build` measures
a real build.

```
leanprof build --clean                 # rebuild the package, measured
leanprof build --clean --validate 6    # and check the rebuild estimates on 6 modules
leanprof build --clean --imports 3     # and try the 3 most promising import changes
leanprof build --html build.html       # with a timeline of the build
```

It runs `lake build -v` (with the targets you give, else the package's
default targets) and records every process Lake starts: each module's
`lean`, each C compile, each link and archive, with when it started and
ended, its peak resident memory and its CPU time. The build is an ordinary
one: Lake reuses it afterwards and nothing is rebuilt by a later plain
`lake build`. Without `--clean` it measures whatever Lake has to rebuild
(nothing, if the build is up to date); `--clean` removes the package's
`.lake/build` first, so every module of the package is rebuilt while the
dependencies' builds (Mathlib from its cache, for instance) stay.

## What it reports

- **The critical path as it happened.** From the job that ended last, back
  through the dependency that ended last: the chain of modules that set the
  build's length, with the wait before each job (Lake's own work, or no
  free worker). Before the first job: Lake starting up, loading the
  workspace and checking what is up to date.
- **Slack per job.** How much later each job could have ended without
  delaying the build, if workers were unlimited (the critical-path method
  on the measured durations). Zero on the critical path; a slow module with
  a lot of slack does not matter for the build's length.
- **Parallelism over time.** How many jobs ran at each moment, the time
  spent with 0, 1, 2, … running, and the stretches of a second or more
  (and 2% of the build) where at most one job ran, with the jobs running
  then: where the build was serialized.
- **Peak memory per process**, in `max_rss_bytes` of each job (the
  process's peak resident set, from `getrusage` after it ended).
- **Rebuild after touching each module, estimated.** Touching a module
  (changing what it exports) reruns its own job, the job of every module
  that imports it, its C compile, and the links that use its object. A list
  scheduler runs those jobs with the same number of workers (`--jobs N`,
  default the hardware threads, which is what Lake's thread pool uses),
  each starting a short measured time after its last dependency ends (a
  quarter of the build's waits were shorter: Lake's own work when a worker
  is free), and adds a measured no-op build (Lake loading the workspace and
  checking traces).

  The jobs' wall times in a clean build are not what they take in a
  rebuild: a clean build keeps every core busy with many jobs, so each one
  waits for a core. On Batteries the median `lean` process got half a
  core's worth of CPU time per second of wall time. So each job is given
  its time alone: its CPU time when that is less than its wall time (it
  waited), else its wall time (it used several threads, and keeps that
  many cores busy). When the running jobs want more cores than the machine
  has, they all slow down by the same factor. Replaying the wall times as
  measured gave rebuild estimates up to 2.5 times the real rebuilds on
  Batteries; the time-alone model brought the mean error to 8.9%
  ([case study](../case-studies/build-time.md)).

  Both models are also run over the whole build and printed next to it:
  the replay checks the dependencies and the scheduling (it should come
  close to the measured build), and the time-alone model shows how much of
  the build was lost to contention.

## How the processes are seen

Lake runs the toolchain's own programs: `<toolchain>/bin/lean` for each
module, `clang` (or `LEAN_CC`) for C files and links, `llvm-ar` (or
`LEAN_AR`) for archives, and on Lean 4.33 and later `leanir` for modules
that postpone code generation. With `LAKE_OVERRIDE_LEAN=true` and
`LEAN_SYSROOT` set, Lake takes the toolchain from `LEAN_SYSROOT`.
`leanprof build` points it at a directory (`.lake/leanprof/build/sysroot`)
of links to the real toolchain, whose `bin/` programs are small scripts
calling `leanprof-build-shim`: the shim runs the real program with the same
arguments and streams, waits for it, writes one record (start, end, exit
code, peak memory and CPU time of the process) and exits with its exit
code. The shim imports only `Init`; it adds about 6 ms to each process
it runs (median of 300 runs of `/usr/bin/true` with and without it, on a
loaded M5 Max: [shim-overhead.json](../case-studies/build-time/shim-overhead.json),
`scripts/shim-overhead.py`), small next to a module's elaboration.

This was chosen over the alternatives because it is the one that gives
start times, the schedule and memory on every Lean from 4.27 to 4.35:

- Lake's `-v` output gives each job's duration but not when it started, so
  neither the critical path nor the concurrency; leanprof still reads it
  for each module's state (`Built`, `Replayed`, `Fetched`, `Unpacked`, or
  `Ran` when there was nothing to do).
- Setting `LEAN` alone does nothing in the usual installation, where Lake
  and Lean come from the same toolchain directory.
- Sampling the process table misses short processes, gives start times to
  the sampling interval and costs CPU while the build runs.

Lake's traces do not depend on the toolchain's path, so a shimmed build
after a plain one rebuilds nothing, and a plain one after a shimmed one
rebuilds nothing either (`scripts/build-check.sh` checks it on every
supported Lean in CI).

Dependencies come from Lake itself: for each module it writes a setup file
(`--setup`, Lean 4.22 and later) with the module's name, package and every
module it imports, transitively. A module's job depends on the jobs of the
rebuilt modules among those; a C compile on its module's job; a link or an
archive on the jobs that wrote its inputs (response files are read). The
import graph is not used to guess durations or the schedule; every time in
the report is a measured process.

## Checking the estimates: `--validate K`

`--validate K` picks K modules spread from the costliest estimated rebuild
to the cheapest, and for each: adds a public definition at the end of the
file (so its `.olean` changes, as with an edit to what it exports), builds,
puts the file back and builds again. Both builds are measured; the report
gives each estimate, the measured times, the error, and whether Lake
rebuilt exactly the predicted modules. This runs in a git worktree of the
working tree (`.lake/leanprof/build/work`, started from a copy of the
project's build, removed at the end unless `--keep-worktree`): the project
itself is never edited.

An edit that does not change a module's `.olean` (a comment, a proof whose
statement stays the same) rebuilds less: Lake skips the importers whose
inputs did not change. The estimate is for an edit that changes what the
module exports.

## Imports: `--imports K`

Removing an import can only help when the module stops depending on
something it waited for. For every import of every rebuilt module of the
package, leanprof computes what would change if it went:

- if the module names a declaration of that module (its `.ilean`
  references), the import is needed and is left out;
- if the module defines nothing (it exists to re-export, like `Mathlib.lean`),
  it is left out;
- if the imported module is still reached through another import, nothing
  changes and it is left out;
- otherwise the module would import, in its place, the modules of the
  declarations it names that it would no longer reach (a heavy module
  imported for one small thing becomes an import of the small thing's
  module).

Each candidate is ranked by the estimated gain on the clean build (the
simulation of the whole build with the changed dependencies) plus the gain
on the rebuild after touching the removed import. The best K are tried in
the worktree: the header is changed, the package builds, and the change
counts only if the build passes with no more `declaration uses 'sorry'`
warnings than before. If it fails (the module uses an instance, a notation
or a macro without naming a declaration), the import is replaced by what
the import itself imports, and the build is tried again. For an accepted
change, the rebuild after touching the removed import is measured before
and after (two builds each); the gain on the clean build stays an estimate
and says so.

The build covers this package's targets only. A module's imports are part
of what its importers outside the package see: a library's users may rely
on something it re-exports. leanprof never edits the project; it reports
the change and its measurements.

## Output

- The text report, then `.lake/leanprof/build.json` (`--json FILE`),
  following [`schemas/build.schema.json`](../../schemas/build.schema.json):
  every job with its dependencies, lane, slack and peak memory; every
  module of the package with its state, direct imports and rebuild
  estimate; the critical path; the parallelism profile; the model's check;
  and the validation and import results when asked for. `--from FILE`
  prints a saved report again (and `--html` draws it).
- `--html FILE`: one page with the number of jobs running over time and a
  Gantt chart of the build (one row per lane, the critical path drawn
  solid; hover a bar for its job), the critical path and the costliest
  rebuilds as tables.
- The MCP tool `build` runs it for agents (`clean`, `validate`, `imports`,
  `targets`, `html`), with the elapsed time, the critical path's work and
  the report's path in its structured result.

## Limits

- The no-op build and the time between jobs are measured once per run, on
  a machine that may be busy; the report records the load average before
  and after. Rebuild estimates inherit the noise of the build they replay.
- Lanes are a way to draw the schedule: Lake has no fixed workers.
- A module whose job did not run in the measured build (up to date, or
  fetched from a cache) has no duration, so no rebuild estimate: use
  `--clean`.
- Peak memory is the process's; for `lean` it includes the imported
  `.olean` files it maps.
