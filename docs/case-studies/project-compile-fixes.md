# Case study: project-wide compile-time changes on Batteries and Mathlib

`leanprof fix --elab --project` reads a project profile with exact counts
(`elab --project --heartbeats --counts --why`), lists changes that act
across files with their evidence, and checks each one with `leanprof
experiment` against the same base: the build, the proof-preservation guard
and the heartbeats of the changed module and every module importing it,
then a timed plain `lake build` of those modules
([guide](../guide/compile-time.md#project-wide-changes-fix---elab---project)).
This is what it found on [Batteries](https://github.com/leanprover-community/batteries)
and on [Mathlib](https://github.com/leanprover-community/mathlib4)'s
elliptic curve modules, both at tag `v4.35.0` (Lean 4.35.0), on an Apple M5
Max shared with other agents' jobs (2026-10-28). Heartbeats do not depend
on the load; the build times do, and each comes with the 1-minute load
average before and after.

The result files are in [`project-fixes/`](project-fixes/): the output of
each run (`*.txt`) and its evidence (`*.json`, schema
[`fix-project`](../../schemas/fix-project.schema.json)), and the hypotheses
as the current version lists them (`*-hypotheses.json`). Kept changes stay
on local branches in `~/projects/leanprof-wt/project-fixes/`; nothing was
sent upstream.

## Batteries

```
leanprof elab --project --heartbeats --counts --why --jobs 6
leanprof fix --elab --project --report project.json --only 2,15,16,17,23,42 \
  --build-runs 3 --lock ~/.leanprof-bench.lock
```

The profile gives 41 hypotheses ([`batteries-hypotheses.json`](project-fixes/batteries-hypotheses.json)):
18 definitions to make irreducible, 3 simp lemmas tried often and rarely
used, Lean's inferred termination measures for 27 declarations in 15
files, and 19 instance problems solved again and again (not tried: a
shortcut instance needs a person to choose where it goes). No instance of
Batteries was tried often enough in two files to suggest a lower priority.
Six were checked, each against the same base
([`batteries.json`](project-fixes/batteries.json),
[`batteries.txt`](project-fixes/batteries.txt)):

| candidate | evidence | verdict | what happened |
|---|---|---|---|
| state the 27 inferred termination measures | `decreasing_tactic` ran 193× in 25 files | KEEP | 61 modules: 751,103 → 655,223 kHB (−12.8%), 24 declarations cheaper, none dearer; plain build 8.35–9.59 s → 8.01–8.34 s |
| `SatisfiesM` irreducible | unfolded 635× (elaborator) and 66× (kernel) in 4 files | DISCARD | does not build: `Batteries/Recycling/MonadSatisfying/List.lean:27:8: Invalid ⟨...⟩ notation: The expected type SatisfiesM motive (f b hd) is not an inductive type` |
| `MLList` irreducible | unfolded 311× (elaborator) in 4 files | DISCARD | builds; 11 modules: 13,271.54 → 13,269.37 kHB, nothing beyond noise |
| `Ordering.byKey` irreducible | unfolded 97× (elaborator) and 18× (kernel) in 4 files | DISCARD | does not build: a type mismatch in `Batteries/Recycling/RBTree/WF.lean:587` |
| `Std.LawfulOrd` irreducible | unfolded 33× and 6× in 3 files | DISCARD | Lean refuses: it is an `abbrev`. leanprof now lists such a candidate as a hypothesis only |
| `@[simp]` off `SatisfiesM_Except_eq` | tried 19×, used 0× | DISCARD | 20 modules: 38,144.45 → 38,107.95 kHB (−0.1%) |

The kept change is the one `fix --elab` already makes per file, applied to
the whole package at once. Its heartbeats went down in 11 of the 61
modules and stayed within noise in the others; the three costliest
declarations went from 17,424 to 6,155 kHB (`firstDiffPos_loop_eq`), 16,274
to 5,954 (`splitAux_of_valid`) and 15,839 to 5,864 (`zoom_del`). The plain
`lake build` of the 61 modules (their outputs removed, base and candidate
alternating, 3 builds each, under the shared timing lock) took 8.01 to
8.34 s against 8.35 to 9.59 s, at a load of 13 to 23: every candidate build
was faster, by a margin that small that it says little on a shared machine.
Branch `leanprof-fix/project-termination-2`.

Each discarded `irreducible` shows what the counts cannot: a definition
unfolded in many files may be unfolded because proofs need it to be. The
evidence ranks where to look; the build decides.

An earlier run of the same six (kept in the log, not in the table) timed
the builds including the wait for the timing lock: one base build took 152
s. The wrapper now starts the clock once it holds the lock.

## Mathlib: elliptic curves

```
leanprof elab --project --heartbeats --counts --why --jobs 4 \
  --module-glob 'Mathlib.AlgebraicGeometry.EllipticCurve.*'    # 19 files
leanprof fix --elab --project --report ec-project.json --no-test \
  --build-runs 3 --lock ~/.leanprof-bench.lock --only ...
```

Mathlib's build came from `lake exe cache get`; nothing was
built from source except the modules each candidate changes and the ones
that import them (the 19 elliptic curve modules have one importer outside
the directory, `Mathlib/NumberTheory/Height/EllipticCurve.lean`, plus
`Mathlib.lean`). `--no-test`: Mathlib's test driver is its whole test
suite; the proofs are checked by rebuilding every module that imports the
change.

The heaviest hypotheses are the types of points: `WeierstrassCurve.Affine`
(unfolded 13,471× by the elaborator in 12 files),
`WeierstrassCurve.Affine.CoordinateRing` (17,037× in 2 files),
`WeierstrassCurve.Projective` (10,184× in 3 files) and `WeierstrassCurve.Jacobian` (8,660× in 3 files). All four are
`abbrev`s, which Lean does not make irreducible, so they stay hypotheses
([`mathlib-ellipticcurve-hypotheses.json`](project-fixes/mathlib-ellipticcurve-hypotheses.json)).
`diagnostics` names them relative to the namespace open where they were
used (`Affine`, `CoordinateRing`); the first version of this command left
such names out, and found nothing to try on Mathlib. Five of the
mechanical ones were checked ([`mathlib-ellipticcurve.json`](project-fixes/mathlib-ellipticcurve.json),
[`mathlib-ellipticcurve.txt`](project-fixes/mathlib-ellipticcurve.txt)):

| candidate | evidence | modules | heartbeats (kHB) | declarations | verdict |
|---|---|---:|---|---|---|
| `WeierstrassCurve.b₆` irreducible | unfolded 17× and 15× (kernel) in 6 files | 21 | 1,903,612.98 → 1,903,647.99 | 10 cheaper, 8 dearer | DISCARD |
| `WeierstrassCurve.Δ` irreducible | unfolded 12× and 9× in 4 files | 21 | 1,903,612.98 → 1,903,639.89 | 12 cheaper, 10 dearer | DISCARD |
| `WeierstrassCurve.preΨ` irreducible | unfolded 45× and 26× in 2 files | 3 | 119,970.00 → 119,974.45 | 3 cheaper, 3 dearer | DISCARD |
| `@[simp]` off `WeierstrassCurve.a₄_of_isCharTwoJNeZeroNF` | tried 28×, used 2× | 3 | 95,949.76 → 95,867.89 | 4 cheaper, 3 dearer | DISCARD |
| `WeierstrassCurve.Affine.linePolynomial` irreducible | unfolded 7× and 7× in 2 files | 12 | 1,397,976.69 → 1,397,901.97 | 8 cheaper, 9 dearer | DISCARD |

Every one built: Mathlib's proofs about these definitions go through their
equations (`simp [b₆]`, `rw`), not through unfolding by unification, so
making them irreducible broke nothing, and saved nothing either. No total
moved by more than 0.09%. The plain builds were within noise each time
(the 3-module builds alternated between about 7 and 12 s on both sides).

Some declarations that "got dearer" are not declarations: a command that
declares nothing is matched by its text and its place among the commands
with that text, so the `attribute [irreducible] ...` line added before
`end WeierstrassCurve` takes over the place of that `end`, and 16 kHB move
from one to the other.

## What it took in leanprof

Besides the command itself, these runs needed:

- `elab.json` lists, for each constant, the files and lines it was reached
  from (`site_files`, `site_keys`) and, for each repeated operation, its
  files (`by_file`);
- a name `diagnostics` prints relative to a namespace is matched to a
  declaration only when one declaration of the profiled files ends so, and
  `elab.json` says so (`located_by_suffix`, `declared_as`); the match is
  not trusted when that declaration is `protected` (Batteries'
  `SatisfiesM.pure` is not `Pure.pure`);
- `experiment try --keep-base`, so that several candidates are each judged
  against the same base.

## Limits

- A hypothesis is ranked by the files the work was seen in, then by its
  exact count. Neither is a cost; the costs the report charges overlap and
  are shown only as evidence.
- Only the changes listed are made. An unfold lemma, a shortcut instance or
  a rewritten `decreasing_by` proof is left to a person.
- The heartbeats are those of a full profile (`elab --heartbeats`), which
  counts more than the build does; the plain build times are the build's,
  but on a shared machine they settle only large changes.
