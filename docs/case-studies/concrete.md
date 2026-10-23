# Case study: concrete

[Concrete](https://github.com/lambdaclass/concrete) is a systems programming
language whose compiler is written in Lean 4 (lexer, parser, elaborator,
checker, SSA, LLVM emission, proof extraction), a 216-job build on Lean
4.34.1 with no dependency on leanprof. The runs below used commit `185d998c` and
leanprof's command from another checkout, on an Apple M5 Max.

The workload is `concrete build` in `examples/lox`, a Lox interpreter
written in Concrete (1,183 lines) plus the standard library it imports
(14,072 lines), compiled to LLVM IR and linked by clang: 0.98 s, of which
the compiler's own CPU time is about 0.5 s. `concrete` finds its project
from the current directory, so it runs there:

```
leanprof sample --cwd examples/lox concrete -- build
```

## Where run time goes (`leanprof sample`)

| inclusive CPU | |
|---|---|
| 45% | `Concrete.loadProject` (`Concrete/Resolve/Project.lean:865`): reading, lexing, parsing and resolving both packages |
| 23% | `Concrete.emitSSAProgram` (`Concrete/Backend/EmitSSA.lean:1775`): LLVM emission |
| 16% | `Concrete.Pipeline.lower` (`Concrete/Pipeline/Pipeline.lean:146`) |
| 14% | `Concrete.Pipeline.elaborate` (`Concrete/Pipeline/Pipeline.lean:117`) |
| 10% | `Concrete.extractProofCore?` (`Concrete/Proof/ProofCore.lean:3926`) |

The self time is dominated by linear searches through lists:

| self CPU | function | what it is |
|---|---|---|
| 10.6% | `Concrete.emitSModule (in List.findSome?)` (`EmitSSA.lean:1458`) | for each generic struct and enum, a search through every type of every instruction of the module (`moduleTys`, lines 1464–1473 and 1479, 1498) |
| 9.2% | `List.reverseAux` | `xs := xs ++ [x]` in loops: `List.appendTR` copies the whole list each time; called from `elabExprEv` (`Elab.lean`, lines 751, 773, 873, 928–1048, 1106), `strictDomDefs`, `tarjanSCC` |
| 5.9% | `Concrete.Symbols.isRuntimeHelperName (in List.elem)` (`Symbols.lean:51`) | 91% of it called from `ensurePtrOp` (`EmitSSA.lean:632`): `isKnownPtr` tests `s.ptrRegs.contains name` (line 129) for every operand, a list of every pointer register of the function |
| 3.3% | `Concrete.Layout.lookupStruct (in List.find?)` (`Check/Layout.lean:25`) | struct definitions in a list, searched by name for every size and alignment query |
| 3.2% | `Concrete.Sha256Fast.compress` (`Proof/Sha256Fast.lean:49`) | `shortHash` of implementation fingerprints |

The third row is worth a note: the specialization of `List.elem` for
strings was made for `isRuntimeHelperName` and named after it, but the
compiler reuses it for every `List String` membership test in the module.
`leanprof sample` now prints who calls it.

**What a fix looks like**: `moduleTys` deduplicated into a hash map keyed by
generic name before the struct and enum loops; `ptrRegs` and the struct and
enum definitions as `Std.HashSet`/`Std.HashMap`; arrays (`push`) instead of
`++ [x]` in the elaborator's loops.

## Allocations (`leanprof run --allocs`)

9,263,970 allocations, 192.8 MiB:

| allocations | share | function | where |
|---|---|---|---|
| 957,927 | 9.0% | `Concrete.LexerState.advance` | `Concrete/Frontend/Lexer.lean:24` |
| 739,308 | 8.8% | `Concrete.termSuccessors` | `Concrete/IR/SSACleanup.lean:25` |
| 655,870 | 5.2% | `Concrete.instDst` | `Concrete/IR/SSACleanup.lean:298` |
| 615,876 | 4.9% | `Concrete.skipWhitespace` | `Concrete/Frontend/Lexer.lean:79` |
| 485,573 | 4.8% | `Concrete.peek` | `Concrete/Frontend/Parser.lean:50` |

The lexer allocates for every character: `LexerState.advance` matches on
`s.peek`, which returns an `Option Char` (a heap cell), and so does
`skipWhitespace`. Testing `s.pos < s.source.size` and indexing directly
avoids both. `termSuccessors` builds a fresh list of successor labels on
every call and `instDst` an `Option String` per instruction; both are
called again for every pass over the CFG.

## Copies and reuse (`leanprof run`, `--counters`)

| copies | bytes | function | where |
|---|---|---|---|
| 979,199 | 8.2 MiB | `Concrete.elabModule (in List.filterMapTR.go)` (strings) | `Concrete/Elab/Elab.lean:2546` |
| 23,821 | 140.1 KiB | `Concrete.coreDefinitionSpellings (in List.mapTR.loop)` | `Concrete/Elab/Elab.lean:2448` |

and, from `--counters`, the same `filterMap` fails 2,933,669 constructor
reuse checks (every list cell it visits is shared). Both point at the same
loop: for every imported symbol, `elabModule` filters the imported module's
whole list of method signatures (`s.implMethodSigs.filterMap`,
`Elab.lean` lines 2695 and 2736) to find the methods whose mangled name
starts with `sym.name ++ "_"`, building strings as it goes. That is about
2.9 million list cells visited to compile this project. Grouping the
methods by type once per imported module makes it proportional to the
methods actually imported. (The copies are only 7.7 ms; the cost is the
traversal.)

## Compile time (`leanprof elab --heartbeats`)

`Concrete/Check/Check.lean` (3,425 lines, among the slowest modules to
build) costs 291.1M heartbeats, **51% of it code generation**:

- **One `mutual` block of `partial def`s, lines 449–2628 (the expression
  and statement checker), is 69% of the file**: 145.2M heartbeats to
  compile (reported at line 456) and 56.0M to elaborate, 36.0M of it the
  `do match e with ...` body of `checkExprCore`. The block is elaborated
  with `set_option backward.do.legacy true` because, as the comment above
  it says, the new `do` elaborator exceeds the default heartbeat limit on
  it; with the legacy one it uses 56,025 kHB, 28% of that limit.
- Repeated instance problems inside it: `Bind ?m` 1,120 times, `Pure ?m`
  756 times, `HAppend String String String` 820 times; `Type =?= Type` is
  checked 12,999 times in the file.
- Splitting the block into smaller mutual groups (most functions do not
  call each other) would cut both costs and let them build in parallel;
  its code generation is the larger half.

Its full trace is 2.4 GB of JSON in one message, which is what made
`leanprof elab` itself run out of memory (below).

## What broke or confused leanprof here, and was fixed

- `concrete build` reads `Concrete.toml` from the current directory, and
  `leanprof run`/`sample` could only run a program in its Lake project.
  They now take `--cwd DIR`; positions still come from the project.
- The largest copy site was reported as
  `List.filterMapTR.go (in List.filterMapTR.go)`, with no position: its
  symbol is a specialization made inside another specialization
  (`List.filterMapTR.go._at_.(List.filterMapTR.go._at_.Concrete.elabModule.spec_107).spec_119`),
  and the demangler took the inner callee for the caller. It now reports
  the user code at the end of the chain, `Concrete.elabModule (in
  List.filterMapTR.go)`, with its position. Concrete links all of Lean,
  and a few hundred of its 192,087 symbols are nested specializations,
  some long enough (over 96 components or 1,024 characters) to be cut
  before demangling; `demangle-check` now passes on all of them.
- `isRuntimeHelperName` looked like the third hottest function of the
  compiler; `sample` now says that 91% of that time is called from
  `ensurePtrOp`.
- With `--auto`, the run took 2.47 s instead of 0.98 s, but the calibrated
  probe cost explained only 0.24 s of it: with 1,675 functions timed, the
  scope tables do not stay in cache and each call costs several times what
  the calibration measures. This is now said in the guide (call counts stay
  exact; take times from `sample`).
- `leanprof elab` needed 15.5 GB of memory for `Concrete/Check/Check.lean`:
  Lean prints the full trace of its large `mutual` block as one 2.4 GB
  message, which leanprof read whole, parsed as JSON and split into lines.
  It now decodes each message a line at a time as it arrives and keeps only
  the operations it reports: 167 MB, with the same report.
