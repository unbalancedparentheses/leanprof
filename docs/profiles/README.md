# Published compile-time profiles

Profiles of real projects made with `leanprof elab --project --heartbeats`,
each as a page to browse ([`leanprof html`](../guide/html-report.md)) and as
the report itself (`elab.json.gz`, for `leanprof compare` or your own
scripts). The pages open on the project view: folders and modules, then a
module's declarations, then a declaration's terms and tactics by exact
source range, with the repeated work and the definitions behind the work at
each level. Heartbeats are Lean's own count of allocations during
elaboration: they do not depend on the machine or its load, so the numbers
repeat (see [compile time](../guide/compile-time.md#heartbeats-exact-compile-cost)).

| profile | page | report | what |
|---|---|---|---|
| Batteries `v4.35.0` | [batteries-v4.35.0](batteries-v4.35.0/index.html) (4.5 MiB) | [elab.json.gz](batteries-v4.35.0/elab.json.gz) (1.1 MiB) | all 195 modules: 1,424 M heartbeats, 6,269 declarations and commands with cost, 14,553 term and tactic ranges |
| Mathlib `v4.35.0`, 40 slowest modules | [mathlib-v4.35.0-slowest-40](mathlib-v4.35.0-slowest-40/index.html) (6.5 MiB) | [elab.json.gz](mathlib-v4.35.0-slowest-40/elab.json.gz) (3.2 MiB) | the 40 modules with the most CPU instructions in Radar ([list](mathlib-v4.35.0-slowest-40/modules.txt)): 16.1 G heartbeats, 7,234 declarations and commands, 20,000 ranges |

On the website the pages are at
`https://unbalancedparentheses.github.io/leanprof/docs/profiles/<name>/index.html`;
on GitHub, download the `.html` file and open it (it needs no network).

## How they were made

Both on an Apple M5 Max (18 cores, 128 GB), macOS 26.6.2, Lean 4.35.0 (elan
toolchain `leanprover/lean4:v4.35.0`), leanprof at commit `1be9563` (branch
`elab-viewer`; the pages were rendered by the commit that added this file),
with leanprof's in-process driver (`exact_ranges` is true in both reports).
The machine was shared: load average 5 to 18 during the runs; heartbeats do
not depend on it, the wall times below do.

**Batteries** (commit `66e469188fe07963e5cf666c7d4433f45b8131c5`):

```
git clone --depth 1 --branch v4.35.0 https://github.com/leanprover-community/batteries
cd batteries && lake build
leanprof elab --project --heartbeats --out bat.json          # 15 s, 9 modules at a time
python3 scripts/publish-profile.py --title "..." batteries bat.json docs/profiles/batteries-v4.35.0
```

The profile took 14.8 s of wall time (13.9 s elaborating, 0.7 s writing the
report); the largest process peaked at 760 MB (`time -l`). Three runs
on the same day gave 1,423,720,817, 1,423,719,967 and 1,423,718,856
heartbeats in all: they differ by at most 1,961 heartbeats, 1.4 in a
million.

**Mathlib** (commit `56a005855ea17e0b0958f73ec801ae140b0a1679`, from the
community cache):

```
git clone --depth 1 --branch v4.35.0 https://github.com/leanprover-community/mathlib4
cd mathlib4 && lake exe cache get
leanprof elab --project --no-build --heartbeats --jobs 4 \
  --module-glob "$(awk '{print $2}' modules.txt | sed 's|/|.|g; s|\.lean$||' | paste -sd, -)" --out ml.json
python3 scripts/publish-profile.py --ranges 5000 --keep 1500 --title "..." mathlib4 ml.json docs/profiles/mathlib-v4.35.0-slowest-40
```

The modules are the 40 with the most CPU instructions in
[Radar](https://radar.lean-lang.org/repos/mathlib4)'s measurement of Mathlib
commit `726a7f1e` (4.35.0-rc3), as lean-source-profiler publishes it
(`modules.txt`: instructions, file); all 40 exist at `v4.35.0`. The profile
took 8.5 minutes of wall time, 4 modules at a time; the largest elaborating
process peaked at 2.9 GB (sampled every 2 s; 3.5 GB maximum resident size
reported by `time -l`). `AlgebraicGeometry/Modules/Tilde.lean` took 215 s
and `Modules/Sheaf.lean` 321 s; every other module under 2 minutes.

`AlgebraicGeometry/Modules/Sheaf.lean` stops with an error: its costliest
command (line 309) reaches 200,068 kHB, just over the default
`maxHeartbeats` of 200,000 kHB, and Lean reports an error at line 322. As
the [Mathlib case study](../case-studies/mathlib.md#limits) found, profiling
costs heartbeats too, so this file fails only when profiled; its numbers stop
at the error.

## What was cut

- **The pages** keep the costliest term and tactic ranges (Batteries 6,000
  of 14,553; Mathlib 5,000 of 20,000) and, for Mathlib, the 1,500 costliest
  repeated operations (of 25,660) and definitions behind the work (of 5,776),
  and the operations and definitions inside the 1,500 costliest declarations
  (of 7,234; the others keep their totals and parts). Each page says so where
  it applies. Source lines are those around the positions the report names.
- **The reports** are whole, except each definition's `path` (where its file
  was on the machine that made the report; the editor reads it, nothing else
  does). `leanprof elab` itself keeps at most 20,000 ranges, the costliest,
  which is why Mathlib's report has exactly 20,000.
- Mathlib is 40 of its 8,555 files.

## What to look at

- Batteries: the project's costliest work is termination and bounds proofs
  (`decreasing_tactic` 193 times, 217 M heartbeats across 25 modules;
  `get_elem_tactic`); the [case study](../case-studies/batteries.md) has the
  findings.
- Mathlib: the definitions behind the most work are `CategoryTheory.Functor.obj`
  (989 M heartbeats of `isDefEq` work from 539 declarations) and
  `DFunLike.coe` (975 M from 1,452); the [case study](../case-studies/mathlib.md)
  has findings on the first 20 of these modules and two candidate patches.
- One limit shows in Mathlib's repeated work: 68 operations whose
  description Lean could not print ("failed to pretty print term") are
  counted as one operation (849 M heartbeats), though they are different
  operations.

To compare a run of your own against these, download the report and give
both to `leanprof html` (base first): every level of the project view then
shows the base, the change and whether it is a regression.
