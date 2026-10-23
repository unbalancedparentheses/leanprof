# Draft: cover note for the runtime profiling hooks proposal

*Draft only. Not sent. To accompany
[`docs/proposals/runtime-profiling-hooks.md`](../proposals/runtime-profiling-hooks.md),
for example in a Zulip DM or a thread in #lean4 dev, or as the body of an
RFC issue if they prefer that.*

---

**Subject:** Optional runtime hooks for profilers: copies, allocations, frees, `#line`

Hi,

I maintain [leanprof](https://github.com/unbalancedparentheses/leanprof), a
profiler for compiled Lean programs. It needs no changes to Lean. It
recompiles a project's generated C with `-Dlean_array_push=leanprof_array_push`
(and similar), so copies of non-exclusive values, allocations, task spawns,
waits and freeing cascades go through counting shims. The `*_nonlinear`
copy entry points (the `sarray` and `string` ones are new in 4.35) made the
copy side much cleaner, so thank you for those.

This works well for user code. On lean-compiler-backend it found a fix
attempt that copied 6.84 GiB on one input, and a tokenizer making a third of
the run's allocations. It does hit three walls that only the runtime can
remove:

1. **Lean's own libraries and runtime.** `run --core` now rewrites symbol
   references in copies of `libInit.a`/`libStd.a`/`libLean.a` with
   `llvm-objcopy` (or GNU `objcopy` on Linux). It works, but it needs an
   extra tool and about 260 MB of archive copies per configuration, and it
   relies on none of those archives defining a redirected function. Allocations the runtime makes inside `libleanrt.a`
   itself (`String`, `Nat` primitives in C++) can't be reached at all.
2. **Frees.** Compiled code reaches the start of a cascade
   (`lean_dec_ref_cold`), but the objects the cascade frees are freed inside
   the runtime. We count them by walking the structure before the runtime
   frees it, which doubles the work and still doesn't give per-object
   lifetimes.
3. **Source lines.** The generated C has no line information, so automatic
   attribution in any profiler (ours, perf, samply, a debugger) stops at
   declarations. Only scopes marked by hand carry a line.

The attached note proposes:

- an optional event hook (`lean_set_event_hook`) called from the
  `*_nonlinear` copies and from freeing, which are already slow paths. For
  allocations, whose small-object fast path is inlined from mimalloc, it
  would probably need a build flag;
- an opt-in `EmitC` option to emit `#line` directives, starting from
  declaration positions;
- start/finish callbacks from the task manager.

It is a draft for discussion, not a PR. Before writing code I'd like to know
which of these, if any, you would consider, and in what form. The questions
at the end of the note are the ones I could not answer from the outside. As
of 2026-10-23, `lean.h` in 4.36.0-rc1 and in that day's nightly has nothing
like this, so I don't think it duplicates existing work. If it does, I'd be
glad to be pointed to it.

If useful, I can share measurements: the benchmark suite in
[`bench/`](https://github.com/unbalancedparentheses/leanprof/blob/main/bench/RESULTS.md)
has the current overhead of the shims, and `--core`'s cost and noise are
described in
[the copies guide](https://github.com/unbalancedparentheses/leanprof/blob/main/docs/guide/copies-and-allocations.md#copies-inside-leans-own-libraries---core).

Thanks for reading,
…

---

## Accuracy review

Reviewed by Codex (`codex exec --sandbox read-only`, codex-cli 0.162.1) on 2026-10-23, in two passes, against README.md, the guides, the case studies, bench/RESULTS.md and the code, and against the measurements re-run for these drafts.

Fixed after the review, here and in `docs/proposals/runtime-profiling-hooks.md`:
- **Allocation hook.** Small allocations inline mimalloc's fast path (`lean_alloc_small_object_core`), so a hook "on the allocator's slow path" would miss most of them. The proposal now separates allocations, probably behind a build flag, from copies and frees (already slow paths).
- **Frees.** Compiled code also reaches the exported `lean_free_object` (via `lean_dec_ref_known`). The missing piece is per-object lifetimes inside a cascade, not "live memory", which leanprof already samples.
- **`#line`.** LCNF/IR carry no `let` positions. The proposal now starts from declaration positions, notes that finer positions are new compiler work, and says that leanprof would itself need to read line tables.
- **`return_address`.** It names the immediate caller: right for compiled Lean code, not for events inside the runtime. The hot/cold-splitting caveat is now described correctly.
- **Lines.** "Every profiler stops at declarations" is now limited to automatic attribution, because `profile!` scopes carry lines.
- **`--core` storage.** About 260 MB per cached set (project, toolchain and options), and it also works with GNU `objcopy` on Linux.

Still unverified (stated as proposals, not facts): the disabled cost of the hooks, and critical paths from task callbacks.

