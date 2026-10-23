# Copies and allocations

## Why copies matter in Lean

Lean values are immutable, but the runtime updates an `Array`, `ByteArray`
or `String` in place when nothing else refers to it, which makes
`arr.push x` in a loop as cheap as in an imperative language. When another
reference is still alive, the runtime copies the whole value first. A loop
that keeps one extra reference copies on every iteration: quadratic work
that looks linear.

```lean
def buildWithHistory (n : Nat) : Array Nat × Array (Array Nat) := Id.run do
  let mut acc := #[]
  let mut history := #[]
  for i in [0:n] do
    history := history.push acc   -- keeps a reference to acc
    acc := acc.push i             -- so this copies acc every time
  return (acc, history)
```

leanprof reports each such copy with the function that made it, its
declaration's file:line, the bytes and time spent copying, its share of the
enclosing scope, and why the value was not exclusive:

| why | meaning |
|---|---|
| `shared` | another reference was alive |
| `multi-threaded` | the value was stored where other threads can reach it (a global `IO.Ref` or `Mutex`, a `Task` result): Lean never updates such values in place |
| `persistent` | a compile-time constant; harmless, hidden unless `LEANPROF_ALL=1` |

## How to get copy reports

- `leanprof run EXE`: no project changes.
- Or link the library and add leanprof's `copyFlags` (from its lakefile) to
  your executable's `moreLeancArgs` and `-rdynamic` to `moreLinkArgs`, or
  build through the compiler wrapper:
  `LEAN_CC=.lake/packages/leanprof/scripts/leanprof-cc lake build` (delete
  `.lake/**/*.c.o*` first: Lake does not notice a new compiler).

Copies made inside Lean's precompiled standard library are not seen, unless
the code was specialized into your module (loops over ranges and arrays
usually are).

## Why it was shared: `leanprof explain`

The report says *that* a value was shared. `leanprof explain` says where the
second reference comes from, for each copy site of the last report
(`.lake/leanprof/report.json`):

```
$ leanprof run copybug -- 2000
$ leanprof explain
buildWithHistory (in Std.Legacy.Range.forIn'.loop)  Examples/CopyBug.lean:17
  Array copies: 1999 shared, 2 of a constant; 15.3 MiB, 2.64 ms copying
  why: `acc` is stored in `history` at line 21 (`history := history.push acc`) and is updated
       afterwards at line 22 (`acc := acc.push i`): both refer to the same Array, so the Array.push
       copies it.
  fix: Store the value after its last update, store something smaller (an index, a summary), or,
       when every intermediate version is needed, keep them in a persistent structure (`List`,
       `Lean.PersistentArray`) instead of copying the whole value at each step.
  where: Examples/CopyBug.lean lines 21, 22
  evidence: .lake/build/ir/Examples/CopyBug.c:186 `v___x_36_ = lean_array_push(v_fst_30_, v_i_26_);`, second reference at .lake/build/ir/Examples/CopyBug.c:183
  confidence: high: the IR takes a second reference on every path to the update; source lines matched by text, not positions
```

It reads the C that Lake keeps in `.lake/build/ir/`: that is Lean's IR after
reference counting, with the IR's variable names. In the copying function it
finds each update that can copy (`Array.push`, `set`, `pop`, `swap`,
`String.push`, `++`, `ByteArray`/`FloatArray` updates), where the updated value
comes from, and the `lean_inc` that gives it a second owner. The patterns it
recognizes, with the fix it suggests:

| what the IR shows | example | suggested fix |
|---|---|---|
| the value is stored elsewhere (pushed into another array, put in a structure, passed on) and then updated | `history := history.push acc; acc := acc.push i` | update before storing, store less, or keep versions in a `List`/`PersistentArray` |
| an element is read out of an array that still holds it, updated, and written back | `xs := xs.set! i (xs[i]!.push v)` | `xs := xs.modify i (·.push v)` (printed with your names) |
| a field is updated while its structure keeps it | `s.name ++ suffix` with `s` kept | take the field out first; for a short string append this copy is just the cost of the result |
| the value is still used after the update | `let b := a.push x; f a b` | do the later read first |
| the value comes from an `IO.Ref` that still holds it | `let a ← r.get; r.set (a.push x)` | `r.modify (·.push x)` |
| nothing in the function takes a second reference | `Array.map` over an array a structure still holds; a loop whose initial state is shared | look at the caller; often one copy per call, which is fine |
| `multi-threaded` | a value reachable from a `Task`, a global `IO.Ref` or `Mutex` | build it in the thread that updates it, per-thread state |

Each explanation states its confidence: *high* when the IR takes the second
reference on every path to the update, *medium* on some paths, *low* when the
reference is not taken in the function at all. IR has no source positions, so
the source lines are found by matching the declaration's text against what the
IR shows (the receiver of `.push`, the container of `xs[i]!`, the field of
`s.f ++`), and say so. The emitted C line is always given, so the claim can be
checked. Copies made in precompiled library code have no C to read.

### Recording the second reference at run time: `--why`

`leanprof explain --why EXE [-- ARGS]` first runs `leanprof run EXE` with
`LEANPROF_WHY=1`. The build then wraps `lean_inc` (after `lean.h`, through
[`c/leanprof_why.h`](../../c/leanprof_why.h)): when an Array or String goes from
one reference to two, the C function, file and line are noted in a small
per-thread table keyed by the object's address, and when that object is then
copied, the copy is counted against that increment. This finds second
references taken in other functions, where the static reading has to say
"from the caller":

```
  recorded at run time (46633 of 46633 shared copies; where the copied value got its second reference):
    46633× `incoming` passed to `...Array.mapMUnsafe.map...` in LeanCompilerBackend.Optimize.function
          (in Array.forIn'Unsafe.loop) (LeanCompilerBackend/Optimize.lean:67), line 73:
          `let values := phi.incoming.map (fun (_,v) => value facts phi.width v)` (or 1 more)
```

It costs a check after every reference-count increment of the instrumented
code (about 7% more wall time on lean-compiler-backend). The table is lossy and addresses
are reused after frees (tag and capacity are checked), and increments made
inside Lean's precompiled library or `lean.h`'s inline functions are not seen,
so each line is "the last recorded increment". The records go to
`.lake/leanprof/why.json` (`LEANPROF_WHY_JSON`).

`leanprof explain` also writes `.lake/leanprof/explain.json`; `#leanprof` adds
the explanation to the copy hint's hover.

## Allocations

`leanprof run --allocs EXE` also counts every allocation made by compiled
Lean code, per scope (with and without children) and per call site:

```
allocations: 11946202, 266.6 MiB (from compiled Lean code; frees are not tracked)
function                                     allocs       bytes    share  in scope             where (declaration)
LeanCompilerBackend.Parser.tokenize (in WellFounded.opaqueFix₃)    4066775    88.8 MiB    33.3%  -    LeanCompilerBackend/Parser.lean:20
LeanCompilerBackend.Parser.peek              910550    16.2 MiB     6.1%  -                    LeanCompilerBackend/Parser.lean:79
```

Frees happen inside the runtime and are not seen, so this is allocation
volume, not live memory. It is off by default because every allocation then
pays a small cost.

## In tests

```lean
Leanprof.expectNoCopies x            -- fails if x copies a shared or multi-threaded value
Leanprof.expectAllocsAtMost 100 x    -- fails if x makes more than 100 allocations
```

These need the test executable built with the flags (`copyFlags`,
`allocFlags`), which turns a performance property into a test.
