# Memory, frees and `leanprof stat`

Four things, from least to most effort:

| | how | cost | gives |
|---|---|---|---|
| Summary | `leanprof stat EXE` | probes for copies, allocations and frees | one screen: time, CPU, peak memory, allocations, copies, frees, tasks, top scopes |
| Memory over time | always on | one memory reading per ms, at scope exits | peak memory, peak and rise per scope, a memory track in the timeline |
| Frees | `--frees` / `LEANPROF_FREES=1` / `freeFlags` | every freeing call is timed | objects freed and freeing pauses per call site and scope, atomic decrements of shared-between-threads objects |
| Retained memory | `run --retained` | every object followed to its free; heap walks | live objects per allocation site at the peak and at exit, what holds them, sites that keep growing ([below](#retained-memory-what-holds-it)) |

## `leanprof stat`

```
leanprof stat [--auto | --auto-all] [--no-allocs] [--no-frees] [--trace FILE] [--json FILE] [--keep] EXE [-- ARGS]
```

builds `EXE` like `leanprof run` (copies, tasks and waits, plus allocations
and frees unless turned off), runs it, and prints a summary like GHC's
`+RTS -s` or Julia's `@time`. On
[lean-compiler-backend](../case-studies/lean-compiler-backend.md),
compiling zlib's `deflate`:

```
leanprof stat: lcb --target aarch64-macos --optimize --allocate zlib/deflate.ssa -o /tmp/x.s   (exit code 0)

  wall         653.40 ms  (2.52 s including process start and the report)
  CPU          621.22 ms user + 31.67 ms system (1.00 cores)
  peak memory  71.33 MiB resident, 31.88 MiB committed by Lean's allocator
  allocations  4,129,146 objects, 93.98 MiB (by compiled Lean code)
  copies       37,980 of shared values, 1.08 MiB, 908.37 µs
  frees        4,067,898 objects in 2,481,440 cascades, 22.85 ms (pause p99 42 ns, max 266.92 µs)
               0 atomic decrements of multi-threaded objects
  tasks        none spawned
  top scopes   none (mark code with profile!, or pass --auto)
```

- **wall** and **CPU** cover the program, from leanprof's start (before
  `main`) to its exit, not process launch or leanprof's own report. The
  time in parentheses includes both, for a warm start: the freshly linked
  binary is first launched once without running it (leanprof's runtime
  exits as it loads), and that launch is printed on the next line. On
  macOS the first launch of a new binary is far slower (the system checks
  it): 1.1 s for `copybug` (61 MB) against 24 ms for the next, 2.3 s for
  concrete's 106 MB compiler.
  CPU is user and system time of all threads, so `cores` above 1 means
  the program ran in parallel.
- **peak memory**: see below.
- **allocations**, **copies** and **frees** count only what compiled Lean
  code does: allocations and frees inside Lean's precompiled standard
  library are not seen.
- **top scopes** are your `profile!` scopes, or every function with
  `--auto`.

The probes slow the program down (allocations and frees are counted on every
call; `--no-allocs --no-frees` removes them). On the run above, wall time
with and without them was within run-to-run noise (650 to 715 ms). The JSON
report is saved as with `run` (`.lake/leanprof/report.json` by default).

## Memory over time

Lean's runtime allocates through [mimalloc](https://github.com/microsoft/mimalloc),
which keeps counters of the memory it has **committed** (asked the OS for
and not returned). leanprof reads them with `mi_process_info` at start, at
exit, and when a scope exits at least 1 ms after the previous reading. That
is cheap enough to be always on: a scope exit checks one timestamp, and a
reading costs about a microsecond once per millisecond. It gives:

```
memory: peak 70.4 MiB resident, peak 31.9 MiB committed by Lean's allocator (31.9 MiB at exit), 185 samples
memory while scopes were active (committed; sampled about every 1 ms at scope exits)
       peak    max rise  sampled  scope  (where)
   23.8 MiB    13.8 MiB        1  LeanCompilerBackend.Parser.parseModule  (LeanCompilerBackend/Parser.lean:692)
   23.8 MiB    13.8 MiB       13  LeanCompilerBackend.Parser.tokenize (in WellFounded.opaqueFix₃)  (LeanCompilerBackend/Parser.lean:20)
   23.8 MiB    13.8 MiB        1  main  (Main.lean:295)
   ...
   23.8 MiB     4.4 MiB        7  LeanCompilerBackend.Parser.separator  (LeanCompilerBackend/Parser.lean:16)
```

That is `leanprof run --auto` on the same compile: parsing (tokenizing) is
where committed memory grows most, by 13.8 MiB, and nothing after it raises
the level until the last millisecond, when 8 MiB more are committed inside
precompiled library code with no scope exit to take a reading (so the per
scope peaks stop at 23.8 MiB while the process peak is 31.9 MiB).


- **peak resident** is the OS's peak resident set size of the whole process
  (`getrusage`): Lean's heap, the binary, the C library's allocations, and
  leanprof's own tables and timeline buffers (with `--trace` or `--auto`
  these add tens of MiB; the run above used `--auto`).
- **peak committed** is mimalloc's own peak: memory of Lean objects plus
  the free space mimalloc keeps around. It is the better measure of the Lean
  program, but it is not live data: freed objects stay committed until
  mimalloc returns their pages to the OS, so it falls late and only in
  steps. It can exceed resident memory when committed pages were never
  touched.
- **peak** per scope is the largest committed value read while a call of
  the scope was running, and **max rise** the largest increase over the
  reading just before such a call started; a call shorter than the time
  since that reading has no rise (the reading would also count what was
  allocated before the call). Scopes are listed by rise. A
  scope with no reading during any of its calls (calls shorter than the
  gap between readings, or with no scope exiting inside them) is not
  listed; readings are taken at scope exits, so a long stretch of code with
  no scope boundaries has no readings either. Values are process-wide:
  another thread's allocations count for every scope running at the time.
- With `--trace`, the timeline has a **memory (MiB)** counter track with the
  committed and resident series.

`Leanprof.peakMemory : BaseIO Nat` reads the peak committed bytes so far
(and takes a reading).

## Frees

Lean has no garbage collector: an object is freed when its reference count
drops to zero, recursively, on the thread that dropped the last reference.
Dropping the last reference to a large structure (an old environment, a
syntax tree, a big map) frees all of it at once, which is Lean's version of
a GC pause. Compiled code calls the runtime's `lean_dec_ref_cold` exactly
then, and also for every decrement of an object shared between threads
(those have negative counts and are decremented atomically, which is slower
and contends between cores).

With `leanprof run --frees`, `LEANPROF_FREES=1` through the compiler
wrapper, or leanprof's `freeFlags` in `moreLeancArgs`, those calls go
through leanprof, which records per call site (the compiled function that
dropped the reference) and innermost scope:

- **cascades**: how many times dropping a reference freed something;
- **objects**: how many objects those cascades freed;
- **pause**: how long each cascade took, as p50, p99 and max;
- **mt decs**: atomic decrements of objects shared between threads.

```
frees: 4067898 objects in 2481440 cascades took 24.8 ms (pause p50 0 ns, p99 42 ns, max 264.0 µs); 0 atomic decrements of multi-threaded objects
  cascades    objects       time       p50       p99       max    mt decs  in scope           function  (where)
   1141902    1141902     8.2 ms      0 ns     42 ns  23.1 µs          0  -                  LeanCompilerBackend.Parser.tokenize (in WellFounded.opaqueFix₃)  (LeanCompilerBackend/Parser.lean:20)
     92132     695154     1.7 ms      0 ns     42 ns  11.0 µs          0  -                  LeanCompilerBackend.validIdentifier  (LeanCompilerBackend/IR.lean:24)
    151918     151918     1.1 ms      0 ns     42 ns    750 ns          0  -                  LeanCompilerBackend.validateFunction (in Std.Legacy.Range.forIn'.loop)  (LeanCompilerBackend/Validate.lean:126)
     27530     197328     1.1 ms      0 ns    292 ns  57.2 µs          0  -                  LeanCompilerBackend.validateFunction (in Array.forIn'Unsafe.loop)  (LeanCompilerBackend/Validate.lean:126)
```

On that compile, freeing is 25 ms of 650 ms. The tokenizer frees 1.14
million objects one at a time (each cascade frees one object: short-lived
values that die right after they are made), 28% of all frees.
`validIdentifier` frees 7.5 objects per cascade. The longest pause, about
240 µs, is a single cascade of 89,435 objects started in `parseModule`;
with `--trace` it shows up as a
`free 89435 objects in LeanCompilerBackend.Parser.parseModule` slice.
`in scope` is `-` because that program has no `profile!` scopes; with
`--auto` it is the innermost function.

The JSON report has the same per site (`frees.sites`) and per scope
(`frees.scopes`), and with `--trace` every cascade of 100 µs or more is a
slice named `free N objects in FUNCTION` on its thread, inside the scope that
dropped the reference. `Leanprof.frees : BaseIO Nat` is the number of objects
freed so far, for tests.

What the numbers mean, and do not:

- **Objects freed are counted, not observed.** The runtime frees
  internally, so before each cascade leanprof walks the structure the way
  the runtime will (an object dies when all its references come from dying
  objects) and counts it. Tasks, promises and external objects count as one
  object each. For objects shared between threads the count is a snapshot
  and can be off if another thread drops a reference at the same moment.
- **Pauses are slightly optimistic for small structures**: the counting walk
  runs first and warms the cache. For structures larger than the cache,
  which are the ones with long pauses, the walk evicts what the free needs
  first, so the effect is small.
- The walk doubles the work of each free, and every free and thread-shared
  decrement is timed, so `--frees` slows programs that free a lot and
  inflates the times of the scopes that free (lean-compiler-backend: 1.40
  times slower than plain, 7.4 million cascades; the `copy` benchmark,
  which frees arrays of shared arrays, 2.8 times). Use it to find where
  frees go, and plain runs for timing.
- Only compiled code of your executable is seen (as for copies): frees
  started inside the precompiled standard library, and atomic *increments*
  (inlined in `lean.h`), are not.
- On Apple Silicon the clock ticks every 41.7 ns, so most single-object
  frees read as 0 or 42 ns; totals over many frees are fine.

A Lean-specific use: values passed to a task are marked multi-threaded, and
from then on every reference-count change on them is atomic. A large
`mt decs` count at a site in a parallel program names the code paying for
that.

## Retained memory: what holds it

```
leanprof run --retained EXE [-- ARGS]
```

follows every object compiled Lean code allocates from its allocation to
its free (it implies `--allocs` and `--frees`). On
[Examples/Retained.lean](../../Examples/Retained.lean), which keeps memory in
four known ways:

```
retained memory (objects compiled Lean code allocated, by allocation site; --retained)
  live: peak 1.8 MiB in 80609 objects at 258.1 ms; at exit 1.8 MiB in 80608 objects
  frees not seen: 3 objects (107 B) were freed in precompiled code or the runtime; found when their address was reused or a walk read them
    at peak    objects     at exit    objects  trend     in scope           function  (where)
    1.8 MiB      80001     1.8 MiB      80000  growing   -                  RetainedTest.logPairs  (Examples/Retained.lean:43)
    7.0 KiB        300     7.0 KiB        300            -                  RetainedTest.hookCells  (Examples/Retained.lean:28)
    4.7 KiB        200     4.7 KiB        200            -                  RetainedTest.lazyCells  (Examples/Retained.lean:33)
    4.4 KiB        101     4.4 KiB        101            -                  RetainedTest.keepPairs  (Examples/Retained.lean:21)
  growing: RetainedTest.logPairs kept rising over the second half of the run, 948.6 KiB -> 1.8 MiB (rose in 23 of 23 samples)

what keeps it alive (exit heap walk at 273.5 ms, 1.9 MiB of tracked objects live; took 10.7 ms)
     1.8 MiB  80000 constructor from RetainedTest.logPairs (Examples/Retained.lean:43)
              held by IO.Ref from RetainedTest.initFn <- global RetainedTest.log (Examples/Retained.lean:14)
              fix: Kept in a global IO.Ref (an `initialize` value): it lives until the Ref is set to something else, ...
     7.0 KiB  300 constructor from RetainedTest.hookCells (Examples/Retained.lean:28)
              held by closure of RetainedTest.scenario <- IO.Ref from ... <- global RetainedTest.hook (Examples/Retained.lean:12)
              fix: Captured by a closure, which keeps every value it captured alive as long as it lives. ...
     4.7 KiB  200 constructor from RetainedTest.lazyCells (Examples/Retained.lean:33)
              held by Thunk from RetainedTest.scenario <- IO.Ref from RetainedTest.initFn <- global RetainedTest.lazy
     2.3 KiB  100 constructor from RetainedTest.keepPairs (Examples/Retained.lean:21)
              held by Array from RetainedTest.keepPairs <- IO.Ref from ... <- global RetainedTest.cache
```

- **Live per site.** Each allocation site (the compiled function, and the
  innermost `profile!` scope) has its live objects and bytes at the
  program's peak of tracked live bytes, at exit, and its own largest. A
  growing array or string keeps the site that made it (the runtime moves it
  into a larger object); an array or string copied from a shared one is
  charged to the copying call.
- **What holds it.** A heap walk reads every tracked object and follows
  constructor fields, array elements, closure arguments, thunks, refs and
  task results. Each object gets one holder (the first found; an object
  shared by two holders shows under one), and each chain ends at a root: a
  global variable (the program's data, scanned for pointers and named from
  its symbols; Lean's `initialize` values and closed terms are globals), a
  local on the stack of the walking thread (scanned conservatively, so a
  stale word can look like a local; named by the function whose frame holds
  it), a module constant, or nothing leanprof can see (another thread's
  stack, the runtime's own structures, an object precompiled code made).
  Runs of one kind of holder (the cells of one list) count once, and a chain
  shows the four holders nearest the object.
- **When walks run.** At exit; at `Leanprof.retainedSnapshot`, which a server
  or a test can call at a moment worth seeing (the first eight are kept);
  and near the peak: when tracked live bytes first pass 256 KiB and then each
  25% above the last walk, keeping the walk that saw the most. Walks near the
  peak only run while one thread uses tracked objects (Lean 4.35 runs `main`
  on a second thread, a hand-over that counts as one), never after a task
  was spawned (another thread could free what a walk reads), and only while
  walks so far took under a quarter of the run (`LEANPROF_RETAINED_WALKS=all`
  lifts the limit, `=0` turns them off). The report says why there was none.
- **Growth.** Every site's live bytes are sampled over the run (64 samples,
  every 20 ms and then half as often each time they fill;
  `LEANPROF_RETAINED_SAMPLE_MS`). A site is *growing* when its live bytes
  rose in two of three samples of the second half of the run, by at least
  64 KiB and 10%, and end near their largest: in a server, a leak. A batch
  program that builds its result until it exits grows too. `leanprof top
  --retained` shows the sites holding the most, with their change per second.
- **Fixes.** Chains with a known cause get one: a value kept in a global
  `IO.Ref` (it lives until the Ref is set to something else), a forced
  `Thunk` (it keeps its value), a closure (it keeps what it captured), a
  `Task` (it keeps its result).

The same is in the JSON report (`retained`: totals, `sites`, `walks` with
`paths`, each with `held_by`, `root` and `hint`), `leanprof explain`
(RETAINED and GROWING findings), the HTML report's Retained tab and the MCP
server (`run` with `retained`, `hot` with kind `retained`, `report`,
`explain`). `Leanprof.retainedLive` gives the tracked live bytes so far
(`none` when not tracking).

What it cannot see, and says:

- **Frees inside precompiled code.** Lean's precompiled libraries and the
  runtime free objects that compiled code made (a list passed to
  `List.toArray`, a value a library function consumes). leanprof does not
  see those frees. Such an object stays in its table until its address is
  allocated again through the shims, or a walk reads its header and finds a
  freed block; both count as `frees not seen`, per site. Until then the
  object counts as live, so the peak can be an overestimate. `--core` also
  routes the precompiled libraries' frees through leanprof.
- **Objects made by precompiled code** are not tracked, except the ones the
  runtime makes for a call from compiled code (`Array.replicate`,
  `Array.mk`, `Array.toList`, `String.mk`, `String.data`, `IO.mkRef`, a
  grown array or string), which count at that call. A chain through an
  untracked object still shows it, as `(made where leanprof does not look)`.
- **A constructor cell reused in place** (Lean's reset/reuse) keeps the site
  that first allocated it.
- **Sites are compiled functions.** The C compiler inlines small functions
  into their callers, so a two-line helper's allocations can show under its
  caller.
- **Threads.** Live counts are exact for a single thread; with several,
  each site's value at the peak can be off by what another thread changed
  at that moment.

Cost: every allocation and free also updates a table of live objects, about
25 ns each on top of `--allocs --frees`, and a walk takes about 150 ns per
live object (M5 Max). A program making 4 million allocations, 1.8 million of
them alive at exit (`--allocs --frees` 0.074 s, plain 0.043 s), took 0.45 s
with `--retained`, most of it the exit walk. The table takes 23 to 46 bytes
per live object.
