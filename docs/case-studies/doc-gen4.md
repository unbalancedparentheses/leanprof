# Case study: doc-gen4

[doc-gen4](https://github.com/leanprover/doc-gen4) generates the API
documentation of Lean packages (it builds the Mathlib docs). The runs below
used its `v4.35.0` tag (commit `0e1ffe2`, Lean 4.35.0) and leanprof's
command from another checkout, on an Apple M5 Max. doc-gen4 links all of
Lean, depends on four packages (one of them, `leansqlite`, compiles SQLite
from C) and has no dependency on leanprof.

It works in two passes, both profiled here:

- `doc-gen4 genCore --build DIR Std api-docs.db` loads Lean's `Std` and
  writes what it finds about each of the 50,979 constants it processes into
  an SQLite database: 68 s, 1.25 GB resident memory.
- `doc-gen4 fromDb --build DIR DIR/api-docs.db` renders the database into
  HTML (494 modules, 90 MB) in about 20 tasks: 7.2 s wall, 20.2 s CPU.

## Pass 1, analysis (`leanprof sample` and `run --auto`)

| sampled (inclusive CPU) | `--auto` (total of 50.2 s) | |
|---|---|---|
| 88% | 46.3 s | `DocGen4.Process.DocInfo.ofConstant` (`DocGen4/Process/DocInfo.lean:167`) |
| **59%** | **33.2 s** | **`DocGen4.Process.computeEquations?` (`DocGen4/Process/DefinitionInfo.lean:30`)**, almost all in `Lean.Elab.Eqns.mkEqns` |
| | 12.4 s | `DocGen4.Process.Info.ofTypedName` (`DocGen4/Process/NameInfo.lean:120`): pretty-printing signatures |
| | 11.4 s | `DocGen4.Process.TheoremInfo.ofTheoremVal` (`DocGen4/Process/TheoremInfo.lean:15`) |
| | 6.4 s | writing the database (`DocGen4.updateModuleDb`, `DocGen4/DB.lean:503`) |

Self time is 21% Lean's C++ expression code (`instantiate`, `replace`, the
hash maps of `replace_rec_fn`), 13% allocation, 11% freeing.

**More than half of the run generates equation lemmas.** For each of the
6,660 definitions, `computeEquations?` calls `getEqnsFor?`, which builds
(realizes) the equation theorems of the definition in doc-gen4's
environment: unfolding, matcher reduction and `isDefEq`, the elaborator's
work. `run --auto` puts it at 30.8 s of self time out of 50 s (Lean's code
is not instrumented, so everything below doc-gen4's function is its self
time). Four definitions (`Std.Time.DateTime.weekOfYear`,
`Std.Time.PlainDateTime.weekday`, `.weekYear`, `.weekOfYear`) run into the
200,000-heartbeat limit and print a warning; each burns the whole budget
first. The result is only used to show equations in the HTML, and
`Output/Definition.lean` drops those that are too large to render.

**What a fix looks like**: there is an option for it (`genEquations` in
`DocGen4/Process/Base.lean:14`) but no command-line flag; exposing it, or
computing equations only for definitions whose page shows them, would make
this pass about twice as fast. A lower heartbeat budget for equation
generation would bound the four outliers.

## Copies, pass 1 (`leanprof run`)

| copies | bytes | time | function | where |
|---|---|---|---|---|
| 29,026 | 69.9 MiB | 43 ms | `DocGen4.Process.process` | `DocGen4/Process/Analyze.lean:190` |
| 145,519 | 3.2 MiB | 1.1 ms | `DocGen4.RenderedCode.pushRight` | `DocGen4/RenderedCode.lean:116` |

`process` (line 222) reads a module with `let module := res[moduleName]!`
while the map `res` still holds it, then pushes onto `module.members`: every
declaration copies its module's member array (quadratic in the size of a
module). `res.modify moduleName fun m => {m with members := m.members.push …}`
updates it in place. At 43 ms it is not what makes the pass slow, but it
grows with the size of the largest module.

Memory: peak 1.18 GiB resident, 648 MiB committed by Lean's allocator,
rising by 595 MiB during `process` (the realized equation lemmas stay in
the environment).

## Pass 2, HTML (`leanprof sample`)

| inclusive CPU | |
|---|---|
| **66%** | **`DocGen4.DB.ReadStmts.getContainedNames` (`DocGen4/DB/Read.lean:662`)**, all in `SQLite.Stmt.step` |
| 18% | `DocGen4.DB.ReadStmts.loadModule` (`DocGen4/DB/Read.lean:601`) |
| 5% | `DocGen4.Html.toString` (`DocGen4/Output/ToHtmlFormat.lean:70`) |

Rendering HTML is a small part of this pass: **two thirds of its CPU time
is one SQL query**, run once per module. `getContainedNamesStmt` (Read.lean,
line 177) finds, for every rendered declaration of a module, the
declarations whose source range lies inside its range: a self-join of
`name_info` and `declaration_ranges` on the module with range comparisons,
so its cost grows with the square of the number of declarations in the
module. The same information comes from sorting the module's ranges by
start position once and walking them with a stack, in Lean, in linear time
after the sort.

**12.7% of the CPU time is threads waiting for SQLite's global memory
mutex** (`__psynch_mutexwait` and `__psynch_mutexdrop`, all under
`sqlite3_mutex_enter` and `sqlite3_mutex_leave` from `sqlite3Malloc` and `sqlite3_free`, 99.8% of the samples). Each task
opens its own connection, but SQLite counts memory statistics in one
global structure behind a mutex unless it is compiled with
`SQLITE_DEFAULT_MEMSTATUS=0`, and `leansqlite` compiles `sqlite3.c` with
only `-DSQLITE_DISABLE_LFS -DSQLITE_ENABLE_COLUMN_METADATA`. Adding the flag
(or `sqlite3_config(SQLITE_CONFIG_MEMSTATUS, 0)` at startup) removes the
contention between the 20 rendering tasks.

## Allocations and reuse, pass 2 (`leanprof run --allocs --counters --frees`)

101.9 million allocations (2.23 GiB):

| allocations | share | function | where |
|---|---|---|---|
| 25,650,492 | 21% | `SQLite.Blob.Deserializer.byte` | `.lake/packages/leansqlite/SQLite/Blob/Classes.lean:65` |
| 20,666,997 | 21% | `DocGen4.Output.renderedCodeToHtmlAux` | `DocGen4/Output/Base.lean:327` |
| 20,090,464 | 20% | `DocGen4.Html.escape` | `DocGen4/Output/ToHtmlFormat.lean:35` |
| 7,302,155 | 7% | `DocGen4.instFromBinaryRenderedCode` | |

Deserializing a blob allocates once per byte, and escaping HTML once per
character. 55% of `renderedCodeToHtmlAux`'s 13 million constructor reuse
checks fail on shared values. Tasks: 21, 67.1 s of run time in total; the
main thread waits 23.3 s for them in `htmlOutputResultsParallel`
(`DocGen4/Output.lean:100`).

## What broke or confused leanprof here, and was fixed

- Building doc-gen4 with probes printed a leanprof report for every module
  of `leansqlite`, `UnicodeBasic` and `MD4Lean`: they set
  `precompileModules`, so `lean` loads their instrumented shared libraries
  while compiling. The build now runs with reports off.
- With `--auto`, `DocGen4.Process.process` showed 140.9 s, 281% of a 50 s
  run, and `runGenCoreCmd` 2 calls and 198%: the `_boxed` wrapper, the
  `_redArg` worker and lambdas of one declaration were separate scopes,
  nested inside each other, and their totals were added. They are now one
  scope, so totals are counted once and a part called by its own
  declaration is not a new call.
- `sample` attributed 84% of pass 2 to
  `Lean.Server.Watchdog.FileWorker.waitForProc (in Std.Mutex.atomically)`:
  a specialization of `Std.Mutex.atomically` that Lean made for its
  language server and doc-gen4 reuses for its database mutex. `sample` now
  says under such a line which declaration calls it in this run
  (`DocGen4.DB.mkReadDB`).
- A C++ symbol of 1,500 characters (`std::__1::__hash_table<…>`, 7% of the
  time) was cut to 512 characters and filled a screen; C++ names are now
  shown without template arguments, and Lean's C++ expression code has its
  own category instead of "other Lean runtime".
- The scope table was printed with a header and no rows when the only scope
  was a task (pass 2).
