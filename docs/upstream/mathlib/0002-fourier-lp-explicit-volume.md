# 0002: give the measure of `Lp` binders in the Fourier files

Patch: [0002-fourier-lp-explicit-volume.patch](0002-fourier-lp-explicit-volume.patch)
Files: `Mathlib/Analysis/Fourier/FourierTransform.lean`,
`Mathlib/Analysis/Fourier/LpSpace.lean`

## Finding

In `FourierTransform.lean`, eight one-line lemmas cost 37 to 63 M heartbeats
each, most of them proved by `rfl`:

```
62570.95 kHB  fourierTransformInvCLM_apply   (f : Lp (α := V) E 1) : ... := by simp [...]
62389.64 kHB  fourierTransformCLM_apply      (f : Lp (α := V) E 1) : ... := rfl
45194.11 kHB  fourierTransform_apply         (f : Lp (α := V) E 1) (x : V) : ... := rfl
37512.32 kHB  coe_fourierTransform           (f : Lp (α := V) E 1) : ... := rfl
...
```

The definitions behind the cost were `MeasureTheory.AEEqFun` (unfolded from 8
declarations, 360 M heartbeats), `AEStronglyMeasurable`,
`Filter.EventuallyEq`, `MeasureTheory.ae` and `Measure.aeEqSetoid`: the
quotient `Lp` is built on. The repeated work named the operation:

```
131235.48 kHB  68×  [Meta.isDefEq] ↥(Lp E 1 ?m) =?= ↥(Lp E 1 volume)
131156.81 kHB 136×  [Meta.isDefEq.delta] Quotient (aeEqSetoid E ?m) =?= Quotient (aeEqSetoid E volume)
```

and the trace of `fourierTransformCLM_apply` shows the statement (not the
proof) taking 38.5 M of its 62 M: `f : ↥(Lp E 1 ?m.21)`, then about twenty
failed unifications `V →ₘ[?m.21] E =?= V →ₘ[volume] E` of 1.9 M heartbeats
each. `Lp`'s measure is an auto-parameter (`(μ : Measure α := by
volume_tac)`); in the binder `(f : Lp (α := V) E 1)` it stays a metavariable
until the tactic runs at the end of the statement, so every coercion and
application in the statement first tries to unify `?m.21` with `volume`
(which it may not assign yet), unfolding the whole `Lp` quotient each time.
`(hf : MemLp f 1)` has the same auto-parameter and the same cost in the two
`_toLp` lemmas.

## Patch

Write the measure: `Lp (α := V) E 1` becomes `Lp E 1 (volume : Measure V)`
(10 places in `FourierTransform.lean`, 31 in `LpSpace.lean`), and
`(hf : MemLp f 1)` becomes `(hf : MemLp f 1 volume)` (2 places). The
elaborated statements are the same (`volume_tac` produced `volume`).

## Measurements

`FourierTransform.lean`:

```
faster  fourierTransformInvCLM_apply: 62570.95 kHB -> 752.28 kHB (-98.80%)
faster  fourierTransformCLM_apply:    62389.64 kHB -> 572.62 kHB (-99.08%)
faster  fourierTransform_apply:       45194.11 kHB -> 529.06 kHB (-98.83%)
faster  fourierTransformInv_apply:    45625.63 kHB -> 971.76 kHB (-97.87%)
faster  fourierTransform_toLp:        37845.77 kHB -> 708.43 kHB (-98.13%)
faster  fourierTransformInv_toLp:     37871.62 kHB -> 734.52 kHB (-98.06%)
faster  coe_fourierTransform:         37512.32 kHB -> 586.55 kHB (-98.44%)
faster  coe_fourierTransformInv:      37524.96 kHB -> 613.46 kHB (-98.37%)
total: 526442.63 kHB -> 164274.26 kHB (-68.80%)
```

`LpSpace.lean`:

```
faster  fourier_toTemperedDistribution_eq:    33804.11 kHB -> 13412.04 kHB (-60.32%)
faster  inner_fourier_eq:                     16651.43 kHB -> 839.35 kHB (-94.96%)
faster  fourierInv_toTemperedDistribution_eq: 11978.90 kHB -> 3744.49 kHB (-68.74%)
faster  instFourierSMul:                       4986.21 kHB -> 3237.53 kHB (-35.07%)
total: 107829.28 kHB -> 57865.24 kHB (-46.34%)
```

(Measured with plain `lean`, `--no-driver`; with leanprof's elaboration driver
the totals are 526,525.61 → 164,357.45 kHB and 107,851.04 → 57,887.61 kHB.)
Together 412 M heartbeats. Wall time of plain `lean`: `FourierTransform.lean`
11.35, 10.37, 8.86 s before and 3.35, 3.40, 3.66 s after; `LpSpace.lean`
3.05, 3.79, 3.99 s before and 2.37, 1.98, 1.99 s after.

The only `compare` regression is a command without a name moving from
13.05 to 17.71 kHB.

## Risk

Low. The statements elaborate to the same terms, and the modules that import
`FourierTransform.lean` (`Fourier.ZMod`, `Fourier.RiemannLebesgueLemma`,
`Fourier.FourierTransformDeriv`, `Distribution.Sobolev`,
`SpecialFunctions.Gaussian.FourierTransform`,
`Measure.CharacteristicFunction.Basic`) build unchanged. `(α := V)` was
there to name the domain without the measure; `(volume : Measure V)` does
both, at the cost of a slightly longer binder.

The same auto-parameter is on `MemLp`, `Integrable`, `AEStronglyMeasurable`
and many other measure-theory predicates, so other files may pay the same
price where a statement elaborates with the measure still pending. Mathlib
has 32 `Lp (α := …)` binders, in this file, `Fourier/LpSpace.lean` (both
patched), `Probability/Kernel/Composition/IntegralCompProd.lean` and two
notations in `MeasureTheory/Function/LpSpace/Basic.lean`; the others were
not measured.
