# Dogfooding: lean-compiler-backend and concrete (2026-10-25)

Every leanprof command was run on two compilers written in Lean 4.34.1, from
fresh clones, with leanprof's `dogfood` branch (from `linux-perf`, built on
Lean 4.35.0). The aims: find what is wrong in leanprof, and find real
speedups in the projects. Machine: the shared 18-CPU Apple M5 Max; load
averages are given with every timing. Only measured claims below. The
changes to the two projects are on local branches only (not pushed).

## lean-compiler-backend (`lcb`, main at `fe10368`)

Workload: `lcb --target aarch64-macos --optimize --allocate deflate.ssa
inflate.ssa trees.ssa crc32.ssa -o zlib.s`, the zlib inputs of
[research/lcb](../../research/lcb/README.md).

### What each tool showed

| tool | result |
|---|---|
| `doctor` | all checks pass (Lean 4.34.1, clang, samply, `rust-objcopy` for `--core`) |
| `run` | self-check ok; output byte-identical to the plain build; `lake build lcb` afterwards rebuilt nothing. Copies are 0.02% of the run after the earlier fixes |
| `run --allocs --counters --frees` | 6,485,632 allocations (168.4 MiB); 27.5% of 6.5M reuse checks fail; 654,564 closure applications, 45% of them `Cleanup.resolve` through the unspecialized `mapOperation`; frees 53 ms |
| `run --core --allocs` | 7,709,601 allocations: 1.2M more inside Lean's libraries, including Lean's own initializers (`KeyedDeclsAttribute`, simprocs, parser tables): `Liveness/Report.lean` imports `Lean`, so the compiler starts all of Lean. Startup is 20 ms; importing only `Lean.Data.Json` changed nothing measurable (paired +0.81%, [−2.92%, 2.84%], before the benchmark lock, load 22) and is not kept |
| `run --auto` | 427 functions; `SSA.constructWithGraph (in List.filterMapTR.go)` 2,029 calls, 108 ms self (with probes); `Liveness.operands` 110 ms self (bit sets as `Nat`) |
| `sample` | 3.7% self in `SSA.constructWithGraph (in List.filterMapTR.go)`; with the new caller notes (below), `List.reverseAux` at 3.9% was 97.75% under `Assembly.emitData`, and `memcmp` 56% under `validateFunctionGraph` |
| `explain`, `explain --json` | all 16 copy sites; none worth fixing (0.02% of the run) |
| `stat` | one screen, consistent with `run` |
| `elab --project --heartbeats` | 80 files in 17.5 s (6 jobs). Slowest: `AArch64.lean` 70.1M heartbeats (26.9M of it compiler), `Verified/PhiExamples.lean` 67.4M; repeated work: `cases w <;> decide +kernel` 11×, 51.8M heartbeats; `CoeT String x Std.Format` 598×, 8.4M |
| `top --plain --auto` | works on a 0.4 s run (17 inputs); scopes, copies, thread stacks |
| `measure` + `judge` | exact allocation counts caught two regressing versions of fix 1 (below); separate `measure` sessions drifted: the `emitData` candidate measured 264 ms against a base measured at 409 ms ten minutes earlier (−35%), where paired timing gives −2% to −5%; `judge` refused the time (overloaded) |
| `measure-pair` + `judge` | the decisive timing tool here (numbers below) |
| `compare`, `report-md`, `html` | base against candidate: no regressions, allocations 6,485,632 → 6,485,589 |
| MCP (`run`, `hot`, `report`, `explain`, `judge`) | works; `hot copies` listed tiny copies first (fixed) |

### Verified speedups (branch `leanprof-dogfood-2026-10-25`)

Every timing below is a `measure-pair` session run under the machine's shared
benchmark lock (no other agent timing at the same time), judged by `judge`
without `--allow-overloaded` (load 2.3–4.4 on 18 CPUs).

1. **`510bee8` SSA construction: group generated phis by block once.** Each
   block filtered the whole list of generated phis. The first version (a
   `HashMap` with `alter`) added 8,740 allocations and `judge` discarded it;
   indexing by block with `getD` (no `Option` cell) leaves the allocation
   count exactly unchanged (6,485,632). 40 pairs: **−6.03%** ([−6.56%,
   −5.44%], 236.6 → 220.9 ms).
2. **`d5bebeb` `Assembly.emitData`: lines in an array.** `lines := lines ++
   [line]` per data item is quadratic in the items of one definition; the
   list cells are reused in place, so allocation counts did not show it
   (−43 in project code), only time did. Against fix 1, 40 pairs: zlib
   workload **−2.39%** ([−3.15%, −1.94%]); crc32 alone (its tables)
   **−14.58%** ([−15.99%, −13.49%], 40.0 → 34.3 ms).

Both against `fe10368`: zlib workload **−8.19%** (40 pairs, [−8.68%, −7.60%],
236.6 → 217.2 ms); all 17 inputs **−6.50%** (30 pairs, [−7.51%, −5.81%],
356.4 → 331.4 ms).

Correctness: `research/lcb/compare.py --identity-only` (540 cases: 17 inputs
× 5 targets × 4 option sets, and 10 malformed inputs) passed for each
commit; `lcb-tests` and `scripts/{ssa,mutable_integer_widths,arm_phi_identity,
data,data_matrix,data_relocations,large_data,data_definition_limit}.py` pass.
The full `scripts/check.sh` (Nix) was not run. Build identity regenerated
with `scripts/build_identity.py --write` in each commit.

Discarded: returning early from `Cleanup.copies` when there are no aliases
(−3,424 allocations, paired −1.31%, [−2.71%, 0.18%]: inconclusive; timed before the benchmark lock existed, at load 9–11).

## concrete (`concrete2` at `8791e092`)

Workload: `concrete build --emit-llvm` in `examples/lox` (1 MB of LLVM IR on
stdout), run with `CONCRETE_STD` pointing at the clone's `std` (a copied
binary does not find it otherwise).

### What each tool showed

| tool | result |
|---|---|
| `sample --cwd examples/lox` | self time: `emitSModule (in List.findSome?)` **13.5%**, `isRuntimeHelperName (in List.elem)` 7.2% (83% from `ensurePtrOp`), `List.reverseAux` 4.9% (now attributed: `resolveImports`, `tarjanSCC.processStack`, `elabModule`), `Layout.lookupStruct` 4.7%, `__getattrlist` 2.6% (93% under `resolveModules`: file-system checks) |
| `run --allocs --counters --frees` | 9,025,484 allocations; `elabModule (in List.filterMapTR.go)` 1,068,123 string copies (1.8% of the run) and 3.2M failed reuse checks: the per-symbol scan of method signatures of the [earlier study](concrete.md) is still there; output and build restored |
| `explain` | names the `elabModule` copy (high confidence), but lists 38 source lines and quotes a comment line as the source (below) |
| `elab --heartbeats Concrete/Check/Check.lean` | 207.3M heartbeats, 62% compiler; the `mutual` block at line 654/661 is 106.6M of compilation and 51.2M of elaboration. It took 74 s with a 10.3 GB maximum resident set (the process tree, `/usr/bin/time -l`), against 4.7 s and 0.79 GB for plain `lean` on the file |
| `elab --heartbeats Concrete/Backend/EmitSSA.lean` | 35.6M heartbeats, 46% compiler; 3.5 s |

### Verified speedups (branch `leanprof-dogfood-2026-10-25`)

Timed under the benchmark lock, load 2.3–3.4, 30 pairs each:

1. **`c3bd7c70` `emitSModule`: generic type arguments indexed once per
   module**, instead of a `findSome?` over every type of every instruction for
   each generic struct and enum (the first match is kept): **−13.60%**
   ([−13.96%, −12.73%], 366.1 → 317.4 ms).
2. **`aefd6157` `ptrRegs` as a `HashSet`** (`isKnownPtr` is asked for every
   operand). Against fix 1: **−6.83%** ([−7.50%, −5.97%]).

Both against `8791e092`: **−19.08%** ([−19.86%, −18.39%], 369.5 → 299.8 ms).

Correctness: stdout, stderr and exit status compared on 6,817 cases: `build
--emit-llvm` in all 33 example projects, and `--emit-llvm`, `--emit-ssa`,
`--emit-core` and `--report caps` on the 4 single-file examples, all 1,530
`tests/programs` and the `tests/invalid_programs` (2,901 of the cases fail
on both sides: invalid programs, and single files that import `std`). All
identical, for fix 1 and for both fixes (6,817/6,817 each).
Concrete's own test suite (Nix) was not run.

## What was wrong in leanprof, and was fixed (branch `dogfood`)

- **`elab` placed definitions at unrelated declarations.** With the
  project on another Lean (4.34.1 against leanprof's 4.35.0), positions come
  from the source, matched by any suffix of the name:
  `Optimize.Algebra.operation` was shown at `SSA.lean`'s `private def
  operation`, `Id.run` at a test's `def run`, `Verified.Machine.address` at
  `RV64.lean`. Declarations are now qualified with their namespace.
- **`sample` did not say who caused hot library code.** `List.reverseAux`,
  `hash_str`, `free` led the table with no caller; each is now listed with
  the project functions it ran under. This found the `emitData` fix.
- **`explain` after `sample`** said "the report has no copies": `sample`
  overwrites `report.json` without copy counts. It now says so.
- **`sample --out FILE`** in a project leanprof had not run in failed at the
  end writing `.lake/leanprof/report.json` (concrete).
- **`judge` could not judge paired sessions while the machine was busy**:
  for the first hours the load sat at 17–22 on 18 CPUs, and −5.2% with
  interval [−7.7%, −2.1%] was "not judged". `--allow-overloaded` (and MCP
  `allow_overloaded`) judges it and says so. (The numbers reported above
  were all remeasured later on a quiet machine, under a benchmark lock,
  without it.)
- **MCP `hot copies`** listed copies of tiny values first (17,775 9-byte
  copies in `SSA.fresh`), which `run` summarizes in one line.
- **`report-md`** printed "(regression: the total grew)" in the details of a
  metric whose total fell.

## Larger issues, not fixed then (see the follow-up below)

- `measure` counts allocations only in the project's code and has no
  `--core`: the `emitData` fix's time came from `List` code in Lean's library
  (cells reused in place), invisible to `judge`'s allocation rule.
- `elab --heartbeats` on concrete's `Check.lean`: 16× the time and 13× the
  memory of plain `lean` (74 s, 10.3 GB).
- `explain` on concrete's `elabModule` copy lists 38 lines and quotes a
  comment (`-- a constant's type with aliases expanded…`) as the source line:
  matching by text accepts comments.
- MCP `explain` is a different, generic explanation, not the IR-based one of
  `leanprof explain --json`; on a sampled report it reports scopes "in 0
  calls".
- `top` and the live view have no notion of tiny copies (no `tiny` flag in
  live snapshots), so `SSA.fresh` is second there too.
- `run` takes `--json FILE`, `sample` takes `--out FILE`, and `run --json`
  does not update `.lake/leanprof/report.json`, so `explain` without
  `--report` reads an older report.
- `stat`'s "2.31 s including process start" for a 0.31 s run is the first
  launch of a freshly linked 106 MB binary (warm runs start in 20 ms); not
  said.

## Follow-up (branch `known-issues`)

Each of the issues above, and two more found meanwhile, with what was done
(details in the [CHANGELOG](../../CHANGELOG.md)):

- **`measure --core`**: copies and allocations in Lean's libraries count;
  `judge` refuses to compare a `--core` summary with a plain one. On
  `corecopies`: 0 → 500 copies, 15 → 3,838 allocations.
- **`elab` on `Check.lean`**: the memory was Lean's. `Elab.step` prints a
  term's whole syntax at every nesting level, so the `mutual` block's
  message was 1.74 GB, and `lean --json` with `trace.profiler` alone took
  28.6 s and 10.3 GB to print it; leanprof reading it took the rest (61 s
  in all). With one-line descriptions (`pp.oneline`) `elab --heartbeats`
  takes 16.9 s and 1.36 GB (plain `lean`: 5.4 s, 0.78 GB), heartbeats
  within 0.03%. The driver (the project on leanprof's Lean, tried by
  switching the clone to 4.35.0) was not affected: 25.2 s, 1.26 GB.
- **`explain` lines**: only structure updates next to the update are cited,
  never comments; `elabModule`'s copy now cites no line instead of 38 (the
  copy is `sp ++ "_"` at `Elab.lean:3356`; finding it is a ROADMAP item).
- **MCP `explain`**: the command's own diagnosis; sampled reports refused.
- **Tiny copies live**: snapshots mark them, `top` and MCP `live` summarize.
- **Options and the last report**: `run --out`, `sample --json`, and
  `report.json` is always the last command's (removed first, so a failed
  run leaves none).
- **`stat`**: launches the new binary once first and prints that launch.
- **Interrupted runs** (found here: a killed `run` left instrumented
  objects that later builds, leanprof's own included, kept): signals are
  caught and the build put back; against SIGKILL, Lake's records of the
  instrumented objects are deleted, so a plain `lake build` recompiles them
  (14.2 s for concrete, only after a kill).
- **`bench/run.py`'s lean-compiler-backend step** gave lcb no input (its
  zlib files moved to compressed copies): `--lcb pinned` clones a pinned
  commit, and the inputs are extracted.
