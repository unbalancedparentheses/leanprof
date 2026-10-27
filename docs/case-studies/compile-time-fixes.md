# Case study: compile-time fixes on Batteries and Mathlib

`leanprof elab --why` names the causes of the costliest declarations,
`leanprof fix --elab` applies the edits Lean computes itself, and
`leanprof experiment` keeps an edit only if the proofs still check, the
proof-preservation guard passes and the heartbeats go down. This is what
they found on [Batteries](https://github.com/leanprover-community/batteries)
and [Mathlib](https://github.com/leanprover-community/mathlib4), both at
tag `v4.35.0` (Lean 4.35.0), on an Apple M5 Max shared with other jobs
(2026-10-26 and 27). Heartbeats are exact, so the load does not change
them; they are counted by full profiles (`elab --heartbeats`, which counts
more than the build itself does). Every edit stays on a local branch, kept
as bundles in `~/projects/leanprof-wt/dogfood-branches/`; nothing was sent
upstream.

## Batteries

```
leanprof elab --project --heartbeats --why --jobs 6     # 195 modules, 21 s
```

Of the 10 costliest declarations, 8 spend 68 to 90% of their heartbeats in
`decreasing_tactic`. There are two cases. A declaration with a
`termination_by` runs it once per recursive call (`Heap.WF.merge'`, 6
calls, 78% of 25.2 M heartbeats). One without runs it once per call and per
measure Lean tries (GuessLex) before it finds one that works
(`firstDiffPos_loop_eq`, `splitAux_of_valid`); `--why` reports the measure
Lean found:

```
  2. 17489.50 kHB  Batteries/Data/String/Lemmas.lean:351  theorem firstDiffPos_loop_eq ...
     termination
       observed   `decreasing_tactic` ran 6× for 13728.69 kHB (78%): with no `termination_by`, Lean
                  tries measures until one works, proving the recursive calls for each
       observed   the measure Lean found (`showInferredTerminationBy`): `termination_by r₁`
       suggested  state it after the proof: `termination_by r₁`; ... [mechanical]
```

Across the project, `--why` collected 1,717 `simp` suggestions: 943 can be
applied mechanically (their calls cost 71.5 M heartbeats in all, 5% of the
project's 1,428 M), 432 are already `only`, 187 ran on several goals with
different lemma lists, and 153 have no source range (a macro's call).

### `fix --elab` (mechanical)

```
leanprof fix --elab Batteries/Data/String/Lemmas.lean Batteries/Data/BinomialHeap/Basic.lean
```

took the 10 costliest edits (2 inferred measures, 8 `simp only` lists) and
judged them in one round: build ok, guard PASS on 9 modules (the two files
and everything in the package importing them, test modules included),
`lake test` passed, KEEP. Branch `leanprof-fix/elab-Lemmas`, 1 commit.

| declaration | before (kHB) | after (kHB) | edit |
|---|---:|---:|---|
| `firstDiffPos_loop_eq` | 17,424 | 6,158 | `termination_by r₁` |
| `splitAux_of_valid` | 16,274 | 5,960 | `termination_by r` |
| `next` | 1,487 | 1,460 | `simp only` |
| `HeapNode.realSize_toHeap` | 382 | 345 | `simp only` |
| 9 modules in all | 129,827 | 108,128 | −16.7% |

The other six `simp only` lists changed their declarations by less than 1%.

### A hypothesis checked by hand

For `Heap.WF.merge'`, `--why` could only suggest (a hypothesis):
"`decreasing_by` with a direct proof". The goals the default tactic faces
(`decreasing_by all_goals trace_state; all_goals sorry` shows them) carry
the equations `s₁ = cons ...` from `split`, so this proof works:

```lean
termination_by s₁.length + s₂.length
decreasing_by all_goals subst_vars; simp only [Heap.length]; omega
```

With the two measures above, as `leanprof experiment try --working-tree`
(branch `leanprof-speedups`): build ok, guard PASS (9 modules, 490
theorems), `lake test` passed, KEEP.

| declaration | before (kHB) | after (kHB) |
|---|---:|---:|
| `Heap.WF.merge'` | 25,174 | 8,314 |
| `firstDiffPos_loop_eq` | 17,424 | 6,155 |
| `splitAux_of_valid` | 16,274 | 5,954 |
| 9 modules in all | 129,827 | 91,378 (−29.6%) |

### What it took in leanprof

The first tries on Batteries were INCONCLUSIVE for reasons in leanprof,
now fixed: the proof-preservation auditor refused a project with a
symbolic link (`docs/README.md`; links other than Lean sources are now
recorded by their target), and could not import two test modules that both
declare `foo` (they are now imported one at a time, and a crash from
freeing their environments early was fixed on the way).

## Mathlib

Six of the slowest files of the [earlier study](mathlib.md) with few
dependents (a try profiles the changed modules and every module importing
them), `elab --heartbeats --why`, 3 at a time: 2,936 M heartbeats in all.

| file | M heartbeats |
|---|---:|
| `Analysis/Distribution/ContDiffMapSupportedIn` | 577 |
| `RingTheory/Polynomial/UniversalFactorizationRing` | 514 |
| `AlgebraicGeometry/AffineTransitionLimit` | 511 * |
| `AlgebraicGeometry/Normalization` | 448 * |
| `RingTheory/Etale/QuasiFinite` | 445 |
| `AlgebraicGeometry/EllipticCurve/Projective/Formula` | 442 |

\* stops at an error with `--why` only (`Unknown constant
term.pseudo.antiquot`, at one call each); the costs after it are missing.

What `--why` found there differs from Batteries. No declaration has an
inferred measure to state. 407 of 662 `simp` calls have a mechanical `simp
only` list, 455 M heartbeats in all, the costliest 36 M. The costliest
declarations are unification: `isDefEq` unfolding instance paths
(`Semiring.toAddCommMonoid` 2,084×, 24% of a lemma in `QuasiFinite`;
`AddSubmonoidClass.toAddCommMonoid`, 25%), `Localization` (11%), the kernel
(52% of `exists_etale_isIdempotentElem_forall_liesOver_...`), and two
`noncomputable def`s in `Projective/Formula` (152 and 91 M) where no single
cause stands out. Those are hypotheses for a person; the advice for
instance paths no longer suggests making them irreducible.

MATHLIB_FIX_RESULT
