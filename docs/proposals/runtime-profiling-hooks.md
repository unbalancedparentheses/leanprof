# Draft: optional profiling hooks in the Lean runtime

*Status: draft for discussion, not submitted.*

## Summary

Profilers for compiled Lean programs can observe most runtime events from
outside: [leanprof](https://github.com/unbalancedparentheses/leanprof)
compiles a program's generated C with `-Dlean_array_push=leanprof_array_push`
(and similar) to route copies of non-exclusive values, allocations, task
spawns and blocking waits through its own shims. This needs no change to
Lean, but it is blind to three things:

1. **Events inside the precompiled libraries and the runtime.** `Init`,
   `Std` and `Lean` are shipped compiled, so the `-D` flags never reach their
   calls to `lean_copy_expand_array`, the allocator and so on. A copy made
   inside `Array.mapM`, or an allocation inside `Std.HashMap.insert`, is
   invisible unless the code was specialized into the user's module.
   leanprof's `run --core` works around this by linking against copies of
   those archives with the references renamed (`llvm-objcopy
   --redefine-sym`). The rewrite needs `llvm-objcopy` (or GNU `objcopy` on
   Linux), and each cached set of copies takes about 260 MB (one per
   project, toolchain and set of options). It is safe only because none of the
   rewritten archives defines a redirected function. Calls the runtime makes
   to itself inside `libleanrt.a` stay invisible either way, for example the
   allocations of `String` and `Nat` primitives implemented in C++.
2. **Frees.** Compiled code reaches the start of a cascade
   (`lean_dec_ref_cold`) and, for some exclusive constructors, the exported
   `lean_free_object` (through `lean.h`'s inline `lean_dec_ref_known`). The
   objects a cascade frees are freed inside the runtime (`lean_del_core`), so
   per-object lifetimes and exact live-object accounting can't be measured.
   Process memory over time can be (resident memory, mimalloc's committed
   bytes).
3. **Source lines.** The generated C carries no line information, so
   automatic attribution (sampled stacks, per-function times, copy sites)
   resolves to declarations, not lines. Explicit `profile!` scopes carry
   their own file:line.

This proposes three small, optional additions. When unused, the copy, free
and task hooks cost one predictable branch on paths that are already slow.
An allocation hook is different, because allocation has a fast path (see
below).

## 1. A runtime event hook

```c
/* lean.h */
typedef enum {
    LEAN_EV_COPY_ARRAY, LEAN_EV_COPY_SARRAY, LEAN_EV_COPY_STRING,   /* non-exclusive value copied */
    LEAN_EV_ALLOC, LEAN_EV_FREE,                                    /* object allocated / freed */
} lean_event_kind;

typedef void (*lean_event_hook)(lean_event_kind kind, lean_object *o, size_t bytes, void *return_address);

LEAN_EXPORT void lean_set_event_hook(lean_event_hook hook);   /* NULL disables */
```

The runtime calls the hook (if set) from paths that already exist:
`lean_copy_expand_array_nonlinear`, `lean_copy_sarray_nonlinear` and
`lean_copy_string_nonlinear` (the last two added in 4.35; `lean.h` describes
them as gadgets "to spot non-linearities in profiles"), and
`lean_free_object`/`lean_del_core`. On these paths, which already copy or
free, an unset hook costs one predictable branch.

Allocations are the exception. Small objects go through
`lean_alloc_small_object_core`, which inlines mimalloc's fast path, so
hooking only the allocator's slow path would miss most allocations, and
hooking every allocation puts a branch on a hot path. For allocations, a
build-time flag (`LEAN_EVENT_HOOKS`, off by default) is probably the right
form, with profilers linking a hooked build of the runtime. The same flag
would also do for the other events, if even a branch on the slow paths is
unwelcome.

The `return_address` (`__builtin_return_address(0)` at the call into the
runtime) identifies the immediate caller. For a copy or allocation made by
compiled Lean code, including code in the precompiled libraries, that is
the Lean function that caused it, provided the runtime function that takes
the address is not split by the C compiler's hot/cold splitting. If the
address is taken in a split-off `.cold` part, it points back into the
runtime function instead, which is why leanprof marks its shims
`noinline`. For events inside the runtime's own code,
or in a cascade of frees, the caller is another runtime function, and a
profiler would have to unwind the stack to find the Lean code.

## 2. `#line` directives in the generated C (optional)

An option for `EmitC` (e.g. `compiler.emitLineDirectives`) that emits
`#line N "File.lean"` directives. At minimum, each function would get its
declaration's position, which the environment has. Finer positions (per
`let`) would need positions carried through the LCNF and IR passes, which
the compiler doesn't do today (`LetDecl` and `Decl` have no source
positions), so that part is new work. Debuggers, `perf` and samply would
then report Lean source lines from the debug line tables. leanprof would
need to read them too: it currently maps function names to `.ilean`
declaration ranges. Off by default, so normal builds and their caches are
unaffected.

## 3. A task event callback

`lean_task_spawn_core`, `lean_task_map_core` and `lean_task_bind_core` are
already exported and can be wrapped, but task start, finish and the queue
are internal to the task manager. A callback for "task started on worker" and
"task finished" (with the task pointer) would let profilers draw accurate
timelines without wrapping closures. Combined with the blocking waits that
leanprof already records, they would also give critical paths.

## What leanprof does today without these

- Copies, allocations, task spawns and waits from user code: redirected at
  compile time (Lean 4.34 and later, tested on 4.34.1 and 4.35.0, no Lean
  changes).
- Failed constructor reuse and closure applications (`--counters`), and
  where a copied value got its second reference (`explain --why`):
  `lean_is_exclusive` and `lean_inc` are `static inline` in `lean.h`, so
  leanprof includes headers after `lean.h` that redefine them (and
  `lean_apply_*`) as macros for its shims. This only sees user code.
- Frees: `lean_dec_ref_cold` is redirected and the cascade walked to count
  objects; pauses are timed, but individual frees and lifetimes are not seen.
- Precompiled libraries: `run --core` rewrites symbol references in copies
  of the static libraries (above). A supported hook would make that
  unnecessary, and would also cover the runtime's own calls.
- As of 2026-10-23, `lean.h` in 4.36.0-rc1 and in the nightly of that date
  has no event hook or callback of this kind.

## Questions for the Lean developers

- Is a hook on these slow paths acceptable in release builds, or only behind
  a build flag?
- Is there a better source of positions for `#line` than declaration
  ranges, and would carrying positions through LCNF be acceptable?
- Would the task manager accept start/finish callbacks, or is there an
  existing tracing mechanism to reuse?
