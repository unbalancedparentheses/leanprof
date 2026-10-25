# Candidate patches for Lean 4 (v4.35.0)

These are performance findings in Lake, the language server, the frontend and
the runtime, made with leanprof. Each one has a patch against
[leanprover/lean4](https://github.com/leanprover/lean4) at tag `v4.35.0`
(commit `eb6cafb`). Nothing here has been sent upstream. These are evidence and
candidate patches for someone to review, not finished pull requests. The way
the profiling was done is in the
[case study](../../case-studies/lake-and-server.md).

| patch | where | measured effect |
|---|---|---|
| [01-lake-noop-io](01-lake-noop-io.patch) | Lake: up-to-date module check | no-op build of a Mathlib project: −37% file-system calls (221,508 → 140,053), −8% CPU |
| [02-lake-findmodule-alloc](02-lake-findmodule-alloc.patch) | Lake: `Package.findModule?` | −758,000 allocations in that build (−24% of Lake's own) |
| [03-lake-job-queue-list](03-lake-job-queue-list.patch) | Lake: build job queue | 3,700 array copies (5.4 MiB, quadratic between monitor drains) → 0 |
| [04-runtime-posix-spawn](04-runtime-posix-spawn.patch) | runtime: `IO.Process.spawn` | `lake env true` −25% wall; no-op `lake build` −16% wall |
| [05-server-module-name-lookup](05-server-module-name-lookup.patch) | server: references | worker's ilean (reference) computation −57% CPU, a whole session −13% |
| [06-findolean-root-cache](06-findolean-root-cache.patch) | `findOLean` (imports) | importing `Mathlib.Data.Set.Card`'s closure: −95% `stat` calls, −12% wall |
| [07-filepath-no-alloc](07-filepath-no-alloc.patch) | `System.FilePath` | `fileName` 205 ns → 66 ns, 17 → 1 allocations; 40% of a no-op Lake build's allocations come from these functions |

Patches 01 to 03 together with 04 make a no-op `lake build` of a project
that depends on Mathlib **19% faster** (median 1.583 s → 1.285 s, 20
interleaved runs each) and use **14% less CPU**.

## Setup

- **Machine**: Apple M5 Max (18 cores), macOS. The machine was shared and
  often loaded (load average 7 to 45), so every timing is a pair of A/B runs
  interleaved 15 to 20 times ([`tools/ab.py`](tools/ab.py)), and we report the
  median. Where exact metrics exist (allocations, copies, system calls), we
  give those first, because they do not change from run to run.
- **Workload for Lake**: a copy of a project that depends on Mathlib
  `v4.35.0` (3,725 build jobs, 3,709 modules, all built). We measure the no-op
  `lake build` and `lake env true`. We also used Batteries `v4.35.0` (222
  jobs).
- **Workload for the frontend**: `Mathlib/Data/Set/Card.lean` (1,486 lines,
  about 4 s), and a file with only its imports.
- **Workload for the server**: [`tools/lsp-session.py`](tools/lsp-session.py)
  opens `Card.lean`, waits until it is elaborated, makes 20 edits (each
  appends a theorem and waits for it), then shuts the server down.
- **Lake from source**: `src/lake` built as a Lake package with
  [`tools/lake-lakefile.toml`](tools/lake-lakefile.toml). The binary at
  `src/lake/.lake/build/bin/lake` finds its own install. This lets leanprof
  run Lake with probes (`run --allocs --counters`), and lets `explain` read
  its C.
- **Lean's own libraries**: we built a static `lean` from
  [`tools/leanfront-Main.lean`](tools/leanfront-Main.lean), a Lake executable
  that does what `lean_main` does: `lean FILE`, `--server` and `--worker`.
  We profiled it with `leanprof run --core`.
- **Testing a patch to one core module without rebuilding Lean**: we
  compiled the patched module with the toolchain
  (`lean --root=src -c M.c src/.../M.lean`, then `leanc -c -O3 -DNDEBUG`) and
  put the object first on the link line (`moreLinkArgs`). The archive
  member it replaces is then never pulled in. We checked that each object
  defines the original's symbols. The runtime patch was tested the same way,
  with `src/runtime/process.cpp` compiled with `clang++ -std=c++17 -O3 -I src
  -I src/include -I <toolchain>/include`.
- **Counting file-system calls**: [`tools/fscount.c`](tools/fscount.c), a
  `DYLD_INSERT_LIBRARIES` library that counts `open`, `stat`, `fstat`,
  `read`, `close`, `fork` and `posix_spawnp`.

---

## 01: Lake re-reads and re-stats every artifact of every up-to-date module

**Finding.** `leanprof sample` on a no-op `lake build` (3,725 jobs) puts
`Lake.Module.computeArtifacts` (`Lake/Build/Module.lean:901`) at 28% of CPU
and `Lake.Module.checkArtifactsExist` (`:836`) at 15%. Nearly all of it is in
the kernel: `stat` 21% and `open` 19% of the samples. A counted run made
131,215 `stat` calls, 35 per module. For each up-to-date module
(`recBuildLean.fetchCore`, `Module.lean:1063`):

- `checkHashUpToDate'` calls `Module.checkExists`, which runs
  `checkArtifactsExist`: 7 stats (8 with the `.ltar` probe).
- Right after that, `fetchCore` calls `checkArtifactsExist` again
  (`unless (← mod.checkArtifactsExist …)`): 7 more stats.
- `computeArtifacts` calls `computeArtifact` on each of the 7 artifacts. Each
  call reads the `.hash` file through `IO.FS.readFile`, which does a `stat`
  for the size and then a read loop. It also calls `getMTime` (one more
  `stat`).
- `adjustMTime` then sets every artifact's modification time to the trace
  file's. The 7 `getMTime` results above are thrown away.

**Patch.**
- Remember what the first existence check found, so the second check does
  not stat the files again. Check the artifacts before the archive, which
  gives the same boolean.
- In `computeArtifacts`, leave the modification time unset. `recBuildLean`'s
  `adjustMTime` always overwrites it. When there is no trace file it now
  reads each artifact's time (`ModuleOutputArtifacts.readMTimes`), which is
  what happened before.
- `Hash.load?` opens the file and reads at most 17 bytes. A valid hash file
  is exactly 16 hex digits, so anything longer is still rejected.

**Measured.**
- `stat` calls: 131,215 → 49,760. All file-system calls: 221,508 → 140,053
  (−37%).
- Lake's CPU: −8% (user+sys median, 15 runs).
- Wall time of the no-op build: within noise on its own (median 1.448 →
  1.488 s, min 1.286 → 1.316 s). The build phase is not limited by these
  calls. With the other patches the total is −19% (see the top).

**Risk.** Low. The modification times are the same values as before: the
trace file's time, or the artifact's own when there is no trace file. Lake's
test suite gives the same results as the baseline (below).

## 02: `Package.findModule?` builds the array of all libraries on every lookup

**Finding.** `leanprof run --allocs` puts 758,544 allocations (23.1 MiB,
22% of all of Lake's own allocations in a no-op build) in
`Lake.Package.findModule?` (`Lake/Config/Module.lean:58`).
`Workspace.findModule?` calls it for every package, for every import of every
module. It runs `self.leanLibs.findSomeRev? …`, and `leanLibs` (through
`configTargets`) allocates a fresh array with a `ConfigTarget` for each
library each time.

**Patch.** Search `targetDecls` directly. Test `LeanLibConfig.isBuildableModule`
on the declaration's configuration, and build the `LeanLib` only for the
match. A first version that built the `LeanLib` before the test still
allocated, because the compiler allocated it before the branch.
`leanprof run --allocs` caught that. The patch checks in the IR that the
allocation is now inside the branch.

**Measured.** All of Lake's allocations in the no-op build: 3,091,385 →
2,362,732 (−23.6%, 104.1 → 81.8 MiB). This includes 03, which allocates
about the same number of cells. Wall time is not measurable on its own.

**Risk.** Very low. The result and the search order (last library first) are
the same.

## 03: the build job queue copies itself on every registration

**Finding.** `leanprof run` reports 3,700 `Array` copies, all
multi-threaded, 5.4 MiB in total, in `Lake.Module.recBuildLean`.
`leanprof explain` points at `lean_array_push` on the result of
`lean_st_ref_take`. This is `registerJob`
(`Lake/Build/Job/Register.lean:43`):
`registeredJobs.modify (·.push job)` on an `IO.Ref (Array OpaqueJob)` that
every build thread uses. `lean_st_ref_put` marks what is stored in a
multi-threaded reference as multi-threaded (`src/runtime/io.cpp`), and
`lean_is_exclusive` is false for multi-threaded objects. So every push
copies the whole array of jobs registered since the monitor last drained the
queue (every 100 ms). The cost is quadratic in the jobs registered per
window, and other threads spin in `lean_st_ref_take` while a copy is made.

**Patch.** `JobQueue := IO.Ref (List OpaqueJob)`, newest first. Registering
conses a cell. `drainQueue` reverses the list into an array, so jobs are
still reported in registration order. The deprecated `monitorJobs` takes a
`JobQueue`.

**Measured.** Copies in `recBuildLean`: 3,700 (5.4 MiB) → 0.

**Risk.** It changes the representation of a public type that `@[inline]`
code uses, through `registerJob` inlined into compiled lakefiles. A
`lakefile.olean` compiled against the old Lake must be re-elaborated. A new
toolchain does that on its own, because its Lean githash changes. A Lake
built from source with the same Lean version crashed (out of memory, in
Mathlib's lakefile code) until we ran `lake build -R`. A smaller change
would keep `Array` and swap the whole array out with
`modifyGet (·, #[])` in the monitor only. That does not remove the copies
during registration.

## 04: spawning processes with `fork` in big processes

**Finding.** `leanprof sample` of `lake env true` on the Mathlib project
puts `__fork` at 7.7% of all CPU (87 ms), plus `_xzm_do_lock_action`
(malloc locks held around `fork`) and `libSystem_atfork_parent`.
`IO.Process.spawn` (`src/runtime/process.cpp`) uses `fork` + `execvp`. In
Lake, after it has imported Lean to load the lakefile, `fork` copies the
page tables of hundreds of MiB of mapped `.olean` files. Workspace loading
runs about 27 `git` commands one after another (`remote get-url`,
`rev-parse`, `diff` per dependency), and a build spawns `lean` once per
module.

**Patch.** Start the child with `posix_spawnp` when that does exactly what
the `fork` path does:
- `inherit_env` is set and `PATH` is not overridden, because `posix_spawnp`
  searches the parent's `PATH` and `execvp` the child's;
- `setsid` and changing the directory can be expressed: `POSIX_SPAWN_SETSID`,
  and `posix_spawn_file_actions_addchdir_np` (macOS 10.15+, glibc 2.29+).

Pipes, `/dev/null` and the environment become file actions and an `envp`.
In every other case, and when `posix_spawnp` fails (a missing executable or
working directory), the old `fork` path runs. It reports those errors from
the child as before (the message, then exit code 255).

**Measured** (the patched `process.o` linked into an otherwise unchanged
Lake):
- `fork`: 30 → 1 per `lake env true`, now 29 `posix_spawnp`.
- `lake env true`: median 0.779 → 0.581 s (−25%), CPU −22%.
- No-op `lake build`: median 1.615 → 1.348 s (−16.5%).
- The language server's watchdog and `lake build`'s `lean` processes get the
  same change. We did not measure them separately.

**Risk.** Medium. This is a platform-level change in the runtime. We only
tested it on macOS. Linux (glibc ≥ 2.29) takes the same code path but was
not run. Windows is untouched. Lake's tests (below) passed with it.

## 05: the server builds the list of all imported module names for every identifier

**Finding.** A scripted server session on `Card.lean` (open + 20 edits),
sampled with `leanprof sample …/lean -- --server`. samply follows the
worker process. The top Lean function by self time is
`Lean.EnvironmentHeader.moduleNames (in Array.mapMUnsafe.map)`, 1.9 s, 7% of
all CPU, and leanprof says 100% of it is called from
`Lean.Server.getModuleContainingDecl?` (`Lean/Server/References.lean:234`).
That function does `env.allImportedModuleNames[modIdx]?`.
`allImportedModuleNames` is `header.modules.map (·.module)`, a fresh array of
about 2,600 names, built for each constant that `identOf` looks at whenever
the worker collects references for its ilean notifications. The same pattern
is in `findModuleOf?` (`Lean/MonadEnv.lean:196`) and in
`LazyDiscrTree.createImportedEnvironmentSeq` (`Lean/Meta/LazyDiscrTree.lean:913`,
once per imported module, so quadratic).

**Patch.** Index `env.header.modules` directly in all three places.

**Measured** (only `References.lean`, linked into the static `lean`,
sampled session with 20 edits):

| | before | after |
|---|---|---|
| `mkIleanInfoNotification` | 5,547 ms | 2,403 ms (−57%) |
| `identOf` | 3,262 ms | 555 ms (−83%) |
| `moduleNames` | 1,473 ms | gone |
| whole session's CPU | 19.7 s | 17.1 s (−13%) |

The time to open the file and the edit latency (about 0.22 s, which looks
like the server's edit delay) did not change. This work runs in the
background, and it competes with elaboration for cores. The other two call
sites were compiled but not measured.

**Risk.** Very low: the same value.

## 06: `findOLean` checks every search path entry, with two `stat`s each, for every module

**Finding.**
- Running `lean` on `Card.lean` with Mathlib's `LEAN_PATH` (11 entries) made
  80,849 `stat` calls, 31 per imported module.
- `leanprof run --core --allocs` on the static `lean` puts 1.7 million
  allocations in `System.FilePath` functions. lldb shows them called from
  `SearchPath.findWithExt`, through `findOLean` and
  `readModuleDataPartsOfMod`.
- `findWithExt` (`Lean/Util/Path.lean:61`) tests each entry with
  `(p / root).isDir <||> ((p / root).addExtension ext).pathExists`. For a
  Mathlib module that is 2 stats for each of the 8 entries before Mathlib's.
- An import calls `findOLean` twice: `readModuleDataPartsOfMod` and
  `readIRPartsOfMod`.

**Patch.** `findOLean` remembers which entry each module root (`Mathlib`)
was found in, for as long as the search path is the same (compared with
`==`). The answer depends only on the root, so it is the same for every
module of that root. It is the same as before unless a root's directory
appears in an earlier entry while the process runs.

**Measured.**
- Importing `Card.lean`'s closure: `stat` 80,849 → 4,295 (−95%), all
  file-system calls 122,741 → 46,187.
- Wall: median 0.747 → 0.659 s (−12%), CPU −12% (20 runs).

**Scope.** Lake builds and the server pass explicit artifact paths
(`importArts` from `lake setup-file`) and skip `findOLean`. The patch helps
`lean` run by hand or through `lake env`, `lean --run` scripts, and tools
that call `importModules` with a search path: REPLs, doc-gen, linters, and
Lake loading lakefiles.

**Risk.** Low (the case above, in a long-running process).

## 07: `System.FilePath` functions allocate for every character they scan

**Finding.**
- `FilePath.fileName`, `parent`, `withExtension` and friends find the last
  separator with `String.revFind?`. Its searcher (`Std.Iterators`) allocates
  for every character it steps over.
- `isAbsolute` and `afterRootDirectory` call `String.front`, which allocates
  an `Option Char`.
- In a micro-benchmark, `fileName` of a 100-character path takes 205 ns and
  allocates 17 objects.
- With `--core`, these functions make 3.6 million of the 9.1 million
  allocations (40%) of a no-op Lake build.

**Patch.** Compare bytes: every path separator is ASCII, so a byte matches
only at a character boundary. `posOfLastSep` walks bytes from the end and
returns `pos?` of the match. `isAbsolute` and `afterRootDirectory` test the
first byte.

**Measured.**
- `fileName`: 205 → 66 ns (3.1×), 17 → 1 allocation (the `Option` result).
- No-op Lake build: wall and CPU unchanged within noise (medians 1.427 vs
  1.461 s, minimums 1.336 vs 1.270 s).

It removes millions of allocations, but they are not on the critical path.
Unlike 01 to 06, this is a library-wide micro-optimization.

**Risk.** Low. Separators are ASCII in every encoding Lean uses for paths.
The broader issue, that `String.find?` and `revFind?` with a predicate
allocate per character, is not addressed here.

---

## Not patched

- **The watchdog loads every `.ilean` at startup.**
  `Lean.Server.Watchdog.startLoadingReferences` took 6.6 to 8.4 s of CPU in
  the server session, mostly `Ilean.load` parsing JSON
  (`Json.Parser.strCore` alone is 3% of all CPU). It runs in the background,
  but on 18 cores it competes with the first elaboration. A binary ilean
  format, or loading on demand, would remove it.
- **Lake's memoization map.** `Lake.recBuildWithIndex` inserts into a
  `Std.DTreeMap` that every thread uses. 432,677 constructor-reuse failures
  (94%) and 458,574 allocations in a no-op build come from that.
- **Lake workspace loading** in a Mathlib project (about 0.8 s of `lake env
  true`) is dominated by importing Lean for the lakefile
  (`importModulesUsingCache`, 420 ms) and `git` checks that run one after
  another: 3 per dependency, about 180 ms. Patch 04 makes each of them
  cheaper. Running them in parallel would remove most of the rest.

## How these were checked

- **Lake tests.** 51 of Lake's own tests (`tests/lake/tests/*`, everything
  that needs no network, Reservoir or stage build) ran with the baseline Lake
  and with Lake plus patches 01 to 04. The results are identical: 42 pass
  with both. 9 fail with both, for reasons of the environment (`8448`,
  `depTree`, `externLib`, `lean`, `noRelease`, `semver`, `serve`, `shake`,
  `versionTags`).
- **No-op builds** stayed no-op ("Build completed successfully (3725 jobs)",
  nothing rebuilt), with every patched binary.
- **Patches 05 to 07** compile with the v4.35.0 toolchain. The static `lean`
  with each override elaborated `Card.lean` and served the LSP session.
- We did not run Lean's own test suite: the clone has no CMake build here.
