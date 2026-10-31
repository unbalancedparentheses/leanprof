# Likely copies in Lean's own code, found statically

`leanprof explain --static` over the C that Lean 4.35.0's own build emits for
`Init`, `Std`, `Lean`, `Lake` and the small tools (`LeanIR`, `Leanc`,
`LeanChecker`, `LeanExport`). Nothing was run: every flag below is a
hypothesis about the compiled code, not a measured cost. Which flags copy at
run time, and how often, is for a later step (see the end).

## What was scanned

- Lean `v4.35.0`, commit `eb6cafb7290e8bd5f2937522d8d804f58f02bafc`,
  built from source with the release preset in Lean's Nix dev shell
  (`nix develop`: cmake 4.1.2, LLVM 19 clang), `make -j12` under `nice -n 10`
  and `taskset -c 0-11`.
- The scanned C is stage 1's: `build/release/stage1/lib/temp/**/*.c`, the
  library code that ships in the 4.35.0 toolchain, emitted by stage 0's
  compiler. 2547 modules, 134,226 compiled functions.
- Sources: the same checkout's `src/`. Declaration lines come from
  `build/release/stage1/lib/lean/**/*.ilean`.

```sh
# in the lean4 checkout, after the build
leanprof explain --static --ir-dir build/release/stage1/lib/temp --src-dir src \
  --all --no-report --json --out static.json
```

`--ir-dir` and `--src-dir` are new for this (they also cover any build whose
C is not in `.lake/build/ir`). The scan took 44 s and 2.4 GB.

Files in [`lean-core-static/`](lean-core-static/):

| file | what |
|---|---|
| `static-4.35.0.json.gz` | the scan's output, every flag with its evidence (gzip of `static.json`) |
| `flags-4.35.0.tsv` | the same flags one per line, with area, cause, loop, confidence and the release check below (`flags-tsv.py` makes it) |
| `released.py`, `released-4.35.0.json` | the check for one false-positive pattern, run in the checkout |

## Counts

1419 flags in all (with `--all`). 1084 are shown by default (string appends
outside loops are hidden), and 326 of those are `map-over-shared-array`:
an `Array.map`/`mapM` over an array that is used again afterwards, which
copies once at about the cost of building the result anyway. Leaving those
out leaves 758.

| area | all | shown | shown, not map-over-shared |
|---|---:|---:|---:|
| Lake | 464 | 163 | 140 |
| `Lean.Elab` | 392 | 389 | 256 |
| `Lean.Meta` | 268 | 263 | 209 |
| compiler (`Lean.Compiler`) | 99 | 84 | 16 |
| `Lean` (other: `Environment`, `CoreM`, `Data`, `Util`, ...) | 77 | 71 | 53 |
| `Std` | 53 | 52 | 51 |
| server and LSP | 32 | 32 | 8 |
| `Init` | 15 | 13 | 10 |
| parser | 11 | 11 | 11 |
| pretty printer, tools | 8 | 6 | 4 |

By cause (shown flags): used after the update 359, map over a shared array
326, field of a structure that is kept 154, stored then updated 135, nested
array element 32, passed twice 24, a global made by `initialize` 17, kept by
a loop 15, a hash-map value updated and inserted back 13, shared on entry 8,
read from an `IO.Ref` 1.

Where they are says little about cost. Most of `Lean.Elab`'s flags are in
code that runs once per declaration or less: `PreDefinition` (85, recursion
compilation), `Tactic/Do` and `VCGen` (50), `Deriving` (24), `DocString`
(21). `Lean.Meta.Constructions` (59) runs once per inductive type. Lake's
are almost all configuration, CLI and cache code. The compiler's are nearly
all `map-over-shared-array` in its passes.

## Precision: one pattern the scan gets wrong

Reading the C of the first candidates turned up a false positive that
repeats: the code rebuilds a structure with the value in it (`{ s with x }`,
or a state tuple), takes a reference for it, and then, on the path to the
update, releases that structure without using it. When the structure is
unique, the release frees it and the value's count drops back to one before
the update, so the update is in place. The scan counts the reference and
not the release.

Verified by reading the C: `Std/Sat/AIG/Cached.lean:116` (`mkGateCached`,
`decls`; `lean_dec_ref(v___x_102_)` at `Cached.c:522` precedes the push at
527), `Lean/Elab/Binders.lean:446` (`elabFunBinderViews`, `localInsts`), and
`Lean/Meta/Tactic/Grind/Main.lean:262` (`collectUsedOrigins`, the hash set
in the state tuple). `released.py` looks for the pattern in all flags: 21
match it (`local_check` = `holder-released` in the TSV), among them all four
AIG/`bv_decide` bitblasting flags, `Json.compress`, and Grind's
`EMatchAction.collect`. The check is a text heuristic over a window of C
before the update; `kept` means it found no such release, not that the copy
is confirmed. The scan should learn this case; that is a change to
leanprof, not to Lean.

The other limits of the method apply as usual: a flag is a path that would
copy if it runs with the value shared; it says nothing about how often it
runs, and a flag found through a caller (`medium` confidence) can be on a
path the caller rarely takes.

## The top 20, ranked

Ranked by how hot the code plausibly is and how likely the copy is real, from
reading the source and, where noted, the C. "Hot" means it runs many times
per declaration in ordinary elaboration; "warm" means per tactic call, per
compiled declaration or per command; "cold" means setup, errors, or opt-in
features. None of this is measured.

| # | where | value, operation | cause | hot? | real? |
|---|---|---|---|---|---|
| 1 | `Lean/Meta/DiscrTree/Main.lean:438` `getMatchLoop` | `todo`, `Array.pop` | the caller keeps `todo` across the recursive call | hot | yes, when a star edge and a key edge both exist |
| 2 | `Lean/Meta/DiscrTree/Main.lean:578` `getUnify.process` | `todo`, `Array.pop` | same, in `getUnify` | hot | likely |
| 3 | `Lean/Meta/Basic.lean:1422` `withNewLocalInstanceImp` | `localInstances`, `Array.push` | field of the reader context, which is kept | hot | yes (C read) |
| 4 | `Lean/Meta/Basic.lean:1971` `withLocalInstancesImp` | `localInstances`, `Array.push` in a loop | field of the reader context | warm | first push only |
| 5 | `Lean/Util/Trace.lean:447` `addTraceAsMessages` | per-position `Array MessageData`, `push` | hash-map value updated and inserted back | cold unless tracing | yes (high) |
| 6 | `Lean/Elab/Tactic/Omega/Core.lean:399` `Problem.addInequality` | `assumptions`, `Array.push` | `p` is used after `{ p with assumptions := ... }` | warm | yes (C read) |
| 7 | `Lean/Elab/Tactic/Omega/Core.lean:417` `Problem.addEquality` | `assumptions`, `Array.push` | same | warm | yes (C read) |
| 8 | `Lean/Compiler/LCNF/Simp/SimpM.lean:127` `withInlining` | `inlineStackOccs` buckets, `HashMap.insert` | field of the reader context | warm (compiling) | likely |
| 9 | `Lean/Compiler/LCNF/Simp/DiscrM.lean:93` `withDiscrCtorImp` | `ctorDiscrMap` buckets, `HashMap.insert` | field of the reader context | warm (compiling) | likely |
| 10 | `Lean/Compiler/LCNF/ExplicitRC.lean:598` `LetDecl.explicitRc` | `args`, `Array.push` | field of the let value, which is kept | warm (compiling) | yes (C: reference taken right before) |
| 11 | `Lean/Meta/ExprDefEq.lean:1044` `CheckAssignment.checkMVar` | `toErase`, `Array.push` in a fold | used after the update on some paths | hot | doubtful: path-dependent, no source line matched |
| 12 | `Lean/Meta/Tactic/Simp/Main.lean:276` `withNewLemmas` | `SimpTheoremsArray`, `Array.set` | field of the simp context, kept | warm, contextual simp only | likely, tiny array |
| 13 | `Lean/Elab/App.lean:1749` `addLValArg.go` | `args`, `Array.push` | used after the update | warm (dot notation) | unverified |
| 14 | `Lean/Elab/Do/Basic.lean:346`, `:351` `declareMutVar(s)` | `mutVars`, `mutVarDefs` | field of the reader context | warm (`let mut`) | likely, small |
| 15 | `Lean/Elab/Term/TermElabM.lean:852` `elabToSyntax` | `fixedTermElabs`, `Array.push` | field of the reader context | cold | yes, small |
| 16 | `Lean/PrettyPrinter/Delaborator/Builtins.lean:471` `tryAppUnexpanders.go` | `argStxs`, `Array.pop` in a loop | stored in `Syntax.mkApp`, then popped | cold in builds, warm in the editor | likely; quadratic in the arguments |
| 17 | `Init/Meta/Defs.lean:605`, `:640` `Syntax.setTailInfo`/`setHeadInfo` | node `args`, `Array.set` | the node is kept | warm | yes, but a persistent update has to copy |
| 18 | `Lean/Meta/Match/MatcherApp/Transform.lean:480` `inferMatchType` | `matcherLevels`, `Array.set` | field of a kept structure | cold | yes (high), once per call |
| 19 | `Lean/Environment.lean:1517`, `:1708` `registerEnvExtension` and persistent variant | the extensions array, `push` | a global shared across threads | cold (startup) | yes; quadratic in extensions, a few hundred |
| 20 | `lake/Lake/Build/Module.lean:130` `Module.fetchImportLibs` | `jobs`, `Array.push` in a loop | field of a kept structure | cold next to `lean` | likely (high) |

### Notes on each

1–2. **DiscrTree lookups.** `getMatchLoop` pops `todo` (the subterms still
to visit) in place, but when a node has a `*` edge and an edge for the
current key, it visits the `*` child with `todo` and then the key child with
`todo ++ args`, so the first recursive call gets a shared `todo` and its pop
copies. The source says so in a comment ("`todo` is not used linearly when
there is `Key.star` edge"). `getMatch` is on simp's path for every subterm it
tries to rewrite, and `getUnify` is how instance synthesis finds candidate
instances, so both run very often. Against that, `todo` is small (the
pending arguments of one term, usually under ten), so each copy is one small
allocation next to `getMatchKeyArgs`' `whnfR` and `instantiateMVars`. The
most plausibly hot flags in the scan, but the per-copy cost is small; whether
they add up to anything is a run-time question.

3–4. **Local instances in the reader context.**
`withNewLocalInstanceImp` runs `withReader fun ctx => { ctx with
localInstances := ctx.localInstances.push ... }`. The context is still held
by the continuation after `k` returns, so the push copies the array every
time a binder whose type is a class is entered (`forallTelescope`,
`lambdaTelescope`, `withLocalDecl`). The C takes the reference on the line
before the push, with no release between. This is how a reader context with
an `Array` behaves, not an accident: the outer scope must keep its array.
The cost is linear in the number of local instances, which is usually a
handful but can be dozens in sections with many `[inst : ...]` variables.
Making it cheaper means a different structure (a `List`, or a
`PersistentArray`), which may cost more than it saves for small sizes.
`withLocalInstancesImp` (4) copies on its first push and then pushes in
place, so the "loop" mark overstates it.

5. **`addTraceAsMessages`** groups the trace trees by position with
`pos2traces.insert key (pos2traces.getD key #[] |>.push msg)`: the array is
still in the map during the push, so every push copies it, and k traces at
one position cost O(k²). It only does work when traces were collected (a
`trace.*` option is on), so ordinary builds never reach it. With tracing on,
all top-level trace trees of a command can share one position. The same code
appears in the scan at `Lean/CoreM.lean:629`, `Lean/Elab/Command.lean:490`,
`Lean/Meta/Basic.lean:2669` and `LeanIR.lean:64`, where it is specialized.
The standard fix (take the array out of the map, or `alter`) is mechanical.

6–7. **omega's problem setup.** `addInequality` builds
`p' := { p with assumptions := p.assumptions.push ... }` and then uses `p`
(`p.replayEliminations f`), so the push copies `assumptions` each time:
adding n facts copies O(n²) elements. The C confirms it: the reference is
taken on the line before the push. Each `omega` call pays this once per
hypothesis it collects; with tens of facts the total is small, but it is a
real copy on a commonly used tactic, and reordering the two lets would avoid
it.

8–9. **LCNF simp's reader context.** `withInlining` inserts into
`inlineStackOccs`, a `HashMap` in the reader context, and
`withDiscrCtorImp` inserts into `ctorDiscrMap`. Both maps are still held by
the outer context, so each insert copies the bucket array. These run per
inlining decision and per `cases` alternative while compiling, so they are
warm in compilation-heavy files; the maps are small.

10. **`ExplicitRC`**: for a let whose value applies a variable,
`args.push (.fvar fvarId)` copies `args` because the let declaration still
holds it. Per such let, in the compiler; small arrays.

11. **`checkMVar`'s `toErase`**: the scan says the old array is used after
the push on some paths only, and no source line matched. Path-dependent
flags like this are often a different branch of a join point; this needs the
C read before anyone spends time on it, and it is on a hot path
(`checkAssignment` during `isDefEq`), which is the only reason it is here.

12. **`withNewLemmas`** (contextual `simp` only) adds hypotheses to the
`SimpTheoremsArray` taken from the context, which the context keeps; the
array has one to three entries, and the theorem sets in it are persistent.
Real, cheap.

13–15. `addLValArg.go` (dot notation's argument insertion), `declareMutVar`
(the `do` elaborator's `let mut`) and `elabToSyntax` are the same
reader-context or kept-value pattern on small arrays. 13 is unverified; 14
also inserts into a `HashMap` in the context.

16. **Delaborator unexpanders**: `go` passes `argStxs` into
`Syntax.mkApp fnStx argStxs` inside a `try` and then pops it for the next
attempt, so each pop copies, O(n²) in the explicit arguments of an
application with an app unexpander. Pretty printing does not run in a batch
build except for messages, but it does in the editor (goals, hovers).

17. **`Syntax.setTailInfo`/`setHeadInfo`** update the last (first) argument
of each node down the spine while the original syntax is still referenced:
a persistent update, which has to copy the spine. Listed because it is
frequent, not because it is avoidable.

18–20 are real but cold: `inferMatchType` once per matcher transform,
extension registration at startup (a few hundred pushes to a global marked
multi-threaded, each a copy: quadratic, but well under a millisecond), and
Lake's per-module import-library list, which runs in Lake, not in `lean`.

### Not in the top 20, and why

- `Std/Sat/AIG/Cached.lean:115-116` and the three `bv_decide` bitblaster
  flags (`Std/Tactic/BVDecide/Bitblast/BVExpr/Circuit/Impl/*.lean`) were
  the most alarming at first sight: a push to the AIG's `decls` per gate
  would make bitblasting quadratic. The C shows the false-positive pattern
  above; the push is in place when the AIG is unique, which is what the
  code is written for.
- `Lean/Elab/Binders.lean:446`, `Lean/Meta/Tactic/Grind/Main.lean:262`,
  `Lean/Meta/Tactic/Grind/EMatchAction.lean:54/68` and
  `Lean/Data/Json/Printer.lean:174`: the same pattern.
- `Lean/Environment.lean` `finalizeImport` (2308, 2313, 2371): once per
  process, on arrays the size of the import closure; the loop flags are
  `map`s that build a new array anyway.
- `Lean/Meta/SynthInstance.lean:226`, `:574` and most of the compiler's
  flags: `map-over-shared-array`, one copy at the cost of the result.
- `Lean/Meta/Tactic/Grind/EMatch.lean:839`: the reverse is in
  `assignmentToMessageData`, a trace message.
- The 17 `multi-threaded-global` flags: registration at initialization.

## What steps 3 and 4 would take

Step 3, counting the copies at run time in Lean itself. leanprof's
`run --core` already counts copies inside `libInit`/`libStd`/`libLean`/`libLake`
by renaming runtime references in copies of those archives
(`llvm-objcopy --redefine-sym`) and linking against them. For the `lean`
executable the same has to be done to stage 1's archives and the `lean`
binary relinked (its `main` is C++ in `src/util/shell.cpp`, linked by the
cmake build that now exists on the server). Estimate: half a day to get an
instrumented `lean` that runs, mostly in the link step and in checking that
the shim counts what the static flags name; then a workload (Lean's own
stage 2 build of `src/`, which takes about 6 minutes here, and a Mathlib
slice for simp and instance-heavy code) and an hour or two to join the
counts to the 1084 flags with `explain --static --report`. A run can only
confirm flags on paths it takes: the cold ones will show as "never ran".

Step 4, fixes, if any flag is confirmed with a cost worth having. The
candidates with a mechanical change are 5 (`addTraceAsMessages`) and 6–7
(omega); the DiscrTree and reader-context ones (1–4, 8–9) are design
choices where the copy is the price of persistence, and a change there needs
a benchmark showing it pays. Each change is a stage-1 rebuild (about 6
minutes) plus a benchmark with enough repetitions to see a small effect;
Lean's own benchmarking (radar) is what upstream would want to see. A day or
two for the first two fixes with measurements, more for anything in Meta.
