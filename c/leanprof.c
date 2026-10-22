/*
 * leanprof runtime: scope timing, copy detection and the exit report.
 *
 * Each thread records into its own tables, so the hot path takes no lock.
 * Tables are registered once in a global list and merged at exit.
 */
#define _GNU_SOURCE /* dladdr on glibc */
#include <lean/lean.h>

#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef __APPLE__
#include <mach/mach_time.h>
#endif

#define LP_TABLE 8192      /* slots per thread table, power of two */
#define LP_DEPTH 512       /* deepest scope nesting we keep frames for */
#define LP_SUB 16          /* histogram sub-buckets per power of two */
#define LP_BUCKETS (64 * LP_SUB)

enum { LP_ARRAY, LP_SCALAR_ARRAY, LP_STRING, LP_KINDS };
enum { LP_SHARED, LP_MULTI_THREADED, LP_PERSISTENT, LP_REASONS };

static const char *lp_kind_name[LP_KINDS] = {"Array", "ScalarArray", "String"};
static const char *lp_reason_name[LP_REASONS] = {"shared", "multi-threaded", "persistent"};

/* A scope is keyed by a `profile!` label (a static string literal) or, in
 * automatic mode, by a function's address. Times are stored with leanprof's
 * own overhead already subtracted (see calibration). */
enum { LP_LABEL, LP_FN, LP_INTERNAL };

typedef struct {
    const void *key;
    uint8_t kind;              /* LP_LABEL, LP_FN, or LP_INTERNAL (calibration) */
    /* Raw times. `sum` is every call's own duration, `total` only outermost
     * calls (recursion). Overhead is removed at report time from the counts:
     * `kids` direct children, `desc_sum`/`desc_total` descendants over all and
     * over outermost calls, `outer` outermost calls. */
    uint64_t calls, total, self, sum, min, max;
    uint64_t kids, desc_sum, desc_total, outer;
    uint32_t active;           /* recursion depth, so totals count the outermost call */
    uint32_t hist[LP_BUCKETS]; /* per call, overhead removed */
} lp_scope;

typedef struct {
    void *pc;                  /* return address inside the copying function */
    const lean_object *site;   /* innermost scope at the time, or NULL */
    uint8_t kind;
    uint64_t count[LP_REASONS];
    uint64_t bytes, ticks;     /* ticks: time spent in the copying call */
} lp_copy;

typedef struct {
    lp_scope *scope;
    uint8_t traced;            /* its begin event was recorded */
    uint64_t start;
    uint64_t child;            /* raw time in direct children */
    uint64_t kids, desc;       /* direct children and all descendants that completed */
} lp_frame;

/* Timeline events, recorded only with LEANPROF_TRACE. */
typedef struct {
    const void *key;           /* scope key, or the copying pc */
    uint64_t ts, bytes;
    uint8_t ph, kind;          /* ph: 'B' begin, 'E' end, 'C' copy; kind: scope or copy kind */
} lp_event;

typedef struct lp_thread {
    lp_scope *scopes[LP_TABLE];
    lp_copy *copies[LP_TABLE];
    lp_frame stack[LP_DEPTH];
    uint32_t depth;
    uint64_t dropped;
    lp_event *events;
    size_t nevents, capevents;
    uint64_t events_dropped;
    uint32_t id;               /* registration order, the trace's tid */
    struct lp_thread *next;
} lp_thread;

static _Thread_local lp_thread *lp_self;
static lp_thread *lp_threads;
static uint32_t lp_nthreads;
static int lp_tracing;                /* LEANPROF_TRACE is set */
static size_t lp_trace_max = 1u << 20; /* events per thread, LEANPROF_TRACE_MAX */
static pthread_mutex_t lp_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t lp_start;

/* Calibration, in 1/1024 ticks: `lp_inner` is what an empty scope measures
 * itself, `lp_pair` what a whole enter/exit pair adds to the scope around it. */
static uint64_t lp_inner_fp, lp_pair_fp;

static void lp_label_name(const char *label, char *out, size_t cap);

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
    t->id = lp_nthreads++;
    t->next = lp_threads;
    lp_threads = t;
    pthread_mutex_unlock(&lp_lock);
    lp_self = t;
    return t;
}

/* Append a timeline event. Begin events stop a frame short of the limit, so
 * every recorded begin can still get its end. */
static int lp_trace(lp_thread *t, uint8_t ph, const void *key, uint8_t kind, uint64_t ts, uint64_t bytes) {
    size_t limit = ph == 'E' ? lp_trace_max : lp_trace_max - LP_DEPTH;
    if (t->nevents >= limit) {
        t->events_dropped++;
        return 0;
    }
    if (t->nevents == t->capevents) {
        size_t cap = t->capevents ? t->capevents * 2 : 4096;
        if (cap > lp_trace_max) cap = lp_trace_max;
        lp_event *e = realloc(t->events, cap * sizeof(lp_event));
        if (e == NULL) { t->events_dropped++; return 0; }
        t->events = e;
        t->capevents = cap;
    }
    t->events[t->nevents++] = (lp_event){key, ts, bytes, ph, kind};
    return 1;
}

static inline size_t lp_hash(const void *a, const void *b) {
    uint64_t h = ((uint64_t)(uintptr_t)a ^ ((uint64_t)(uintptr_t)b * 0x9e3779b97f4a7c15ull));
    h ^= h >> 29;
    h *= 0xbf58476d1ce4e5b9ull;
    h ^= h >> 32;
    return (size_t)h & (LP_TABLE - 1);
}

static lp_scope *lp_scope_get(lp_thread *t, const void *key, uint8_t kind) {
    size_t i = lp_hash(key, NULL);
    for (size_t n = 0; n < LP_TABLE; n++, i = (i + 1) & (LP_TABLE - 1)) {
        lp_scope *s = t->scopes[i];
        if (LEAN_LIKELY(s != NULL && s->key == key)) return s;
        if (s == NULL) {
            s = calloc(1, sizeof(lp_scope));
            if (s == NULL) abort();
            s->key = key;
            s->kind = kind;
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

__attribute__((no_instrument_function)) static inline void lp_enter(const void *key, uint8_t kind) {
    lp_thread *t = lp_thread_get();
    uint32_t d = t->depth++;
    if (LEAN_UNLIKELY(d >= LP_DEPTH)) return;
    lp_scope *s = lp_scope_get(t, key, kind);
    if (s != NULL) s->active++;
    lp_frame *f = &t->stack[d];
    f->scope = s;
    f->child = f->kids = f->desc = 0;
    f->start = lp_now();
    f->traced = LEAN_UNLIKELY(lp_tracing) && kind != LP_INTERNAL && lp_trace(t, 'B', key, kind, f->start, 0);
}

static inline uint64_t lp_sub(uint64_t a, uint64_t b) { return a > b ? a - b : 0; }

__attribute__((no_instrument_function)) static inline void lp_exit(void) {
    uint64_t now = lp_now();
    lp_thread *t = lp_self;
    if (t == NULL || t->depth == 0) return;
    uint32_t d = --t->depth;
    if (LEAN_UNLIKELY(d >= LP_DEPTH)) return;
    lp_frame *f = &t->stack[d];
    if (LEAN_UNLIKELY(f->traced)) lp_trace(t, 'E', f->scope ? f->scope->key : NULL, 0, now, 0);
    uint64_t raw = now - f->start;
    if (d > 0) {
        lp_frame *p = &t->stack[d - 1];
        p->child += raw;
        p->kids++;
        p->desc += 1 + f->desc;
    }
    lp_scope *s = f->scope;
    if (s == NULL) return;
    s->calls++;
    s->self += raw - f->child;
    s->sum += raw;
    s->kids += f->kids;
    s->desc_sum += f->desc;
    if (--s->active == 0) {
        s->total += raw;
        s->desc_total += f->desc;
        s->outer++;
    }
    /* per-call view for min/max/percentiles: clamped, so only approximate */
    uint64_t elapsed = lp_sub(raw, (lp_inner_fp + f->desc * lp_pair_fp) >> 10);
    if (elapsed < s->min) s->min = elapsed;
    if (elapsed > s->max) s->max = elapsed;
    s->hist[lp_bucket(elapsed)]++;
}

/* ---------- automatic mode ----------
 * Code compiled with -finstrument-functions-after-inlining (see
 * scripts/leanprof-cc, LEANPROF_AUTO) calls these around every function. */

__attribute__((no_instrument_function)) LEAN_EXPORT void __cyg_profile_func_enter(void *fn, void *call_site) {
    (void)call_site;
    lp_enter(fn, LP_FN);
}

__attribute__((no_instrument_function)) LEAN_EXPORT void __cyg_profile_func_exit(void *fn, void *call_site) {
    (void)fn;
    (void)call_site;
    lp_exit();
}

/* ---------- calibration ---------- */

static char lp_calibration_key[2];

/* Measure one enter/exit pair. Noise only ever adds time, so after a warm-up
 * (the CPU may still be clocked down) keep the fastest of many small batches.
 * Runs at startup and again at exit, keeping the lower estimate. */
static void lp_calibrate(void) {
    const char *off = getenv("LEANPROF_NO_CALIBRATION");
    if (off != NULL && strcmp(off, "1") == 0) return;
    enum { BATCH = 2048, BATCHES = 64 };
    lp_thread *t = lp_thread_get();
    uint32_t depth = t->depth;
    uint64_t best_pair = UINT64_MAX, best_inner = 0;
    uint64_t warm_until = lp_now() + (uint64_t)(3e6 / lp_ns_per_tick()); /* ~3 ms */
    lp_enter(&lp_calibration_key[0], LP_INTERNAL); /* outer frame: sees the full pair cost */
    lp_scope *inner = lp_scope_get(t, &lp_calibration_key[1], LP_INTERNAL);
    for (int b = -1; b < BATCHES; b++) {
        if (b == -1) {
            while (lp_now() < warm_until) {
                lp_enter(&lp_calibration_key[1], LP_INTERNAL);
                lp_exit();
            }
            continue;
        }
        uint64_t sum0 = inner ? inner->sum : 0;
        uint64_t t0 = lp_now();
        for (int i = 0; i < BATCH; i++) {
            lp_enter(&lp_calibration_key[1], LP_INTERNAL);
            lp_exit();
        }
        uint64_t pair = ((lp_now() - t0) << 10) / BATCH;
        if (pair < best_pair) {
            best_pair = pair;
            best_inner = inner ? ((inner->sum - sum0) << 10) / BATCH : 0;
        }
    }
    lp_exit();
    t->depth = depth;
    if (best_inner > best_pair) best_inner = best_pair;
    if (lp_pair_fp == 0 || best_pair < lp_pair_fp) {
        lp_pair_fp = best_pair;
        lp_inner_fp = best_inner;
    }
}

LEAN_EXPORT double leanprof_overhead_ns(void) {
    return (double)lp_pair_fp / 1024.0 * lp_ns_per_tick();
}

LEAN_EXPORT lean_obj_res leanprof_scope(b_lean_obj_arg site, lean_obj_arg f) {
    lp_enter(site, LP_LABEL);
    lean_object *r = lean_apply_1(f, lean_box(0));
    lp_exit();
    return r;
}

LEAN_EXPORT lean_obj_res leanprof_enter(b_lean_obj_arg site) {
    lp_enter(site, LP_LABEL);
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
 * was not exclusive and how long the copying call took.
 */

static inline int lp_reason(lean_object *o) {
    int rc = lean_internal_get_rc(o);
    if (rc == 0) return LP_PERSISTENT;
    if (rc < 0) return LP_MULTI_THREADED;
    return LP_SHARED;
}

/* What we know about a value before the runtime call consumes it. */
typedef struct {
    void *pc;
    uint8_t kind, reason;
    size_t bytes;
    uint64_t start;
} lp_pending;

static inline lp_pending lp_begin(void *pc, lean_object *o, uint8_t kind, size_t bytes) {
    lp_pending p = {pc, kind, (uint8_t)lp_reason(o), bytes, 0};
    p.start = lp_now();
    return p;
}

static inline void lp_end(const lp_pending *p) {
    uint64_t elapsed = lp_now() - p->start;
    lp_thread *t = lp_thread_get();
    const lean_object *site = NULL;
    uint32_t d = t->depth;
    /* the innermost `profile!` scope; automatic-mode frames are skipped */
    for (uint32_t k = d < LP_DEPTH ? d : LP_DEPTH; k > 0; k--) {
        lp_scope *sc = t->stack[k - 1].scope;
        if (sc != NULL && sc->kind == LP_LABEL) { site = (const lean_object *)sc->key; break; }
    }
    if (LEAN_UNLIKELY(lp_tracing)) lp_trace(t, 'C', p->pc, p->kind, p->start, p->bytes);
    lp_copy *c = lp_copy_get(t, p->pc, site, p->kind);
    if (c == NULL) return;
    c->count[p->reason]++;
    c->bytes += p->bytes;
    c->ticks += elapsed;
}

static inline size_t lp_sarray_bytes(lean_object *a) {
    return lean_sarray_size(a) * lean_sarray_elem_size(a);
}

#define LP_PC __builtin_return_address(0)

/* Called only when the value is not exclusive: always a copy. */
#define LP_COPY(kind, obj, bytes, call)                       \
    do {                                                      \
        lp_pending p_ = lp_begin(LP_PC, (obj), (kind), (bytes)); \
        lean_object *r_ = (call);                             \
        lp_end(&p_);                                          \
        return r_;                                            \
    } while (0)

/* Copies only when the value is not exclusive. */
#define LP_MAYBE_COPY(kind, obj, bytes, call)                 \
    do {                                                      \
        if (LEAN_LIKELY(lean_is_exclusive(obj))) return (call); \
        LP_COPY(kind, obj, bytes, call);                      \
    } while (0)

LEAN_EXPORT lean_obj_res leanprof_copy_expand_array_nonlinear(lean_obj_arg a, bool expand) {
    LP_COPY(LP_ARRAY, a, lean_array_size(a) * sizeof(void *), lean_copy_expand_array_nonlinear(a, expand));
}

LEAN_EXPORT lean_obj_res leanprof_copy_sarray_nonlinear(lean_obj_arg a, size_t cap) {
    LP_COPY(LP_SCALAR_ARRAY, a, lp_sarray_bytes(a), lean_copy_sarray_nonlinear(a, cap));
}

LEAN_EXPORT lean_obj_res leanprof_copy_string_nonlinear(lean_obj_arg s, size_t cap) {
    LP_COPY(LP_STRING, s, lean_string_size(s), lean_copy_string_nonlinear(s, cap));
}

LEAN_EXPORT lean_object *leanprof_array_push(lean_obj_arg a, lean_obj_arg v) {
    LP_MAYBE_COPY(LP_ARRAY, a, lean_array_size(a) * sizeof(void *), lean_array_push(a, v));
}

LEAN_EXPORT lean_obj_res leanprof_byte_array_push(lean_obj_arg a, uint8_t b) {
    LP_MAYBE_COPY(LP_SCALAR_ARRAY, a, lp_sarray_bytes(a), lean_byte_array_push(a, b));
}

LEAN_EXPORT lean_obj_res leanprof_float_array_push(lean_obj_arg a, double d) {
    LP_MAYBE_COPY(LP_SCALAR_ARRAY, a, lp_sarray_bytes(a), lean_float_array_push(a, d));
}

LEAN_EXPORT lean_obj_res leanprof_string_push(lean_obj_arg s, uint32_t c) {
    LP_MAYBE_COPY(LP_STRING, s, lean_string_size(s), lean_string_push(s, c));
}

LEAN_EXPORT lean_obj_res leanprof_string_append(lean_obj_arg s1, b_lean_obj_arg s2) {
    LP_MAYBE_COPY(LP_STRING, s1, lean_string_size(s1), lean_string_append(s1, s2));
}

LEAN_EXPORT lean_obj_res leanprof_string_utf8_set(lean_obj_arg s, b_lean_obj_arg i, uint32_t c) {
    LP_MAYBE_COPY(LP_STRING, s, lean_string_size(s), lean_string_utf8_set(s, i, c));
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

static void lp_symbol_raw(void *pc, char *out, size_t cap) {
    Dl_info info;
    if (!dladdr(pc, &info) || info.dli_sname == NULL) snprintf(out, cap, "%p", pc);
    else snprintf(out, cap, "%s", info.dli_sname);
}

static void lp_symbol_name(void *pc, char *out, size_t cap) {
    Dl_info info;
    if (!dladdr(pc, &info) || info.dli_sname == NULL) {
        snprintf(out, cap, "%p", pc);
        return;
    }
    lp_demangle(info.dli_sname, out, cap);
}

/* ---------- declaration positions ----------
 * Lake writes a `.ilean` file per module with each declaration's range:
 * `"decls":{"Name":[l0,c0,l1,c1,selL0,selC0,selL1,selC1],...}` (0-based).
 * At report time we read the ones under LEANPROF_ILEAN_DIR (default: this
 * package's `.lake/build/lib/lean` and each dependency's) to give copy sites a
 * file:line.
 */

typedef struct {
    char *name, *file;
    unsigned line;
} lp_decl;

static lp_decl *lp_decls;
static size_t lp_ndecls, lp_capdecls;
static int lp_indexed;

static void lp_add_decl(const char *name, const char *prefix, const char *module, unsigned line) {
    if (lp_ndecls == lp_capdecls) {
        size_t cap = lp_capdecls ? lp_capdecls * 2 : 256;
        lp_decl *d = realloc(lp_decls, cap * sizeof(lp_decl));
        if (d == NULL) return;
        lp_decls = d;
        lp_capdecls = cap;
    }
    size_t np = strlen(prefix), n = strlen(module);
    char *file = malloc(np + n + 6);
    char *nm = strdup(name);
    if (file == NULL || nm == NULL) { free(file); free(nm); return; }
    memcpy(file, prefix, np);
    for (size_t i = 0; i < n; i++) file[np + i] = module[i] == '.' ? '/' : module[i];
    memcpy(file + np + n, ".lean", 6);
    lp_strip(nm);
    lp_decls[lp_ndecls++] = (lp_decl){nm, file, line};
}

/* Read a JSON string at `p` (just after the opening quote) into out. */
static const char *lp_json_read_str(const char *p, char *out, size_t cap) {
    size_t n = 0;
    while (*p && *p != '"') {
        if (*p == '\\' && p[1]) p++;
        if (n + 1 < cap) out[n++] = *p;
        p++;
    }
    out[n] = 0;
    return *p == '"' ? p + 1 : p;
}

/* Name.mangle for module names: escape each component, join with '_' (or
 * '_00' where the mangler disambiguates). Enough for module names. */
static void lp_mangle_module(const char *m, char *out, size_t cap) {
    size_t n = 0;
    int start = 1;
    char prev = 0;
    for (const char *p = m; *p && n + 12 < cap; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '.') { start = 1; continue; }
        if (start && n > 0) {
            int digit = c >= '0' && c <= '9';
            if (prev == '_' || digit || c == '_') { memcpy(out + n, "_00", 3); n += 3; }
            else out[n++] = '_';
        }
        start = 0;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) out[n++] = (char)c;
        else if (c == '_') { out[n++] = '_'; out[n++] = '_'; }
        else n += (size_t)snprintf(out + n, cap - n, "_x%02x", c);
        prev = (char)c;
    }
    out[n] = 0;
}

/* Package names whose modules may be linked into this program: the root
 * package (from its lakefile) and each checked-out dependency. */
static char lp_root_pkg[256];

static void lp_find_root_pkg(void) {
    FILE *f = fopen("lakefile.toml", "r");
    char line[512];
    if (f != NULL) {
        while (fgets(line, sizeof line, f)) {
            char *q;
            if (strncmp(line, "name", 4) == 0 && (q = strchr(line, '"')) != NULL) {
                lp_json_read_str(q + 1, lp_root_pkg, sizeof lp_root_pkg);
                break;
            }
        }
        fclose(f);
        return;
    }
    f = fopen("lakefile.lean", "r");
    if (f == NULL) return;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "package ", 8) == 0) {
            /* not sscanf: newer glibc renames it, and Lean links an older one */
            size_t n = 0;
            for (const char *q = line + 8; n + 1 < sizeof lp_root_pkg; q++) {
                char c = *q;
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' ||
                      c == '\'' || c == '-'))
                    break;
                lp_root_pkg[n++] = c;
            }
            lp_root_pkg[n] = 0;
            break;
        }
    }
    fclose(f);
}

/* Is `module` part of this program? Its initializer symbol tells us; this
 * keeps a test executable's `main` from matching an example's. Without
 * exported symbols (no -rdynamic) every module counts. */
static int lp_module_linked(const char *module, const char *pkg) {
    static int symbols_visible = -1;
    if (symbols_visible < 0) symbols_visible = dlsym(RTLD_DEFAULT, "lean_main") != NULL ||
                                               dlsym(RTLD_DEFAULT, "_lean_main") != NULL;
    if (!symbols_visible || pkg == NULL) return 1;
    char mm[512], mp[256], sym[1024];
    lp_mangle_module(module, mm, sizeof mm);
    snprintf(sym, sizeof sym, "initialize_%s", mm);
    if (dlsym(RTLD_DEFAULT, sym) != NULL) return 1;
    if (pkg != NULL && pkg[0]) {
        lp_mangle_module(pkg, mp, sizeof mp);
        snprintf(sym, sizeof sym, "initialize_%s_%s", mp, mm);
        if (dlsym(RTLD_DEFAULT, sym) != NULL) return 1;
    }
    return 0;
}

static void lp_index_file(const char *path, const char *prefix, const char *pkg) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) return;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = size > 0 ? malloc((size_t)size + 1) : NULL;
    if (buf == NULL || fread(buf, 1, (size_t)size, f) != (size_t)size) { free(buf); fclose(f); return; }
    buf[size] = 0;
    fclose(f);
    char module[512] = "";
    const char *m = strstr(buf, "\"module\":\"");
    if (m != NULL) lp_json_read_str(m + 10, module, sizeof module);
    const char *p = strstr(buf, "\"decls\":{");
    if (module[0] == 0 || p == NULL || !lp_module_linked(module, pkg)) { free(buf); return; }
    p += 9;
    while (*p == '"') {
        char name[512];
        p = lp_json_read_str(p + 1, name, sizeof name);
        if (*p != ':' || p[1] != '[') break;
        p += 2;
        unsigned v[8] = {0}, k = 0;
        while (*p && *p != ']') {
            if (*p >= '0' && *p <= '9') {
                unsigned x = 0;
                while (*p >= '0' && *p <= '9') x = x * 10 + (unsigned)(*p++ - '0');
                if (k < 8) v[k++] = x;
            } else {
                p++;
            }
        }
        if (*p == ']') p++;
        /* the name's own line (selection range) when present */
        lp_add_decl(name, prefix, module, (k >= 5 ? v[4] : v[0]) + 1);
        if (*p == ',') p++;
    }
    free(buf);
}

static void lp_index_dir(const char *dir, const char *prefix, const char *pkg, int depth) {
    if (depth > 32) return;
    DIR *d = opendir(dir);
    if (d == NULL) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        char path[4096];
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        size_t n = strlen(e->d_name);
        if (n > 6 && strcmp(e->d_name + n - 6, ".ilean") == 0) lp_index_file(path, prefix, pkg);
        else lp_index_dir(path, prefix, pkg, depth + 1); /* opendir fails quietly on files */
    }
    closedir(d);
}

/* file:line of a reported function name, or "" when unknown. */
static const char *lp_where(const char *fn, char *out, size_t cap) {
    if (!lp_indexed) {
        lp_indexed = 1;
        const char *dir = getenv("LEANPROF_ILEAN_DIR");
        if (dir && dir[0]) {
            lp_index_dir(dir, "", NULL, 0);
        } else {
            /* this package, then each dependency Lake checked out */
            lp_find_root_pkg();
            lp_index_dir(".lake/build/lib/lean", "", lp_root_pkg, 0);
            DIR *d = opendir(".lake/packages");
            struct dirent *e;
            while (d != NULL && (e = readdir(d)) != NULL) {
                if (e->d_name[0] == '.') continue;
                char path[1024], prefix[1024];
                snprintf(path, sizeof path, ".lake/packages/%s/.lake/build/lib/lean", e->d_name);
                snprintf(prefix, sizeof prefix, ".lake/packages/%s/", e->d_name);
                lp_index_dir(path, prefix, e->d_name, 0);
            }
            if (d != NULL) closedir(d);
        }
    }
    char name[256];
    snprintf(name, sizeof name, "%s", fn);
    char *in = strstr(name, " (in ");
    if (in != NULL) *in = 0;
    out[0] = 0;
    for (size_t i = 0; i < lp_ndecls; i++) {
        if (strcmp(lp_decls[i].name, name) == 0) {
            snprintf(out, cap, "%s:%u", lp_decls[i].file, lp_decls[i].line);
            break;
        }
    }
    return out;
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

/* Completed calls of scopes named `site` (positions ignored), on all threads. */
LEAN_EXPORT lean_obj_res leanprof_calls(b_lean_obj_arg site) {
    const char *want = lean_string_cstr(site);
    char name[128];
    uint64_t n = 0;
    pthread_mutex_lock(&lp_lock);
    for (lp_thread *t = lp_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++) {
            if (t->scopes[i] == NULL || t->scopes[i]->kind != LP_LABEL) continue;
            lp_label_name(lean_string_cstr((lean_object *)t->scopes[i]->key), name, sizeof name);
            if (strcmp(name, want) == 0) n += t->scopes[i]->calls;
        }
    pthread_mutex_unlock(&lp_lock);
    return lean_uint64_to_nat(n);
}

/* Total time of scopes named `site` (outermost calls, overhead removed), in
 * ns, on all threads. */
LEAN_EXPORT double leanprof_total_ns(b_lean_obj_arg site) {
    const char *want = lean_string_cstr(site);
    char name[128];
    double inner = (double)lp_inner_fp / 1024.0, pair = (double)lp_pair_fp / 1024.0, ticks = 0;
    pthread_mutex_lock(&lp_lock);
    for (lp_thread *t = lp_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++) {
            lp_scope *sc = t->scopes[i];
            if (sc == NULL || sc->kind != LP_LABEL) continue;
            lp_label_name(lean_string_cstr((lean_object *)sc->key), name, sizeof name);
            if (strcmp(name, want) == 0)
                ticks += (double)sc->total - (double)sc->outer * inner - (double)sc->desc_total * pair;
        }
    pthread_mutex_unlock(&lp_lock);
    return ticks > 0 ? ticks * lp_ns_per_tick() : 0;
}

/* Open scopes on the current thread. */
LEAN_EXPORT lean_obj_res leanprof_depth(void) {
    lp_thread *t = lp_self;
    return lean_box(t == NULL ? 0 : t->depth);
}

LEAN_EXPORT lean_obj_res leanprof_where(b_lean_obj_arg fn) {
    char out[512];
    lp_where(lean_string_cstr(fn), out, sizeof out);
    return lean_mk_string(out);
}

LEAN_EXPORT lean_obj_res leanprof_demangle(b_lean_obj_arg sym) {
    char out[512];
    lp_demangle(lean_string_cstr(sym), out, sizeof out);
    return lean_mk_string(out);
}

/* ---------- report ---------- */

/* `profile!` labels are "name\x1fFile.lean:line"; older or hand-written ones
 * have no position. */
#define LP_POS_SEP '\x1f'

static void lp_label_name(const char *label, char *out, size_t cap) {
    const char *sep = strchr(label, LP_POS_SEP);
    size_t n = sep ? (size_t)(sep - label) : strlen(label);
    if (n >= cap) n = cap - 1;
    memcpy(out, label, n);
    out[n] = 0;
}

static const char *lp_label_pos(const char *label) {
    const char *sep = strchr(label, LP_POS_SEP);
    return sep ? sep + 1 : "";
}

typedef struct {
    const char *label;         /* merge key: the label, or "\x01" + function name */
    char name[256], where[512];
    uint8_t is_fn;
    uint64_t calls, total, self, sum, min, max;
    uint32_t hist[LP_BUCKETS];
} lp_scope_sum;

typedef struct {
    char fn[256], sym[256], scope[128], where[512];
    const char *label;
    uint8_t kind;
    uint64_t count[LP_REASONS], bytes, total, ticks;
} lp_copy_sum;

static int lp_by_total(const void *a, const void *b) {
    const lp_scope_sum *x = a, *y = b;
    return x->total < y->total ? 1 : x->total > y->total ? -1 : 0;
}

/* Costliest first; bytes break ties when the clock is too coarse. */
static int lp_by_cost(const void *a, const void *b) {
    const lp_copy_sum *x = a, *y = b;
    if (x->ticks != y->ticks) return x->ticks < y->ticks ? 1 : -1;
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

static int lp_interesting(const lp_copy_sum *c) {
    return c->count[LP_SHARED] + c->count[LP_MULTI_THREADED] > 0;
}

static const lp_scope_sum *lp_find_scope(const lp_scope_sum *S, size_t ns, const char *label) {
    for (size_t k = 0; k < ns; k++)
        if (strcmp(S[k].label, label) == 0) return &S[k];
    return NULL;
}

static void lp_print(FILE *f, const lp_scope_sum *S, size_t ns, const lp_copy_sum *C, size_t nc, double tick,
                     double wall, uint64_t dropped) {
    char w[32];
    lp_fmt_time(wall, w, sizeof w);
    fprintf(f, "\nleanprof: %zu scopes, wall %s, %.1f ns overhead per scope subtracted\n", ns, w,
            (double)lp_pair_fp / 1024.0 * tick);
    int any_fn = 0;
    for (size_t k = 0; k < ns; k++) any_fn |= S[k].is_fn;
    if (ns > 0) {
        fprintf(f, "\n%-24s %10s %10s %10s %6s %10s %10s %10s  %s\n", "scope", "calls", "total", "self", "%wall",
                "mean", "p50", "p99", "where");
        for (size_t k = 0; k < ns; k++) {
            char tt[32], st[32], mt[32], p50[32], p99[32];
            lp_fmt_time((double)S[k].total * tick, tt, sizeof tt);
            lp_fmt_time((double)S[k].self * tick, st, sizeof st);
            lp_fmt_time((double)S[k].sum * tick / (double)S[k].calls, mt, sizeof mt);
            lp_fmt_time((double)lp_percentile(S[k].hist, S[k].calls, 0.50) * tick, p50, sizeof p50);
            lp_fmt_time((double)lp_percentile(S[k].hist, S[k].calls, 0.99) * tick, p99, sizeof p99);
            char shown[300];
            if (any_fn && !S[k].is_fn) snprintf(shown, sizeof shown, "\"%s\"", S[k].name); /* a profile! label */
            else snprintf(shown, sizeof shown, "%s", S[k].name);
            fprintf(f, "%-24s %10llu %10s %10s %5.1f%% %10s %10s %10s  %s\n", shown,
                    (unsigned long long)S[k].calls, tt, st,
                    wall > 0 ? 100.0 * (double)S[k].total * tick / wall : 0.0, mt, p50, p99,
                    S[k].where);
        }
    }
    const char *all = getenv("LEANPROF_ALL");
    int show_all = all != NULL && strcmp(all, "1") == 0;
    size_t shown = 0, hidden = 0;
    for (size_t k = 0; k < nc; k++) {
        if (show_all || lp_interesting(&C[k])) shown++;
        else hidden++;
    }
    if (shown > 0) {
        fprintf(f, "\ncopies of non-exclusive values (each one copied the whole value)\n");
        fprintf(f, "%-40s %-12s %8s %11s %10s %7s  %-15s %-20s %s\n", "function", "kind", "copies", "bytes",
                "time", "%scope", "why", "in scope", "where (declaration)");
        for (size_t k = 0; k < nc; k++) {
            if (!show_all && !lp_interesting(&C[k])) continue;
            char bt[32], tt[32], share[16] = "-", why[64] = "";
            lp_fmt_bytes((double)C[k].bytes, bt, sizeof bt);
            lp_fmt_time((double)C[k].ticks * tick, tt, sizeof tt);
            const lp_scope_sum *sc = C[k].label ? lp_find_scope(S, ns, C[k].label) : NULL;
            if (sc != NULL && sc->total > 0)
                snprintf(share, sizeof share, "%.1f%%", 100.0 * (double)C[k].ticks / (double)sc->total);
            for (int r = 0; r < LP_REASONS; r++) {
                if (C[k].count[r] == 0) continue;
                if (why[0]) strncat(why, "+", sizeof why - strlen(why) - 1);
                strncat(why, lp_reason_name[r], sizeof why - strlen(why) - 1);
            }
            fprintf(f, "%-40s %-12s %8llu %11s %10s %7s  %-15s %-20s %s\n", C[k].fn, lp_kind_name[C[k].kind],
                    (unsigned long long)C[k].total, bt, tt, share, why, C[k].scope, C[k].where);
        }
    }
    if (hidden > 0)
        fprintf(f, "\nleanprof: %zu sites only copied compile-time constants (LEANPROF_ALL=1 shows them)\n", hidden);
    if (dropped > 0) fprintf(f, "\nleanprof: %llu events dropped (table full)\n", (unsigned long long)dropped);
    fprintf(f, "\n");
}

static void lp_write_json(FILE *f, const lp_scope_sum *S, size_t ns, const lp_copy_sum *C, size_t nc, double tick,
                          double wall, uint64_t dropped) {
    fprintf(f, "{\"version\":3,\"wall_ns\":%.0f,\"overhead_ns\":%.1f,\"dropped\":%llu,\"scopes\":[", wall,
            (double)lp_pair_fp / 1024.0 * tick, (unsigned long long)dropped);
    for (size_t k = 0; k < ns; k++) {
        fprintf(f, "%s{\"name\":", k ? "," : "");
        lp_json_str(f, S[k].name);
        fprintf(f, ",\"pos\":");
        lp_json_str(f, S[k].where);
        fprintf(f, ",\"auto\":%s", S[k].is_fn ? "true" : "false");
        fprintf(f, ",\"calls\":%llu,\"total_ns\":%.0f,\"self_ns\":%.0f,\"min_ns\":%.0f,\"max_ns\":%.0f,"
                   "\"mean_ns\":%.0f,\"p50_ns\":%.0f,\"p99_ns\":%.0f}",
                (unsigned long long)S[k].calls, (double)S[k].total * tick, (double)S[k].self * tick,
                (double)S[k].min * tick, (double)S[k].max * tick, (double)S[k].sum * tick / (double)S[k].calls,
                (double)lp_percentile(S[k].hist, S[k].calls, 0.50) * tick,
                (double)lp_percentile(S[k].hist, S[k].calls, 0.99) * tick);
    }
    fprintf(f, "],\"copies\":[");
    for (size_t k = 0; k < nc; k++) {
        fprintf(f, "%s{\"function\":", k ? "," : "");
        lp_json_str(f, C[k].fn);
        fprintf(f, ",\"symbol\":");
        lp_json_str(f, C[k].sym);
        fprintf(f, ",\"scope\":");
        lp_json_str(f, C[k].scope);
        fprintf(f, ",\"where\":");
        lp_json_str(f, C[k].where);
        fprintf(f, ",\"kind\":\"%s\",\"copies\":%llu,\"bytes\":%llu,\"copy_ns\":%.0f,\"shared\":%llu,"
                   "\"multi_threaded\":%llu,\"persistent\":%llu}",
                lp_kind_name[C[k].kind], (unsigned long long)C[k].total, (unsigned long long)C[k].bytes,
                (double)C[k].ticks * tick, (unsigned long long)C[k].count[LP_SHARED],
                (unsigned long long)C[k].count[LP_MULTI_THREADED], (unsigned long long)C[k].count[LP_PERSISTENT]);
    }
    fprintf(f, "]}\n");
}

/* True when the only thread is the one calibration ran on, with nothing else
 * recorded. */
static int lp_only_calibrated(void) {
    lp_thread *t = lp_threads;
    for (size_t i = 0; i < LP_TABLE; i++) {
        if (t->scopes[i] != NULL && t->scopes[i]->kind != LP_INTERNAL) return 0;
        if (t->copies[i] != NULL) return 0;
    }
    return 1;
}

static int lp_show_all(void) {
    const char *all = getenv("LEANPROF_ALL");
    return all != NULL && strcmp(all, "1") == 0;
}

static uint64_t lp_clamp(double v) { return v > 0 ? (uint64_t)(v + 0.5) : 0; }

/* Chrome trace format, for ui.perfetto.dev or chrome://tracing. */
static void lp_write_trace(const char *path, double tick) {
    FILE *f = fopen(path, "w");
    if (f == NULL) {
        fprintf(stderr, "leanprof: cannot write %s\n", path);
        return;
    }
    fprintf(f, "{\"displayTimeUnit\":\"ns\",\"traceEvents\":[");
    int first = 1;
    uint64_t dropped = 0;
    char name[300], buf[300];
    /* names, cached per key: small open-addressing table */
    enum { NCACHE = 1 << 14 };
    const void **ckey = calloc(NCACHE, sizeof(void *));
    char **cname = calloc(NCACHE, sizeof(char *));
    for (lp_thread *t = lp_threads; t != NULL; t = t->next) {
        dropped += t->events_dropped;
        if (t->nevents == 0) continue;
        fprintf(f, "%s{\"ph\":\"M\",\"name\":\"thread_name\",\"pid\":1,\"tid\":%u,\"args\":{\"name\":\"%s %u\"}}",
                first ? "" : ",", t->id, t->id == 0 ? "startup" : "thread", t->id);
        first = 0;
        for (size_t i = 0; i < t->nevents; i++) {
            lp_event *e = &t->events[i];
            double us = (double)(e->ts - lp_start) * tick / 1000.0;
            if (e->ph == 'E') {
                fprintf(f, ",{\"ph\":\"E\",\"pid\":1,\"tid\":%u,\"ts\":%.3f}", t->id, us);
                continue;
            }
            const char *nm = NULL;
            size_t h = lp_hash(e->key, (const void *)(uintptr_t)(e->ph == 'C' ? 1 + e->kind : 0)) & (NCACHE - 1);
            if (ckey != NULL && cname != NULL) {
                for (size_t n = 0; n < NCACHE; n++, h = (h + 1) & (NCACHE - 1)) {
                    if (ckey[h] == NULL) break;
                    if (ckey[h] == e->key && cname[h] != NULL) { nm = cname[h]; break; }
                }
            }
            if (nm == NULL) {
                if (e->ph == 'C') {
                    lp_symbol_name((void *)e->key, buf, sizeof buf);
                    snprintf(name, sizeof name, "copy %s in %s", lp_kind_name[e->kind], buf);
                } else if (e->kind == LP_FN) {
                    lp_symbol_name((void *)e->key, name, sizeof name);
                } else {
                    lp_label_name(lean_string_cstr((lean_object *)e->key), name, sizeof name);
                }
                nm = name;
                if (ckey != NULL && cname != NULL && ckey[h] == NULL) {
                    ckey[h] = e->key;
                    cname[h] = strdup(name);
                }
            }
            if (e->ph == 'C') {
                fprintf(f, ",{\"ph\":\"i\",\"s\":\"t\",\"cat\":\"copy\",\"pid\":1,\"tid\":%u,\"ts\":%.3f,\"name\":",
                        t->id, us);
                lp_json_str(f, nm);
                fprintf(f, ",\"args\":{\"bytes\":%llu}}", (unsigned long long)e->bytes);
            } else {
                fprintf(f, ",{\"ph\":\"B\",\"cat\":\"%s\",\"pid\":1,\"tid\":%u,\"ts\":%.3f,\"name\":",
                        e->kind == LP_FN ? "function" : "scope", t->id, us);
                lp_json_str(f, nm);
                fputc('}', f);
            }
        }
    }
    fprintf(f, "]}\n");
    fclose(f);
    if (cname != NULL)
        for (size_t i = 0; i < NCACHE; i++) free(cname[i]);
    free(cname);
    free(ckey);
    if (dropped > 0)
        fprintf(stderr, "leanprof: trace kept the first %zu events per thread; %llu dropped (LEANPROF_TRACE_MAX)\n",
                lp_trace_max, (unsigned long long)dropped);
}

static void lp_report(void) {
    if (lp_threads == NULL || (lp_threads->next == NULL && lp_only_calibrated())) return; /* linked but unused */
    lp_calibrate(); /* the CPU is warm now; keeps the lower estimate */
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
            if (s == NULL || s->calls == 0 || s->kind == LP_INTERNAL) continue;
            char fn[256] = "", fnkey[260];
            const char *label;
            if (s->kind == LP_FN) {
                /* only Lean declarations: not module initializers, closed-term
                 * initializers or C runtime glue, unless LEANPROF_ALL=1 */
                char raw[256];
                lp_symbol_raw((void *)s->key, raw, sizeof raw);
                const char *r = raw;
#ifdef __APPLE__
                if (r[0] == '_') r++;
#endif
                int lean_decl = strncmp(r, "l_", 2) == 0 || strncmp(r, "lp_", 3) == 0 ||
                                strcmp(r, "_lean_main") == 0 || strcmp(r, "lean_main") == 0;
                if (!lean_decl && !lp_show_all()) continue;
                lp_symbol_name((void *)s->key, fn, sizeof fn);
                snprintf(fnkey, sizeof fnkey, "\x01%s", fn);
                label = fnkey;
            } else {
                label = lean_string_cstr((lean_object *)s->key);
            }
            size_t k = 0;
            while (k < ns && strcmp(S[k].label, label) != 0) k++;
            if (k == ns) {
                if (ns == cap_s) {
                    cap_s *= 2;
                    S = realloc(S, cap_s * sizeof(lp_scope_sum));
                    if (S == NULL) return;
                }
                memset(&S[k], 0, sizeof(lp_scope_sum));
                S[k].is_fn = s->kind == LP_FN;
                if (S[k].is_fn) {
                    S[k].label = strdup(fnkey);
                    snprintf(S[k].name, sizeof S[k].name, "%s", fn);
                    lp_where(fn, S[k].where, sizeof S[k].where);
                } else {
                    S[k].label = label;
                    lp_label_name(label, S[k].name, sizeof S[k].name);
                    snprintf(S[k].where, sizeof S[k].where, "%s", lp_label_pos(label));
                }
                if (S[k].label == NULL) return;
                S[k].min = UINT64_MAX;
                ns++;
            }
            /* remove leanprof's own cost (see calibration) */
            double inner = (double)lp_inner_fp / 1024.0, pair = (double)lp_pair_fp / 1024.0;
            S[k].calls += s->calls;
            S[k].total += lp_clamp((double)s->total - (double)s->outer * inner - (double)s->desc_total * pair);
            S[k].self += lp_clamp((double)s->self - (double)s->calls * inner - (double)s->kids * (pair - inner));
            S[k].sum += lp_clamp((double)s->sum - (double)s->calls * inner - (double)s->desc_sum * pair);
            if (s->min < S[k].min) S[k].min = s->min;
            if (s->max > S[k].max) S[k].max = s->max;
            for (size_t b = 0; b < LP_BUCKETS; b++) S[k].hist[b] += s->hist[b];
        }
        for (size_t i = 0; i < LP_TABLE; i++) {
            lp_copy *c = t->copies[i];
            if (c == NULL) continue;
            char fn[256];
            lp_symbol_name(c->pc, fn, sizeof fn);
            const char *label = c->site ? lean_string_cstr((lean_object *)c->site) : NULL;
            size_t k = 0;
            while (k < nc && !(C[k].kind == c->kind && strcmp(C[k].fn, fn) == 0 &&
                               (C[k].label == label || (C[k].label && label && strcmp(C[k].label, label) == 0))))
                k++;
            if (k == nc) {
                if (nc == cap_c) {
                    cap_c *= 2;
                    C = realloc(C, cap_c * sizeof(lp_copy_sum));
                    if (C == NULL) return;
                }
                memset(&C[k], 0, sizeof(lp_copy_sum));
                snprintf(C[k].fn, sizeof C[k].fn, "%s", fn);
                lp_symbol_raw(c->pc, C[k].sym, sizeof C[k].sym);
                lp_where(fn, C[k].where, sizeof C[k].where);
                C[k].label = label;
                if (label) lp_label_name(label, C[k].scope, sizeof C[k].scope);
                else snprintf(C[k].scope, sizeof C[k].scope, "-");
                C[k].kind = c->kind;
                nc++;
            }
            for (int r = 0; r < LP_REASONS; r++) {
                C[k].count[r] += c->count[r];
                C[k].total += c->count[r];
            }
            C[k].bytes += c->bytes;
            C[k].ticks += c->ticks;
        }
    }
    pthread_mutex_unlock(&lp_lock);

    qsort(S, ns, sizeof(lp_scope_sum), lp_by_total);
    qsort(C, nc, sizeof(lp_copy_sum), lp_by_cost);

    const char *quiet = getenv("LEANPROF_QUIET");
    if (quiet == NULL || strcmp(quiet, "1") != 0) lp_print(stderr, S, ns, C, nc, tick, wall, dropped);

    const char *trace = getenv("LEANPROF_TRACE");
    if (trace != NULL && trace[0] != 0) lp_write_trace(trace, tick);

    const char *path = getenv("LEANPROF_JSON");
    if (path != NULL && path[0] != 0) {
        FILE *f = fopen(path, "w");
        if (f == NULL) {
            fprintf(stderr, "leanprof: cannot write %s\n", path);
        } else {
            lp_write_json(f, S, ns, C, nc, tick, wall, dropped);
            fclose(f);
        }
    }
    for (size_t k = 0; k < ns; k++)
        if (S[k].is_fn) free((void *)S[k].label);
    free(S);
    free(C);
}

__attribute__((constructor)) static void lp_init(void) {
    lp_calibrate();
    const char *trace = getenv("LEANPROF_TRACE");
    lp_tracing = trace != NULL && trace[0] != 0;
    const char *max = getenv("LEANPROF_TRACE_MAX");
    if (max != NULL) {
        size_t n = 0;
        for (const char *q = max; *q >= '0' && *q <= '9'; q++) n = n * 10 + (size_t)(*q - '0');
        if (n > 2 * LP_DEPTH) lp_trace_max = n;
    }
    lp_start = lp_now();
    atexit(lp_report);
}
