# Case study: Lake, the language server and `lean`

This case study profiles Lean's own tools with leanprof: Lake, the language
server, and the `lean` frontend. All of them are toolchain v4.35.0, on a copy
of a project that depends on Mathlib (3,725 build jobs) and on Batteries. It
produced seven candidate patches. The patches, with every number, are in
[docs/upstream/lean4](../upstream/lean4/README.md). None of them has been sent
upstream. This page is about how leanprof got there, and about what leanprof
had to learn along the way.

## Getting Lean's tools in front of leanprof

| target | how | modes that work |
|---|---|---|
| released `lean`, `lake`, `lean --server` | `leanprof sample /path/to/bin/lean -- ARGS` | sampling with Lean names and positions (new, below) |
| Lake from source | `src/lake` as a Lake package ([lakefile](../upstream/lean4/tools/lake-lakefile.toml)); `leanprof run --cwd PROJECT lake -- build` | everything: `run --allocs --counters`, `explain`, `stat` |
| `lean`, `--server`, `--worker` with Lean statically linked | [`leanfront`](../upstream/lean4/tools/leanfront-Main.lean), a 60-line Lake executable that calls `lean_shell_main` | `run --core --allocs` (copies and allocations inside Lean's libraries), `sample` |
| one patched core module | compile it with the toolchain (`lean -c`, `leanc -c`) and put the object first in `moreLinkArgs` | A/B of a Lean patch without rebuilding Lean |

samply follows child processes. So
`leanprof sample …/bin/lean -- --server`, run under a scripted LSP session
([`lsp-session.py`](../upstream/lean4/tools/lsp-session.py)), profiles the
watchdog and the file worker it starts.

## Lake: a no-op build

```
$ cd lean4/src/lake && leanprof sample --cwd ~/mathlib-project lake -- build
  1188.70 ms   21.06%   [libsystem_kernel.dylib] stat
  1077.28 ms   19.09%   [libsystem_kernel.dylib] __open
  ...
  1942.10 ms   34.41%   Lake.Module.computeArtifacts  (Lake/Build/Module.lean:901)
  1813.09 ms   32.13%   Lake.Hash.load?  (Lake/Build/Trace.lean:155)
   614.15 ms   10.88%   Lake.Module.checkArtifactsExist  (Lake/Build/Module.lean:836)
```

In the source, every up-to-date module checks that its 7 artifacts exist,
checks again, reads their 7 `.hash` files, and reads their 7 modification
times that are then overwritten. A counter of file-system calls confirmed it:
35 `stat`s per module. [Patch 01](../upstream/lean4/01-lake-noop-io.patch)
brings that to 13.

`leanprof run --allocs --counters` found the other two:

```
allocations: 3091385, 104.1 MiB
    758544    23.1 MiB   22.2%   Lake.Package.findModule? (in Array.foldlMUnsafe.fold)  (Lake/Config/Module.lean:58)
copies of non-exclusive values
      3709     5.4 MiB  15.4 ms  Array  multi-threaded   Lake.Module.recBuildLean  (Lake/Build/Module.lean:1011)
```

`findModule?` built the array of every library for each import it resolved.
The copies were the job queue: an `Array` in an `IO.Ref` that all build
threads share. Lean marks what is stored in such a reference as
multi-threaded, and never updates a multi-threaded value in place, so every
`push` copied every job registered since the last drain.
`leanprof explain` found the copy at `lean_array_push` on the result of
`lean_st_ref_take`, but could not say more than "low confidence". It now
names the pattern and the fix (see below).

The first version of the `findModule?` fix still allocated: the compiler
built the `LeanLib` value before the branch that needed it. The allocation
count did not move, and `run --allocs` showed it at once.

The fix to the job queue then crashed Lake with "out of memory". An
interpreted lakefile (Mathlib's) had been compiled against the old type of
the queue. lldb on `lean_internal_panic_out_of_memory` showed the
interpreter pushing onto the new list as if it were an array. `lake build
-R` fixed it. This is the patch's main risk.

Sampling `lake env true` pointed somewhere unexpected: `__fork` was 7.7% of
the CPU. The runtime starts processes with `fork`, and Lake by then maps
hundreds of MiB of `.olean`s, so each `git` call during workspace loading
copies page tables. Starting them with `posix_spawnp`
([patch 04](../upstream/lean4/04-runtime-posix-spawn.patch)) makes `lake env`
25% faster.

Patches 01 to 04 together make the no-op build 19% faster (1.58 → 1.29 s).
Lake's own tests give the same results before and after.

## The frontend: `lean` on a heavy file

`leanprof sample` on the released `lean` (Lean code in `libleanshared`) now
gives Lean names and positions in the toolchain's sources. `run --core
--allocs` on the static `leanfront` counted 66.6 million allocations for
`Mathlib/Data/Set/Card.lean`. 1.7 million of them were in `System.FilePath`
functions, which is odd for an elaborator. A breakpoint showed them all
coming from `findOLean`. For each imported module it tests every
`LEAN_PATH` entry before Mathlib's with two `stat`s, and it runs twice per
module. Remembering each root's entry
([patch 06](../upstream/lean4/06-findolean-root-cache.patch)) removes 95% of
the `stat`s and makes importing 12% faster.

The same profile, and a 20-line benchmark, showed that `FilePath.fileName`
allocates once per character: `String.revFind?`'s searcher allocates for each
step. [Patch 07](../upstream/lean4/07-filepath-no-alloc.patch) makes it 3×
faster with one allocation. It also removes 40% of a no-op Lake build's
allocations, but that does not change the build's time.

## The language server

A session that opens `Card.lean` and makes 20 edits, under
`leanprof sample …/lean -- --server`:

```
  1895.12 ms   6.95%   Lean.EnvironmentHeader.moduleNames (in Array.mapMUnsafe.map)  (Lean/Environment.lean:182)
                       100.00% of it called from Lean.Server.getModuleContainingDecl?  (Lean/Server/References.lean:234)
```

The "called from" line pointed straight at the cause: building the array of
all ~2,600 imported module names to look up one, for every identifier, on
each round of reference collection.
[Patch 05](../upstream/lean4/05-server-module-name-lookup.patch) indexes the
header instead. The worker's reference work drops by 57%, and the session's
CPU by 13%. The same profile shows the watchdog parsing every `.ilean` file
at startup: 6 to 8 s of CPU, not patched.

## What leanprof learned (fixed on this branch)

- **`sample` takes a path** (`leanprof sample /path/to/lean -- ARGS`). It
  does not need to build a target first.
- **Lean code in Lean's shared libraries** (`libleanshared`,
  `libInit_shared`, `libLake_shared`) is demangled and counted as Lean
  code. Before, the released `lean` and `lake` showed only
  `[libleanshared.dylib] l_Lean_…`.
- **Positions of Lean's own declarations** come from the toolchain's
  `.ilean` files and `src/lean` sources. They are read only for names the
  project does not know. `run` passes the toolchain to the program, so
  copies inside Lean's libraries (`--core`) get positions too.
- **`LEANPROF_PROJECT` no longer breaks absolute paths.**
- **`run --core` finds rustup's llvm-objcopy** (`rust-objcopy`) when no
  other is installed, and `doctor` checks for an objcopy. Before, `doctor`
  said "everything leanprof needs is here" and `run --core` then failed.
- **`explain`** recognizes an array pushed inside a shared `IO.Ref`. It no
  longer prints the multi-threaded explanation for a site where only a few
  copies (12 of 7,420) were multi-threaded.

Still open: `leanprof compare` treats any rise in multi-threaded copies as a
regression. In a parallel program like Lake that count depends on timing
(39,243 vs 39,386 copies in `BuildTrace.mix` between identical runs), so
`compare` reports noise there.
