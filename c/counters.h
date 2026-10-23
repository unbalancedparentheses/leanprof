/*
 * leanprof counters: force-included (`-include c/counters.h`) into the C that
 * Lean generates, when counters are on (LEANPROF_COUNTERS=1 through
 * scripts/leanprof-cc, or `counterFlags` in the lakefile).
 *
 * `lean_is_exclusive` is `static inline` in lean.h, so `-D` cannot redirect
 * it without also renaming its definition. Including lean.h first (it is
 * `#pragma once`, so the generated file's own #include is then a no-op) and
 * defining the macros afterwards leaves lean.h's inline bodies untouched and
 * redirects only the uses in the generated code. In Lean's output these uses
 * are the reset/reuse checks (`isSharedCheck = !lean_is_exclusive(x)`) that
 * decide whether a constructor cell is updated in place.
 *
 * The `lean_apply_*` entry points are exported runtime functions; they are
 * renamed here too so the generated code calls leanprof's shims, which
 * classify the application and forward to the runtime.
 *
 * The shims are in c/counters.inc.c. Both return exactly what the runtime
 * would, so behavior does not change.
 */
#pragma once
#include <lean/lean.h>

LEAN_EXPORT bool leanprof_is_exclusive(lean_object *o);
#define lean_is_exclusive(o) leanprof_is_exclusive(o)

LEAN_EXPORT lean_object *leanprof_apply_1(lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_2(lean_object *, lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_3(lean_object *, lean_object *, lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_4(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_5(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                          lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_6(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                          lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_7(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                          lean_object *, lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_8(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                          lean_object *, lean_object *, lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_9(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                          lean_object *, lean_object *, lean_object *, lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_10(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_11(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_12(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_13(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *, lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_14(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *, lean_object *, lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_15(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_16(lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *, lean_object *, lean_object *, lean_object *,
                                           lean_object *, lean_object *);
LEAN_EXPORT lean_object *leanprof_apply_n(lean_object *f, unsigned n, lean_object **args);
LEAN_EXPORT lean_object *leanprof_apply_m(lean_object *f, unsigned n, lean_object **args);

#define lean_apply_1 leanprof_apply_1
#define lean_apply_2 leanprof_apply_2
#define lean_apply_3 leanprof_apply_3
#define lean_apply_4 leanprof_apply_4
#define lean_apply_5 leanprof_apply_5
#define lean_apply_6 leanprof_apply_6
#define lean_apply_7 leanprof_apply_7
#define lean_apply_8 leanprof_apply_8
#define lean_apply_9 leanprof_apply_9
#define lean_apply_10 leanprof_apply_10
#define lean_apply_11 leanprof_apply_11
#define lean_apply_12 leanprof_apply_12
#define lean_apply_13 leanprof_apply_13
#define lean_apply_14 leanprof_apply_14
#define lean_apply_15 leanprof_apply_15
#define lean_apply_16 leanprof_apply_16
#define lean_apply_n leanprof_apply_n
#define lean_apply_m leanprof_apply_m
