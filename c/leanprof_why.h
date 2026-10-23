/*
 * Force-included after lean.h (`-include lean/lean.h -include leanprof_why.h`)
 * by scripts/leanprof-cc when LEANPROF_WHY=1. lean.h's own inline functions
 * are already compiled by then and stay unchanged; from here on, the emitted
 * C's reference-count increments go through these versions, which tell
 * leanprof (c/explain.inc.c) when an Array, scalar array or String becomes
 * shared, and where: `leanprof explain` reports it next to each copy.
 */
#pragma once
#include <lean/lean.h>

LEAN_EXPORT void leanprof_note_share(lean_object *o, const char *fn, const char *file, unsigned line);

static inline void leanprof_why_check(lean_object *o, int n, const char *fn, const char *file, unsigned line) {
    /* single-threaded and now exactly 1 + n references: it just became shared */
    if (lean_is_st(o) && o->m_rc == 1 + n) {
        uint8_t tag = lean_ptr_tag(o);
        if (tag == LeanArray || tag == LeanScalarArray || tag == LeanString)
            leanprof_note_share(o, fn, file, line);
    }
}

static inline void leanprof_why_inc_ref_n(lean_object *o, size_t n, const char *fn, const char *file,
                                          unsigned line) {
    lean_inc_ref_n(o, n);
    leanprof_why_check(o, (int)n, fn, file, line);
}

static inline void leanprof_why_inc_n(lean_object *o, size_t n, const char *fn, const char *file, unsigned line) {
    if (!lean_is_scalar(o)) leanprof_why_inc_ref_n(o, n, fn, file, line);
}

#define lean_inc_ref(o) leanprof_why_inc_ref_n((o), 1, __func__, __FILE__, __LINE__)
#define lean_inc_ref_n(o, n) leanprof_why_inc_ref_n((o), (n), __func__, __FILE__, __LINE__)
#define lean_inc(o) leanprof_why_inc_n((o), 1, __func__, __FILE__, __LINE__)
#define lean_inc_n(o, n) leanprof_why_inc_n((o), (n), __func__, __FILE__, __LINE__)
