# Draft: issue for lean-dojo/LeanProfiler

*Draft only. Not filed. Re-verified on 2026-10-23 against LeanProfiler
`main` at `35e1899` (no newer commits; fresh clone) with leanprof at
`2021ecd`. Still present: per-span cost still grows with the number of
events recorded.*

---

**Title:** Recording overhead per span grows with capture size (event array and `eventDepths` copied on every span)

**Summary.** With `LEAN_PROFILE=1` and no event limit (the default:
`LEAN_PROFILE_MAX_EVENTS` unset), the average overhead per span grows with
the number of spans already recorded, so recording n spans takes
roughly quadratic time. The cause appears to be that `events` and
`eventDepths` in `ProfilerState` are never updated in place: each span
copies the event array's slots and the bucket arrays of the depth map.
Building the report afterwards has two smaller loops with the same pattern.

**Measurements.** Lean 4.35.0, macOS arm64 (Apple M5 Max), LeanProfiler at
`35e1899`, uninstrumented build. One worker task runs n spans around
`IO.Ref.modify`, inside a capture opened on the main thread. The table shows extra time per span compared with the same loop
without spans, as the range over three runs. The machine was running other
jobs (load average 12 to 18), so treat the absolute values as noisy. The
growth is the point.

| worker spans | per span, 2026-10-22 | per span, 2026-10-23 (3 runs) |
|---|---|---|
| 1,000 | 4.6 µs | 6.0–7.1 µs |
| 4,000 | 20.1 µs | 22.7–33.3 µs |
| 16,000 | 88.5 µs | 122–221 µs |

With recording off, a span costs about 23–36 ns (22.6–26.0 ns earlier,
34.5–35.8 ns on the loaded machine today).

**Where.** We built the program with leanprof's compiler wrapper. It
compiles LeanProfiler's and the benchmark's C with `-D` flags that send the Lean runtime's copy
paths to counting shims, so LeanProfiler's sources stay unchanged. It reports the following (bytes are array slots copied, not
deep copies of events):

```
spans   copies       bytes       time  why             function  (where)
1,000     3003     7.9 MiB  869.0 µs  multi-threaded  LeanProfiler.Internal.reserveSpan (in Std.DHashMap.Internal.Raw₀.insert)  (LeanProfiler/Runtime/Capture.lean:65)
          2002     3.8 MiB  661.2 µs  multi-threaded  LeanProfiler.Internal.completeSpan  (LeanProfiler/Runtime/Capture.lean:94)
4,000    12003   123.0 MiB   17.8 ms  multi-threaded  LeanProfiler.Internal.reserveSpan (in Std.DHashMap.Internal.Raw₀.insert)  (LeanProfiler/Runtime/Capture.lean:65)
          8002    61.1 MiB   16.0 ms  multi-threaded  LeanProfiler.Internal.completeSpan  (LeanProfiler/Runtime/Capture.lean:94)
16,000   48003    1.91 GiB  299.8 ms  multi-threaded  LeanProfiler.Internal.reserveSpan (in Std.DHashMap.Internal.Raw₀.insert)  (LeanProfiler/Runtime/Capture.lean:65)
         32002   976.7 MiB  272.7 ms  multi-threaded  LeanProfiler.Internal.completeSpan  (LeanProfiler/Runtime/Capture.lean:94)
```

Four times the spans means sixteen times the bytes. Both functions update
the state with `let state ← get` and then `set { state with ... }` inside
`profilerState.atomically` (`LeanProfiler/Runtime/Capture.lean:65` and
`:94`). Most of the bytes come from `events.push` (`Capture.lean:107`) and
from the bucket arrays of the hash maps updated on every span:
`eventDepths.insert` (`:89`) and `stacks.insert` (`:88`, and again at
`:109`). The hash-map insertion is one specialization shared by both
functions, which is why its copies all show up under `reserveSpan (in
Std.DHashMap.Internal.Raw₀.insert)`, so that row is not `eventDepths`
alone.

**Why the arrays are never updated in place.** As far as we can tell:

1. `profilerState` is a global created by `initialize` (`Capture.lean:51`,
   `Std.Mutex.new {}`), and the generated C marks it persistent at module
   initialization (`lean_mark_persistent(lp_LeanProfiler_LeanProfiler_Internal_profilerState)`
   in `Capture.c`).
2. `Std.Mutex` keeps its state in an `IO.Ref`, and `AtomicT` writes through
   `Ref.set`. When the ref is persistent or multi-threaded, the runtime
   marks the stored value multi-threaded. The copy report gives the reason
   for every one of these copies as `multi-threaded`, not `shared`.
3. `lean_is_exclusive` is false for multi-threaded objects (`lean.h`), so
   `Array.push` and the hash map's bucket updates always copy, even when the
   state holds the only reference.

So every span copies `events` and the bucket arrays of `eventDepths`.
Entries for completed spans are removed from `eventDepths` only when the
event is dropped (`Capture.lean:110–111`, `if isDropped then
state.eventDepths.erase event.index else state.eventDepths`). For retained
events the map keeps growing, so fixing `events` alone would leave this
cost. With `LEAN_PROFILE_MAX_EVENTS` set, spans past the limit aren't pushed
onto `events` and their depth entries are erased. They are still inserted
first, though.

**At export (smaller, same pattern).** After the capture closes, two analysis
loops also copy an array per event, 4,001 times at 4,000 spans:

```
spans   copies       bytes       time  why     function  (where)
4,000     4001    61.0 MiB    8.2 ms  shared  LeanProfiler.validateEvents (in Array.forIn'Unsafe.loop)  (LeanProfiler/Analysis/Validation.lean:58)
          4001    61.0 MiB    2.6 ms  shared  LeanProfiler.Internal.buildRows (in Array.forIn'Unsafe.loop)  (LeanProfiler/Analysis/Summary.lean:53)
16,000   16001   976.5 MiB  159.5 ms  shared  LeanProfiler.validateEvents (in Array.forIn'Unsafe.loop)  (LeanProfiler/Analysis/Validation.lean:58)
         16001   976.5 MiB   40.4 ms  shared  LeanProfiler.Internal.buildRows (in Array.forIn'Unsafe.loop)  (LeanProfiler/Analysis/Summary.lean:53)
```

Both read an array out of a hash map that still holds it, push onto it, and
insert it back:

- `buildRows` (`Summary.lean:58–70`): `let current := totals.getD key {}`,
  then `totals.insert key { ... durations := current.durations.push
  timing.inclusiveNs ... }`.
- `validateEvents` (`Validation.lean:97–98`): `let siblings :=
  siblingsByParent.getD key #[]`, then `siblingsByParent.insert key
  (siblings.push { ... })`.

The map's copy keeps a second reference to the array, so each push copies
it. These loops are quadratic in the number of events that share a key. In
this benchmark, the worker's n `step` spans share a key (the same name in
`buildRows`, and the same parent and thread in `validateEvents`). The
enclosing `bench` span on the parent thread accounts for the extra one in
4,001 and 16,001.

**Possible fixes** (untested):

- Store events in a structure whose append doesn't copy everything when the
  value is shared, such as `Lean.PersistentArray`. leanprover/lean4#15228
  applied the same fix to frontend arrays that were copied on every push.
- Bound `eventDepths`, or keep it out of the shared state. Completed spans
  can't simply be removed, because a later span can name a completed span
  as its explicit parent (`withContext ... parentIndex`) and the depth is
  looked up there. Storing the depth in the reservation that the child
  receives, or in a structure that doesn't copy on insert, would avoid
  that.
- Alternatively, record into per-thread buffers that are never stored in
  the shared ref, and merge them at export.
- For the export loops, take the value out of the map before updating it
  (erase it, or use `Std.HashMap.alter`/`modify` if they hand over the only
  reference; we have not checked that they do), or keep durations and
  siblings in arrays indexed by a key number instead of inside the map.

**Reproduce.** See
https://github.com/unbalancedparentheses/leanprof/tree/main/bench.

```
cd bench && lake build bench
LEAN_PROFILE=1 .lake/build/bin/bench leanprofiler 1 4000
# with copy counts: LeanProfiler and the benchmark are rebuilt with
# leanprof's probes, run, and the normal build is put back
LEAN_PROFILE=1 lake exe leanprof run bench -- leanprofiler 1 4000
```

(`leanprof run` builds every package with a `LEAN_CC` wrapper that forwards
to the system clang, adds `-D` flags that route the runtime's copy and task
functions through counting shims, and links with `-rdynamic` so the report
can name functions. The shims come from leanprof, which the benchmark
package depends on. LeanProfiler's sources are not changed.)

---

## Notes for us (not part of the issue)

- Reproduce steps simplified on 2026-10-23 (branch `runtime-checks`):
  `leanprof run` now rebuilds dependencies with the probes and puts the
  normal build back. Checked at 4,000 spans that it gives the same copy
  counts and bytes as the old manual rebuild (`find .lake -name '*.c.o*'
  -delete` and `LEAN_CC=../scripts/leanprof-cc lake build bench`): 12003
  (123.0 MiB), 8002 (61.1 MiB), 4001 and 4001 (61.0 MiB each).

- Changes from the earlier scratch draft: the measurements were re-run.
  The copy reason is now printed as `multi-threaded` (leanprof used to print
  `multi-threaded+persistent`). `lean_mark_persistent(...profilerState)` is
  still in the generated `Capture.c` (line 4286 in our build). That the
  runtime marks values stored into a persistent ref as multi-threaded is
  from reading Lean's runtime earlier and was not re-checked today (the
  toolchain ships no runtime sources). We also added the 1,000 and 16,000 span copy counts and the two export-time loops
  (new).
- `bench/README.md` still shows the 2026-10-22 numbers. They are consistent
  with today's runs (same copy counts and bytes at 4,000 spans; times
  higher under load).
- Tone: this is someone else's project. Keep the issue factual, credit
  what works (recording off is cheap; the spans API and Perfetto output),
  and offer a PR if they want one.

## Accuracy review

Reviewed by Codex (`codex exec --sandbox read-only`, codex-cli 0.162.1) on 2026-10-23, in two passes, against README.md, the guides, the case studies, bench/RESULTS.md and the code, and against the measurements re-run for these drafts.

Fixed after the review:
- The `reserveSpan (in ...insert)` row is now attributed to both hash maps (`eventDepths` and `stacks`): one specialization shared by both functions.
- The quadratic growth is now scoped to the default, uncapped capture (`LEAN_PROFILE_MAX_EVENTS` unset).
- The "same key" explanation now covers the extra event (the enclosing `bench` span) and `validateEvents`' (parent, thread) key.
- Removing completed spans from `eventDepths` would break explicit parent links (`withContext ... parentIndex`). The suggestion now says so.
- The wrapper's description now includes clang selection and `-rdynamic`, and the reproduction comment no longer says "every package".
- Recording-off cost is now 23–36 ns, and "2 threads in total" was dropped (not verifiable).

