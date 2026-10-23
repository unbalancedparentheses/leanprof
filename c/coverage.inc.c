/*
 * Included from leanprof.c (after the task and allocation shims).
 *
 * Task continuations: Task.map, Task.bind, IO.mapTask and IO.bindTask are
 * redirected here like Task.spawn, so the tasks they create are linked to the
 * scope that created them. Their wait is from creation to start, so it
 * includes waiting for the input task, not only for a worker.
 *
 * Core-library coverage (`leanprof run --core`) needs no code of its own: the
 * toolchain's static libraries are copied with their references to the
 * runtime functions renamed to the same `leanprof_*` shims (see
 * LeanprofCli.lean, `coreLibDir`). The definitions live in libleanrt, which is
 * not rewritten, so the shims' own calls still reach the real functions.
 */

LEAN_EXPORT lean_obj_res leanprof_task_map_core(lean_obj_arg f, lean_obj_arg t, unsigned prio, bool sync,
                                                bool keep_alive) {
    return lean_task_map_core(lpf_task_wrap(f), t, prio, sync, keep_alive);
}

LEAN_EXPORT lean_obj_res leanprof_task_bind_core(lean_obj_arg x, lean_obj_arg f, unsigned prio, bool sync,
                                                 bool keep_alive) {
    return lean_task_bind_core(x, lpf_task_wrap(f), prio, sync, keep_alive);
}

/* IO.mapTask and IO.bindTask: the runtime applies the action to the input
 * task's value and the world. `f` gets both inside lpf_task_run's timing:
 * `lpf_io_apply` fixes the world and takes the value as the one argument
 * lpf_task_run passes on. */
static lean_obj_res lpf_io_apply(lean_obj_arg f, lean_obj_arg w, lean_obj_arg a) {
    return lean_apply_2(f, a, w);
}

static lean_obj_res lpf_io_task_run(lean_obj_arg ctx, lean_obj_arg a, lean_obj_arg w) {
    lean_object *f = lean_ctor_get(ctx, 0);
    lean_inc(f);
    lean_object *g = lean_alloc_closure((void *)lpf_io_apply, 3, 2);
    lean_closure_set(g, 0, f);
    lean_closure_set(g, 1, w);
    lean_object *c = lean_alloc_ctor(0, 1, 17);
    lean_ctor_set(c, 0, g);
    memcpy(lean_ctor_scalar_cptr(c), lean_ctor_scalar_cptr(ctx), 17);
    lean_dec(ctx);
    return lpf_task_run(c, a);
}

/* Like lpf_task_wrap, for an action that takes a value and the world. */
static lean_obj_res lpf_io_task_wrap(lean_obj_arg f) {
    lean_object *w = lpf_task_wrap(f);
    lean_object *ctx = lean_closure_get(w, 0);
    lean_inc(ctx);
    lean_dec(w);
    lean_object *r = lean_alloc_closure((void *)lpf_io_task_run, 3, 1);
    lean_closure_set(r, 0, ctx);
    return r;
}

LEAN_EXPORT lean_object *lean_io_map_task(lean_object *f, lean_object *t, lean_object *prio, uint8_t sync);
LEAN_EXPORT lean_object *lean_io_bind_task(lean_object *t, lean_object *f, lean_object *prio, uint8_t sync);

LEAN_EXPORT lean_object *leanprof_io_map_task(lean_object *f, lean_object *t, lean_object *prio, uint8_t sync) {
    return lean_io_map_task(lpf_io_task_wrap(f), t, prio, sync);
}

LEAN_EXPORT lean_object *leanprof_io_bind_task(lean_object *t, lean_object *f, lean_object *prio, uint8_t sync) {
    return lean_io_bind_task(t, lpf_io_task_wrap(f), prio, sync);
}
