# Memory of compilation: Batteries, leanprof and a project using Mathlib

`leanprof build-memory` ([guide](../guide/compile-time.md#memory-of-compilation))
run on three projects, its numbers compared with `/usr/bin/time -l`, its
advice on the number of jobs checked with real builds, and its own cost.

Machine: an Apple M5 Max (18 CPUs, 128 GB) shared with other agents'
work; every run below held the shared benchmark lock, and the 1-minute load
average before and after each one is in [load.txt](build-memory/load.txt)
(between 7.9 and 21, and 106 to 158 during the Mathlib `--jobs 2` run).
Lean 4.35.0. Batteries and leanprof were measured on 2026-10-27, the
Mathlib project on 2026-10-28. Every number here is in the files of
[build-memory/](build-memory/).

## Batteries

`leanprof build-memory --clean --mem-limit 2G --decls 2` at commit
`66e4691` ([report](build-memory/batteries.txt),
[JSON](build-memory/batteries.json)): 196 `lean` processes, at most 18 at
a time.

| module | peak RSS | footprint | imports | own |
|---|---|---|---|---|
| runLinter (the linter executable's root) | 1.36 GiB | 255 MiB | 1.30 GiB | 65 MiB |
| Batteries.Data.List.Lemmas | 586 MiB | 300 MiB | 362 MiB | 224 MiB |
| Batteries.Recycling.RBTree.WF | 545 MiB | 258 MiB | 370 MiB | 175 MiB |

Most of a module's peak is its imports: the median module's header alone
reaches 90% of its peak. The footprint (the private memory macOS charges)
is a third of the peak RSS for the median module; the rest is pages of
mapped `.olean` files, which the processes share. `runLinter` imports all
of Lean (1.30 GiB resident before it does anything) and is the heaviest
process of the build.

All 18 at a time, the peaks of the modules running together added up to
6.37 GiB at most, while the sum sampled every 0.2 s reached 4.36 GiB
resident, and 1.69 GiB counting the shared part once.

**Jobs under 2 GiB.** The two largest peaks add up to 1.94 GiB, so 2 jobs
are safe whatever runs together; counting the shared pages once, the
estimate is 3 jobs (1.91 GiB). Both checked with real builds
(`--clean --jobs J --mem-limit 2G`):

| jobs | most running together | peaks of those running together, added up | sampled, resident sets added up | sampled, private plus shared once |
|---|---|---|---|---|
| 2 ([JSON](build-memory/batteries-jobs2.json)) | 2 | 1.89 GiB | 1.63 GiB | 1.46 GiB |
| 3 ([JSON](build-memory/batteries-jobs3.json)) | 3 | 2.25 GiB | 2.03 GiB | 1.40 GiB |

At 2 jobs every measure stays under the limit. At 3, resident sets added
up go above it (they count the shared `.olean` pages once per process)
while the private memory plus one shared part stays at 1.40 GiB: the
estimate held, and the bound is the conservative one. `LEAN_NUM_THREADS`
limits Lake as expected: at most 2 and 3 `lean` processes ran at once.

**Per command.** `Batteries.Data.List.Lemmas`, elaborated serially: 358 MiB
after the imports, 425 MiB at its peak, reached during `swap_swap`
(line 1422); the largest single rise, 11 MiB, during
`count_getElem_take_succ` (line 22). In the build, where proofs run in
parallel, the same module peaked at 586 MiB: a serial run says where the
memory grows, not how much the build needs.

## leanprof

`build-memory --clean --mem-limit 4G --decls 1 -- leanprof` on a copy of
this repository ([report](build-memory/leanprof.txt),
[JSON](build-memory/leanprof.json)): the 15 modules of the command, at
most 8 at a time. The elab driver imports all of Lean and peaks at
1.31 GiB (1.22 GiB of it the imports); `LeanprofCli` has the largest own
part, 299 MiB of 833 MiB. Under 4 GiB, 4 jobs are safe (3.45 GiB for the
4 largest peaks); the sampled sum reached 2.51 GiB resident and 1.28 GiB
with the shared part once.

## A project using Mathlib

A project requiring Mathlib at `56a0058` (v4.35.0), with Mathlib's build
cache (nothing of Mathlib compiled locally), and four modules
([how it is made](build-memory/mathlib-project-files.sh)): `import
Mathlib` alone, and copies of three of Mathlib's most expensive files by
Radar's ranking ([Mathlib case study](mathlib.md)), compiled here against
the cached build with Mathlib's `autoImplicit` and `maxSynthPendingDepth`
options (not its linters). `build-memory --clean --mem-limit 8G
Mlp/Tilde.lean -- Mlp` ([report](build-memory/mathlib-project.txt),
[JSON](build-memory/mathlib-project.json)):

| module | peak RSS | footprint | imports | own | wall |
|---|---|---|---|---|---|
| `import Mathlib` | 5.44 GiB | 853 MiB | 5.43 GiB | 13 MiB | 23.6 s |
| copy of `CategoryTheory/Sites/SheafCohomology/MayerVietoris` | 1.76 GiB | 948 MiB | 1.06 GiB | 714 MiB | 33.5 s |
| copy of `AlgebraicGeometry/Modules/Tilde` | 1.57 GiB | 625 MiB | 1.25 GiB | 333 MiB | 21.4 s |
| copy of `Analysis/Fourier/FourierTransform` | 1.29 GiB | 424 MiB | 1.18 GiB | 113 MiB | 16.7 s |

Importing all of Mathlib maps 5.4 GiB of `.olean` files, but only 853 MiB
of it is private. `MayerVietoris` imports a fifth as much and needs more
private memory than all of Mathlib's imports (948 MiB); its own
elaboration, 714 MiB, is the largest here (the kernel does most of this
file's work, per the Mathlib case study).

The four ran together: their peaks add up to 10.07 GiB, the sampled sum
reached 7.98 GiB resident and 6.06 GiB with the shared part once. Under
8 GiB, 2 jobs are safe (7.20 GiB); the estimate with shared pages counted
once allows all four (7.39 GiB). The build with `--jobs 2`
([JSON](build-memory/mathlib-project-jobs2.json)) ran at most 2 at a time,
with 7.20 GiB for the two that ran together and 5.44 GiB sampled.

**Per command.** The copy of `Tilde`, elaborated serially: 1.24 GiB after
the imports, 1.50 GiB at its peak. The largest rise, 178 MiB, came during
`Scheme.Modules.fromTildeΓ` (line 253, 61.8 M heartbeats), then 28 MiB
during `restrictAppIso_smul_Spec` (line 128) and 20 MiB during
`modulesSpecToSheaf` (line 43); the peak itself was reached during
`tildeEquiv` (line 885).

## Against `/usr/bin/time -l`

The same `lean` command lines Lake ran (outputs to a temporary directory),
under `/usr/bin/time -l` and under the wrapper alone, against the number
in the build's report ([Batteries](build-memory/batteries-time-l.json),
three runs each; [Mathlib project](build-memory/mathlib-project-time-l.json),
two runs each):

| module | build: RSS / footprint | `time -l`: RSS / footprint | wrapper alone: RSS / footprint |
|---|---|---|---|
| Batteries.Data.List.Lemmas | 586 / 300 MiB | 584–591 / 297–304 MiB | 580–587 / 295–300 MiB |
| runLinter | 1397 / 255 MiB | 1394–1396 / 253–254 MiB | 1395–1396 / 254 MiB |
| Batteries.Data.String.Lemmas | 513 / 221 MiB | 509–513 / 219–221 MiB | 512–514 / 220–222 MiB |
| Batteries.Data.Char | 376 / 121 MiB | 376–378 / 121–123 MiB | 377 / 121–124 MiB |
| `import Mathlib` | 5571 / 853 MiB | 5570 / 851–853 MiB | 5571–5573 / 853–854 MiB |
| MayerVietoris copy | 1804 / 948 MiB | 1801–1804 / 946–947 MiB | 1795–1798 / 950–951 MiB |
| Tilde copy | 1609 / 625 MiB | 1597–1601 / 609–618 MiB | 1603–1612 / 614–616 MiB |

The build's numbers are within the run-to-run spread of `time -l`, at
most 1% apart for the resident set and 3% for the footprint (the Tilde
copy, whose parallel proofs vary from run to run).

## Cost

[batteries-overhead.json](build-memory/batteries-overhead.json), two
rounds on Batteries, each a clean build:

- the wrapper itself: 1.4 MiB resident, one per running `lean`;
- leanprof during the build: 45 MiB at most;
- wall time: plain `lake build` 14.7 and 15.1 s; with the wrapper, 15.3
  and 16.2 s without sampling, 15.8 and 14.8 s with it (within the noise
  of a shared machine);
- the imports measured apart: 34.1 and 26.9 s for the whole command, so
  12 to 18 s on top of the build (one more `lean` per module, 9 at a
  time).

The `lean` processes are not changed, so the wrapper adds nothing to their
memory; what it adds to the machine is the 1.4 MiB per process and
leanprof's 45 MiB.

## What it does not do

- It measures only the `lean` processes Lake runs: modules up to date, or
  restored from a cache, are not measured, and neither is the C compiler.
- The jobs bound assumes any modules can run together. Dependencies keep
  some apart, so it can be lower than needed; the estimate is not a bound.
- On Linux the private peak is sampled every 20 ms (`RssAnon`), not exact.
- Per command, only a serial run is attributed, and it says where memory
  was reached, not who owns it.
