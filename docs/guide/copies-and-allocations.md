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
usually are), or you use `--core`.

## Copies inside Lean's own libraries (`--core`)

`xs ++ ys` calls `Array.append`, which is compiled into the toolchain's
`libInit.a` and pushes onto `xs` there. If `xs` is still referenced, that
copy happens in code leanprof did not compile. `leanprof run --core EXE`
sees it:

```
copies of non-exclusive values (each one copied the whole value)
  copies       bytes       time  %scope  kind        why            in scope           function  (where)
     500     3.8 MiB  131.0 µs   44.9%  Array       shared         appendShared       Array.append
```

That is [`Examples/CoreCopies.lean`](../../Examples/CoreCopies.lean): without
`--core` the report shows no copies. The copy is charged to the core
function (`Array.append`, which has no position) and to your scope that was
open at the time. With `--allocs` as well, allocations inside the core
library are counted too; on a 4.34.1 compiler project this raised the
count from 4.1 to 5.2 million.

How it works: `--core` copies `libInit.a`, `libStd.a`, `libLean.a`,
`libLake.a` and `libLeanExport.a` with every reference to a redirected
runtime function renamed to leanprof's shim (`llvm-objcopy --redefine-sym`),
and links your program against the copies. The runtime itself (`libleanrt.a`)
is not rewritten, so the shims still call the real functions. The copies
take about 260 MB, and are cached in `.lake/leanprof/core/` per toolchain
and set of options, so the rewrite (a few seconds) happens once.

It needs `llvm-objcopy`: `brew install llvm` on macOS, `apt install llvm`
on Debian and Ubuntu (GNU `objcopy` also works on Linux), or point
`LEANPROF_OBJCOPY` at one.

Expect more noise: Lean's own startup (registering builtin attributes and
environment extensions when the program imports `Lean`) shows up as
`multi-threaded` copies in functions such as `Lean.PersistentHashMap.insert`.
Copies made by Lean's module initializers, which are not exported symbols,
may be named after a nearby function (for example `lean_obj_once_cold`).
With `--allocs`, a large program can have more allocation sites than
leanprof's per-thread table holds (8,192); the report then says how many
events were dropped, and the run is slower.

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
  fix: `acc` only grows (by `push`), so each version stored in `history` is a prefix of the final
       `acc`: store its length and rebuild version k as `acc.extract 0 history[k]!` when it is
       needed. If whole versions must be kept, keep them in a persistent structure (`List`,
       `Lean.PersistentArray`) instead of copying the array at each step.
         history := history.push acc.size
  where: Examples/CopyBug.lean lines 21, 22
  evidence: .lake/build/ir/Examples/CopyBug.c:186 `v___x_36_ = lean_array_push(v_fst_30_, v_i_26_);`, second reference at .lake/build/ir/Examples/CopyBug.c:183
  confidence: high: the IR takes a second reference on every path to the update; source lines matched by text, not positions
```

It reads the C that Lake keeps in `.lake/build/ir/`: that is Lean's IR after
reference counting, with the IR's variable names. In the copying function it
finds each update that can copy (`Array.push`, `set`, `pop`, `swap`,
`String.push`, `++`, `ByteArray`/`FloatArray` updates), where the updated value
comes from, and the `lean_inc` that gives it a second owner. When it
recognises the cause, it prints the fix as Lean code with your names, under
`fix:` (alternatives separated by `or:`). The causes it recognises are the
ones found in real projects; each has a copying and a fixed version in
[`Examples/ExplainPatterns.lean`](../../Examples/ExplainPatterns.lean), and
the tests ([`Tests/ExplainFixes.lean`](../../Tests/ExplainFixes.lean)) check
that `explain` names the cause, that the code it prints is the fixed version
line for line, and that the fixed version makes no copies (Lean 4.35, 400
updates over 10 keys or slots):

| cause (`--json`) | what the IR shows | example | printed fix | copies before → after |
|---|---|---|---|---|
| `nested-array-element` | an element read out of an array that still holds it, updated, written back (lean-compiler-backend's `CFG.build`) | `buckets := buckets.set! i (buckets[i]!.push v)` | `buckets := buckets.modify i (·.push v)` | 390 → 0 |
| `map-value-reinserted` | a value (or a field of one) returned by a hash-map lookup, updated while the map holds it, inserted back (LeanProfiler's `buildRows`, doc-gen4's `process`) | `let members := groups.getD key #[]` then `groups := groups.insert key (members.push v)` | `groups := groups.alter key fun members? => some ((members?.getD #[]).push v)`, or `groups := (groups.erase key).insert key (members.push v)` | 390 → 0 (both) |
| | | `let module := res[key]!` then `res := res.insert key { module with members := module.members.push v }` | `res := res.modify key fun module => { module with members := … }`, or erase first | 390 → 0 (both) |
| | | `match groups[key]? with \| some members => groups := groups.insert key (members.push v)` | erase first: `groups := (groups.erase key).insert key (members.push v)` | 390 → 0 |
| `stored-then-updated` | the value is stored elsewhere (pushed into another array, put in a structure, passed on) and then updated | `history := history.push acc; acc := acc.push i` | when `acc` only grows: `history := history.push acc.size` (version k is `acc.extract 0 history[k]!`); otherwise: update before storing, store less, or keep versions in a `List`/`PersistentArray` | 399 → 0 |
| `multi-threaded-global` | `multi-threaded` copies, and the function uses a global made by `initialize` (LeanProfiler's capture state) | `events.modify (·.push v)` with `initialize events : IO.Ref (Array Nat)` | `let buf ← IO.mkRef #[]`, `buf.modify (·.push v)`, then `events.set (← buf.get)` once | 399 → 0 |
| | | `state.atomically (modify (·.push v))` with `initialize state : Std.Mutex (Array Nat)` | `let mut buf := #[]`, `buf := buf.push v`, then `state.atomically (modify (· ++ buf))` once | 399 → 0 per update |
| `loop-over-updated-array` | the loop's state arrives shared, and the loop is `for x in xs` over the array it updates | `for x in xs do xs := xs.set! j (x + 1)` | `for i in [0:xs.size] do` with `let x := xs[i]!` | 10 → 0 (one full copy per run of the loop) |

Why the global case cannot be fixed with `modify`: a value created by
`initialize` is marked persistent, and what is later stored in a persistent
`IO.Ref` (a `Std.Mutex` keeps its state in one) is marked multi-threaded, as
any thread can reach it. `lean_is_exclusive` is false for multi-threaded
objects, so every update copies, even with a single reference, and `modify`,
`take` or `atomically` change nothing (the copy counter shows 999 multi-threaded copies
for 1,000 `atomically (modify (·.push v))`). The only fix is to update a
value no other thread can reach and publish it once; with several threads,
one buffer per thread merged at the end.

`alter` and `modify` on `Std.HashMap` hand the value over: they set the
bucket to empty before calling your function, so the value has one owner.
`m.getD`/`m[k]!`/`m[k]?` return a second reference to a value the map keeps.

The other readings keep general advice:

| cause (`--json`) | what the IR shows | example | suggested fix |
|---|---|---|---|
| `field-of-kept-structure` | a field is updated while its structure keeps it | `s.name ++ suffix` with `s` kept | take the field out first; for a short string append this copy is just the cost of the result |
| `used-after-update` | the value is still used after the update | `let b := a.push x; f a b` | do the later read first |
| `io-ref-read` | the value comes from an `IO.Ref` that still holds it | `let a ← r.get; r.set (a.push x)` | `r.modify (·.push x)` |
| `shared-on-entry`, `map-over-shared-array` | nothing in the function takes a second reference | `Array.map` over an array a structure still holds; a loop whose initial state is shared | look at the caller; often one copy per call, which is fine |
| `multi-threaded` | a value reachable from a `Task`, or a global not found in the source | | build it in the thread that updates it, per-thread state |

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
the explanation and the fix code to the copy hint's hover.

### For agents: `leanprof explain --json`

`--json` prints the findings on stdout instead of text, in the order the
sites are explained (`rank`, from 1), one finding per explanation of a site:

```json
{"report": ".lake/leanprof/report.json", "sites": 8,
 "findings": [
  {"rank": 7, "function": "groupBy (in Std.Legacy.Range.forIn'.loop)", "symbol": "lp_…",
   "where": "Examples/ExplainPatterns.lean:47", "kind": "Array",
   "cause": "map-value-reinserted",
   "file": "Examples/ExplainPatterns.lean", "lines": [51, 52],
   "why": "`members` is read out of `groups` at line 51 …",
   "fix": "Let the map hand over its only reference: …",
   "fix_code": ["groups := groups.alter key fun members? => some ((members?.getD #[]).push v)",
                "groups := (groups.erase key).insert key (members.push v)"],
   "confidence": "high: …", "strength": 3,
   "copies": 1000, "shared": 990, "multi_threaded": 0, "bytes": 396000,
   "copy_ns": 25750, "estimated_cost_ns": 25750}]}
```

`fix_code` holds alternatives (apply one); each may span several lines
(`\n`), and replaces the line(s) given in `lines`, except for the global case,
whose first and last lines go before and after the loop. It is empty when the
cause is not recognised. `estimated_cost_ns` is the measured time spent
copying at the site, what the fix saves at most besides the copies'
allocation. The autoresearch loop ([research/program.md](../../research/program.md))
reads this to pick its next experiment.

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

## Failed constructor reuse and closure applications

`leanprof run --counters EXE` adds two counters, per function, with the
declaration's file:line:

```
constructor reuse: 2744186 checks, 671240 failed on shared values (24.5%), 16892 on compile-time constants (LEANPROF_ALL=1 shows them)
(a failure allocates a new cell and retains every field instead of updating in place)
    failed     checks   rate  fields  why                      function  (where)
    130130     130130 100.0%     1.0  shared                   LeanCompilerBackend.Statement.definition  (LeanCompilerBackend/IR.lean:228)
     44716      89432  50.0%     2.0  shared                   LeanCompilerBackend.Parser.take  (LeanCompilerBackend/Parser.lean:82)

closure applications: 141709 (exact 141709, partial 0, over-applied 0)
closure targets (the function each applied closure runs)
   applies   share    partial       over  sites  target  (where)
    108064   76.3%          0          0      6  LeanCompilerBackend.Optimize.Cleanup.resolve  (LeanCompilerBackend/Optimize/Cleanup.lean:32)
closure call sites (a hot site is a higher-order call that was not specialized or inlined)
   applies   share    partial       over  call site  (where)  ->  target
     75762   53.5%          0          0  LeanCompilerBackend.Optimize.Cleanup.mapOperation  (LeanCompilerBackend/Optimize/Cleanup.lean:8)  ->  LeanCompilerBackend.Optimize.Cleanup.resolve
```

**Constructor reuse.** When a function takes a constructor value apart and
builds one of the same size (`{ s with x := v }`, `match t with | node l r
=> node l' r`, `.assign i => some ..`), Lean's compiler emits a check:
if the old cell is exclusive it is updated in place, otherwise its fields are
retained, the old value is released and a new cell is allocated. This is the
constructor version of a copy. leanprof counts every check per function and
each failure with the same `why` as copies (`shared`, `multi-threaded`,
`persistent`) and the cell's field count (a failure costs one allocation plus
one increment per field). Read the rate:

- **100% in a function that reads from a structure** (an accessor such as
  `Statement.definition` above, called on elements still held in an array):
  the argument is borrowed from a live container, so it can never be reused.
  The allocation is unavoidable unless the function is given ownership, or
  returns something that does not need a new cell.
- **A loop or state update with a high rate** (a `StateT` state, an
  accumulator record, a tree being rebuilt): an extra reference is keeping
  the old value alive, exactly like a shared array. Find it the same way.

**Closure applications.** Code that calls a function value goes through the
runtime's `lean_apply_N`. leanprof counts each call by its call site and by
the closure's function (its target), and classifies it: `exact` (the
closure gets all its missing arguments and runs), `partial` (too few: a new
closure is allocated) or `over` (too many: it runs, then the result is
applied to the rest). A hot call site is usually a higher-order function
that was not specialized for the function passed to it (above,
`Cleanup.mapOperation (map : Operand → Operand)` called 75,762 times with
`resolve aliases`). `@[specialize]` on the higher-order function, or
`@[inline]` if it is small, lets Lean call the target directly and often
removes the closure allocation as well.

Both counters see only code compiled with them: the precompiled standard
library is not counted unless it was specialized into your module, so a
`List.map f` that calls `f` inside the core library does not show up.

How it works: `lean_is_exclusive` is a `static inline` function in
`lean.h`, so it cannot be renamed with `-D` like the copy functions.
`c/counters.h` is force-included (`-include`) instead: it includes `lean.h`
first (which is `#pragma once`, so the generated file's own include is then
skipped) and then defines `lean_is_exclusive` and `lean_apply_*` as macros
for leanprof's shims. `lean.h`'s own inline functions keep the original, and
in the C that Lean emits the only uses are the reset/reuse checks
(`isSharedCheck = !lean_is_exclusive(x)`). The shims return exactly what
the runtime would. Without `--counters` nothing is redirected and nothing
is counted. To build with the counters yourself, add leanprof's
`counterFlags` to `moreLeancArgs`, or build through the wrapper with
`LEANPROF_COUNTERS=1`. Every check and application then pays a hash-table
update, so leave it off for timing.

## In tests

```lean
Leanprof.expectNoCopies x            -- fails if x copies a shared or multi-threaded value
Leanprof.expectAllocsAtMost 100 x    -- fails if x makes more than 100 allocations
Leanprof.expectNoReuseFailures x     -- fails if a constructor in x could not be reused in place
Leanprof.expectClosureApplicationsAtMost 10 x  -- fails if x applies more than 10 closures
```

These need the test executable built with the flags (`copyFlags`,
`allocFlags`, `counterFlags`), which turns a performance property into a
test. The counts themselves are `Leanprof.copies`, `allocs`,
`reuseChecks`, `reuseFailures` and `closureApplications`.
