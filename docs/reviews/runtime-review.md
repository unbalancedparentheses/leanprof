# Runtime review: sanitizers, an independent review, a stress test

October 2026, after about ten branches were merged in one day. Three bugs
between branches had been found by hand (a live reader that could read a
freed scope stack, two competing double-count fixes, a calibration shape
mismatch), so the C runtime (`c/leanprof.c` and the files it includes,
`c/counters.h`, `c/leanprof_why.h`, `scripts/leanprof-cc`) was checked
three ways:

1. **Sanitizers.** The tests, the examples (`copybug`, `tasks`,
   `taskchains`, `corecopies`, `server` with `LEANPROF_LIVE` at 10 ms and
   `LEANPROF_FLIGHT` with slow-scope and SIGUSR1 dumps),
   `leanprof run --allocs --counters --frees`, `leanprof explain --why`
   and the stress test, built with `-fsanitize=address,undefined` and with
   `-fsanitize=thread` (macOS arm64 locally, Linux in CI).
2. **An independent review** by Codex (`codex exec --sandbox read-only`),
   asked for data races, use-after-free, unbounded growth, the SIGUSR1
   handler's signal safety, integer overflow and error paths. Each finding
   was checked against the code, and reproduced where it could be.
3. **A stress test** (`Examples/Stress.lean`, `scripts/stress.sh`): pool
   and dedicated tasks, recursion deep enough to grow the scope stack six
   times, 12.8 million scopes and 12.7 million copies, snapshots every
   10 ms and flight dumps under load, all counts checked exactly.

All three now run in CI (the `sanitizers` job).

## How the sanitizer builds work, and what they cannot see

`LEANPROF_SANITIZE=address,undefined` (or `thread`) with
`LEAN_CC=scripts/leanprof-cc` compiles and links with the sanitizers, and
the lakefile compiles leanprof's runtime with clang and the same flags.
Lean's runtime (`libleanrt`, mimalloc) and its precompiled libraries are
not rebuilt, so:

- **ASan** checks leanprof's own memory (tables, stacks, rings, report
  buffers) and the emitted C's stack and globals. Lean objects live in
  mimalloc's heap, which ASan does not track: an overflow inside a Lean
  object is not seen.
- **UBSan** checks leanprof's code and the emitted C (with `lean.h`'s
  inline functions), not the runtime.
- **TSan** sees races between accesses that are both instrumented, which
  means races inside leanprof's runtime. The emitted C is linked with TSan
  but not instrumented for it: its threads synchronize through the
  runtime's atomics (task completion, reference counts), which TSan cannot
  see. Instrumented, it reported a false race on a task's result, written
  by the worker and read after `IO.wait`. On Linux TSan also intercepts
  the runtime's own `memcpy`, `memmove` and `memset`; two workers' array
  copies (`lean_copy_expand_array`) into memory mimalloc reused between
  them were reported, a false race in the Lean heap. `scripts/tsan.supp`
  suppresses races whose top frame is one of these three, or inside the
  runtime's `lean_copy_*`: leanprof shares no memory through them. It
  also suppresses races inside Lean's C++ runtime (`lean::`) and its IO
  primitives, seen in the `leanprof` command itself: a `FILE` buffer
  allocated by one task's read and freed by the handle's finalizer on
  another thread.
- **LeakSanitizer is off**: leanprof keeps its records until the exit
  report, and Lean's runtime does not free everything at exit.

Two environment notes. Lean installs its own alternate signal stack on the
thread that runs `main`, and ASan tries to unmap it as its own when that
thread exits (`AddressSanitizer: CHECK failed ... unable to unmmap`, in
every program). `ASAN_OPTIONS=use_sigaltstack=0` avoids this; it is
Lean's runtime against ASan's, not leanprof. On Ubuntu 24.04, TSan needs
`vm.mmap_rnd_bits=28`. Under a sanitizer only leanprof's runtime is slowed
down, not the program's code, so the calibration removes more than the
probes cost. The one timing check in the tests (`scope total is reported`)
accepts 0 when `LEANPROF_SANITIZE` is set.

## Fixed

| Finding | How found | Fix |
|---|---|---|
| Thread registration, new scope and copy records, and their counters were written with plain stores while the live thread read them. The live view's "seen one snapshot earlier" rule gives no happens-before, and a plain read-modify-write racing with an atomic load is a data race. Also the open frames' scope and start, the depth, and the queries (`calls`, `copies`, `totalNs`, `allocs`, `frees`, the counters) reading other threads' tables. | TSan (server with `LEANPROF_LIVE`), Codex | Records published with release stores (`LP_PUBLISH`), read with acquire loads (`LP_GET`); counters and the fields the live thread reads written with relaxed atomic stores (`LP_ST`, `LP_ADD`: the same instructions as before). |
| Calibration wrote the timing and weight arrays while other threads' exits read them, and two calibrations (first use, a query, exit) could run at once. | TSan, Codex | One calibration at a time (`lpf_cal_lock`); results stored and read with relaxed atomics. |
| A task's scope got its spawning scope's kind (`parent_kind`) after the scope was published, and its begin event its kind after the event count was published. The flight dump dropped each thread's newest event when it was such a begin, to avoid the second. | Codex, my reading | The kind is known before `lpf_enter` (`task_parent_kind` on the thread): the scope is created with it and the event recorded with it; the dump's workaround is gone. |
| The flight recorder copied (dump thread) and compacted (owner) the same events with plain `memcpy`/`memmove`. The sequence count rejects torn copies, but the accesses themselves were races. | Codex | Events written and read field by field with relaxed atomics, inside the same sequence protocol. |
| Threads that exit (a new thread per dedicated task) kept their tables (about 1 MiB), counters, memory tables, `explain` table and flight buffer (8 MiB) forever: memory grew with every such task. | Codex; confirmed by the stress test: 83 thread records, 1.0 GB peak RSS for a 46 MB Lean heap | A pthread key's destructor closes the thread's open scopes and hands all its records to the next new thread. The stress test then used 27 records and 0.47 GB. Records keep their contents (merged by name anyway) and their id. |
| Under `--auto`, every copy and allocation looked down the scope stack for the innermost `profile!` label: with no labels, the whole stack. Deep recursion that allocates was quadratic: 20,000 levels 246 ms, 40,000 1.07 s, 80,000 4.45 s (1 ms without probes). | My reading; measured | Each frame keeps the innermost label at or below it: 80,000 levels in 6 ms, 400,000 in 25 ms. The stress test runs a 100,000-deep allocating recursion under `--auto --allocs` in CI. |
| Histogram buckets were `uint32_t`: a scope that is called often fills one in about a minute (4.3 billion short calls), and its percentiles then wrapped (to 0). | Codex | 64-bit buckets in the scopes, free sites, report and live rows. |
| `LEANPROF_TRACE_MAX` was parsed without a bound: a huge value wrapped `n * sizeof(lpf_event)` to a small flight buffer that the recorder then wrote past. | Codex | Capped at 2^28 events (8 GiB) while parsing. |
| Memory was sampled every millisecond for as long as the program ran: 24 bytes per sample, up to 400 MB in chunks, for a long-running server. | My reading | After the first minute, samples are spread over the run so far (1/65,536 of it): about 540,000 samples (13 MB) in a day. |
| `lpf_report` returned with `lpf_lock` held when out of memory (and lost the old buffer on `realloc` failure); any later query would deadlock. | Codex | One unlock-and-free path. |
| A live snapshot without memory for its row index wrote broken JSON over the last good snapshot. | Codex | The temporary file is dropped instead. |
| The report's JSON, the timeline, `explain`'s data and the flight marker ignored write errors (the marker could be renamed over a good one when truncated). | Codex | `ferror`/`fclose` checked; failures said on stderr; the marker is only renamed when whole. |
| If the live thread could not be created, the flight recorder stayed on: a buffer per thread, a marker telling `leanprof dump` to signal, nothing to write dumps. | Codex | Live snapshots and the flight recorder are turned off again, the marker removed and SIGUSR1's previous handler restored. |
| The SIGUSR1 flag (`volatile sig_atomic_t`) was tested and then cleared by the background thread: a signal in between was lost, and the cross-thread access was a race. | Codex | A lock-free atomic `int`, stored by the handler and exchanged by the thread. |
| A dump asked for just before the program ended was dropped. | Stress test (no SIGUSR1 dump when the last signal came late) | The background thread serves a pending request before it stops. |
| A query inside an open scope (`totalNs`, `overheadNs` run a calibration) charged the calibration's time and overhead units to that scope. | My reading | Calibration restores the enclosing frame's child time, overhead units and allocation counts. |
| The counters' table (`lpf_ctr_get`) had no fill limit: once full, every call scanned all 32,768 slots. | My reading | Stops taking new keys at 7/8 full, like the other tables. |
| `lpf_ctr_collect` sized its array from a first count of records, then added every record it met in a second pass: a thread still running at exit could add records in between and make it write past the array. | Codex | The second pass stops at the array's size. |
| `lpf_frees_seen` was written by every free from every thread; `lpf_why_used` was set in a `pthread_once` and read by copy shims on other threads; `leanprof_peak_memory` read the peak after releasing its lock. | Codex | Relaxed atomics (the free hook stores only when the flag is not yet set, so threads do not share a written cache line); the peak is read under the lock. |
| The project's package names were read lazily: the live thread (snapshots, dumps), `LEANPROF_SLOW_SCOPE`'s check on a program thread and `demangle` queries could all read them at once. The declaration index (`lpf_where`) was built lazily the same way, and two threads building it reallocate one array. | My reading | Package names are read once (`pthread_once`, and at startup when the live view is on); the index is built and searched under a lock. |
| `leanprof_set_symbols` passed `NULL` to `qsort` when `strdup` failed. | My reading | Keeps the names read so far. |

The stress test also needed a fix of its own: `history (200 + seed * 0)`
became a closed term computed once at startup, so its tasks made no copies.
The length now comes from the command line.

## Rejected or left as limits

- **"Make every concurrently accessed field atomic on both sides; publish
  the depth only after the frame is initialized"** (Codex). The counters
  the live thread reads are now atomic. `active`, `min`, the frames'
  `child`, `kids`, `desc` and allocation fields are only read by their
  owner, so they stay plain. The depth is still stored before the frame is
  filled in. A snapshot can then show the frame's previous scope (the stack
  buffers are never freed, and the live view only names a scope pointer it
  already resolved), for one 10 ms snapshot. That does not justify a
  second protocol on the hot path.
- **"Publish an immutable calibration result"** (Codex). The values are
  estimates that only get lower. A reader can see one path's new value
  next to another's old one for the length of one calibration, and the
  exit report recalibrates anyway. Serializing the writers and making the
  accesses atomic was enough.
- **"Establish producer quiescence before the final collection"**
  (Codex). On a normal return from `main`, the emitted `main` calls
  `lean_finalize_task_manager()`, which waits for the workers, before
  `atexit` handlers run, so the report reads quiet tables (and TSan saw no
  race at exit in any run). A program that calls `exit` (`IO.Process.exit`) while tasks
  still run can have the report read tables that are being written, and
  with `LEANPROF_TRACE` an event buffer that a worker is reallocating.
  Stopping every thread at exit would need a check on the hot path, so this
  stays a documented limit. The one out-of-bounds write it could cause
  (`lpf_ctr_collect`) is fixed.
- **The SIGUSR1 handler itself** was checked and is async-signal-safe: it
  only stores to a lock-free atomic. The dump runs on the background
  thread, which blocks all signals.
- **ASan's report at thread exit** (`unable to unmmap`) is ASan against
  Lean's runtime (its alternate signal stack), not leanprof; it is
  avoided with `use_sigaltstack=0`.
- **TSan's report in `Examples/Tasks.lean`'s emitted C** is a false
  positive (see above); the emitted C is not instrumented for TSan.
- My first reading suspected that `lpf_task_run` patched
  `t->events[t->nevents - 1]` with no event written in flight mode. It
  cannot crash: the frame is only marked traced when the event was
  appended. The code is gone anyway (see the `parent_kind` fix).

## Results

On the final code, macOS arm64 (18 cores), every run in the sanitizer
builds was clean: the tests, the examples, the server with live snapshots
and dumps, `run --allocs --counters --frees`, `explain --why` and the
stress test.

| Stress run | scopes (leaf, deep, io) | copies | dumps | wall |
|---|---|---|---|---|
| plain, defaults (8 rounds, 40 tasks each) | 12.8 M, 6.4 M, 1.28 M, exact | 12,736,000, exact | 3 slow-scope, SIGUSR1 | 3.8 s |
| ASan + UBSan, defaults | exact | exact | 3 slow-scope, SIGUSR1 | |
| TSan, `4 16 20000 5000` | 1.6 M, 400 k, 160 k, exact | 1,592,000, exact | 3 slow-scope, SIGUSR1 | |
| `run --auto --allocs`, `2 16 20000 100000` | 4,000,040 `pairs` calls, exact | exact | | 0.23 s |

The probes' cost did not change measurably: `overhead` reports 19.0 ns per
scope before and 19.3 to 20.0 ns after (noise between runs is of the same
size). The relaxed atomic stores compile to the same instructions; the
innermost label adds one load and one store per scope entered.
