# Candidate Mathlib patches

Compile-time fixes found with `leanprof elab --heartbeats` on Mathlib at tag
`v4.35.0` (Lean 4.35.0). They have not been sent upstream. How they were
found is in the [case study](../../case-studies/mathlib.md).

| patch | files | heartbeats before → after | wall time (plain `lean`, 3 runs) |
|---|---|---|---|
| [0001](0001-elliptic-projective-formula-nat-exponents.md) | `AlgebraicGeometry/EllipticCurve/Projective/Formula.lean` | 441.0 M → 197.0 M (−55.3%) | 8.2–8.5 s → 2.6–2.7 s |
| [0002](0002-fourier-lp-explicit-volume.md) | `Analysis/Fourier/FourierTransform.lean` | 526.4 M → 164.3 M (−68.8%) | 8.9–11.4 s → 3.4–3.7 s |
| | `Analysis/Fourier/LpSpace.lean` | 107.8 M → 57.9 M (−46.3%) | 3.1–4.0 s → 2.0–2.4 s |

Heartbeats are for the whole file, from `leanprof elab --heartbeats FILE`
before and after, compared with `leanprof compare`; they are exact (nearly the
same on every run). Wall times are plain `lean` runs with Lake's setup for
the module (imports included) on an Apple M5 Max shared with other jobs.

Both patches change only how statements are written, not what they say: the
elaborated terms are the same. With both applied, the three files and the
seven modules that import them directly
(`EllipticCurve.Projective.Point`, `Fourier.ZMod`,
`Fourier.RiemannLebesgueLemma`, `Fourier.FourierTransformDeriv`,
`Distribution.Sobolev`, `SpecialFunctions.Gaussian.FourierTransform`,
`Measure.CharacteristicFunction.Basic`) build (`lake build`, 13 modules
rebuilt, no errors).

To apply one in a Mathlib checkout at `v4.35.0`:

```
git apply /path/to/leanprof/docs/upstream/mathlib/0001-elliptic-projective-formula-nat-exponents.patch
```
