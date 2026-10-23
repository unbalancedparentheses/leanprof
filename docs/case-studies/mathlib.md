# Case study: compile time of Mathlib's slowest files

[Mathlib](https://github.com/leanprover-community/mathlib4) at tag
`v4.35.0` (Lean 4.35.0), 8,555 files, built from the community cache
(`lake exe cache get`), on an Apple M5 Max (18 cores) shared with other
jobs. leanprof's CLI from another checkout:

```
git clone --depth 1 --branch v4.35.0 https://github.com/leanprover-community/mathlib4
cd mathlib4 && lake exe cache get
leanprof elab --heartbeats --module-glob 'Mathlib.AlgebraicGeometry.Modules.Tilde,...' --jobs 3
leanprof elab --heartbeats --counts --module-glob '...' --jobs 3
leanprof elab --heartbeats Mathlib/Analysis/Fourier/FourierTransform.lean    # before and after a change
leanprof compare before.json after.json
```

Two candidate patches came out of it, saving 244 M and 412 M heartbeats
(55% and 69% of their files, wall time 3× faster); they are in
[docs/upstream/mathlib](../upstream/mathlib/README.md), not sent upstream.
Seven problems in leanprof showed up on the way and are fixed (below).

## Choosing the files

Profiling all of Mathlib at once was not needed: [Radar](https://radar.lean-lang.org/repos/mathlib4)
measures every file's build in CPU instructions, and
[lean-source-profiler](https://github.com/Vilin97/lean-source-profiler)
publishes a snapshot of it at commit `726a7f1e` (4.35.0-rc3, a few weeks
before `v4.35.0`). Its 20 most expensive files all exist at `v4.35.0` and
were profiled with `--heartbeats`, 3 at a time: 17.5 minutes, up to 3.2 GB per
`lean` process at most, 430 MB for leanprof itself.

## The slowest files

Heartbeats (exact), by part; Radar's instructions for comparison:

| heartbeats | elab | kernel | lint | Radar instr. | file |
|---|---|---|---|---|---|
| 879 M | 762 M | 105 M | 11 M | 3.2e11 | `AlgebraicGeometry/Modules/Tilde` |
| 753 M* | 689 M | 53 M | 8 M | 2.6e11 | `AlgebraicGeometry/Modules/Sheaf` |
| 580 M | 544 M | 18 M | 15 M | 1.7e11 | `Analysis/Distribution/ContDiffMapSupportedIn` |
| 572 M | 495 M | 62 M | 14 M | 2.0e11 | `Analysis/InnerProductSpace/Adjoint` |
| 526 M | 513 M | 5 M | 8 M | 1.7e11 | `Analysis/Fourier/FourierTransform` |
| 517 M | 485 M | 20 M | 12 M | 1.7e11 | `Analysis/Fourier/FourierTransformDeriv` |
| 513 M | 461 M | 40 M | 9 M | 1.8e11 | `RingTheory/Polynomial/UniversalFactorizationRing` |
| 511 M | 447 M | 46 M | 18 M | 2.2e11 | `AlgebraicGeometry/AffineTransitionLimit` |
| 477 M | 454 M | 13 M | 9 M | 1.5e11 | `RingTheory/ZariskisMainTheorem` |
| 471 M | 436 M | 13 M | 15 M | 1.4e11 | `MeasureTheory/VectorMeasure/Integral` |
| 465 M | 425 M | 18 M | 19 M | 1.6e11 | `Analysis/Distribution/SchwartzSpace/Basic` |
| 447 M | 399 M | 39 M | 9 M | 1.4e11 | `AlgebraicGeometry/Normalization` |
| 444 M | 358 M | 77 M | 9 M | 1.9e11 | `RingTheory/Etale/QuasiFinite` |
| 441 M | 407 M | 8 M | 22 M | 1.5e11 | `AlgebraicGeometry/EllipticCurve/Projective/Formula` |
| 412 M | 153 M | 257 M | 2 M | 2.6e11 | `CategoryTheory/Sites/SheafCohomology/ExactSequences` |
| 394 M | 109 M | 284 M | 2 M | 2.5e11 | `CategoryTheory/Sites/SheafCohomology/MayerVietoris` |
| 303 M | 92 M | 208 M | 3 M | 1.7e11 | `AlgebraicGeometry/ProjectiveSpectrum/Functor` |
| 265 M | 42 M | 221 M | 2 M | 2.0e11 | `CategoryTheory/Sites/SheafCohomology/Basic` |
| 92 M | 81 M | 6 M | 3 M | 1.5e11 | `CategoryTheory/Monoidal/Internal/FunctorCategory` |
| 84 M | 71 M | 5 M | 5 M | 1.7e11 | `CategoryTheory/LocallyCartesianClosed/ChosenPullbacksAlong` |

\* stops at a heartbeat limit reached only when profiled (see below).

9.15 G heartbeats in all: `isDefEq` 37% (self), instance synthesis 18%, the
kernel 16%, tactic steps 8.5%. The ranks differ from Radar's: instructions
include loading imports and writing `.olean` files, and work that does not
allocate; the last two files cost little to elaborate. The three
`SheafCohomology` files and `ProjectiveSpectrum/Functor` spend 54–84% in
the kernel.

## Findings

**1. A polynomial definition costing 150 M heartbeats** (patch
[0001](../upstream/mathlib/0001-elliptic-projective-formula-nat-exponents.md)).
`negDblY` and `dblX` in `EllipticCurve/Projective/Formula.lean` are among
the costliest declarations of all 20 files, and they are *definitions*: a
polynomial written out. Nothing in them is over the 10,000-heartbeat
threshold; a `set_option trace.profiler.threshold 0 in` on one showed
`instHPow` tried 11,309 times for about 60 powers. Numeral exponents get
their type from a default instance, and while they are pending each round
retries all of them. Writing `^ (2 : ℕ)` in the eight definitions:
441.0 M → 197.0 M heartbeats for the file, 8.2 s → 2.6 s.

**2. `Lp` binders whose measure is still unknown** (patch
[0002](../upstream/mathlib/0002-fourier-lp-explicit-volume.md)). In
`Fourier/FourierTransform.lean`, eight one-line lemmas (`rfl` proofs)
cost 37–63 M heartbeats each. The definitions behind the work were
`MeasureTheory.AEEqFun` (360 M, from 8 declarations), `AEStronglyMeasurable`
and `Measure.aeEqSetoid`, and the repeated work
`↥(Lp E 1 ?m) =?= ↥(Lp E 1 volume)` (68 times, 131 M). In `(f : Lp (α :=
V) E 1)` the measure is an auto-parameter (`by volume_tac`) that runs only
at the end of the statement, so every coercion before that tries to unify a
metavariable with `volume`, unfolding the `Lp` quotient. Writing `Lp E 1
(volume : Measure V)`, and `MemLp f 1 volume`: 526.4 M → 164.3 M in that
file, 107.8 M → 57.9 M in `Fourier/LpSpace.lean`; 10 s → 3.5 s and 3.6 s →
2.1 s.

**3. A quarter of the cost is under `respectTransparency false`.** 252 of
the 3,149 declarations are wrapped in `set_option
backward.isDefEq.respectTransparency false in` (or its `.types` variant),
the migration switch for Lean's stricter unfolding; they take 2.34 G of the
9.15 G heartbeats (25.6%), up to 560 M of `Modules/Tilde`'s 879 M. 1,470
Mathlib files use it. Removing it from one costly declaration
(`Normalization.lean`'s `toNormalization_app_preimage`, 107 M) breaks it
(`failed to synthesize`), so these need proofs rewritten one at a time; the
table says where that pays most.

**4. The same type elaborated hundreds of times.** In the repeated-work
table across files: elaborating the type `E →L[ℝ] F →L[ℝ] G` 537 times
(193 M, `VectorMeasure/Integral.lean`), with `Module ℝ (F →L[ℝ] G)`
synthesized 176 times (67 M); `SMulCommClass ℝ 𝕜 F` 234 times (82 M) and
`SMul ℝ F` 268 times (73 M) in `ContDiffMapSupportedIn.lean`. These are
section `variable`s, elaborated again for every declaration that uses
them; a cheaper instance path for the continuous-linear-map module
structure would pay in every such file. Not tried.

**5. Coercing a bundled map whose type is still unknown.** In
`InnerProductSpace/Adjoint.lean`, `A†` (`ContinuousLinearMap.adjoint A`)
searches `CoeFun ((?E →L[?𝕜] ?F) ≃ₗᵢ⋆[?𝕜] ?F →L[?𝕜] ?E)` before `A` fixes
the types: 74 searches, 70 M heartbeats, plus 16 M unifying with the
`LinearIsometryEquiv` instance. A notation that applies the coercion after
the argument is known would avoid it; not tried, since it changes how `A†`
is printed.

**6. Category-theory automation and `rfl`.** `cat_disch` runs 141 times for
367 M heartbeats in these files; `AlgebraicGeometry/Modules/Sheaf.lean:591`
is an `rfl` that runs 11 times for 119 M; the costliest tactic line overall
is a `let`/`have` block in `ZariskisMainTheorem.lean:147` (120 M, unfolding
`Ring.toSemiring` 2,078 times and `Subsemiring.toSemiring` 462 times).

**7. The kernel.** `--counts` on `ProjectiveSpectrum/Functor`,
`SheafCohomology/Basic` and `Adjoint` (45 s for the three, 3 at a time):
the kernel unfolded `Membership.mem` 957,469 times, `DFunLike.coe`
846,168, `CategoryTheory.Functor.obj` 548,653, and in `Functor.lean`
`HomogeneousLocalization.NumDenSameDeg.den` 195,815 times. `awayι_comp_map`
(`Functor.lean:189`) is 123 M heartbeats of kernel checking and none of
elaboration: the proof term `simp` builds is cheap to make and expensive to
check.

**A negative result.** In `SchwartzSpace/Basic.lean`'s `smulRightCLM`
(68 M), the report charged 16 M to the simp lemma `map_zero`. Replacing
the three `simp` calls in its bound by the `simp only` sets `simp?` gives
saved 2.5 M (3.7%): a simp lemma's cost is the unification just before it,
which the rewrite does not remove. Not kept.

## Problems in leanprof, fixed

- **Modules from the cache had no setup.** `elab` elaborates a module with
  the setup file Lake writes when it builds it; a module fetched by `lake
  exe cache get` was never built locally and has none. Lean then ran
  without Mathlib's `leanOptions` (`maxSynthPendingDepth 3`, its linters),
  and 8 of the 20 files failed (21 errors in one). `elab` now asks `lake
  setup-file` (about 2 s per file).
- **`variable … in` and `set_option … in` counted twice.** Lean traces the
  inner command at its own position and then the wrapper, over a range that
  contains it, including its cost. Only commands at one position were
  matched. 2.70 G of the first report's 11.85 G heartbeats were double
  counted; a declaration under three `set_option … in`
  (`Normalization.lean:594`) appeared four times at 82 M each. Now a
  command counts only what it adds to the commands inside its range.
- **Errors said only "files had errors".** Now the first error of each file
  is printed with its line, and a heartbeat limit gets a note.
- **A failing file was elaborated twice**, again without its setup, even
  when the error was in a proof. Now only for errors in the header.
- **Declarations named after the wrong command.** `variable (W') in` puts
  its inner `section` where the declaration starts, and a doc comment
  longer than the text leanprof keeps left the name empty: `negAddY`,
  `addX`, `addZ` were reported as `variable (W')`, and `compare` matched
  them by line. They are named from the source now.
- **`compare` on compile-time reports** printed new and removed scopes'
  heartbeats as milliseconds, thousands of lines in no order, and `calls 0
  -> 0` everywhere. It now sorts by the size of the change, uses kHB, ends
  with the total, and matches commands that declare nothing by their text
  and order in the file, so moving lines does not make them new and gone.

## Limits

- **Profiling `Modules/Sheaf.lean` is slow and changes its result.** Plain
  `lean` builds it in 24 s; with `trace.profiler` it takes about 10
  minutes, and `pseudofunctor` (line 313) stops at `maxHeartbeats`
  (200,000 kHB), which it does not reach when built. A sampled profile of
  the profiled run (samply, 623,407 samples) puts 94% of the time in
  `Message.toJson` → `MessageData.format` → the delaborator: Lean printing
  the large category-theory terms of the traced operations after
  elaboration (`pp.maxSteps=100`, `pp.deepTerms=false` brought it only to
  9.4 minutes). This is Lean's trace output rather than leanprof's reading
  of it; Lean's `trace.profiler.output` (a Firefox profile without printed
  terms) would avoid it, at the cost of the descriptions `elab` reads.
- Heartbeats from `trace.profiler` include the trace's own allocations, so
  absolute numbers are somewhat above the build's; comparisons made the same
  way are exact (two runs of the 20 files differ by 1,270 heartbeats in 9.1
  billion).
