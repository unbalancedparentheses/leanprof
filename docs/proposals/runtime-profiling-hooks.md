# Draft: optional profiling hooks in the Lean runtime

*Status: draft for discussion, not submitted.*

## Summary

Profilers for compiled Lean programs can observe most runtime events from
outside: [leanprof](https://github.com/unbalancedparentheses/leanprof)
compiles a program's generated C with `-Dlean_array_push=leanprof_array_push`
(and similar) to route copies of non-exclusive values, allocations, task
spawns and blocking waits through its own shims. This needs no change to
Lean, but it is blind to three things:

1. **Events inside the precompiled libraries.** `Init`, `Std` and `Lean` are
   shipped compiled; their calls to `lean_copy_expand_array`, the allocator
   and so on cannot be redirected, so a copy made inside `Array.mapM` or an
   allocation inside `Std.HashMap.insert` is invisible unless the code was
   specialized into the user's module.
2. **Frees.** Objects are freed inside `lean_del_core`; only the start of a
   cascade (`lean_dec_ref_cold`) is reachable, so live memory and object
   lifetimes cannot be measured.
3. **Source lines.** The generated C carries no line information, so
   profiles resolve to declarations, not lines.

This proposes three small, optional additions that cost nothing when unused.

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

The runtime calls the hook (if set) from the slow paths that already exist:
`lean_copy_expand_array_nonlinear`, `lean_copy_sarray_nonlinear`,
`lean_copy_string_nonlinear` (added in 4.35 "to spot non-linearities in
profiles"), the allocator's slow path and `lean_free_object`/`lean_del_core`.
When no hook is set the cost is one predictable branch on paths that already
copy or free. The `return_address` (`__builtin_return_address(0)` at the
call into the runtime) lets a profiler attribute the event to the Lean
function that caused it, including functions in the precompiled libraries.

A build-time flag (`LEAN_EVENT_HOOKS`, off by default) would also be
acceptable if a branch on the allocation path is unwelcome; profilers would
then link a hooked build of the runtime.

## 2. `#line` directives in the generated C (optional)

An option for `EmitC` (e.g. `compiler.emitLineDirectives`) that emits
`#line N "File.lean"` from the positions the compiler still has (LCNF
declarations and, where kept, `let` positions). Debuggers, `perf`, samply and
leanprof would then report Lean source lines instead of declarations. Off by
default, so normal builds and their caches are unaffected.

## 3. A task event callback

`lean_task_spawn_core`, `lean_task_map_core` and `lean_task_bind_core` are
already exported and can be wrapped, but task start, finish and the queue
are internal to the task manager. A callback for "task started on worker" and
"task finished" (with the task pointer) would let profilers draw accurate
timelines and critical paths without wrapping closures.

## What leanprof does today without these

- Copies, allocations, task spawns and waits from user code: redirected at
  compile time (works on Lean 4.34 and 4.35, no Lean changes).
- Frees: `lean_dec_ref_cold` is redirected and the cascade walked to count
  objects; pauses are timed, but individual frees and lifetimes are not seen.
- Precompiled libraries: rewriting symbol references in copies of the static
  libraries with `llvm-objcopy` is being evaluated; a supported hook would
  make that unnecessary.

## Questions for the Lean developers

- Is a hook on these slow paths acceptable in release builds, or only behind
  a build flag?
- Is there a better source of positions for `#line` than LCNF declarations?
- Would the task manager accept start/finish callbacks, or is there an
  existing tracing mechanism to reuse?
