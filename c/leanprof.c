/*
 * leanprof runtime: scope timing, copy detection and the exit report.
 *
 * Each thread records into its own tables, so the hot path takes no lock.
 * Tables are registered once in a global list and merged at exit.
 */
#define _GNU_SOURCE /* dladdr on glibc */
#include <lean/lean.h>

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef __APPLE__
#include <mach/mach_time.h>
#endif

#define LP_TABLE 1024      /* slots per thread table, power of two */
#define LP_DEPTH 512       /* deepest scope nesting we keep frames for */
#define LP_SUB 16          /* histogram sub-buckets per power of two */
#define LP_BUCKETS (64 * LP_SUB)

enum { LP_ARRAY, LP_SCALAR_ARRAY, LP_STRING, LP_KINDS };
enum { LP_SHARED, LP_MULTI_THREADED, LP_PERSISTENT, LP_REASONS };

static const char *lp_kind_name[LP_KINDS] = {"Array", "ScalarArray", "String"};
static const char *lp_reason_name[LP_REASONS] = {"shared", "multi-threaded", "persistent"};

typedef struct {
    const lean_object *site;   /* scope label, a static string literal */
    uint64_t calls, total, self, sum, min, max; /* sum: every call's own duration */
    uint32_t active;           /* recursion depth, so totals count the outermost call */
    uint32_t hist[LP_BUCKETS];
} lp_scope;

typedef struct {
    void *pc;                  /* return address inside the copying function */
    const lean_object *site;   /* innermost scope at the time, or NULL */
    uint8_t kind;
    uint64_t count[LP_REASONS];
    uint64_t bytes;
} lp_copy;

typedef struct {
    lp_scope *scope;
    uint64_t start, child;
} lp_frame;

typedef struct lp_thread {
    lp_scope *scopes[LP_TABLE];
    lp_copy *copies[LP_TABLE];
    lp_frame stack[LP_DEPTH];
    uint32_t depth;
    uint64_t dropped;
    struct lp_thread *next;
} lp_thread;

static _Thread_local lp_thread *lp_self;
static lp_thread *lp_threads;
static pthread_mutex_t lp_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t lp_start;

/* ---------- clock ---------- */

static inline uint64_t lp_now(void) {
#ifdef __APPLE__
    return mach_absolute_time();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

static double lp_ns_per_tick(void) {
#ifdef __APPLE__
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (double)tb.numer / (double)tb.denom;
#else
    return 1.0;
#endif
}

/* ---------- histogram: 16 sub-buckets per power of two, ~6% error ---------- */

static inline uint32_t lp_bucket(uint64_t v) {
    if (v < LP_SUB) return (uint32_t)v;
    uint32_t msb = 63 - (uint32_t)__builtin_clzll(v);
    uint32_t sub = (uint32_t)(v >> (msb - 4)) & (LP_SUB - 1);
    return (msb - 3) * LP_SUB + sub;
}

static uint64_t lp_bucket_low(uint32_t b) {
    if (b < LP_SUB) return b;
    uint32_t msb = b / LP_SUB + 3, sub = b % LP_SUB;
    return (uint64_t)(LP_SUB + sub) << (msb - 4);
}

static uint64_t lp_percentile(const uint32_t *hist, uint64_t calls, double q) {
    uint64_t want = (uint64_t)(q * (double)calls), seen = 0;
    for (uint32_t b = 0; b < LP_BUCKETS; b++) {
        seen += hist[b];
        if (seen > want) return lp_bucket_low(b);
    }
    return 0;
}

/* ---------- per-thread state ---------- */

static lp_thread *lp_thread_get(void) {
    lp_thread *t = lp_self;
    if (LEAN_LIKELY(t != NULL)) return t;
    t = calloc(1, sizeof(lp_thread));
    if (t == NULL) abort();
    pthread_mutex_lock(&lp_lock);
    t->next = lp_threads;
    lp_threads = t;
    pthread_mutex_unlock(&lp_lock);
    lp_self = t;
    return t;
}

static inline size_t lp_hash(const void *a, const void *b) {
    uint64_t h = ((uint64_t)(uintptr_t)a ^ ((uint64_t)(uintptr_t)b * 0x9e3779b97f4a7c15ull));
    h ^= h >> 29;
    h *= 0xbf58476d1ce4e5b9ull;
    h ^= h >> 32;
    return (size_t)h & (LP_TABLE - 1);
}

static lp_scope *lp_scope_get(lp_thread *t, const lean_object *site) {
    size_t i = lp_hash(site, NULL);
    for (size_t n = 0; n < LP_TABLE; n++, i = (i + 1) & (LP_TABLE - 1)) {
        lp_scope *s = t->scopes[i];
        if (LEAN_LIKELY(s != NULL && s->site == site)) return s;
        if (s == NULL) {
            s = calloc(1, sizeof(lp_scope));
            if (s == NULL) abort();
            s->site = site;
            s->min = UINT64_MAX;
            t->scopes[i] = s;
            return s;
        }
    }
    t->dropped++;
    return NULL;
}

static lp_copy *lp_copy_get(lp_thread *t, void *pc, const lean_object *site, uint8_t kind) {
    size_t i = lp_hash(pc, site);
    for (size_t n = 0; n < LP_TABLE; n++, i = (i + 1) & (LP_TABLE - 1)) {
        lp_copy *c = t->copies[i];
        if (c != NULL && c->pc == pc && c->site == site && c->kind == kind) return c;
        if (c == NULL) {
            c = calloc(1, sizeof(lp_copy));
            if (c == NULL) abort();
            c->pc = pc;
            c->site = site;
            c->kind = kind;
            t->copies[i] = c;
            return c;
        }
    }
    t->dropped++;
    return NULL;
}

/* ---------- scopes ---------- */

static inline void lp_enter(const lean_object *site) {
    lp_thread *t = lp_thread_get();
    uint32_t d = t->depth++;
    if (LEAN_UNLIKELY(d >= LP_DEPTH)) return;
    lp_scope *s = lp_scope_get(t, site);
    if (s != NULL) s->active++;
    t->stack[d].scope = s;
    t->stack[d].child = 0;
    t->stack[d].start = lp_now();
}

static inline void lp_exit(void) {
    uint64_t now = lp_now();
    lp_thread *t = lp_self;
    if (t == NULL || t->depth == 0) return;
    uint32_t d = --t->depth;
    if (LEAN_UNLIKELY(d >= LP_DEPTH)) return;
    lp_frame *f = &t->stack[d];
    uint64_t elapsed = now - f->start;
    if (d > 0) t->stack[d - 1].child += elapsed;
    lp_scope *s = f->scope;
    if (s == NULL) return;
    s->calls++;
    s->self += elapsed - f->child;
    s->sum += elapsed;
    if (--s->active == 0) s->total += elapsed;
    if (elapsed < s->min) s->min = elapsed;
    if (elapsed > s->max) s->max = elapsed;
    s->hist[lp_bucket(elapsed)]++;
}

LEAN_EXPORT lean_obj_res leanprof_scope(b_lean_obj_arg site, lean_obj_arg f) {
    lp_enter(site);
    lean_object *r = lean_apply_1(f, lean_box(0));
    lp_exit();
    return r;
}

LEAN_EXPORT lean_obj_res leanprof_enter(b_lean_obj_arg site) {
    lp_enter(site);
    return lean_box(0);
}

LEAN_EXPORT lean_obj_res leanprof_exit(lean_obj_arg unit) {
    (void)unit;
    lp_exit();
    return lean_box(0);
}

/* ---------- copies ----------
 * Programs built with leanprof's copy flags call these instead of the runtime
 * functions (see `-D` flags in the README). Each shim records why the value
 * was not exclusive, then forwards to the real function.
 */

static inline int lp_reason(lean_object *o) {
    int rc = lean_internal_get_rc(o);
    if (rc == 0) return LP_PERSISTENT;
    if (rc < 0) return LP_MULTI_THREADED;
    return LP_SHARED;
}

static inline void lp_record(void *pc, lean_object *o, uint8_t kind, size_t bytes) {
    lp_thread *t = lp_thread_get();
    const lean_object *site = NULL;
    uint32_t d = t->depth;
    if (d > 0 && d <= LP_DEPTH && t->stack[d - 1].scope != NULL) site = t->stack[d - 1].scope->site;
    lp_copy *c = lp_copy_get(t, pc, site, kind);
    if (c == NULL) return;
    c->count[lp_reason(o)]++;
    c->bytes += bytes;
}

static inline size_t lp_sarray_bytes(lean_object *a) {
    return lean_sarray_size(a) * lean_sarray_elem_size(a);
}

#define LP_PC __builtin_return_address(0)

LEAN_EXPORT lean_obj_res leanprof_copy_expand_array_nonlinear(lean_obj_arg a, bool expand) {
    lp_record(LP_PC, a, LP_ARRAY, lean_array_size(a) * sizeof(void *));
    return lean_copy_expand_array_nonlinear(a, expand);
}

LEAN_EXPORT lean_obj_res leanprof_copy_sarray_nonlinear(lean_obj_arg a, size_t cap) {
    lp_record(LP_PC, a, LP_SCALAR_ARRAY, lp_sarray_bytes(a));
    return lean_copy_sarray_nonlinear(a, cap);
}

LEAN_EXPORT lean_obj_res leanprof_copy_string_nonlinear(lean_obj_arg s, size_t cap) {
    lp_record(LP_PC, s, LP_STRING, lean_string_size(s));
    return lean_copy_string_nonlinear(s, cap);
}

LEAN_EXPORT lean_object *leanprof_array_push(lean_obj_arg a, lean_obj_arg v) {
    if (!lean_is_exclusive(a)) lp_record(LP_PC, a, LP_ARRAY, lean_array_size(a) * sizeof(void *));
    return lean_array_push(a, v);
}

LEAN_EXPORT lean_obj_res leanprof_byte_array_push(lean_obj_arg a, uint8_t b) {
    if (!lean_is_exclusive(a)) lp_record(LP_PC, a, LP_SCALAR_ARRAY, lp_sarray_bytes(a));
    return lean_byte_array_push(a, b);
}

LEAN_EXPORT lean_obj_res leanprof_float_array_push(lean_obj_arg a, double d) {
    if (!lean_is_exclusive(a)) lp_record(LP_PC, a, LP_SCALAR_ARRAY, lp_sarray_bytes(a));
    return lean_float_array_push(a, d);
}

LEAN_EXPORT lean_obj_res leanprof_string_push(lean_obj_arg s, uint32_t c) {
    if (!lean_is_exclusive(s)) lp_record(LP_PC, s, LP_STRING, lean_string_size(s));
    return lean_string_push(s, c);
}

LEAN_EXPORT lean_obj_res leanprof_string_append(lean_obj_arg s1, b_lean_obj_arg s2) {
    if (!lean_is_exclusive(s1)) lp_record(LP_PC, s1, LP_STRING, lean_string_size(s1));
    return lean_string_append(s1, s2);
}

LEAN_EXPORT lean_obj_res leanprof_string_utf8_set(lean_obj_arg s, b_lean_obj_arg i, uint32_t c) {
    if (!lean_is_exclusive(s)) lp_record(LP_PC, s, LP_STRING, lean_string_size(s));
    return lean_string_utf8_set(s, i, c);
}

/* ---------- symbol names ----------
 * Inverse of Lean.Name.mangle for the common cases: `l_` and `lp_<pkg>_`
 * prefixes, `__` for `_`, `_x`/`_u`/`_U` escapes, `_00` disambiguation and
 * `_N_` numeric components. Compiler-generated suffixes (`_lam_0`,
 * `_boxed`, `_closed_1`, `_redArg`, ...) are dropped so copies group by the
 * user declaration.
 */

static void lp_put_utf8(char **o, char *end, uint32_t c) {
    char buf[4];
    int n;
    if (c < 0x80) { buf[0] = (char)c; n = 1; }
    else if (c < 0x800) { buf[0] = (char)(0xc0 | c >> 6); buf[1] = (char)(0x80 | (c & 0x3f)); n = 2; }
    else if (c < 0x10000) {
        buf[0] = (char)(0xe0 | c >> 12); buf[1] = (char)(0x80 | ((c >> 6) & 0x3f));
        buf[2] = (char)(0x80 | (c & 0x3f)); n = 3;
    } else {
        buf[0] = (char)(0xf0 | c >> 18); buf[1] = (char)(0x80 | ((c >> 12) & 0x3f));
        buf[2] = (char)(0x80 | ((c >> 6) & 0x3f)); buf[3] = (char)(0x80 | (c & 0x3f)); n = 4;
    }
    for (int k = 0; k < n && *o < end; k++) *(*o)++ = buf[k];
}

static int lp_hex(const char *s, int n, uint32_t *out) {
    uint32_t v = 0;
    for (int k = 0; k < n; k++) {
        char ch = s[k];
        if (ch >= '0' && ch <= '9') v = v << 4 | (uint32_t)(ch - '0');
        else if (ch >= 'a' && ch <= 'f') v = v << 4 | (uint32_t)(ch - 'a' + 10);
        else return 0;
    }
    *out = v;
    return 1;
}

/* Decode a mangled body into `out` with components separated by '.'.
 * A run of k underscores is k/2 escaped '_' when k is even. When k is odd one
 * of them is a separator: before the escapes for a component starting with
 * '_' (`___at` is `._at`), or after them for `_00` and `_x..` escapes, which
 * the mangler only emits inside a component or after one ending in '_'. */
static void lp_decode(const char *s, char *out, size_t cap) {
    char *o = out, *end = out + cap - 1;
    int at_sep = 1; /* at the start of a component */
    while (*s && o < end) {
        if (at_sep && *s >= '0' && *s <= '9') {
            /* numeric component `N_`; the trailing '_' ends it */
            while (*s >= '0' && *s <= '9' && o < end) *o++ = *s++;
            if (*s == '_') s++;
            at_sep = 0;
            continue;
        }
        at_sep = 0;
        if (*s != '_') { *o++ = *s++; continue; }
        size_t k = 0;
        while (s[k] == '_') k++;
        const char *next = s + k;
        uint32_t c;
        if (k % 2 == 0) {
            for (size_t i = 0; i < k / 2 && o < end; i++) *o++ = '_';
            s = next;
            continue;
        }
        size_t esc = (k - 1) / 2;
        int hex = (next[0] == 'x' && lp_hex(next + 1, 2, &c)) || (next[0] == 'u' && lp_hex(next + 1, 4, &c)) ||
                  (next[0] == 'U' && lp_hex(next + 1, 8, &c));
        if (next[0] == '0' && next[1] == '0') {
            for (size_t i = 0; i < esc && o < end; i++) *o++ = '_';
            if (o < end) *o++ = '.';
            s = next + 2;
        } else if (hex) {
            for (size_t i = 0; i < esc && o < end; i++) *o++ = '_';
            lp_put_utf8(&o, end, c);
            s = next + 1 + (next[0] == 'x' ? 2 : next[0] == 'u' ? 4 : 8);
        } else {
            if (o < end) *o++ = '.';
            for (size_t i = 0; i < esc && o < end; i++) *o++ = '_';
            s = next;
            at_sep = esc == 0;
        }
    }
    *o = 0;
}

/* Drop `_private.<Module>.<N>.` prefixes and compiler suffixes like `._lam_0`. */
static void lp_strip(char *name) {
    char *p;
    while ((p = strstr(name, "_private.")) != NULL) {
        char *q = p + 9;
        /* skip module components up to the numeric one */
        while (*q) {
            char *dot = strchr(q, '.');
            if (dot == NULL) break;
            int numeric = q < dot;
            for (char *r = q; r < dot; r++) if (*r < '0' || *r > '9') numeric = 0;
            q = dot + 1;
            if (numeric) break;
        }
        memmove(p, q, strlen(q) + 1);
    }
    for (char *q = name; *q; q++) {
        if (q[0] == '.' && q[1] == '_') { *q = 0; break; }
    }
}

/* Turn a decoded name into what we show. A specialization
 * `Callee._at_.Caller.spec_N` is reported under the caller, because that is
 * the user code whose values were copied. */
static void lp_clean(char *name, size_t cap) {
    char *at = strstr(name, "._at_.");
    if (at != NULL) {
        char callee[256], caller[256];
        size_t n = (size_t)(at - name) < sizeof callee - 1 ? (size_t)(at - name) : sizeof callee - 1;
        memcpy(callee, name, n);
        callee[n] = 0;
        snprintf(caller, sizeof caller, "%s", at + 6);
        char *spec = strstr(caller, ".spec_");
        if (spec != NULL) *spec = 0;
        lp_strip(callee);
        lp_strip(caller);
        snprintf(name, cap, "%s (in %s)", caller, callee);
        return;
    }
    lp_strip(name);
}

/* `lp_<pkg>_<body>`: the package is the shortest prefix whose underscore
 * runs are all escapes (even length) and whose remainder can start a body. */
static const char *lp_skip_package(const char *s) {
    for (const char *p = s; *p; p++) {
        if (*p != '_') continue;
        int run = 0;
        const char *q = p;
        while (q > s && q[-1] == '_') q--;
        for (const char *r = q; r < p; r++) run++;
        if (run % 2 != 0) continue; /* this '_' completes an escape */
        const char *rest = p + 1;
        if (rest[0] == '_' && rest[1] != '_' && rest[1] != 'x' && rest[1] != 'u' && rest[1] != 'U' &&
            rest[1] != '0')
            continue;
        return rest;
    }
    return s;
}

static void lp_demangle(const char *s, char *out, size_t cap) {
#ifdef __APPLE__
    if (s[0] == '_') s++; /* Mach-O leading underscore */
#endif
    if (strcmp(s, "_lean_main") == 0 || strcmp(s, "lean_main") == 0) {
        snprintf(out, cap, "main");
        return;
    }
    if (strncmp(s, "lp_", 3) == 0) {
        s = lp_skip_package(s + 3);
    } else if (strncmp(s, "l_", 2) == 0) {
        s += 2;
    } else {
        snprintf(out, cap, "%s", s);
        return;
    }
    lp_decode(s, out, cap);
    lp_clean(out, cap);
}

static void lp_symbol_name(void *pc, char *out, size_t cap) {
    Dl_info info;
    if (!dladdr(pc, &info) || info.dli_sname == NULL) {
        snprintf(out, cap, "%p", pc);
        return;
    }
    lp_demangle(info.dli_sname, out, cap);
}

/* ---------- queries, for tests and assertions ---------- */

/* Copies of non-constant values recorded so far, on all threads. */
LEAN_EXPORT lean_obj_res leanprof_copies(void) {
    uint64_t n = 0;
    pthread_mutex_lock(&lp_lock);
    for (lp_thread *t = lp_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++)
            if (t->copies[i] != NULL) n += t->copies[i]->count[LP_SHARED] + t->copies[i]->count[LP_MULTI_THREADED];
    pthread_mutex_unlock(&lp_lock);
    return lean_uint64_to_nat(n);
}

/* Completed calls of scopes labelled `site`, on all threads. */
LEAN_EXPORT lean_obj_res leanprof_calls(b_lean_obj_arg site) {
    const char *label = lean_string_cstr(site);
    uint64_t n = 0;
    pthread_mutex_lock(&lp_lock);
    for (lp_thread *t = lp_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++)
            if (t->scopes[i] != NULL && strcmp(lean_string_cstr((lean_object *)t->scopes[i]->site), label) == 0)
                n += t->scopes[i]->calls;
    pthread_mutex_unlock(&lp_lock);
    return lean_uint64_to_nat(n);
}

/* Open scopes on the current thread. */
LEAN_EXPORT lean_obj_res leanprof_depth(void) {
    lp_thread *t = lp_self;
    return lean_box(t == NULL ? 0 : t->depth);
}

LEAN_EXPORT lean_obj_res leanprof_demangle(b_lean_obj_arg sym) {
    char out[512];
    lp_demangle(lean_string_cstr(sym), out, sizeof out);
    return lean_mk_string(out);
}

/* ---------- report ---------- */

typedef struct {
    const char *label;
    uint64_t calls, total, self, sum, min, max;
    uint32_t hist[LP_BUCKETS];
} lp_scope_sum;

typedef struct {
    char fn[256];
    const char *label;
    uint8_t kind;
    uint64_t count[LP_REASONS], bytes, total;
} lp_copy_sum;

static int lp_by_total(const void *a, const void *b) {
    const lp_scope_sum *x = a, *y = b;
    return x->total < y->total ? 1 : x->total > y->total ? -1 : 0;
}

static int lp_by_bytes(const void *a, const void *b) {
    const lp_copy_sum *x = a, *y = b;
    if (x->bytes != y->bytes) return x->bytes < y->bytes ? 1 : -1;
    return x->total < y->total ? 1 : x->total > y->total ? -1 : 0;
}

static void lp_fmt_time(double ns, char *buf, size_t n) {
    if (ns < 1e3) snprintf(buf, n, "%.0f ns", ns);
    else if (ns < 1e6) snprintf(buf, n, "%.1f µs", ns / 1e3);
    else if (ns < 1e9) snprintf(buf, n, "%.1f ms", ns / 1e6);
    else snprintf(buf, n, "%.2f s", ns / 1e9);
}

static void lp_fmt_bytes(double b, char *buf, size_t n) {
    if (b < 1024) snprintf(buf, n, "%.0f B", b);
    else if (b < 1024 * 1024) snprintf(buf, n, "%.1f KiB", b / 1024);
    else if (b < 1024.0 * 1024 * 1024) snprintf(buf, n, "%.1f MiB", b / (1024 * 1024));
    else snprintf(buf, n, "%.2f GiB", b / (1024.0 * 1024 * 1024));
}

static void lp_json_str(FILE *f, const char *s) {
    fputc('"', f);
    for (; *s; s++) {
        if (*s == '"' || *s == '\\') fprintf(f, "\\%c", *s);
        else if ((unsigned char)*s < 0x20) fprintf(f, "\\u%04x", *s);
        else fputc(*s, f);
    }
    fputc('"', f);
}

static void lp_report(void) {
    if (lp_threads == NULL) return; /* linked but never used */
    double tick = lp_ns_per_tick();
    double wall = (double)(lp_now() - lp_start) * tick;
    size_t ns = 0, nc = 0, cap_s = 64, cap_c = 64;
    uint64_t dropped = 0;
    lp_scope_sum *S = calloc(cap_s, sizeof(lp_scope_sum));
    lp_copy_sum *C = calloc(cap_c, sizeof(lp_copy_sum));
    if (S == NULL || C == NULL) return;

    pthread_mutex_lock(&lp_lock);
    for (lp_thread *t = lp_threads; t != NULL; t = t->next) {
        dropped += t->dropped;
        for (size_t i = 0; i < LP_TABLE; i++) {
            lp_scope *s = t->scopes[i];
            if (s == NULL || s->calls == 0) continue;
            const char *label = lean_string_cstr((lean_object *)s->site);
            size_t k = 0;
            while (k < ns && strcmp(S[k].label, label) != 0) k++;
            if (k == ns) {
                if (ns == cap_s) {
                    cap_s *= 2;
                    S = realloc(S, cap_s * sizeof(lp_scope_sum));
                    if (S == NULL) return;
                }
                memset(&S[k], 0, sizeof(lp_scope_sum));
                S[k].label = label;
                S[k].min = UINT64_MAX;
                ns++;
            }
            S[k].calls += s->calls;
            S[k].total += s->total;
            S[k].self += s->self;
            S[k].sum += s->sum;
            if (s->min < S[k].min) S[k].min = s->min;
            if (s->max > S[k].max) S[k].max = s->max;
            for (size_t b = 0; b < LP_BUCKETS; b++) S[k].hist[b] += s->hist[b];
        }
        for (size_t i = 0; i < LP_TABLE; i++) {
            lp_copy *c = t->copies[i];
            if (c == NULL) continue;
            char fn[256];
            lp_symbol_name(c->pc, fn, sizeof fn);
            const char *label = c->site ? lean_string_cstr((lean_object *)c->site) : "-";
            size_t k = 0;
            while (k < nc && !(C[k].kind == c->kind && strcmp(C[k].fn, fn) == 0 && strcmp(C[k].label, label) == 0)) k++;
            if (k == nc) {
                if (nc == cap_c) {
                    cap_c *= 2;
                    C = realloc(C, cap_c * sizeof(lp_copy_sum));
                    if (C == NULL) return;
                }
                memset(&C[k], 0, sizeof(lp_copy_sum));
                snprintf(C[k].fn, sizeof C[k].fn, "%s", fn);
                C[k].label = label;
                C[k].kind = c->kind;
                nc++;
            }
            for (int r = 0; r < LP_REASONS; r++) {
                C[k].count[r] += c->count[r];
                C[k].total += c->count[r];
            }
            C[k].bytes += c->bytes;
        }
    }
    pthread_mutex_unlock(&lp_lock);

    qsort(S, ns, sizeof(lp_scope_sum), lp_by_total);
    qsort(C, nc, sizeof(lp_copy_sum), lp_by_bytes);

    const char *quiet = getenv("LEANPROF_QUIET");
    if (quiet == NULL || strcmp(quiet, "1") != 0) {
        FILE *f = stderr;
        char w[32];
        lp_fmt_time(wall, w, sizeof w);
        fprintf(f, "\nleanprof: %zu scopes, wall %s\n", ns, w);
        if (ns > 0) {
            fprintf(f, "\n%-28s %10s %10s %10s %6s %10s %10s %10s\n",
                    "scope", "calls", "total", "self", "%wall", "mean", "p50", "p99");
            for (size_t k = 0; k < ns; k++) {
                char tt[32], st[32], mt[32], p50[32], p99[32];
                lp_fmt_time((double)S[k].total * tick, tt, sizeof tt);
                lp_fmt_time((double)S[k].self * tick, st, sizeof st);
                lp_fmt_time((double)S[k].sum * tick / (double)S[k].calls, mt, sizeof mt);
                lp_fmt_time((double)lp_percentile(S[k].hist, S[k].calls, 0.50) * tick, p50, sizeof p50);
                lp_fmt_time((double)lp_percentile(S[k].hist, S[k].calls, 0.99) * tick, p99, sizeof p99);
                fprintf(f, "%-28s %10llu %10s %10s %5.1f%% %10s %10s %10s\n", S[k].label,
                        (unsigned long long)S[k].calls, tt, st,
                        wall > 0 ? 100.0 * (double)S[k].total * tick / wall : 0.0, mt, p50, p99);
            }
        }
        const char *all = getenv("LEANPROF_ALL");
        int show_all = all != NULL && strcmp(all, "1") == 0;
        size_t shown = 0, hidden = 0;
        for (size_t k = 0; k < nc; k++) {
            if (show_all || C[k].count[LP_SHARED] + C[k].count[LP_MULTI_THREADED] > 0) shown++;
            else hidden++;
        }
        if (shown > 0) {
            fprintf(f, "\ncopies of non-exclusive values (each one copied the whole value)\n");
            fprintf(f, "%-44s %-12s %10s %12s  %-14s %s\n", "function", "kind", "copies", "bytes", "why", "in scope");
            for (size_t k = 0; k < nc; k++) {
                if (!show_all && C[k].count[LP_SHARED] + C[k].count[LP_MULTI_THREADED] == 0) continue;
                char bt[32], why[64] = "";
                lp_fmt_bytes((double)C[k].bytes, bt, sizeof bt);
                for (int r = 0; r < LP_REASONS; r++) {
                    if (C[k].count[r] == 0) continue;
                    if (why[0]) strncat(why, "+", sizeof why - strlen(why) - 1);
                    strncat(why, lp_reason_name[r], sizeof why - strlen(why) - 1);
                }
                fprintf(f, "%-44s %-12s %10llu %12s  %-14s %s\n", C[k].fn, lp_kind_name[C[k].kind],
                        (unsigned long long)C[k].total, bt, why, C[k].label);
            }
        }
        if (hidden > 0)
            fprintf(f, "\nleanprof: %zu sites only copied compile-time constants (LEANPROF_ALL=1 shows them)\n",
                    hidden);
        if (dropped > 0) fprintf(f, "\nleanprof: %llu events dropped (table full)\n", (unsigned long long)dropped);
        fprintf(f, "\n");
    }

    const char *path = getenv("LEANPROF_JSON");
    if (path != NULL && path[0] != 0) {
        FILE *f = fopen(path, "w");
        if (f == NULL) {
            fprintf(stderr, "leanprof: cannot write %s\n", path);
        } else {
            fprintf(f, "{\"version\":1,\"wall_ns\":%.0f,\"dropped\":%llu,\"scopes\":[", wall,
                    (unsigned long long)dropped);
            for (size_t k = 0; k < ns; k++) {
                fprintf(f, "%s{\"name\":", k ? "," : "");
                lp_json_str(f, S[k].label);
                fprintf(f, ",\"calls\":%llu,\"total_ns\":%.0f,\"self_ns\":%.0f,\"min_ns\":%.0f,\"max_ns\":%.0f,"
                           "\"mean_ns\":%.0f,\"p50_ns\":%.0f,\"p99_ns\":%.0f}",
                        (unsigned long long)S[k].calls, (double)S[k].total * tick, (double)S[k].self * tick,
                        (double)S[k].min * tick, (double)S[k].max * tick,
                        (double)S[k].sum * tick / (double)S[k].calls,
                        (double)lp_percentile(S[k].hist, S[k].calls, 0.50) * tick,
                        (double)lp_percentile(S[k].hist, S[k].calls, 0.99) * tick);
            }
            fprintf(f, "],\"copies\":[");
            for (size_t k = 0; k < nc; k++) {
                fprintf(f, "%s{\"function\":", k ? "," : "");
                lp_json_str(f, C[k].fn);
                fprintf(f, ",\"scope\":");
                lp_json_str(f, C[k].label);
                fprintf(f, ",\"kind\":\"%s\",\"copies\":%llu,\"bytes\":%llu,\"shared\":%llu,"
                           "\"multi_threaded\":%llu,\"persistent\":%llu}",
                        lp_kind_name[C[k].kind], (unsigned long long)C[k].total, (unsigned long long)C[k].bytes,
                        (unsigned long long)C[k].count[LP_SHARED],
                        (unsigned long long)C[k].count[LP_MULTI_THREADED],
                        (unsigned long long)C[k].count[LP_PERSISTENT]);
            }
            fprintf(f, "]}\n");
            fclose(f);
        }
    }
    free(S);
    free(C);
}

__attribute__((constructor)) static void lp_init(void) {
    lp_start = lp_now();
    atexit(lp_report);
}
