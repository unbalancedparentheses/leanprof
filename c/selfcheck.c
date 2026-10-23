/*
 * leanprof self-check, compiled with the same copy flags as the program's
 * code (scripts/leanprof-cc, or `copyFlags` in the lakefile), so its calls
 * reach the runtime through the same lean.h and the same `-D` renames as
 * the C that Lean generates. leanprof.c runs each operation once at exit on
 * a shared one-element value: each must be counted as one copy. When one is
 * not (a Lean version made a function inline, or moved the copy into a
 * function the flags do not rename), the report warns that copies of that
 * kind may be undercounted. Lean 4.36 did this to lean_string_push.
 */
#include "selfcheck.h"

LEAN_EXPORT int leanprof_selfcheck_flags(void) {
#ifdef lean_array_push /* -Dlean_array_push=leanprof_array_push */
    return 1;
#else
    return 0;
#endif
}

LEAN_EXPORT lean_object *leanprof_selfcheck_op(unsigned op, lean_object *x) {
    switch (op) {
    case LPS_ARRAY_PUSH: return lean_array_push(x, lean_box(1));
    case LPS_ARRAY_SET: return lean_array_set(x, lean_box(0), lean_box(1));
    case LPS_STRING_PUSH: return lean_string_push(x, 'x');
    case LPS_STRING_APPEND: return lean_string_append(x, x); /* the caller holds another reference */
    case LPS_BYTE_ARRAY_PUSH: return lean_byte_array_push(x, 1);
#if LEAN_VERSION_MAJOR > 4 || (LEAN_VERSION_MAJOR == 4 && LEAN_VERSION_MINOR >= 35)
    case LPS_BYTE_ARRAY_SET: return lean_byte_array_set(x, lean_box(0), 1);
#endif
    default: lean_dec(x); return NULL;
    }
}
