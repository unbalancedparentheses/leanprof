/*
 * "Who shared it": where the second reference to a copied value was taken.
 *
 * Included once from leanprof.c, after `lpf_begin` and before the copy shims.
 *
 * Programs built with LEANPROF_WHY=1 (see scripts/leanprof-cc) get
 * `c/leanprof_why.h` force-included after `lean.h`: it turns `lean_inc`,
 * `lean_inc_ref` and their `_n` forms in the emitted C into versions that, when
 * an Array, scalar array or String goes from one reference to two, call
 * `leanprof_note_share` with the C function, file and line of the increment.
 * Each thread keeps the last such increment per object address in a small
 * direct-mapped table (no locks; single-threaded objects stay on one thread).
 * When a copy shim then sees a shared value, it looks the address up and
 * counts (copy site, increment site) pairs, which are written at exit to
 * LEANPROF_WHY_JSON (default .lake/leanprof/why.json) for `leanprof explain`.
 *
 * Heuristics, said in the output: the table is lossy (a newer object at the
 * same slot replaces an older one), an address can be reused after a free
 * (tag and capacity are checked to catch most of these), and increments made
 * inside Lean's precompiled library or inside `lean.h`'s inline functions are
 * not seen, so a record is "the last recorded increment".
 */

#define LP_SHARE_SLOTS 4096 /* per thread, power of two */
#define LP_WHY_PAIRS 4096   /* distinct (copy site, increment site) pairs */

typedef struct {
    const lean_object *obj;
    const char *fn, *file;
    unsigned line;
    uint8_t tag;
    size_t cap;
} lpf_share;

typedef struct {
    void *pc;            /* the copying call */
    const char *fn, *file; /* the increment */
    unsigned line;
    uint64_t count;
} lpf_why_pair;

static _Thread_local lpf_share *lpf_shares;
static lpf_why_pair lpf_why[LP_WHY_PAIRS];
static uint64_t lpf_why_unknown, lpf_why_dropped;
static int lpf_why_used;
static pthread_mutex_t lpf_why_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t lpf_why_once = PTHREAD_ONCE_INIT;

static void lpf_symbol_raw(void *pc, char *out, size_t cap);
static void lpf_symbol_name(void *pc, char *out, size_t cap);
static void lpf_demangle(const char *s, char *out, size_t cap);
static const char *lpf_where(const char *fn, char *out, size_t cap);
static void lpf_json_str(FILE *f, const char *s);

static size_t lpf_obj_cap(lean_object *o) {
    switch (lean_ptr_tag(o)) {
    case LeanArray: return lean_to_array(o)->m_capacity;
    case LeanScalarArray: return lean_to_sarray(o)->m_capacity;
    case LeanString: return lean_to_string(o)->m_capacity;
    default: return 0;
    }
}

static void lpf_why_write(void) {
    if (!lpf_why_used) return;
    const char *path = getenv("LEANPROF_WHY_JSON");
    if (path == NULL || !path[0]) path = ".lake/leanprof/why.json";
    FILE *f = fopen(path, "w");
    if (f == NULL) return;
    fprintf(f, "{\"version\":1,\"unrecorded\":%llu,\"dropped\":%llu,\"shares\":[",
            (unsigned long long)lpf_why_unknown, (unsigned long long)lpf_why_dropped);
    int first = 1;
    for (size_t i = 0; i < LP_WHY_PAIRS; i++) {
        lpf_why_pair *p = &lpf_why[i];
        if (p->count == 0) continue;
        char sym[1024], copyfn[1024], fn[1024], where[1024];
        lpf_symbol_raw(p->pc, sym, sizeof sym);
        lpf_symbol_name(p->pc, copyfn, sizeof copyfn);
        lpf_demangle(p->fn, fn, sizeof fn);
        lpf_where(fn, where, sizeof where);
        fprintf(f, "%s{\"copy_symbol\":", first ? "" : ",");
        first = 0;
        lpf_json_str(f, sym);
        fprintf(f, ",\"copy_function\":");
        lpf_json_str(f, copyfn);
        fprintf(f, ",\"symbol\":");
        lpf_json_str(f, p->fn);
        fprintf(f, ",\"function\":");
        lpf_json_str(f, fn);
        fprintf(f, ",\"where\":");
        lpf_json_str(f, where);
        fprintf(f, ",\"file\":");
        lpf_json_str(f, p->file);
        fprintf(f, ",\"line\":%u,\"count\":%llu}", p->line, (unsigned long long)p->count);
    }
    fprintf(f, "]}\n");
    fclose(f);
}

static void lpf_why_init(void) {
    lpf_why_used = 1;
    atexit(lpf_why_write);
}

/* Called by the force-included header when an increment makes an Array,
 * scalar array or String shared (its count goes from 1 to 1 + n). */
LEAN_EXPORT void leanprof_note_share(lean_object *o, const char *fn, const char *file, unsigned line) {
    if (LEAN_UNLIKELY(lpf_shares == NULL)) {
        pthread_once(&lpf_why_once, lpf_why_init);
        lpf_shares = calloc(LP_SHARE_SLOTS, sizeof(lpf_share));
        if (lpf_shares == NULL) return;
    }
    lpf_share *s = &lpf_shares[((uintptr_t)o >> 4) & (LP_SHARE_SLOTS - 1)];
    s->obj = o;
    s->fn = fn;
    s->file = file;
    s->line = line;
    s->tag = lean_ptr_tag(o);
    s->cap = lpf_obj_cap(o);
}

/* Out of line: the copy shims stay small. */
__attribute__((noinline)) static void lpf_why_count(void *pc, lean_object *o) {
    const lpf_share *s = NULL;
    if (lpf_shares != NULL) {
        s = &lpf_shares[((uintptr_t)o >> 4) & (LP_SHARE_SLOTS - 1)];
        if (s->obj != o || s->tag != lean_ptr_tag(o) || s->cap != lpf_obj_cap(o)) s = NULL;
    }
    pthread_mutex_lock(&lpf_why_lock);
    if (s == NULL) {
        lpf_why_unknown++;
    } else {
        size_t h = (((uintptr_t)pc >> 2) ^ ((uintptr_t)s->file >> 3) ^ s->line * 2654435761u) & (LP_WHY_PAIRS - 1);
        size_t k = 0;
        for (; k < LP_WHY_PAIRS; k++, h = (h + 1) & (LP_WHY_PAIRS - 1)) {
            lpf_why_pair *p = &lpf_why[h];
            if (p->count == 0) {
                *p = (lpf_why_pair){pc, s->fn, s->file, s->line, 1};
                break;
            }
            if (p->pc == pc && p->line == s->line && p->file == s->file) {
                p->count++;
                break;
            }
        }
        if (k == LP_WHY_PAIRS) lpf_why_dropped++;
    }
    pthread_mutex_unlock(&lpf_why_lock);
}

/* The copy shims below take their caller's address with
 * `__builtin_return_address(0)`. clang's hot/cold splitting can move a shim's
 * slow path into a separate `.cold` function, where that address is inside
 * the shim, and the copy is then reported under the shim's name. Functions
 * marked `noinline` are not split. */
#define LP_NOSPLIT __attribute__((noinline))
LEAN_EXPORT lean_obj_res leanprof_copy_expand_array_nonlinear(lean_obj_arg a, bool expand) LP_NOSPLIT;
#if LEAN_VERSION_MAJOR > 4 || (LEAN_VERSION_MAJOR == 4 && LEAN_VERSION_MINOR >= 35)
LEAN_EXPORT lean_obj_res leanprof_copy_sarray_nonlinear(lean_obj_arg a, size_t cap) LP_NOSPLIT;
LEAN_EXPORT lean_obj_res leanprof_copy_string_nonlinear(lean_obj_arg s, size_t cap) LP_NOSPLIT;
#endif
LEAN_EXPORT lean_object *leanprof_array_push(lean_obj_arg a, lean_obj_arg v) LP_NOSPLIT;
LEAN_EXPORT lean_obj_res leanprof_byte_array_push(lean_obj_arg a, uint8_t b) LP_NOSPLIT;
LEAN_EXPORT lean_obj_res leanprof_float_array_push(lean_obj_arg a, double d) LP_NOSPLIT;
LEAN_EXPORT lean_obj_res leanprof_string_push(lean_obj_arg s, uint32_t c) LP_NOSPLIT;
#if LEAN_VERSION_MAJOR > 4 || (LEAN_VERSION_MAJOR == 4 && LEAN_VERSION_MINOR >= 36)
LEAN_EXPORT lean_obj_res leanprof_string_push_cold(lean_obj_arg s, uint32_t c) LP_NOSPLIT;
#endif
LEAN_EXPORT lean_obj_res leanprof_string_append(lean_obj_arg s1, b_lean_obj_arg s2) LP_NOSPLIT;
LEAN_EXPORT lean_obj_res leanprof_string_utf8_set(lean_obj_arg s, b_lean_obj_arg i, uint32_t c) LP_NOSPLIT;

/* `lpf_begin` with the share lookup; the copy shims below call this one. */
static inline lpf_pending lpf_explain_begin(void *pc, lean_object *o, uint8_t kind, size_t bytes) {
    if (LEAN_UNLIKELY(lpf_why_used) && lean_internal_get_rc(o) > 0) lpf_why_count(pc, o);
    return lpf_begin(pc, o, kind, bytes);
}
#define lpf_begin lpf_explain_begin
