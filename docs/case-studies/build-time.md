# Case study: build time of Batteries, leanprof and a Mathlib project

`leanprof build --clean --validate K --imports 3` on three projects, on an
Apple M5 Max (18 cores, 128 GB) shared with other jobs: the load average is
in every report, and was between 10 and 23 during these runs. Each run held
the benchmark lock, so no other timing run overlapped it. The reports are
in [build-time/](build-time/) (`.json`, the text report `.txt`, and the
timeline page `.html`); every number below comes from them.

| project | modules | clean `lake build` | critical path | jobs at once (mean, peak) | report |
|---|---|---|---|---|---|
| [Batteries](https://github.com/leanprover-community/batteries) `v4.35.0` | 195 (+ `runLinter`) | 15.5 s | 12 jobs, 11.5 s of work | 10.9, 18 | [batteries](build-time/batteries.txt) |
| leanprof (`lake build leanprof`, this branch) | 23 | 25.4 s | 9 jobs, 20.8 s | 3.2, 9 | [leanprof](build-time/leanprof.txt) |
| lean-extremevaluetheory (Mathlib `v4.35.0` from the cache) | 225 (+ 9,035 Mathlib and other modules up to date) | 205.1 s | 23 jobs, 189.1 s | 8.0, 18 | [evt](build-time/evt.txt) |

All three on Lean 4.35.0. The tool itself was also checked end to end on
Lean 4.27.0 (`scripts/build-check.sh leanprover/lean4:v4.27.0`).

## What the timelines show

**lean-extremevaluetheory is a chain.** 189.1 s of its 205.1 s build is
one chain of 23 modules, each importing the one before
(`OrderContinuity`, `PseudoInverses`, `TransformedCDF`, … `GPDJointNormalityNeg`,
`GPDMLENormality`, `ReturnLevelNormality`, `ConfidenceIntervals`). With
unlimited cores the build would still take 189.1 s, so a faster machine with
more cores would not help; shortening that chain, or splitting a module on
it so that its importers can start earlier, would. The chain's first module did not
start until 12.0 s into the build, 10 s after the first modules started:
Lake ran others first. The last 12.8 s ran one job at a time. Each `lean`
process reached a peak of 3.0 GB resident at the median and 6.3 GB at most
(`Statistics.GPDJointNormalityNeg`).

**Batteries is wide, with a short chain.** 18 jobs ran at once for 4.6 s
of its 15.5 s, and at most one ran for 1.1 s. The critical path, 12 modules
from `Tactic.Lint.Basic` to `Batteries`, went through `Classes.Order`
because `Classes.Order` imports `Tactic.Basic`; its second module,
`Tactic.Lint.Misc`, waited 2.5 s for a worker.

**leanprof is two serial ends.** At most one job ran for 10.0 s of its
25.4 s build: the elaboration driver's link at the start, and at the end
`LeanprofCli` (the command), its C compile (4.8 s) and the
link. Splitting `LeanprofCli` would shorten the build's tail; the critical
path has 20.8 s of work.

## Rebuild estimates, checked

The estimate of the rebuild after touching a module is a no-op build plus a
simulation of the jobs it reruns, each with its time alone (its CPU time
when it waited for a core), sharing the cores
([build time](../guide/build-time.md#what-it-reports)). `--validate` touched
modules from the costliest estimate to the cheapest in a worktree and
rebuilt, twice each (touched, then put back):

| project | modules touched | mean error | largest | replaying the clean build's wall times instead | rebuilt modules as predicted |
|---|---|---|---|---|---|
| Batteries | 8 | 39.1% | 148.1% | 120.0% (largest 305.6%) | 7 of 8 |
| leanprof | 6 | 29.3% | 73.9% | 34.7% (largest 66.5%) | 5 of 6 |
| lean-extremevaluetheory | 6 | 22.9% | 49.8% | 26.8% (largest 54.9%) | 6 of 6 |

The largest rebuild checked, touching `OrderContinuity` in
lean-extremevaluetheory, reran 102 modules: estimated 175.4 s, measured
155.6 s and 169.2 s. On Batteries, touching `Tactic.Lint.Basic` reran 41:
estimated 10.9 s, measured 9.6 s twice.

The estimates are mostly too high, and the samples say why: the same jobs
take more CPU time in a clean build than in a rebuild. Touching
`CodeAction.Attr` in Batteries reran jobs that had taken 4.4 s of CPU in
the clean build and 3.1 s in the rebuild; in lean-extremevaluetheory,
`StableIntegral`'s 27 modules took 173.5 s of CPU in the clean build and
131.6 s in the rebuild (`clean_cpu_s` and `rebuild_cpu_s` in each sample).
With every core busy, a job is slower per unit of work (the M5 Max mixes
performance and efficiency cores, and the jobs share caches and memory
bandwidth), not only waiting for a core. Using wall times as measured is
worse: on Batteries, where the clean build kept 18 jobs running, that model
was 120% off on average.

Two predictions of which modules rebuild were wrong, both found by the
validation:

- leanprof's `LeanprofBuildShim`: Lake also rebuilt `LeanprofCli`, because
  the `leanprof` executable `needs` the shim's executable and Lake adds a
  target's `needs` to its modules' inputs. The model does not know `needs`
  (measured 4.4 s, estimated 1.1 s).
- Batteries' `Data.RBMap.Alter`: three modules were predicted, and only
  the module itself was rebuilt, not `Data.RBMap` and `Batteries`, which
  import it: Lake found their inputs unchanged. The estimate assumes an
  edit that changes what the module exports.

## Imports, tried

| project | imports of rebuilt modules | importer names a declaration of it | in a module that only re-exports | reached another way too | would break an importer | tried | build passed |
|---|---|---|---|---|---|---|---|
| Batteries | 377 | 112 | 240 | 11 | 0 | 3 | 1 |
| leanprof | 39 | 38 | 0 | 0 | 1 | 0 | 0 |
| lean-extremevaluetheory | 585 | 309 | 230 | 19 | 9 | 3 | 2 |

Most imports are needed: the module names a declaration of the imported
module, or it exists to re-export. Every change below was built in a git
worktree with the whole package (proofs included), with no more `sorry`
warnings than before; the rebuild times are measured, two builds each.

- **lean-extremevaluetheory, `Statistics.ExtremalIndexEstimators`**:
  importing `Statistics.HillDependent` instead of `Statistics.HillCluster`
  builds, and the rebuild after touching `HillCluster` went from 25.6 s
  (4 modules) to 10.9 s (2 modules).
- **lean-extremevaluetheory, `Minimality.ClassicalGeneralizedCLT`**:
  importing `StableLaws.GaussianDomain.Necessity` instead of
  `StableLaws.GaussianDomain` builds; the rebuild after touching
  `GaussianDomain` went from 17.0 s to 10.6 s.
- **Batteries, `Classes.Order`**: importing four modules
  (`Lean.Elab.Tactic.ElabTerm`, `Batteries.Linter`, `Batteries.Tactic.Init`,
  `Batteries.Util.ProofWanted`) instead of `Batteries.Tactic.Basic` builds;
  the rebuild after touching `Tactic.Basic` went from 2.62 s to 0.71 s, and
  the clean build was estimated 3.13 s shorter (the module is on the
  critical path). Measured with four clean builds each, alternated, the
  median went from 16.5 s to 15.5 s at load averages of 30 to 64
  ([batteries-order-clean-ab.json](build-time/batteries-order-clean-ab.json)):
  in the estimate's direction, smaller, and within the run-to-run spread.
  But the import is marked `-- shake: keep` in Batteries: it is there on
  purpose, for the modules that import `Classes.Order` outside Batteries,
  which a build of Batteries cannot see. leanprof now leaves imports
  marked that way out (this run predates it), and reports how many.

The failed tries show why the build is required: a module used an
extensionality lemma, an instance or a notation from the removed import
without naming a declaration (`No applicable extensionality theorem
found`, `failed to synthesize instance`, `unexpected identifier`).

## Reproducing

```
git clone --depth 1 --branch v4.35.0 https://github.com/leanprover-community/batteries
cd batteries && leanprof build --clean --validate 8 --imports 3 --html batteries.html
```

and in leanprof's checkout `leanprof build --clean --validate 6 --imports 3
leanprof`. The times depend on the machine and its load; the reports
record both.
