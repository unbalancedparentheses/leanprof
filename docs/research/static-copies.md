# Static retained-array copy prototype

> Superseded by `leanprof explain --static` ([guide](../guide/static-copies.md)),
> which reads the emitted C instead of an IR export and finds all 8 copying
> examples. The prototype's scripts were removed; this note records it.

This experiment reads Lean's saved **post-reference-counting compiler IR** and
flags `Array.push` calls whose receiver appears to retain another reference.
It needs compiled modules, but no executable or workload run. It is a standalone
prototype on `codex/static-copies`, not part of the `leanprof` CLI or editor.

The first real check finds both retained-inner-array push sites in the old
lean-compiler-backend `CFG.build`, and neither in its fixed version. The broader
example suite also shows why this is not yet a general copy detector: it detects
2 of 8 copying examples, with no warnings on 10 zero-copy alternatives.

## Run it

Build the modules using their normal project configuration first:

```sh
cd /path/to/project
lake build MyProject.Module
python3 /path/to/leanprof/scripts/static-copies/analyze.py \
  --project . --module MyProject.Module \
  --save-ir /tmp/module-ir.json > /tmp/static-copies.json
```

Repeat `--module` to scan more modules. Libraries with no executable work.
The scanner does not start builds or change instrumentation flags. It runs
`lake env lean --run Export.lean` to import the saved IR; normal imported module
initializers can run, but the program's workload is not invoked. Use it on the
same trusted projects you would build normally.

An export can be analyzed again without invoking Lean:

```sh
python3 /path/to/leanprof/scripts/static-copies/analyze.py \
  --ir /tmp/module-ir.json > /tmp/static-copies.json
```

JSON schema 1 includes the Lean version/compiler Git hash, IR SHA-256, findings,
per-function coverage and per-module body counts. A finding identifies the
compiler function, IR node ID, receiver variable, update expression, preceding
increment, known retaining container, and path conditions. Source mappings are
**declaration ranges**, not exact Lean update/retention expressions. Source names
for specialized functions are recovered from their compiler names and checked
against saved declaration ranges; unavailable mappings remain null.

Exit 0 means the requested analysis finished, not that there are no copies.
Exit 2 accompanies `error`, `no-ir-bodies`, or `partial`. Missing modules and
failed exports never become clean reports. `--max-states` bounds path exploration
per function (default 10,000); exhaustion, unresolved joins and join cycles are
reported. `--timeout` bounds the export subprocess (default 120 seconds).

The collector and IR rules have been exercised on Lean 4.35.0 and 4.34.1. They
use compiler internals and should be revalidated before relying on another
version. Rebuild before scanning: source/IR freshness is **not** checked, so
saved ranges may describe an older source revision. Save the IR when retaining
findings as evidence.

## Analysis boundary

The exporter reads `Lean.IR.declMapExt` entries, including the `.ir` bodies of
ordinary runtime definitions. It does not parse emitted C or search source text
for `.push`.

The analyzer follows branches and join-point parameter substitutions with a
bounded per-path walk. Its local model tracks increments/decrements, constructor
and array ownership, array projections, known stores and consuming calls. It
uses compiler parameter borrowing information for calls. Releasing a container
or moving an element out can cancel an apparent extra reference. Calls without
an ownership summary are handled conservatively and listed in coverage limits.

Only `Array.push` is a warning target. Array reads and setters are modeled to
explain when an inner array is still held by its outer array, and when
`Array.modify`'s temporary replacement releases it. Known-empty receiver copies
are suppressed and counted in `suppressedEmptySites`. They can still allocate:
the empty-retained fixture records one nonconstant copy event, but copies zero
existing elements. Compiler-marked persistent increments are excluded from this
local-retention warning.

A finding is **likely-copy**, not a proof or a cost estimate. The model does not
solve arbitrary aliasing, interprocedural retention, multi-threaded/persistent
ownership, or loop invariants. Borrowed array-read evidence assumes an in-bounds
access; an out-of-bounds default can have different ownership. Conditions are
possible compiler paths, not assertions that the selected workload reaches them.
`trackedReferences` is the local model's evidence, not a measured reference count.
A missing warning is never a claim of exclusivity.

Suggestions describe the two known patterns (`Array.modify`, or history prefix
lengths when semantics allow). The tool neither applies nor verifies a rewrite.
Runtime profiling is still needed to establish frequency, bytes and cost.

## Measurements, 2026-10-25

[Recorded results](static-copies-results.json) include compiler identities,
source revisions/hashes, prediction outcomes and output graph hashes. Counts
below are from `Leanprof.copies`, which excludes persistent constants. They are
not timing measurements or a claim of full runtime/core-library coverage.

### Targeted compiled fixtures

`Tests/StaticCopies` compiles actual Lean code with array-copy instrumentation
and runs with array sizes 2, 20 and 128.

| Case | Warning | Nonconstant copies per run |
|---|---|---:|
| Retain the old array in the result | yes | 1 |
| Store the array in history, then push | yes | 1 |
| Update an element retained by an outer array | yes | 1 |
| Conditionally retain the array | yes, conditional | 1 on the retaining branch; 0 on the other |
| Exclusive update | no | 0 |
| Move a field out of its owning structure | no | 0 |
| Release history before updating | no | 0 |
| `Array.modify` replacement | no | 0 |
| Retain a known-empty array | suppressed | 1, with no existing elements to copy |
| Retention across a non-inlined function call | **missed** | 1 |

The tests also check source precision, bounded exploration, missing-module
errors, and absent/unsupported evidence. These are small targeted cases, not a
representative precision estimate for arbitrary Lean projects.

### Existing example suite

On `Examples.ExplainPatterns` at `n=400`, `k=10`:

- `nestedBuckets`: warned; 390 copies. Fixed version: no warning, 0 copies.
- `keepHistory`: warned; 399 copies. Prefix-length version: no warning, 0 copies.
- The other 8 fixed variants: no warning, 0 copies.
- Six copying variants are missed: `groupBy`, `groupByOpt`, `addMembers`,
  `logGlobal`, `logMutex`, and `bumpAll`. These exercise map/callee retention,
  multi-threaded state and array-set loops beyond the local push pattern.

At the **function/workload** level this is 2 true positives, 0 false positives,
6 false negatives and 10 true negatives. It is not site-level precision or a
claim that every path through a warned function copies.

### Real lean-compiler-backend sources

The reproducer builds the original `IR.lean` and `CFG.lean` from these revisions
in isolated projects using their pinned Lean 4.34.1:

- Before: `a623accdc611b2659941b220af54fd42d4b87d75`
- After: `8a0d286fba88298d6f8074e598781478bf6c5cc9`

It runs the actual `CFG.build` on synthetic branching graphs with shared target
blocks. This is a real-function check, **not a full compiler benchmark**.

| Blocks | Old build: 2 flagged push sites | Fixed build: 0 flagged sites |
|---:|---:|---:|
| 10 | 17 copies | 1 copy |
| 40 | 77 copies | 1 copy |
| 100 | 197 copies | 1 copy |

The complete successor and predecessor arrays match at all three sizes. One
nonconstant copy remains in the fixed implementation; it is not attributed by
this prototype. The fixed function must not be described as copy-free.

### Lake: useful negative result

The installed Lean 4.35.0 `Lake.Build.Module` contributes 1,028 IR function
bodies and 142 reachable `Array.push` sites to the scan. Four apparent findings
in `computeExportInfo` push onto known-empty arrays and are suppressed. No
retained-array warning remains.

The [existing Lake case study](../case-studies/lake-and-server.md) reports
thousands of job-queue copies caused by multi-threaded `IO.Ref` ownership. This
prototype does **not** detect that cause. The Lake scan was static; the historical
no-op build workload was not rerun for this experiment. Treat this as a known
coverage gap, not a false-positive-free validation of all of Lake.

## Reproduce and next step

```sh
python3 -B Tests/StaticCopies/check.py
python3 -B Tests/StaticCopies/real_projects.py \
  --lcb-repo /path/to/lean-compiler-backend \
  --output /tmp/static-copy-real-projects-new
```

The second command requires the pinned commits in the local compiler repository
and installed toolchains. The output directory must be new. It preserves source
copies, build/runtime logs, IR, analysis and a summary; neither the compiler
checkout nor its normal build is modified.

The next useful extension is a small set of validated ownership summaries for
map lookups and `IO.Ref` operations, followed by fresh runtime comparisons on
those missed cases. Exact expression-level source attribution and source
freshness checks are prerequisites for editor warnings. This evidence supports
continuing the experiment, not enabling blanket editor diagnostics yet.
