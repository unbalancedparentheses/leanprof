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
