/*
 * leanprof self-check: the operations c/selfcheck.c performs. Shared by
 * c/selfcheck.c (compiled with the copy flags, like the program's code) and
 * c/leanprof.c (which runs them once at exit and checks that each copy was
 * seen by a shim).
 */
#pragma once
#include <lean/lean.h>

enum {
    LPS_ARRAY_PUSH,      /* Array.push        -> lean_array_push */
    LPS_ARRAY_SET,       /* Array.set!        -> lean_array_set -> lean_copy_expand_array_nonlinear */
    LPS_STRING_PUSH,     /* String.push       -> lean_string_push (inline since 4.36: lean_string_push_cold) */
    LPS_STRING_APPEND,   /* String.append     -> lean_string_append */
    LPS_BYTE_ARRAY_PUSH, /* ByteArray.push    -> lean_byte_array_push */
    LPS_BYTE_ARRAY_SET,  /* ByteArray.set!    -> lean_byte_array_set -> lean_copy_sarray_nonlinear (4.35+) */
    LPS_OPS
};

/* Runs operation `op` on `x` (consumed) as compiled Lean code calls it and
 * returns the result, or NULL if `op` does not exist in this Lean version. */
LEAN_EXPORT lean_object *leanprof_selfcheck_op(unsigned op, lean_object *x);
/* 1 when c/selfcheck.c was compiled with leanprof's copy flags. */
LEAN_EXPORT int leanprof_selfcheck_flags(void);
