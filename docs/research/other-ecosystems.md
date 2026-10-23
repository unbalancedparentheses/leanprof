# Ideas from other ecosystems' profilers, ranked for leanprof

Research note, 2026-10-23. Question: which ideas from profilers in C/C++,
Rust, Zig, Go, OCaml, Haskell, JVM, .NET, JavaScript, Python and Julia are
missing from leanprof? Ranked by value to Lean users divided by effort.

Scope rules followed:

- Nothing already in leanprof is re-suggested unless the version here is
  materially better. Overlaps with [ROADMAP.md](../../ROADMAP.md) are named.
- Claims about Lean's runtime were checked against the v4.35.0 toolchain
  (`include/lean/lean.h`, `include/lean/mimalloc.h`, `nm` on
  `lib/lean/*.a`, and the C that Lean emits for this repo). The checks are
  listed in [Facts checked locally](#facts-checked-locally).
- Claims about other tools were checked against the linked pages during this
  session. Anything not confirmed is marked **(unverified)**.
- **[Lean change]** marks ideas that need changes to Lean itself.
  Everything else uses leanprof's existing mechanisms: `-D` redirection
  in `scripts/leanprof-cc`, clang instrumentation, samply, Lake, and the
  Lean frontend.

## Facts checked locally

These facts are what most of the ideas below rely on.

1. **Reset/reuse is visible in the emitted C.** The compiler's constructor
   reuse appears as `v_isSharedCheck = !lean_is_exclusive(x); if (... == 0)
   { reuse } else { lean_inc(fields); lean_dec(x); x = lean_box(0); }`. Seen
   in `.lake/build/ir/LeanprofCli.c`, for example lines 1303-1315.
2. **`lean_is_exclusive`, `lean_inc_ref_n` and `lean_dec_ref` are `static
   inline` in `lean.h`.** `-D` cannot hook them, because it also renames the
   header's definition. They can be hooked in user code with a
   **post-include macro**: `lean.h` uses `#pragma once`, so `leanprof-cc`
   can pass `-include lean/lean.h -include leanprof_post.h`. The second
   header then defines `#define lean_is_exclusive(o)
   leanprof_is_exclusive(o, __func__)`. The header's own inline bodies are
   already parsed and stay unchanged. Every use in the emitted C after that
   gets the C function name for free, with no unwinding. **(Mechanism
   reasoned from the header, not prototyped.)**
3. **`lean_dec_ref_cold` is an out-of-line `LEAN_EXPORT` function.** The
   inline `lean_dec_ref` calls it when the count is ≤ 1. Multi-threaded
   objects have a negative `m_rc` (lean.h lines 133-135, `lean_is_st` is
   `rc > 0`), so it is also called for **every decrement of a thread-shared
   object**. It is redirectable with `-D` like the copy functions.
   `libInit.a` alone references it from 653 places.
4. **The runtime uses mimalloc 3.4.5** (`LEAN_MIMALLOC` in `config.h`,
   `MI_MALLOC_VERSION 30405`). `libleanrt.a` exports `mi_process_info`,
   `mi_heap_visit_blocks`, `mi_heap_main`, `mi_stats_get` and
   `mi_stats_get_json`. Under mimalloc, small objects keep their size in
   `m_cs_sz` (lean.h line 147).
5. **These runtime entry points are exported and so redirectable:**
   `lean_apply_1..16`, `lean_apply_m`, `lean_task_map_core`,
   `lean_task_bind_core`, `lean_io_basemutex_lock`, `lean_io_condvar_wait`,
   `lean_io_promise_*`, `lean_mark_mt` and `lean_mark_persistent`.
6. **The precompiled core library can be rewritten without rebuilding
   Lean.** `llvm-objcopy --redefine-sym _lean_dec_ref_cold=_leanprof_dec_ref_cold
   libInit.a out.a` worked on the Mach-O archive: all 653 undefined
   references were renamed and none of the old name remained. `libInit.a`
   also references `lean_array_push` (70) and
   `lean_copy_expand_array_nonlinear` (20). **Linking a program against the
   rewritten archive was not tested.**
7. **Lake writes `.ir` files** (olean format) for module-system packages,
   for example `.lake/build/lib/lean/Leanprof.ir`. They are the obvious input
   for static IR analysis. **(Contents not inspected.)**

## Ranking at a glance

| # | Idea | Borrowed from | Effort | Lean change? |
|---|---|---|---|---|
| 1 | Failed constructor reuse, per function | GHC ticky-ticky; Lean's own reset/reuse | 0.5–1 day | no |
| 2 | Freeing pauses and thread-shared refcount traffic, per site | OCaml olly `gc-stats` latency; GHC `+RTS -s` | 0.5–1 day | no |
| 3 | Core library made visible by rewriting archive symbols | GNU ld `--wrap`, heaptrack-style interposition | 1–3 days | no |
| 4 | Memory over time, peak per scope, `leanprof stat` | Tracy plots, olly counters, GHC `+RTS -s`, Julia `@time`, poop | 1 day | no |
| 5 | "Who shared it": last-share site recorded for each copied value | GHC retainer profiling, Chrome DevTools retainers | 2–3 days | no |
| 6 | Live view through Tracy's C client | Tracy, Zig's Tracy bindings, puffin_http | 2–4 days | no |
| 7 | Closure-application and specialization counters | GHC ticky-ticky, Go PGO | 1–2 days | no |
| 8 | Flight recorder and `leanprof dump <pid>` | Go 1.25 flight recorder, py-spy `dump` | 1–2 days | no |
| 9 | Heap census by object kind and closure, no profiling build | GHC `-hT`/`-hi`, ghc-debug | 3–5 days (risky) | no, if mimalloc cooperates |
| 10 | Task work/span, parallelism and critical path | Cilkscale, ThreadScope, cargo `--timings` | 2–4 days | no |
| 11 | Instruction counts in `compare`/`measure` | gungraun (iai-callgrind), CodSpeed, poop | 2–4 days (Linux) | no |
| 12 | Static copy predictor on the IR | JET.jl `@report_opt` | 1–2 weeks | no |
| 13 | Sampled allocations with stacks and lifetimes | OCaml memtrace, async-profiler `--alloc`, Julia `Profile.Allocs`, heaptrack | 3–5 days | partly |
| 14 | Build timeline and module critical path | cargo `--timings` | 2–4 days | maybe |
| 15 | Causal profiling | coz, JCoz, Cozgo | days (wrapper) / 2–3 weeks (native) | no |
| 16 | pprof export | Go pprof, Pyroscope | 1 day | no |
| 17 | Clang PGO of the emitted C | Go PGO, clang PGO | 1–2 days to measure | no |
| 18 | Lock and condition-variable contention | Go mutex/block profiles, async-profiler `lock` | 1 day after #3 | no |

---

## 1. Failed constructor reuse, per function

**What it is.** For every function, count how often a constructor value
could have been updated in place but was not, because it was shared at
runtime. Each failure means the code allocates a fresh object and increments
every field instead of reusing the old one.

**Where it comes from.** GHC's ticky-ticky counters give per-closure entries
and allocation counts, and flag dictionary arguments to show where
specialisation failed
([GHC user guide, ticky](https://downloads.haskell.org/ghc/latest/docs/users_guide/profiling.html)).
The reset/reuse optimisation itself is Lean's, from
[Counting Immutable Beans](https://arxiv.org/abs/1908.05647). No other tool
reports reuse failures because no other mainstream runtime has them.

**Why it matters for Lean.** leanprof already catches the big case: copies
of arrays and strings. The same failure happens, more quietly, on every
`{ s with field := v }`, every `match` that rebuilds a node, and every state
update in a `StateT` when the state is also held elsewhere. Today that cost
shows up only as "allocation" or "freeing" in the sampled runtime breakdown,
with no explanation. It is the constructor version of the copy report, and it
answers "why does my tree or record update allocate?"

**How to build it.**

- Add the post-include macro (fact 2) to `leanprof-cc`:
  `lean_is_exclusive(o)` becomes `leanprof_is_exclusive(o, __func__)`.
- The hook evaluates the real check. On `false` it bumps a per-thread counter
  keyed by (C function name, `lean_ptr_tag`, `lean_ctor_num_objs`), and
  records why: thread-shared, persistent or rc > 1. This uses the same
  vocabulary as the copy report.
- Demangle with the existing demangler, then add file:line from `.ilean`.
- Add a "reuse failures" table next to the copies table, an
  `expectNoReuseFailures` assertion beside `expectNoCopies`, and exact counts
  in `compare`.

**Caveats.** `lean_is_exclusive` is also emitted for `isExclusiveUnsafe`, so
the hook should report "reset sites" only where the check feeds
`isSharedCheck`. Reuse inside the precompiled core library is invisible,
because the check is inlined there. The cost of a reuse failure is
O(fields), not O(size), so rank the sites by count × field count, not by
bytes.

**Effort.** Half a day to a day.

## 2. Freeing pauses and thread-shared refcount traffic, per site

**What it is.** Redirect `lean_dec_ref_cold` (fact 3) and time each call.
This gives three things:

- a latency histogram of **freeing cascades**: dropping the last reference
  to a large tree frees it recursively inside the runtime;
- the site in user code where the last reference was dropped;
- the number of **decrements of thread-shared objects** per site. These are
  atomic and contended, and they go through the same cold path.

**Where it comes from.**

- OCaml's olly `gc-stats` reports GC time and a GC tail-latency profile, with
  latency percentiles
  ([runtime_events_tools](https://github.com/tarides/runtime_events_tools)).
- GHC's `+RTS -s` summary reports GC time.
- perf c2c-style contention hunting is the general idea for the atomic
  traffic. Not checked in this session.

Lean has no GC, but frees are its GC pauses: they are synchronous and land
on whoever drops the last reference.

**Why it matters for Lean.**

- Large frees are a classic surprise in compilers, provers and servers
  written in Lean. A request handler drops an old environment, and the next
  request stalls. leanprof's sampled breakdown shows "freeing" in total, but
  not where or how spiky it is.
- `lean_mark_mt` runs on every value passed to a Task. After that, every
  inc/dec on the value is atomic. This is a Lean-specific way that adding
  parallelism slows a program down, and no other tool can name the site.

**How to build it.**

- Add `-Dlean_dec_ref_cold=leanprof_dec_ref_cold`.
- In the hook, branch on `lean_is_mt(o)`:
  - thread-shared: count it, and call through if needed;
  - otherwise it is a free: read the clock, call the real function, read the
    clock, and add the time to a log-bucket histogram per caller.
- Get the caller from `__builtin_return_address(0)` symbolized at exit, or
  from the leanprof scope stack.
- Emit Perfetto slices for frees over a threshold (for example 100 µs), and
  give the root object's tag and its size from `m_cs_sz`.
- Report p50/p99/max free pause per site, and thread-shared decrements per
  site and object kind.

**Caveats.**

- `dec_ref_cold` runs on every last-reference drop, which is very frequent.
  Make the timing opt-in (`--frees`). Counting alone is cheap.
- To keep it cheap, time only tags that can cascade: constructors, arrays,
  closures and thunks, not strings or scalar arrays.
- The atomic increments of thread-shared objects are inlined in `lean.h`, so
  this sees decrements only. Increments need the post-include macro on
  `lean_inc_ref_n` (user code only).
- With #3, decrements in the core library become visible too.

**Effort.** Half a day to a day.

## 3. Core library made visible by rewriting archive symbols

**What it is.** Copy `libInit.a`, `libStd.a` and `libLean.a`, rename the
runtime symbols leanprof already redirects with `llvm-objcopy
--redefine-sym old=new` (fact 6), and link the program against the
rewritten copies. This is the static-archive equivalent of GNU ld's
`--wrap=symbol`, which only exists on ELF linkers.

**Where it comes from.** Interposition is how heaptrack, bytehound,
async-profiler `nativemem` and Scalene see allocations or copies in code
they did not compile:

- heaptrack attaches by "injecting heaptrack into application via GDB"
  ([heaptrack](https://github.com/KDE/heaptrack));
- async-profiler's `nativemem` mode records `malloc`/`free`
  ([profiling modes](https://github.com/async-profiler/async-profiler/blob/master/docs/ProfilingModes.md)).

Those tools interpose dynamic libraries. Lean links its runtime and core
library statically, so the same idea has to be applied at link time.

**Why it matters for Lean.** It closes a known gap: copies inside
precompiled core code, such as `Array.map`, `List.toArray`, `HashMap`
resizing and `String` functions, become visible. They are attributed to the
user scope that called them, through leanprof's scope stack, and to the core
function, through the return address. Many real copy bugs happen when user
code passes a shared array into a core function that updates it. The same
rewrite gives #2 and #18 core coverage, plus allocation counts inside core
functions.

**How to build it.**

- In `leanprof run`, after the build, produce rewritten archives in a cache
  directory keyed by toolchain and leanprof version.
- In `leanprof-cc`'s link branch, replace `-lInit -lStd -lLean` (or the
  paths leanc passes) with the rewritten ones.
- `llvm-objcopy` is not shipped in the Lean toolchain (it has `ld64.lld` and
  `llvm-ar`). Either require it from the system or nix, or write a small
  Mach-O/ELF symbol-string patcher: the rename only rewrites string-table
  entries.

**Caveats.** Internal calls inside `libleanrt.a` itself, such as
`lean_array_push` calling the copy routine in the same object file, cannot be
renamed this way. That does not matter here, because leanprof already wraps
the entry points. The link step must be tested. Using shorter names than the
originals (for example `_lpf_dec_ref_cold`) avoids growing the string table,
if a hand-written patcher is used.

**Effort.** One to three days. This is the enabler for several other ideas
and closes a known gap, so it ranks this high despite being plumbing.

## 4. Memory over time, peak per scope, and `leanprof stat`

**What it is.**

- A background thread samples `mi_process_info` (current and peak RSS,
  current and peak commit, page faults) every 1–10 ms. These become a
  counter track in the Perfetto export and a "peak commit while active"
  column per scope.
- A new `leanprof stat -- prog` command prints a one-screen summary: wall,
  user and sys time, peak RSS, allocations, copies and bytes copied, reuse
  failures (#1), freeing time (#2), tasks spawned and maximum concurrency.

**Where it comes from.**

- GHC's `+RTS -s` and olly `gc-stats` print wall, CPU and GC time, latency
  percentiles and allocation counts
  ([runtime_events_tools](https://github.com/tarides/runtime_events_tools)).
- Julia's `@time` prints allocations and GC % in one line
  ([Julia profiling manual](https://docs.julialang.org/en/v1/manual/profile/)).
- poop reports peak memory next to hardware counters
  ([poop](https://github.com/andrewrk/poop)).
- Tracy plots arbitrary values over time.
- `olly trace --emit-counters` adds heap occupancy counters to traces.

**Why it matters for Lean.** It partly closes the "no live or peak memory"
gap without hooking frees, which happen inside the runtime. It is coarse
(process-level, not per object), but it answers the first questions Lean
users ask: "does this scope blow up memory?" and "is memory flat over a long
run?" The summary command gives new users a zero-setup first view.

**How to build it.**

- Call `mi_process_info` from `c/leanprof.c`. It is exported by
  `libleanrt.a` and declared in `lean/mimalloc.h`.
- Write Chrome-trace `"ph":"C"` counter events.
- Try `mi_stats_get_json` too. Whether the runtime's mimalloc is built with
  statistics enabled is **(unverified)**. If it is, the summary gets live
  bytes per size class.

**Effort.** About a day.

## 5. "Who shared it": the last-share site for each copied value

**What it is.** When a copy happens, report not only where it was copied
but where the value became shared: the last place that took an extra
reference to that array or string.

**Where it comes from.**

- GHC retainer profiling breaks the live heap down by retainer set
  ([GHC user guide, profiling](https://downloads.haskell.org/ghc/latest/docs/users_guide/profiling.html)).
- Chrome DevTools heap snapshots show a retainers path for each object
  (well known, not re-checked in this session).
- ghc-debug offers retainer and dominator analyses on a paused program. Its
  client library lists modules for retainers, dominators, profiles and
  snapshots
  ([ghc-debug-client](https://hackage.haskell.org/package/ghc-debug-client)).
  The pause-and-inspect mechanism was not confirmed from that page.

**Why it matters for Lean.** The copy report says *that* an array was
shared. Users then hunt for *who* holds the other reference, which is the
hard part. ROADMAP M6 plans to answer this by reading the IR. This is the
dynamic counterpart: it works across function boundaries, closures and
structures, where static reading struggles.

**How to build it.**

- Hook `lean_inc_ref_n` (and `lean_inc`) in user code with the post-include
  macro from fact 2.
- On each increment of an array, scalar array or string (one tag load) at
  or above a size threshold, record `ptr → (__func__, increment count)` in
  a small per-thread open-addressing table.
- When `leanprof_copy_*` fires, look up the pointer and print "made shared
  in `foo` (Foo.lean:12)".
- Make it opt-in (`--why`), because it slows every increment.
- With #3, increments in the core library are still invisible (they are
  inlined there), so say "last recorded share".

**Caveats.** The last increment is a heuristic. It is usually the culprit
(storing the value into a structure or a history list, or capturing it in a
closure), but not always. Report the last few increments.

**Effort.** Two to three days.

## 6. Live view through Tracy's C client

**What it is.** A second backend for leanprof's runtime that forwards
scopes, copies, task waits and the memory counters from #4 to Tracy:
scopes as zones, copies as messages, memory as plots. The Tracy GUI then
gives a live view, statistics and trace comparison immediately.

**Where it comes from.**

- Tracy offers real-time remote telemetry, hybrid sampling and
  instrumentation, memory and lock profiling, and has third-party bindings
  for Rust, Zig, C#, OCaml and Odin ([Tracy](https://github.com/wolfpld/tracy)).
  Release 0.14 brought statistical parity to the comparison view
  ([releases](https://github.com/wolfpld/tracy/releases)).
- The Zig compiler profiles itself through Tracy bindings in `src/tracy.zig`
  ([Ziggit thread](https://ziggit.dev/t/how-to-use-tracy/4296)).
- puffin streams scopes to `puffin_viewer` over TCP via `puffin_http`, at a
  stated 50–200 ns per scope ([puffin](https://github.com/EmbarkStudios/puffin)).

Tracy's C API (`TracyC.h`, `___tracy_emit_zone_begin` and so on) is from
memory and was **not re-checked on the pages fetched**. Check the Tracy
manual before building.

**Why it matters for Lean.** "No live view" is a known gap, and ROADMAP M7
plans a custom shared-memory ring buffer plus a terminal UI, which is weeks
of work. Tracy gives a polished live GUI in days. It also gives Tracy's
sampling of the same run, so the hybrid view (M7's "one file merging
samples and scopes") comes for free on platforms where Tracy samples.

**How to build it.**

- Compile Tracy's client (`TracyClient.cpp`, C++) with `TRACY_ENABLE` into
  an optional `libleanprof_tracy`.
- In `leanprof-cc`'s link branch, add it when `LEANPROF_TRACY=1`. Lean
  programs already link the C++ runtime.
- Map scope enter and exit to zone begin and end with a static source
  location: the scope name and `.ilean` file:line, created once per scope id.
- Map copies to messages and `mi_process_info` to plots.
- Pin the Tracy version, because client and GUI protocol versions must match.

**Effort.** Two to four days. Keep the ring buffer for an MCP or agent
interface later. Tracy is the shortcut for humans.

## 7. Closure-application and specialization counters

**What it is.** Count `lean_apply_*` calls per call site and per **target
function** (the closure's `m_fun`, symbolized to a Lean name). Classify each
call as exact (arity matches), under-saturated (a partial application is
built) or over-saturated (it chains).

**Where it comes from.** GHC ticky-ticky counts entries and allocations per
closure, and its encoding flags dictionary arguments, which "can reveal
calls where specialisation failed"
([GHC user guide, ticky](https://downloads.haskell.org/ghc/latest/docs/users_guide/profiling.html)).
Go PGO uses profiles to inline hot calls more aggressively; the docs claim
2–14% gains ([Go PGO](https://go.dev/doc/pgo)).

**Why it matters for Lean.** Unspecialized higher-order code is one of
Lean's most common slowdowns: a `foldl` over an un-`@[specialize]`d
combinator, or a monad stack that is not inlined. Each step then goes
through `lean_apply_n`, boxes its arguments and may allocate partial
applications. The sampled runtime breakdown shows "closures" in total. This
idea names the higher-order function and the closure, and suggests
`@[specialize]` or `@[inline]`.

ROADMAP M6 lists "closure application counts". The material improvement is
attributing to the *target* function and classifying by arity. That turns a
count into a fix.

**How to build it.**

- Add `-Dlean_apply_N=leanprof_apply_N` for N = 1..16 and `lean_apply_m`.
  These are exported (fact 5).
- In the hook, read `lean_closure_fun`, `lean_closure_arity` and
  `lean_closure_num_fixed` before calling through.
- Key a per-thread table by (caller via `__builtin_return_address`, `m_fun`).
  With #3 this also covers applications inside core combinators, which is
  most of them.

**Effort.** One to two days.

## 8. Flight recorder and `leanprof dump <pid>`

**What it is.** There are two parts.

1. **Flight recorder.** Keep leanprof's bounded per-thread trace buffers as
   rings. On a trigger, write the last N seconds to Perfetto. Triggers are a
   signal, a `Leanprof.dumpTrace` call, or a scope exceeding a configured
   duration.
2. **Dump.** Print every thread's current stack of a running program, with
   Lean names, plus leanprof's scope stack and any blocked task waits.

**Where it comes from.**

- Go 1.25's flight recorder keeps a ring buffer of recent trace data, and
  `WriteTo` snapshots it when a problem is detected
  ([Go blog](https://go.dev/blog/flight-recorder)).
- `py-spy dump --pid` shows each thread's stack without restarting the
  program ([py-spy](https://github.com/benfred/py-spy)).

**Why it matters for Lean.** Long-running Lean programs, such as language
servers, agents, provers in a loop and Lake, have rare slow requests and
occasional deadlocks: a `Task.get` on a task that waits on the caller. Full
traces are too big to keep on, and samply needs a restart unless attached.
For hangs, the most useful single fact is "every thread is blocked here,
waiting on this task, spawned there".

**How to build it.**

- The flight recorder is mostly a change in buffer policy: overwrite instead
  of stopping at `LEANPROF_TRACE_MAX`, plus a `SIGUSR1` handler that sets a
  flag checked at the next scope boundary.
- For dump, use `sample <pid>` on macOS or `eu-stack`/`gdb -p` on Linux,
  then pipe the output through leanprof's demangler and `.ilean` resolver.
- Read the scope stack and pending waits from a small shared-memory region
  the runtime publishes (a fixed-size slot per thread, written at scope
  boundaries).

**Effort.** One to two days.

## 9. Heap census by object kind and closure, without a profiling build

**What it is.** On demand (at exit, on a signal, or at a scope boundary on
the main thread), walk every live mimalloc block with `mi_heap_visit_blocks`
(fact 4). Classify each block by its `lean_object` header:

- constructor shape: tag, number of object fields, scalar size;
- closure, by `m_fun` symbol, which gives a Lean name;
- array or string, by size bucket;
- thunk, task, `mpz`, external.

Report live bytes and count per class, and emit census snapshots as a stacked
area chart over time.

**Where it comes from.** GHC's `-hT` breaks the heap down by closure type and
"does not require the profiling runtime". `-hi` breaks it down by info table,
with `-finfo-table-map` giving source locations
([GHC user guide](https://downloads.haskell.org/ghc/latest/docs/users_guide/profiling.html)).
Closure code pointers play the role of info tables here.

**Why it matters for Lean.** "What is in my heap?" has no answer today short
of a C debugger. Typical findings would be millions of retained thunks,
closures capturing large environments, or `Expr`-shaped constructors
dominating. That is the Lean version of a space leak. It also gives exact
live bytes, partly closing the peak-memory gap better than RSS (#4).

**How to build it and the risks.**

- mimalloc 3.x moved to process-wide heaps with per-thread "theaps".
  Whether `mi_heap_visit_blocks(mi_heap_main(), true, ...)` sees blocks of
  all threads, and whether it is safe while other threads run, is
  **(unverified)**. Start with single-threaded programs or at a point where
  all workers are idle.
- Non-Lean allocations (libuv, C++ runtime) live in the same heap. Filter by
  a plausible header: valid tag range and `m_cs_sz` equal to the block size.
- Constructor shapes are not type names. Map shapes to types using the
  allocation sites from `--allocs` (site → declaration → the constructors it
  builds), or show shapes alongside the top allocating declarations.

**Effort.** Three to five days, with a real chance the cross-thread part
needs **[Lean change]**: a runtime hook to stop the world or to enumerate
per-thread heaps.

## 10. Task work/span, parallelism and critical path

**What it is.** From the spawn, start, finish and wait events leanprof
already records, build the task graph and report four numbers:

- **work**: the sum of task run times;
- **span**: the longest dependency chain;
- **parallelism**: work divided by span, an upper bound on useful cores;
- the **critical path**, as a list of scopes.

Add a "running tasks over time" counter track.

**Where it comes from.**

- OpenCilk's Cilkscale reports work, span, parallelism and burdened
  parallelism. Parallelism "upper-bounds the number of processors that may
  productively work in parallel"
  ([Cilkscale](https://www.opencilk.org/doc/users-guide/cilkscale/)).
- ThreadScope shows per-capability activity over time (from memory, not
  re-checked).
- cargo `--timings` draws a concurrency graph of active, waiting and
  inactive units ([cargo timings](https://doc.rust-lang.org/cargo/reference/timings.html)).

**Why it matters for Lean.** Lean users parallelize with `Task.spawn` and
`IO.asTask`, and with elaboration tasks in the frontend. "Is it worth adding
more tasks, or is the span the limit?" is the first question in that work,
and it is a cheap, deterministic stand-in for causal profiling on Task
programs.

**How to build it.**

- Redirect `lean_task_map_core` and `lean_task_bind_core`, which are
  exported (fact 5). This also fixes the known Task.map/bind gap.
- Add flow events to Perfetto (spawn → start, finish → wait).
- Compute the longest path over the graph at exit.

**Effort.** Two to four days.

## 11. Instruction counts in `compare` and `measure`

**What it is.** A near-deterministic cost metric next to time, so that
regressions on CI do not depend on noisy wall-clock thresholds.

**Where it comes from.**

- gungraun (formerly iai-callgrind) is a "high-precision, one-shot and
  consistent benchmarking framework" built on Callgrind, Cachegrind, DHAT
  and perf ([gungraun](https://github.com/gungraun/gungraun)).
- CodSpeed's CPU simulation runs a benchmark once and models instructions
  plus cache and memory cost
  ([CodSpeed](https://codspeed.io/docs/instruments/cpu)). Whether it is
  built on Valgrind is **(unverified)** from that page.
- poop reports hardware counters through `perf_event_open` and is Linux-only
  ([poop](https://github.com/andrewrk/poop)).

**Why it matters for Lean.** leanprof's exact checks (copies, calls,
heartbeats) already catch many regressions deterministically. Time is the
one flaky dimension. Instruction counts, plus cache misses for Lean's
pointer-heavy data, fill that hole. They also suit the
autoresearch-style loop in progress, because a judge needs a low-noise
signal.

**How to build it.**

- Phase 1 (Linux): `perf_event_open` for instructions, cycles and L1D/LLC
  misses around the whole run in `leanprof measure`, plus exact comparison
  with a small tolerance in `compare`.
- Phase 2: per-scope counters, reading the counters at scope enter and exit.
  This costs more than the 11 ns clock read; use `rdpmc` on x86.
- macOS: counters exist only through the private kperf framework, which coz
  uses on macOS with elevated privileges ([coz](https://github.com/plasma-umass/coz)).
  Treat it as best-effort.
- Valgrind does not support macOS on Apple silicon **(unverified, from
  memory)**.

**Effort.** Two to four days for Linux whole-run counters, plus a week for
per-scope counters.

## 12. Static copy predictor on the IR

**What it is.** A pass over each declaration's IR after reference-count
insertion. It reports a destructive-update call (`Array.push`, `set`,
`modify`, `String.push`, `reset`) whose argument is still live afterwards or
was `inc`'d before the call. Those calls will copy or fail to reuse whenever
they execute. Results appear in `#leanprof` inlay hints and as a CI lint.

**Where it comes from.** JET.jl uses Julia's type inference to find "type
instabilities" and "runtime dispatch" statically, with `@report_opt`
([JET](https://aviatesk.github.io/JET.jl/stable/)). Julia's main performance
footgun is found by analyzing the compiler's own IR. Lean's main footgun is
non-unique updates, and that is decidable from the RC-annotated IR in many
cases.

**Why it matters for Lean.** Dynamic detection only sees paths that ran. A
lint catches the quadratic loop before the benchmark that would have found
it, and it explains the copy in terms of the IR.

**How to build it.**

- Load the module IR through the frontend: the `.ir` files from fact 7, or
  the environment's IR declarations; the exact API is **(unverified)**.
- Run a liveness pass that already exists in the compiler.
- Flag definite cases only: an `inc x` followed by a destructive use of `x`
  with no `dec x` in between.
- Show the IR snippet in the hover.

ROADMAP M6 plans IR-based explanations *for observed copies*. This is the
static predictor that needs no run, and it shares most of the code.

**Effort.** One to two weeks.

## 13. Sampled allocations with stacks and lifetimes

**What it is.** In the existing allocation hooks, sample allocations by
bytes: for example one per 512 KiB, Poisson-distributed. Capture a
frame-pointer stack for each sample to produce an allocation flame graph
with Lean names, cheap enough to leave on. For sampled objects, record
death when `lean_dec_ref_cold` (#2) frees them, which gives lifetimes and
"temporary allocation" counts per site.

**Where it comes from.**

- OCaml memtrace "can tell when, if ever, each [sampled allocation] is
  collected" ([memtrace](https://github.com/janestreet/memtrace)).
- async-profiler `--alloc 500k` samples about every 500 KB
  ([profiling modes](https://github.com/async-profiler/async-profiler/blob/master/docs/ProfilingModes.md)).
- Julia's `Profile.Allocs` records stack, type and size, with a
  `sample_rate` ([Julia](https://docs.julialang.org/en/v1/manual/profile/)).
- heaptrack reports temporary allocations, defined as ones "directly
  followed by their deallocation" ([heaptrack](https://github.com/KDE/heaptrack)).
- DHAT reports per-site lifetimes and a short-lived metric
  ([DHAT](https://valgrind.org/docs/manual/dh-manual.html)).

**Why it matters for Lean.** Exact per-site allocation counts already exist,
but the sites are leaf runtime calls. Stacks show which caller chain
allocates. Short lifetimes point at boxing, and at missed reuse or
unboxing.

**Caveat.** Objects freed *inside* a freeing cascade never go through
`dec_ref_cold`, so their deaths are missed. Detect them lazily: at report
time, check whether the sampled block still holds the same header, using
`mi_usable_size` or a heap visit. This is approximate. Exact deaths need
**[Lean change]**: a free hook in `lean_del_core`.

**Effort.** Three to five days.

## 14. Build timeline and module critical path

**What it is.** A Gantt chart of module builds in a `lake build`, with the
critical path and a concurrency graph. It says which modules gate the build
and where cores sit idle.

**Where it comes from.** cargo `--timings` draws a unit graph where lines
show which units each finishing unit unblocks, "which helps you spot the
critical path", plus a concurrency graph
([cargo timings](https://doc.rust-lang.org/cargo/reference/timings.html)).
clang `-ftime-trace` with ClangBuildAnalyzer is the C++ analogue (not
re-checked).

**Why it matters for Lean.** Compile time is the top performance complaint
in large Lean projects. `leanprof elab` profiles inside a module. Nothing
shows the import graph's critical path, which decides whether splitting a
module or removing an import speeds up the whole build. ROADMAP M9 plans
"whole-project runs"; this adds the scheduling view.

**How to build it.** Lake reads the `LEAN` environment variable to locate
the Lean installation (`Lake/Config/InstallPath.lean`). Whether Lake
*invokes* a wrapper given there, as it does with `LEAN_CC`, is
**(unverified)**. If not, reconstruct the timeline after the build:

- end time of each module = mtime of its `.olean`;
- start time ≥ the latest end time among its imports;
- check the durations against `trace.profiler` totals.

Alternatively, propose a timing output to Lake, which would be a
**[Lean change]** to Lake.

**Effort.** Two to four days.

## 15. Causal profiling

**What it is.** Coz-style "if this code were X% faster, how much faster would
the program be?", measured against progress points.

**Where it comes from.** [coz](https://github.com/plasma-umass/coz) runs on
Linux via `perf_event_open`. Its README says it also runs on macOS through
the private kperf framework, with elevated privileges. It needs `-g` debug
info and offers throughput (`COZ_PROGRESS`) and latency
(`COZ_BEGIN`/`COZ_END`) progress points. Ports exist for Java (JCoz), Go
(Cozgo) and Swift.

**Why it matters for Lean.** It is a known gap, and the right tool for
multi-threaded Lean servers. For most Lean programs, which are
single-threaded, its value is low, and #10 answers the Task-level question
more cheaply.

**How to build it.**

- **Quick:** `leanprof coz -- prog` builds with `-g` through `leanprof-cc`,
  exposes `COZ_PROGRESS` as a Lean `@[extern]` behind a `progress!` macro,
  runs coz, and post-processes its output. Map C lines to Lean declarations
  with the demangler, or to Lean lines once the emitter carries `#line`
  (the ROADMAP upstream item, **[Lean change]**). This takes days.
- **Native:** virtual speedup driven by leanprof's own scope events. When
  any thread runs inside the selected scope for time t, every other thread
  owes a delay of t × speedup, paid at its next scope boundary. This is
  exact at scope granularity and portable. It takes two to three weeks. It
  is an original design, not taken from a tool, and is not validated.

## 16. pprof export

**What it is.** Write the profile in pprof's `profile.proto`. The format
carries several value types per sample (for example time, copies, copy
bytes, allocations), locations with inlined lines, and labels
([pprof format](https://github.com/google/pprof/blob/main/proto/README.md)).
Export both `leanprof sample` stacks and the instrumented scope tree.

**Where it comes from and why.** It gives `go tool pprof`: the web UI,
`-diff_base` comparisons, `list` and `peek`. It also gives Pyroscope
ingestion (`format=pprof`; see the
[Pyroscope server API](https://archive.grafana.com/docs/pyroscope/v1.10.x/configure-server/about-server-api/))
and a path to continuous profiling for the few Lean services that run in
production, all without writing viewers. It is also the input format Go PGO
uses, which matters if #17 pans out. Parca's pprof support was **not
verified** in this session.

**Effort.** About a day: a minimal protobuf writer in Lean or C.

## 17. Clang PGO of the emitted C

**What it is.** `leanprof pgo -- prog` builds through `leanprof-cc` with
`-fprofile-instr-generate`, runs a representative workload, merges the
profile with `llvm-profdata`, and rebuilds with `-fprofile-instr-use`.

**Where it comes from.** Go PGO claims 2–14% from profile-guided inlining
([Go PGO](https://go.dev/doc/pgo)). Clang has supported instrumented PGO for
years; its profile format even has a MemProf section
([LLVM profile format](https://llvm.org/docs/InstrProfileFormat.html)).

**Why it matters for Lean.** Lean's generated C is simple, branchy code that
calls `static inline` helpers from `lean.h`. Block layout and inlining
guided by real branch frequencies could help. **The size of the gain for
Lean programs is unknown**: treat this as an experiment and report numbers
before building UX. The runtime and core library stay unprofiled unless
rebuilt.

**Effort.** One to two days to measure on the existing benchmarks and the
case study.

## 18. Lock and condition-variable contention

**What it is.** For each call site, report time spent waiting in
`lean_io_basemutex_lock` and `lean_io_condvar_wait`, plus promise waits.

**Where it comes from.** Go's mutex profile "reports the lock contentions"
and its block profile "shows where goroutines block waiting on
synchronization primitives"
([Go diagnostics](https://go.dev/doc/diagnostics)). async-profiler `-e lock`
counts nanoseconds spent waiting to enter a monitor. dotnet-counters shows
lock contention live
([dotnet-counters](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-counters)).

**Why it matters for Lean.** `Std.Mutex` and `IO.Channel` users in servers
and agents. It is a small population, so it ranks low.

**How to build it.** Redirect the exported symbols (fact 5). The calls
mostly sit inside precompiled `Std` code (`Mutex.atomically`), so this needs
#3.

**Effort.** One day after #3.

---

## Already on the roadmap, with specifics from other tools

These were found in other tools but are already planned. Only the borrowed
detail is new.

- **Paired, interleaved comparisons with confidence intervals (M4).** Borrow
  hyperfine's warm-up and prepare steps, criterion-style bootstrap intervals
  (not re-checked), and Tracy 0.14's comparison view, which reports
  coefficient of variation and change-coloured markers
  ([Tracy releases](https://github.com/wolfpld/tracy/releases)).
- **Allocations in benchmarks (M4/M5).** divan's `AllocProfiler` wraps the
  global allocator and counts allocation operations and bytes per benchmark,
  noting that it affects timings
  ([divan docs](https://docs.rs/divan/latest/divan/struct.AllocProfiler.html)).
  The same caveat applies to `LEANPROF_ALLOCS`.
- **Shared-memory ring buffer read by another process (M7).** This is
  exactly OCaml's Runtime_events: per-domain rings in a memory-mapped
  `<pid>.events` file, read by an external process, with lost events when
  the reader is slow ([OCaml manual](https://ocaml.org/manual/5.3/runtime-tracing.html),
  [olly](https://github.com/tarides/runtime_events_tools)). Haskell's
  `eventlog-live` streams the eventlog over a Unix socket into an
  OpenTelemetry collector ([eventlog-live](https://hackage.haskell.org/package/eventlog-live-otelcol)),
  which is the "agents query a running program" idea, already built
  elsewhere.
- **One file merging samples and scopes (M7).** Tracy and Superluminal both
  present sampling and instrumentation in one UI. For Superluminal this is
  **(unverified)** from its public pages, which only mention PC samples and
  thread interactions ([Superluminal](https://superluminal.eu/)).
- **CPU time per scope (M2).** JDK 25's JFR adds CPU-time sampling (JEP 509,
  Linux only) next to wall-clock sampling ([JEP 509](https://openjdk.org/jeps/509)).
  async-profiler's wall mode samples sleeping and blocked threads too. samply
  already records off-CPU samples on macOS and Windows but not Linux
  ([samply](https://github.com/mstange/samply)). Document that limit in
  `leanprof sample`.

## Considered and ranked low

- **Leak detection at exit**, as in Zig's debug allocator (not re-checked)
  or async-profiler `nativemem --leak`. Reference counting frees
  everything except cycles through `IO.Ref`/`ST.Ref` and deliberate
  persistence, so the value is low. A heap census (#9) at exit gives the
  same answer for free.
- **USDT/DTrace probes and Instruments signposts** for copies and tasks.
  They would let bpftrace or Instruments see leanprof events. The audience
  is small and SIP restricts DTrace on macOS.
- **A continuous-profiling agent** (Parca, Pyroscope). Few Lean services
  run in production. pprof export (#16) is the cheap bridge if that changes.
- **Biographical heap profiling** (GHC `-hb`: lag, drag, void, use). "Drag",
  where a value is held after its last use, is the root cause of many Lean
  copies, but measuring it needs per-object use tracking: **[Lean change]**.
- **Scalene-style per-line attribution of CPU, memory and copy volume**
  ([scalene](https://github.com/plasma-umass/scalene)). leanprof already
  has copy volume per function. Per *line* needs `#line` from the C
  emitter, which is the existing upstream item: **[Lean change]**.
- **Python 3.15's Tachyon sampler** (`profiling.sampling`, PEP 799;
  [What's new](https://docs.python.org/3.16/whatsnew/3.15.html)).
  Interesting as evidence that attach-anytime sampling is now a language
  default. leanprof gets the same from samply.

## Needs changes to Lean (collected)

- Free hooks or a deletion callback in `lean_del_core`: exact deaths for
  #13, biographical profiling, and exact live bytes per scope.
- A stop-the-world point or per-thread heap enumeration, if #9 cannot be
  done safely through mimalloc alone.
- `#line` directives in the emitted C, for per-line attribution in samply,
  coz (#15) and Scalene-style views. This is already an upstream item.
- An optional runtime event ring buffer in the Lean runtime, like OCaml's
  Runtime_events, so copies and frees inside the runtime are reported
  without symbol rewriting (#3).
- Possibly Lake build timings (#14), if wrapping or mtimes prove
  insufficient.
