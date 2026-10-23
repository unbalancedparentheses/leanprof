# 0001: numeral exponents in the projective addition formulae

Patch: [0001-elliptic-projective-formula-nat-exponents.patch](0001-elliptic-projective-formula-nat-exponents.patch)
File: `Mathlib/AlgebraicGeometry/EllipticCurve/Projective/Formula.lean`

## Finding

Two *definitions* are among the costliest declarations of the 20 slowest
Mathlib files:

```
150409.00 kHB  Formula.lean:310  noncomputable def negDblY (P : Fin 3 → R) : R :=
 90301.95 kHB  Formula.lean:239  noncomputable def dblX (P : Fin 3 → R) : R :=
```

Each is a polynomial in `W'.a₁ … W'.a₆` and `P x`, `P y`, `P z`, written out
(`negDblY` has 29 lines of terms). `negDblY` alone is 75% of the default
`maxHeartbeats` (200,000 kHB) and a third of the file.

Nothing under them is over the 10,000-heartbeat threshold, so the cost is in
many small operations. Profiling `dblX` with `set_option
trace.profiler.threshold 0 in` showed where: the instance `instHPow` is
tried 11,309 times (34 M heartbeats), `Monoid.Pow` 11,395 times, for about
60 `^` in the definition. Each `x ^ 2` has a numeral exponent whose type is
only fixed by a default instance (`Monoid.npow`'s `ℕ`), and while it is
pending every other pending power is retried: the cost grows with the square
of the number of powers in one term.

## Patch

In the bodies of the eight definitions with powers (`dblU`, `dblZ`, `dblX`,
`negDblY`, `addU`, `addZ`, `addX`, `negAddY`), write numeral exponents with
their type, `P y ^ (3 : ℕ)` instead of `P y ^ 3` (70 exponents). The terms are
the same (`Monoid.npow` with a natural number literal). Lemma statements are
left alone: converting them as well saves another 9 M heartbeats (188.1 M
instead of 197.0 M) at the cost of 80 more edits.

A file-local `macro_rules | `($x ^ $n:num) => `(HPow.hPow $x ($n : ℕ))`
would be a smaller diff, but the file is a `module` and the quotation does
not parse there without more imports; it was not pursued.

## Measurements

`leanprof compare` (before → after, whole file; `leanprof elab --heartbeats`
with its elaboration driver, which counts a `variable (W') in` wrapper with the
declaration inside it):

```
faster  negDblY:  151367.86 kHB -> 4627.54 kHB (-96.94%)
faster  dblX:      91082.12 kHB -> 3722.30 kHB (-95.91%)
faster  negAddY:    5560.78 kHB -> 1837.22 kHB (-66.96%)
faster  addZ:       4570.49 kHB -> 1234.97 kHB (-72.98%)
faster  addX:       4430.91 kHB -> 1651.93 kHB (-62.72%)
faster  dblU:        231.65 kHB -> 194.71 kHB (-15.95%)
total: 441135.90 kHB -> 197145.96 kHB (-55.31%)
no regressions
```

Without the driver (`--no-driver`, plain `lean`) the totals are 441,015.88
→ 197,019.80 kHB, the same saving.

Wall time of plain `lean` on the file: 8.15, 8.15, 8.54 s before; 2.64, 2.70,
2.56 s after.

## Risk

Low. The elaborated definitions are the same terms; the lemmas about them
(`dblX_eq`, `negDblY_eq'`, the `map_*` and `baseChange_*` lemmas) still
elaborate unchanged, and `EllipticCurve.Projective.Point`, which imports
the file, builds. The cost is readability: `^ (2 : ℕ)` is noisier than `^ 2`,
and a reviewer may prefer fixing the elaborator (the quadratic retry of
pending default instances) to editing the formulae. Other long polynomial
definitions (the Jacobian-coordinate formulae in
`EllipticCurve/Jacobian/Formula.lean`) are likely to have the same cost and
were not measured.
