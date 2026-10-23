# Case study: verso

[Verso](https://github.com/leanprover/verso) is the documentation tool
Lean's own manuals are written in: documents are Lean files, elaborated by
Lean, and a small executable renders them. The runs below used its
`v4.35.0` tag (Lean 4.35.0) and leanprof's command from another checkout,
on an Apple M5 Max; Verso has no dependency on leanprof. The workload is
Verso's user guide (`doc/UsersGuide`, the `usersguide` executable):
building it takes 586 build jobs, and running it writes 5.1 MB of HTML in
0.19 s. Most of the cost is at compile time, so this study is mostly about
that.

## Compile time (`leanprof elab --heartbeats`)

Four of the slowest modules to build: three chapters of the guide
(`Manuals.lean`, `Websites.lean`, `Output/HTML.lean`) and
`VersoManual/Docstring.lean`, the `{docstring}` machinery the chapters use.
833.1M heartbeats in all.

- Kind of work: **code generation 56%**, command elaboration 25%,
  elaboration steps 18%, Verso blocks 4%.
- **`renderTaggedInMeta` (`src/verso-manual/VersoManual/Docstring.lean:100`)
  costs 125.0M heartbeats, all in the compiler: 15% of the four files for a
  three-line function.** It calls SubVerso's `renderTagged`
  (`SubVerso/Highlighting/Code.lean:894`), a `partial def` generic in its
  monad with eight instance arguments, at `ReaderT Context MetaM`; the
  compiler specializes the whole of `renderTagged` for that monad and
  compiles it again in this module. A monomorphic version in SubVerso (or
  `@[nospecialize]` on its instance arguments) would compile it once.
- `DeclType.ofName` (line 236) costs 79.5M heartbeats in the compiler too,
  and `blockFromMarkdownWithLean` (line 1372) 28.1M: `Docstring.lean` is
  73% code generation.
- In the chapters, the costliest work is repeated: **56 elaborations of
  `fun docReconstInBlock => ...` against `DocReconstruction Manual →
  Doc.Block Manual` cost 120.5M heartbeats** (`Manuals.lean`, first at
  line 24), one per block of the document, with `isDefEq` checks such as
  `Option String =?= Option ?m` done 3,691 times. The chapters' costs are
  reported near their last line (`Manuals.lean:307` of 309, 62.7M heartbeats):
  Verso elaborates the whole document there.

## Where run time goes (`leanprof sample`)

| inclusive CPU | |
|---|---|
| 80% | `Verso.Genre.Manual.manualMain.emitHtml` (`VersoManual.lean:1061`) |
| 31% | `Verso.Genre.Manual.traverse` (`VersoManual.lean:358`): resolving cross-references |
| 28% | `Verso.Genre.Manual.docstring.descr` (`VersoManual/Docstring.lean:809`) |
| **23%** | **`Verso.Genre.Manual.Index.addEntry.cmpEntry` (`VersoManual/Index.lean:145`)**, 90% of it in `Std.Format.pretty` |
| 22% | `Std.Format.pretty` overall |

**A fifth of the run pretty-prints JSON to compare index entries.**
`Index.addEntry` keeps the index sorted with `Array.binInsert cmpEntry`,
and `cmpEntry` compares two entries with the same id by
`toString e1 < toString e2`: it renders both JSON values to strings, through
`Format`, at every comparison of a binary search. Entries with the same id
are common: `docstring.descr`'s `saveRef` (`Docstring.lean:903`) adds one
per field and constructor of the documented structure, all under the
docstring's id. Comparing the JSON values directly (or keeping the rendered
key next to each entry) removes this.

## Allocations, copies and closures (`leanprof run --allocs --counters`)

2,975,442 allocations (75.8 MiB):

| allocations | share | function | where |
|---|---|---|---|
| 927,870 | 28% | `Verso.BinFiles.Z85.decodeChunk` | `VersoUtil/BinFiles/Z85.lean:80` |
| 309,290 | 13% | `Verso.BinFiles.Z85.decode` | `VersoUtil/BinFiles/Z85.lean:155` |
| 243,522 | 10% | `Verso.Search.Stemmer.Porter.step2` | `VersoSearch/PorterStemmer.lean:212` |

Every run decodes the static files embedded in the executable from Z85
text: `decodeChunk` returns its four bytes as a nested tuple (three cells
per five characters) and `decode` builds a `Substring` per chunk, 1.2
million allocations for 1.2 MB of data. Writing the bytes straight into the
`ByteArray` (or returning a `UInt32`) makes it allocation-free.

Copies are small here (the largest: 876 copies of a hash map's buckets, 2.8
MiB, in `Verso.Code.Hover.Dedup.insert`, `Verso/Code/Highlighted.lean:102`;
972 copies of the index array, 1.9 MiB, in `saveRef`'s `binInsert`, because
the index is taken out of the shared JSON state before inserting). The
Porter stemmer's rules (`Rule.apply?`, `PorterStemmer.lean:144`) fail half
of their 490,307 constructor reuse checks, and the search pipeline applies
its filters as closures (`Verso.Search.Pipeline.run`, `VersoSearch.lean:490`).

## What broke or confused leanprof here, and was fixed

- **`leanprof elab` reported the three chapters as nearly free** (under
  0.1M heartbeats each). It ran `lake env lean FILE`, which cannot load the
  shared library of MD4Lean's precompiled modules: Lean aborted at the
  first `{docstring}` (`Could not find native implementation of external
  declaration 'MD4Lean.parse'`) and leanprof read the few traces printed
  before. It now runs `lake lean FILE`, which loads plugins and shared
  libraries the way the build does, and says when Lean fails on a file.
- The costliest lines were named by the trace's pretty-printed command,
  which for Verso was often `failed to pretty print term (use 'set_option
  pp.rawOnError true' ...)`; they are now named by their source line.
- `kHB` was not explained: it is now said to be the unit of
  `maxHeartbeats`.
