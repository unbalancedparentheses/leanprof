# Copies without running: `leanprof explain --static`

`leanprof run` counts a copy only when the workload takes the path that
copies. `leanprof explain --static` reads the code the compiler emitted for
every function of a package and flags the updates that are likely to copy,
without running anything. It works on libraries with no executable, and on
code that no test or workload reaches.

```
leanprof explain --static                    # the whole package (runs `lake build` first)
leanprof explain --static MyLib.Parser       # these modules, and the modules under them
leanprof explain --static --report run.json  # and what a run said about each flag
leanprof explain --static --json             # the flags as JSON, for agents and scripts
```

Each flag gives the file and line of the update, the value updated, why
another reference to it is alive there, and the fix `leanprof explain` gives
for that cause, with the program's own names:

```
$ leanprof explain --static

leanprof explain --static: 10 likely copies in 4 modules (162 compiled functions, 64 updates
that copy a shared value), from the compiler's IR; nothing was run

Examples/ExplainPatterns.lean:33  nestedBuckets  Array.push of `buckets[…]`
  why: the Array updated by Array.push is an element read out of an array (`buckets[…]` at line 33)
       that still holds it, so the update copies the element before it is written back with `set`.
  fix: Use `Array.modify`, which takes the element out of the array before updating it, so the
       update is in place:
         buckets := buckets.modify i (·.push v)
  where: Examples/ExplainPatterns.lean line 33
  evidence: .lake/build/ir/Examples/ExplainPatterns.c:288 `v___x_12_ = lean_array_push(v___x_11_, v_i_5_);`,
            second reference at .lake/build/ir/Examples/ExplainPatterns.c:287
  confidence: high: the IR takes a second reference on every path to the update; source lines matched by text, not positions
...
```

The results are also written to `.lake/leanprof/static.json` (`--out FILE`),
which `#leanprof` reads.

## How it works

Lake keeps the C it compiles in `.lake/build/ir`. That C is Lean's IR after
reference counting, one statement per line: every `lean_inc` that takes a
second reference is there, and so is every `Array.push`, `set`, `pop`,
`swap`, `String.append`, `String.push` and `ByteArray`/`FloatArray` update,
each of which copies its value when the value is not exclusive. For each
such update in each compiled function, `explain --static` asks where the
value came from and whether another reference to it is alive at the update.
It flags the update when the IR shows one of these:

- **In the same function** (the analysis `leanprof explain` runs on a site a
  run counted): an element read out of an array that still holds it
  (`nested-array-element`); a value read from a hash map and inserted back
  (`map-value-reinserted`); a value stored in another container, or still
  used, after the update (`stored-then-updated`, `used-after-update`); a
  field of a structure that is kept (`field-of-kept-structure`); a value read
  from an `IO.Ref` that still holds it (`io-ref-read`).
- **In a caller.** A function that updates its parameter in place copies
  when the caller passes a value it still holds. The scan records which
  parameter (or field of a parameter) each function updates, follows the
  calls up to four levels, and flags the call where the caller keeps
  another reference: the value is used or released after the call, stored
  elsewhere, passed twice, or kept by a loop for its next iteration
  (`kept-by-loop`). A loop over the array it updates (`for x in xs` while
  `xs := xs.set! …`) and `Array.map` over a shared array are found this
  way. Calls of `Array.append` (`++`), `Array.appendList` and
  `Array.reverse`, which update their first argument inside Lean's
  precompiled library, count too.
- **In a global.** A value taken out of an `IO.Ref` or `Std.Mutex` made by
  `initialize` is multi-threaded, and Lean never updates a multi-threaded
  value in place (`multi-threaded-global`). This includes closures run on a
  mutex's contents (`mutex.atomically (modify (·.push x))`).

These are the causes `leanprof explain` names for a counted copy, and the
fix printed is the one `explain` prints for that cause. A flag known from a
caller is shown at the caller's call, where the change is made.

Some updates copy whatever the program does, and are not flagged:

- updates of a constant (`#[]`, a string literal, a closed term), which copy
  it once (`explain` calls these harmless unless large), and of an array
  just made empty by `Array.mkEmpty`, which copies no elements. The number
  skipped is printed;
- appends to a string that is still in use, outside a loop. Each copies the
  string, which costs about as much as building the result, and building
  the result happens anyway. In a loop the copy repeats, and those are
  flagged. `--all` shows the others.

## Checking flags against a run

With a report of `leanprof run` (`--report FILE`, by default the last report
when there is one), each flag says what the run saw:

| status | meaning |
|---|---|
| `confirmed at run time: N copies, B bytes` | the function with the update copied shared values N times in the run |
| `ran: N copies of a constant only` | it copied, but only constants |
| `ran, no copies counted` | it ran (report of `run --auto`) and copied nothing: the flagged path did not run, or the flag is wrong |
| `never ran` | it did not run (report of `run --auto`, which times every function) |
| `no copies counted` | the report has no copies for it, and says nothing about whether it ran (a report without `--auto`) |

A report counts copies per function, not per update, so a function with two
flags gets the same counts on both. An update inside `Array.append` is in
Lean's precompiled library: `leanprof run --core` counts its copies, a plain
run does not.

## In the editor and for agents

`#leanprof` shows each flag of `.lake/leanprof/static.json` in its file as an
inlay hint at the update (`⚠ likely copy`, or `⚠ likely copy: N copies in
the last run`), with the why and the fix in the hover
([editor](editor.md)). The MCP server has a `static_copies` tool with the
same flags as text ([live and MCP](live.md)).

## How accurate it is

On the examples in this repository, every function that copies is flagged
and none of the versions that do not copy is. `Tests/StaticCopies.lean`
checks this in `lake test`: it runs the scan on the C of the test cases and
of `Examples/ExplainPatterns.lean`, runs every case with copy counting, and
requires the flagged functions to be exactly the ones that copy.

| | copying functions flagged | non-copying functions flagged |
|---|---:|---:|
| `Examples/ExplainPatterns.lean` | 8 of 8 | 0 of 10 |
| `Tests/StaticCopies.lean` (retained, stored, conditional, nested, through a helper, kept by a loop, in a caller, string history) | 8 of 8 | 0 of 8 |
| `Examples/CopyBug.lean`, `Examples/CoreCopies.lean`, `Examples/Server.lean` | 3 of 3 | 0 of 2 |

The earlier prototype ([research note](../research/static-copies.md)) found 2
of the 8 copying functions of `ExplainPatterns`. The same results hold for
the C of Lean 4.27.0 and 4.35.0; the test suite runs on every Lean version
CI checks.

On real code, a flag is checked by running a workload with `leanprof run
--auto` and asking which flagged functions ran and copied
(`reproduce/static-copies.py`). On lean-compiler-backend at a25c541, compiling
zlib (Lean 4.34.1; 2,997 compiled functions, 2,207 updates that can copy):

| | |
|---:|---|
| 63 | flags, strings outside loops included |
| 36 | flagged functions that ran |
| 20 | of them copied shared values, 9 copied only constants, 7 copied nothing |
| 27 | flagged functions never ran in this workload |
| 17 of 26 | functions that copied shared values in the run were flagged |
| 116,465 of 119,516 | copies in the run were in flagged functions (97%) |

Most of the 7 that ran without copying are appends to string fields, which
copy only on paths the workload did not take, and one `Array.append`, whose
copies a run counts only with `--core`. The 9 functions not flagged copy
mostly through `Array.map` over an array whose second reference is more than
one structure away. The flag on `CFG.build` names both push lines of the
nested-array pattern before its fix (a623acc), and is gone after it
(8a0d286); one flag of another cause stays there, matching the one copy the
fixed version still makes.

On leanprof's own code, profiled on four of its commands (`explain
--static`, `explain`, `report-md`, `compare`), 16 flagged functions ran: 11
copied shared values, 3 copied only constants, 2 copied nothing (one of them
an `Array.append`, counted only with `--core`).

## Limits

- A flag is a likely copy on some path through the function, not a proof
  and not a cost: `leanprof run` says how often it happens and what it
  costs. Reading the IR statement by statement, the scan does not prove
  that the flagged path runs, and conditions on it are not shown.
- A missing flag is not a proof that nothing copies. Not followed: values
  shared through closures (other than a mutex's `atomically`), through
  structures passed between functions more than one field deep, or through
  more than four levels of calls; copies inside Lean's precompiled libraries
  other than the three functions above; values shared between threads by
  tasks.
- Source lines are found by matching the declaration's text against what
  the IR shows, not from positions in the IR, which has none. When nothing
  matches, the flag points at the declaration's first line.
- The C must be current: the scan runs `lake build` first (`--no-build`
  skips it) and says when a source file is newer than its C.
- `--ir-dir` and `--src-dir` scan C that Lake did not put in
  `.lake/build/ir`, such as Lean's own, from a build of Lean from source:
  `leanprof explain --static --ir-dir build/release/stage1/lib/temp --src-dir src`
  in a Lean checkout (`docs/research/lean-core-static-copies.md`).
- The analysis reads compiler output, which changes between Lean versions.
  It is tested on Lean 4.27.0 through 4.35.0. On Lean before 4.30 the C has
  no source names for variables, so values are named from the source when
  the declaration makes it clear, and are "a temporary" otherwise.

## Options

| option | effect |
|---|---|
| `MODULE...` | only these modules and the modules under them (default: every module of the package) |
| `--deps` | also the C of the package's dependencies in `.lake/packages` |
| `--no-build` | scan what is built; do not run `lake build` first |
| `--ir-dir DIR` | scan the C under DIR instead of `.lake/build/ir`, without building; declaration lines come from the `.ilean` files in `lib/lean` beside DIR, or in `lean` beside it |
| `--src-dir DIR` | with `--ir-dir`: the directory the modules' sources are under (default `.`) |
| `--all` | also appends to strings outside loops |
| `--report FILE` | the run report to check the flags against (default `.lake/leanprof/report.json` when it exists) |
| `--no-report` | do not read a report |
| `--out FILE` | where to write the flags (default `.lake/leanprof/static.json`) |
| `--json` | print the flags as JSON instead of text |
