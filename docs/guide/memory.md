# Memory, frees and `leanprof stat`

Three things, from least to most effort:

| | how | cost | gives |
|---|---|---|---|
| Summary | `leanprof stat EXE` | probes for copies, allocations and frees | one screen: time, CPU, peak memory, allocations, copies, frees, tasks, top scopes |
| Memory over time | always on | one memory reading per ms, at scope exits | peak memory, peak and rise per scope, a memory track in the timeline |
| Frees | `--frees` / `LEANPROF_FREES=1` / `freeFlags` | every freeing call is timed | objects freed and freeing pauses per call site and scope, atomic decrements of shared-between-threads objects |

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
