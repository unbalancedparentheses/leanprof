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

enum { LP_ARRAY, LP_SCALAR_ARRAY, LP_STRING, LP_KINDS, LP_WAIT = LP_KINDS, LP_ALLOC };
enum { LP_SHARED, LP_MULTI_THREADED, LP_PERSISTENT, LP_REASONS };

static const char *lpf_kind_name[LP_KINDS + 2] = {"Array", "ScalarArray", "String", "wait", "alloc"};
static const char *lpf_reason_name[LP_REASONS] = {"shared", "multi-threaded", "persistent"};

/* A scope is keyed by a `profile!` label (a static string literal) or, in
 * automatic mode, by a function's address. Times are stored with leanprof's
 * own overhead already subtracted (see calibration). */
/* LP_TASK: a task's run, keyed by the scope that spawned it (its kind in
 * `parent_kind`; key NULL when spawned outside any scope). */
enum { LP_LABEL, LP_FN, LP_INTERNAL, LP_TASK };

typedef struct {
    const void *key;
    uint8_t kind;              /* LP_LABEL, LP_FN, or LP_INTERNAL (calibration) */
    /* Raw times. `sum` is every call's own duration, `total` only outermost
     * calls (recursion). Overhead is removed at report time from the counts:
     * `kids` direct children, `desc_sum`/`desc_total` descendants over all and
     * over outermost calls, `outer` outermost calls. */
    uint64_t calls, total, self, sum, min, max;
    uint64_t kids, desc_sum, desc_total, outer;
    uint64_t wait, wait_max;   /* LP_TASK: time from spawn to start */
    /* allocations (LEANPROF_ALLOCS builds): made while this scope was the
     * innermost (self), and including children over outermost calls (total) */
    uint64_t allocs_self, bytes_self, allocs_total, bytes_total;
    uint8_t parent_kind;       /* LP_TASK: kind of the spawning scope */
    uint32_t active;           /* recursion depth, so totals count the outermost call */
    uint32_t hist[LP_BUCKETS]; /* per call, overhead removed */
} lpf_scope;

typedef struct {
    void *pc;                  /* return address inside the copying function */
    const lean_object *site;   /* innermost scope at the time, or NULL */
    uint8_t kind;
    uint64_t count[LP_REASONS];
    uint64_t bytes, ticks;     /* ticks: time spent in the copying call */
} lpf_copy;

typedef struct {
    lpf_scope *scope;
    uint8_t traced;            /* its begin event was recorded */
    uint64_t start;
    uint64_t child;            /* raw time in direct children */
    uint64_t kids, desc;       /* direct children and all descendants that completed */
    uint64_t allocs, bytes;    /* allocations while innermost */
    uint64_t allocs_in, bytes_in; /* including completed children */
} lpf_frame;

/* Timeline events, recorded only with LEANPROF_TRACE. */
typedef struct {
    const void *key;           /* scope key, or the copying pc */
    uint64_t ts, bytes;
    uint8_t ph, kind;          /* ph: 'B' begin, 'E' end, 'C' copy; kind: scope or copy kind */
} lpf_event;

typedef struct lpf_thread {
    lpf_scope *scopes[LP_TABLE];
    lpf_copy *copies[LP_TABLE];
    lpf_frame stack[LP_DEPTH];
    uint32_t depth;
    uint64_t dropped;
    lpf_event *events;
    size_t nevents, capevents;
    uint64_t events_dropped;
    uint32_t id;               /* registration order, the trace's tid */
    struct lpf_thread *next;
} lpf_thread;

static _Thread_local lpf_thread *lpf_self;
static lpf_thread *lpf_threads;
static uint32_t lpf_nthreads;
static int lpf_tracing;                /* LEANPROF_TRACE is set */
static size_t lpf_trace_max = 1u << 20; /* events per thread, LEANPROF_TRACE_MAX */
static pthread_mutex_t lpf_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t lpf_start;

/* Calibration, in 1/1024 ticks: `lpf_inner` is what an empty scope measures
 * itself, `lpf_pair` what a whole enter/exit pair adds to the scope around it. */
static uint64_t lpf_inner_fp, lpf_pair_fp;
static int lpf_calibrated; /* first calibration started (atomic) */
static void lpf_calibrate(void);

static void lpf_label_name(const char *label, char *out, size_t cap);

/* ---------- clock ---------- */

static inline uint64_t lpf_now(void) {
#ifdef __APPLE__
    return mach_absolute_time();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

static double lpf_ns_per_tick(void) {
#ifdef __APPLE__
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (double)tb.numer / (double)tb.denom;
#else
    return 1.0;
#endif
}

/* ---------- histogram: 16 sub-buckets per power of two, ~6% error ---------- */

static inline uint32_t lpf_bucket(uint64_t v) {
    if (v < LP_SUB) return (uint32_t)v;
    uint32_t msb = 63 - (uint32_t)__builtin_clzll(v);
    uint32_t sub = (uint32_t)(v >> (msb - 4)) & (LP_SUB - 1);
    return (msb - 3) * LP_SUB + sub;
}

static uint64_t lpf_bucket_low(uint32_t b) {
    if (b < LP_SUB) return b;
    uint32_t msb = b / LP_SUB + 3, sub = b % LP_SUB;
    return (uint64_t)(LP_SUB + sub) << (msb - 4);
}

static uint64_t lpf_percentile(const uint32_t *hist, uint64_t calls, double q) {
    uint64_t want = (uint64_t)(q * (double)calls), seen = 0;
    for (uint32_t b = 0; b < LP_BUCKETS; b++) {
        seen += hist[b];
        if (seen > want) return lpf_bucket_low(b);
    }
    return 0;
}

/* ---------- per-thread state ---------- */

static lpf_thread *lpf_thread_get(void) {
    lpf_thread *t = lpf_self;
    if (LEAN_LIKELY(t != NULL)) return t;
    t = calloc(1, sizeof(lpf_thread));
    if (t == NULL) abort();
    pthread_mutex_lock(&lpf_lock);
    t->id = lpf_nthreads++;
    t->next = lpf_threads;
    lpf_threads = t;
    pthread_mutex_unlock(&lpf_lock);
    lpf_self = t;
    return t;
}

/* Append a timeline event. Begin events stop a frame short of the limit, so
 * every recorded begin can still get its end. */
static int lpf_trace(lpf_thread *t, uint8_t ph, const void *key, uint8_t kind, uint64_t ts, uint64_t bytes) {
    size_t limit = ph == 'E' ? lpf_trace_max : lpf_trace_max - LP_DEPTH;
    if (t->nevents >= limit) {
        t->events_dropped++;
        return 0;
    }
    if (t->nevents == t->capevents) {
        size_t cap = t->capevents ? t->capevents * 2 : 4096;
        if (cap > lpf_trace_max) cap = lpf_trace_max;
        lpf_event *e = realloc(t->events, cap * sizeof(lpf_event));
        if (e == NULL) { t->events_dropped++; return 0; }
        t->events = e;
        t->capevents = cap;
    }
    t->events[t->nevents++] = (lpf_event){key, ts, bytes, ph, kind};
    return 1;
}

static inline size_t lpf_hash(const void *a, const void *b) {
    uint64_t h = ((uint64_t)(uintptr_t)a ^ ((uint64_t)(uintptr_t)b * 0x9e3779b97f4a7c15ull));
    h ^= h >> 29;
    h *= 0xbf58476d1ce4e5b9ull;
    h ^= h >> 32;
    return (size_t)h & (LP_TABLE - 1);
}

static lpf_scope *lpf_scope_get(lpf_thread *t, const void *key, uint8_t kind) {
    size_t i = lpf_hash(key, (const void *)(uintptr_t)(kind == LP_TASK));
    for (size_t n = 0; n < LP_TABLE; n++, i = (i + 1) & (LP_TABLE - 1)) {
        lpf_scope *s = t->scopes[i];
        if (LEAN_LIKELY(s != NULL && s->key == key && (s->kind == LP_TASK) == (kind == LP_TASK))) return s;
        if (s == NULL) {
            s = calloc(1, sizeof(lpf_scope));
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

static lpf_copy *lpf_copy_get(lpf_thread *t, void *pc, const lean_object *site, uint8_t kind) {
    size_t i = lpf_hash(pc, site);
    for (size_t n = 0; n < LP_TABLE; n++, i = (i + 1) & (LP_TABLE - 1)) {
        lpf_copy *c = t->copies[i];
        if (c != NULL && c->pc == pc && c->site == site && c->kind == kind) return c;
        if (c == NULL) {
            c = calloc(1, sizeof(lpf_copy));
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

__attribute__((no_instrument_function)) static inline void lpf_enter(const void *key, uint8_t kind) {
    /* Calibrate on first use, before any frame is open, so the cost lands in
     * no scope; programs that never profile never pay it. */
    if (LEAN_UNLIKELY(!__atomic_load_n(&lpf_calibrated, __ATOMIC_RELAXED)) && kind != LP_INTERNAL &&
        !__atomic_exchange_n(&lpf_calibrated, 1, __ATOMIC_ACQ_REL))
        lpf_calibrate();
    lpf_thread *t = lpf_thread_get();
    uint32_t d = t->depth++;
    if (LEAN_UNLIKELY(d >= LP_DEPTH)) return;
    lpf_scope *s = lpf_scope_get(t, key, kind);
    if (s != NULL) s->active++;
    lpf_frame *f = &t->stack[d];
    f->scope = s;
    f->child = f->kids = f->desc = 0;
    f->allocs = f->bytes = f->allocs_in = f->bytes_in = 0;
    f->start = lpf_now();
    f->traced = LEAN_UNLIKELY(lpf_tracing) && kind != LP_INTERNAL && lpf_trace(t, 'B', key, kind, f->start, 0);
}

static inline uint64_t lpf_sub(uint64_t a, uint64_t b) { return a > b ? a - b : 0; }

__attribute__((no_instrument_function)) static inline void lpf_exit(void) {
    uint64_t now = lpf_now();
    lpf_thread *t = lpf_self;
    if (t == NULL || t->depth == 0) return;
    uint32_t d = --t->depth;
    if (LEAN_UNLIKELY(d >= LP_DEPTH)) return;
    lpf_frame *f = &t->stack[d];
    if (LEAN_UNLIKELY(f->traced)) lpf_trace(t, 'E', f->scope ? f->scope->key : NULL, 0, now, 0);
    uint64_t raw = now - f->start;
    if (d > 0) {
        lpf_frame *p = &t->stack[d - 1];
        p->child += raw;
        p->kids++;
        p->desc += 1 + f->desc;
        p->allocs_in += f->allocs + f->allocs_in;
        p->bytes_in += f->bytes + f->bytes_in;
    }
    lpf_scope *s = f->scope;
    if (s == NULL) return;
    s->calls++;
    s->self += raw - f->child;
    s->sum += raw;
    s->kids += f->kids;
    s->desc_sum += f->desc;
    s->allocs_self += f->allocs;
    s->bytes_self += f->bytes;
    if (--s->active == 0) {
        s->total += raw;
        s->desc_total += f->desc;
        s->outer++;
        s->allocs_total += f->allocs + f->allocs_in;
        s->bytes_total += f->bytes + f->bytes_in;
    }
    /* per-call view for min/max/percentiles: clamped, so only approximate */
    uint64_t elapsed = lpf_sub(raw, (lpf_inner_fp + f->desc * lpf_pair_fp) >> 10);
    if (elapsed < s->min) s->min = elapsed;
    if (elapsed > s->max) s->max = elapsed;
    s->hist[lpf_bucket(elapsed)]++;
}

/* ---------- automatic mode ----------
 * Code compiled with -finstrument-functions-after-inlining (see
 * scripts/leanprof-cc, LEANPROF_AUTO) calls these around every function. */

__attribute__((no_instrument_function)) LEAN_EXPORT void __cyg_profile_func_enter(void *fn, void *call_site) {
    (void)call_site;
    lpf_enter(fn, LP_FN);
}

__attribute__((no_instrument_function)) LEAN_EXPORT void __cyg_profile_func_exit(void *fn, void *call_site) {
    (void)fn;
    (void)call_site;
    lpf_exit();
}

/* ---------- calibration ---------- */

static char lpf_calibration_key[2];

/* Measure one enter/exit pair. Noise only ever adds time, so after a warm-up
 * (the CPU may still be clocked down) keep the fastest of many small batches.
 * Runs at startup and again at exit, keeping the lower estimate. */
static void lpf_calibrate(void) {
    const char *off = getenv("LEANPROF_NO_CALIBRATION");
    if (off != NULL && strcmp(off, "1") == 0) return;
    enum { BATCH = 2048, BATCHES = 64 };
    lpf_thread *t = lpf_thread_get();
    uint32_t depth = t->depth;
    uint64_t best_pair = UINT64_MAX, best_inner = 0;
    uint64_t warm_until = lpf_now() + (uint64_t)(3e6 / lpf_ns_per_tick()); /* ~3 ms */
    lpf_enter(&lpf_calibration_key[0], LP_INTERNAL); /* outer frame: sees the full pair cost */
    lpf_scope *inner = lpf_scope_get(t, &lpf_calibration_key[1], LP_INTERNAL);
    for (int b = -1; b < BATCHES; b++) {
        if (b == -1) {
            while (lpf_now() < warm_until) {
                lpf_enter(&lpf_calibration_key[1], LP_INTERNAL);
                lpf_exit();
            }
            continue;
        }
        uint64_t sum0 = inner ? inner->sum : 0;
        uint64_t t0 = lpf_now();
        for (int i = 0; i < BATCH; i++) {
            lpf_enter(&lpf_calibration_key[1], LP_INTERNAL);
            lpf_exit();
        }
        uint64_t pair = ((lpf_now() - t0) << 10) / BATCH;
        if (pair < best_pair) {
            best_pair = pair;
            best_inner = inner ? ((inner->sum - sum0) << 10) / BATCH : 0;
        }
    }
    lpf_exit();
    t->depth = depth;
    if (best_inner > best_pair) best_inner = best_pair;
    if (lpf_pair_fp == 0 || best_pair < lpf_pair_fp) {
        lpf_pair_fp = best_pair;
        lpf_inner_fp = best_inner;
    }
}

/* Queries refine the estimate (they are not on a hot path). */
LEAN_EXPORT double leanprof_overhead_ns(void) {
    __atomic_store_n(&lpf_calibrated, 1, __ATOMIC_RELEASE);
    lpf_calibrate();
    return (double)lpf_pair_fp / 1024.0 * lpf_ns_per_tick();
}

LEAN_EXPORT lean_obj_res leanprof_scope(b_lean_obj_arg site, lean_obj_arg f) {
    lpf_enter(site, LP_LABEL);
    lean_object *r = lean_apply_1(f, lean_box(0));
    lpf_exit();
    return r;
}

LEAN_EXPORT lean_obj_res leanprof_enter(b_lean_obj_arg site) {
    lpf_enter(site, LP_LABEL);
    return lean_box(0);
}

LEAN_EXPORT lean_obj_res leanprof_exit(lean_obj_arg unit) {
    (void)unit;
    lpf_exit();
    return lean_box(0);
}

/* ---------- copies ----------
 * Programs built with leanprof's copy flags call these instead of the runtime
 * functions (see `-D` flags in the README). Each shim records why the value
 * was not exclusive and how long the copying call took.
 */

static inline int lpf_reason(lean_object *o) {
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
} lpf_pending;

static inline lpf_pending lpf_begin(void *pc, lean_object *o, uint8_t kind, size_t bytes) {
    lpf_pending p = {pc, kind, (uint8_t)lpf_reason(o), bytes, 0};
    p.start = lpf_now();
    return p;
}

static inline void lpf_end(const lpf_pending *p) {
    uint64_t elapsed = lpf_now() - p->start;
    lpf_thread *t = lpf_thread_get();
    const lean_object *site = NULL;
    uint32_t d = t->depth;
    /* the innermost `profile!` scope; automatic-mode frames are skipped */
    for (uint32_t k = d < LP_DEPTH ? d : LP_DEPTH; k > 0; k--) {
        lpf_scope *sc = t->stack[k - 1].scope;
        if (sc != NULL && sc->kind == LP_LABEL) { site = (const lean_object *)sc->key; break; }
    }
    if (LEAN_UNLIKELY(lpf_tracing)) lpf_trace(t, 'C', p->pc, p->kind, p->start, p->bytes);
    lpf_copy *c = lpf_copy_get(t, p->pc, site, p->kind);
    if (c == NULL) return;
    c->count[p->reason]++;
    c->bytes += p->bytes;
    c->ticks += elapsed;
}

static inline size_t lpf_sarray_bytes(lean_object *a) {
    return lean_sarray_size(a) * lean_sarray_elem_size(a);
}

#define LP_PC __builtin_return_address(0)

/* Called only when the value is not exclusive: always a copy. */
#define LP_COPY(kind, obj, bytes, call)                       \
    do {                                                      \
        lpf_pending p_ = lpf_begin(LP_PC, (obj), (kind), (bytes)); \
        lean_object *r_ = (call);                             \
        lpf_end(&p_);                                          \
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

/* Lean 4.35 added non-linear copy gadgets for scalar arrays and strings. */
#if LEAN_VERSION_MAJOR > 4 || (LEAN_VERSION_MAJOR == 4 && LEAN_VERSION_MINOR >= 35)
LEAN_EXPORT lean_obj_res leanprof_copy_sarray_nonlinear(lean_obj_arg a, size_t cap) {
    LP_COPY(LP_SCALAR_ARRAY, a, lpf_sarray_bytes(a), lean_copy_sarray_nonlinear(a, cap));
}

LEAN_EXPORT lean_obj_res leanprof_copy_string_nonlinear(lean_obj_arg s, size_t cap) {
    LP_COPY(LP_STRING, s, lean_string_size(s), lean_copy_string_nonlinear(s, cap));
}
#endif

LEAN_EXPORT lean_object *leanprof_array_push(lean_obj_arg a, lean_obj_arg v) {
    LP_MAYBE_COPY(LP_ARRAY, a, lean_array_size(a) * sizeof(void *), lean_array_push(a, v));
}

LEAN_EXPORT lean_obj_res leanprof_byte_array_push(lean_obj_arg a, uint8_t b) {
    LP_MAYBE_COPY(LP_SCALAR_ARRAY, a, lpf_sarray_bytes(a), lean_byte_array_push(a, b));
}

LEAN_EXPORT lean_obj_res leanprof_float_array_push(lean_obj_arg a, double d) {
    LP_MAYBE_COPY(LP_SCALAR_ARRAY, a, lpf_sarray_bytes(a), lean_float_array_push(a, d));
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

/* ---------- tasks ----------
 * Spawns are redirected here (see the -D flags): the task's closure is
 * wrapped so that, when a worker runs it, we record how long it waited and
 * time it as "task <- spawning scope". Blocking waits are timed per call site.
 */

/* The innermost open scope on this thread, for attributing tasks and waits. */
static void lpf_current(lpf_thread *t, const void **key, uint8_t *kind) {
    *key = NULL;
    *kind = LP_LABEL;
    for (uint32_t k = t->depth < LP_DEPTH ? t->depth : LP_DEPTH; k > 0; k--) {
        lpf_scope *sc = t->stack[k - 1].scope;
        if (sc == NULL || sc->kind == LP_INTERNAL) continue;
        if (sc->kind == LP_TASK) {
            *key = sc->key;
            *kind = sc->parent_kind;
        } else {
            *key = sc->key;
            *kind = sc->kind;
        }
        return;
    }
}

/* Called by the runtime in place of the task's closure: (ctx, arg). */
static lean_obj_res lpf_task_run(lean_obj_arg ctx, lean_obj_arg arg) {
    uint64_t now = lpf_now();
    lean_object *orig = lean_ctor_get(ctx, 0);
    lean_inc(orig);
    const void *parent = (const void *)(uintptr_t)lean_ctor_get_uint64(ctx, sizeof(void *));
    uint64_t spawned = lean_ctor_get_uint64(ctx, sizeof(void *) + 8);
    uint8_t parent_kind = lean_ctor_get_uint8(ctx, sizeof(void *) + 16);
    lean_dec(ctx);
    lpf_thread *t = lpf_thread_get();
    lpf_enter(parent, LP_TASK);
    uint32_t d = t->depth;
    if (d > 0 && d <= LP_DEPTH && t->stack[d - 1].scope != NULL) {
        lpf_scope *s = t->stack[d - 1].scope;
        s->parent_kind = parent_kind;
        if (t->stack[d - 1].traced) t->events[t->nevents - 1].kind = (uint8_t)(LP_TASK | (parent_kind << 4));
        uint64_t w = now > spawned ? now - spawned : 0;
        s->wait += w;
        if (w > s->wait_max) s->wait_max = w;
    }
    lean_object *r = lean_apply_1(orig, arg);
    lpf_exit();
    return r;
}

/* Wrap closure `c` so lpf_task_run sees the spawning scope. */
static lean_obj_res lpf_task_wrap(lean_obj_arg c) {
    lpf_thread *t = lpf_thread_get();
    const void *key;
    uint8_t kind;
    lpf_current(t, &key, &kind);
    lean_object *ctx = lean_alloc_ctor(0, 1, 17);
    lean_ctor_set(ctx, 0, c);
    lean_ctor_set_uint64(ctx, sizeof(void *), (uint64_t)(uintptr_t)key);
    lean_ctor_set_uint64(ctx, sizeof(void *) + 8, lpf_now());
    lean_ctor_set_uint8(ctx, sizeof(void *) + 16, kind);
    lean_object *w = lean_alloc_closure((void *)lpf_task_run, 2, 1);
    lean_closure_set(w, 0, ctx);
    return w;
}

LEAN_EXPORT lean_obj_res leanprof_task_spawn_core(lean_obj_arg c, unsigned prio, bool keep_alive) {
    return lean_task_spawn_core(lpf_task_wrap(c), prio, keep_alive);
}

LEAN_EXPORT lean_object *lean_io_as_task(lean_object *act, lean_object *prio);
LEAN_EXPORT lean_object *lean_io_wait(lean_object *t);

LEAN_EXPORT lean_object *leanprof_io_as_task(lean_object *act, lean_object *prio) {
    return lean_io_as_task(lpf_task_wrap(act), prio);
}

static void lpf_record_wait(void *pc, uint64_t start) {
    uint64_t elapsed = lpf_now() - start;
    lpf_thread *t = lpf_thread_get();
    const void *key;
    uint8_t kind;
    lpf_current(t, &key, &kind);
    const lean_object *site = kind == LP_LABEL ? (const lean_object *)key : NULL;
    lpf_copy *c = lpf_copy_get(t, pc, site, LP_WAIT);
    if (c == NULL) return;
    c->count[0]++;
    c->ticks += elapsed;
}

LEAN_EXPORT lean_object *leanprof_io_wait(lean_object *task) {
    uint64_t start = lpf_now();
    lean_object *r = lean_io_wait(task);
    lpf_record_wait(LP_PC, start);
    return r;
}

LEAN_EXPORT b_lean_obj_res leanprof_task_get(b_lean_obj_arg task) {
    uint64_t start = lpf_now();
    lean_object *r = lean_task_get(task);
    lpf_record_wait(LP_PC, start);
    return r;
}

/* ---------- allocations ----------
 * Opt-in (LEANPROF_ALLOCS=1 when building through the wrapper): allocation
 * calls from compiled Lean code come here. Each is charged to the innermost
 * scope and to its call site. Frees happen inside the runtime and are not
 * seen, so these are allocation counts and bytes, not live memory.
 */

static inline void lpf_alloc(void *pc, size_t sz) {
    lpf_thread *t = lpf_thread_get();
    uint32_t d = t->depth;
    if (d > 0 && d <= LP_DEPTH) {
        t->stack[d - 1].allocs++;
        t->stack[d - 1].bytes += sz;
    }
    const lean_object *site = NULL;
    for (uint32_t k = d < LP_DEPTH ? d : LP_DEPTH; k > 0; k--) {
        lpf_scope *sc = t->stack[k - 1].scope;
        if (sc != NULL && sc->kind == LP_LABEL) { site = (const lean_object *)sc->key; break; }
    }
    lpf_copy *c = lpf_copy_get(t, pc, site, LP_ALLOC);
    if (c == NULL) return;
    c->count[0]++;
    c->bytes += sz;
}

#if LEAN_VERSION_MAJOR > 4 || (LEAN_VERSION_MAJOR == 4 && LEAN_VERSION_MINOR >= 35)
LEAN_EXPORT lean_object *leanprof_alloc_small_object_core(unsigned sz) {
    lpf_alloc(LP_PC, sz);
    return lean_alloc_small_object_core(sz);
}
#endif

LEAN_EXPORT lean_object *leanprof_alloc_object(size_t sz) {
    lpf_alloc(LP_PC, sz);
    return lean_alloc_object(sz);
}

#ifdef LEAN_MIMALLOC
LEAN_EXPORT void *leanprof_mi_malloc(size_t sz) {
    lpf_alloc(LP_PC, sz);
    return mi_malloc(sz);
}

LEAN_EXPORT void *leanprof_mi_malloc_small(size_t sz) {
    lpf_alloc(LP_PC, sz);
    return mi_malloc_small(sz);
}
#endif

#include "counters.inc.c"

/* ---------- symbol names ----------
 * Inverse of Lean.Name.mangle: `l_` and `lp_<pkg>_` prefixes, then Lean's
 * Name.demangle, shown like Name.toString. Compiler-generated parts
 * (`_lam_0`, `_boxed`, `_closed_1`, `_redArg`, ...) are dropped so copies
 * group by the user declaration. `demangle-check` (Tests/DemangleCheck.lean)
 * compares this with Lean's own demangler on whole binaries.
 */

static void lpf_put_utf8(char **o, char *end, uint32_t c) {
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

static int lpf_hex(const char *s, int n, uint32_t *out) {
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

/* A decoded name: its components, each a string or a number. */
#define LPF_NAME_MAX 96
typedef struct {
    char text[1024];
    size_t len;
    unsigned short off[LPF_NAME_MAX];
    unsigned char num[LPF_NAME_MAX];
    int n;
} lpf_name;

typedef struct {
    char s[512];
    size_t n;
} lpf_acc;

static void lpf_acc_put(lpf_acc *a, char c) {
    if (a->n + 1 < sizeof a->s) a->s[a->n++] = c;
}

static void lpf_acc_unders(lpf_acc *a, size_t k) {
    while (k-- > 0) lpf_acc_put(a, '_');
}

static void lpf_name_add(lpf_name *nm, const char *s, size_t n, int num) {
    if (nm->n >= LPF_NAME_MAX || nm->len + n + 1 > sizeof nm->text) return;
    nm->off[nm->n] = (unsigned short)nm->len;
    nm->num[nm->n++] = (unsigned char)num;
    memcpy(nm->text + nm->len, s, n);
    nm->len += n;
    nm->text[nm->len++] = 0;
}

static const char *lpf_comp(const lpf_name *nm, int i) { return nm->text + nm->off[i]; }

static int lpf_digit(char c) { return c >= '0' && c <= '9'; }

/* A numeric component `N_`, then the '_' before the next component. */
static const char *lpf_decode_num(const char *s, lpf_name *nm) {
    const char *b = s;
    while (lpf_digit(*s)) s++;
    lpf_name_add(nm, b, (size_t)(s - b), 1);
    for (int k = 0; k < 2 && *s; k++) s++;
    return s;
}

/* Lean's Name.demangle (Lean/Compiler/NameMangling.lean), step for step: a
 * run of k underscores is k/2 escaped '_'; when k is odd the last one starts
 * a `_xHH`/`_uHHHH`/`_UHHHHHHHH` escape, a numeric component (`_N_`), a
 * component that would otherwise read as one of those (`_00`), or else
 * separates components (the escaped underscores then begin the next one). */
static void lpf_decode(const char *s, lpf_name *nm) {
    lpf_acc a;
    nm->n = 0;
    nm->len = 0;
    while (*s) { /* start of a component */
        char ch = *s++;
        size_t u = 0;
        a.n = 0;
        if (lpf_digit(ch)) {
            if (ch == '0' && *s == '0') {
                s++;
            } else {
                s = lpf_decode_num(s - 1, nm);
                continue;
            }
        } else if (ch == '_') {
            u = 1;
        } else {
            lpf_acc_put(&a, ch);
        }
        for (;;) {
            if (*s == 0) {
                lpf_acc_unders(&a, u / 2);
                lpf_name_add(nm, a.s, a.n, 0);
                return;
            }
            ch = *s++;
            if (ch == '_') {
                u++;
                continue;
            }
            if (u % 2 == 0) {
                lpf_acc_unders(&a, u / 2);
                lpf_acc_put(&a, ch);
                u = 0;
                continue;
            }
            if (lpf_digit(ch)) {
                lpf_acc_unders(&a, u / 2);
                lpf_name_add(nm, a.s, a.n, 0);
                a.n = 0;
                u = 0;
                if (ch == '0' && *s == '0') {
                    s++;
                    continue;
                }
                s = lpf_decode_num(s - 1, nm);
                break;
            }
            uint32_t c;
            int w = ch == 'x' ? 2 : ch == 'u' ? 4 : ch == 'U' ? 8 : 0;
            if (w && lpf_hex(s, w, &c)) {
                char buf[4], *o = buf;
                lpf_acc_unders(&a, u / 2);
                lpf_put_utf8(&o, buf + 4, c);
                for (char *p = buf; p < o; p++) lpf_acc_put(&a, *p);
                s += w;
                u = 0;
                continue;
            }
            lpf_name_add(nm, a.s, a.n, 0);
            a.n = 0;
            lpf_acc_unders(&a, u / 2);
            lpf_acc_put(&a, ch);
            u = 0;
        }
    }
}

/* Name.toString's escaping: a component that is not an identifier is
 * shown as «...», which is also how .ilean files spell declarations. */
static uint32_t lpf_utf8_next(const unsigned char **p) {
    const unsigned char *s = *p;
    uint32_t c = s[0];
    int n = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
    if (n > 1) c &= 0x3f >> (n - 1);
    for (int k = 1; k < n; k++) {
        if ((s[k] & 0xc0) != 0x80) {
            *p = s + k;
            return 0xfffd;
        }
        c = c << 6 | (s[k] & 0x3f);
    }
    *p = s + n;
    return c;
}

static int lpf_letter_like(uint32_t c) {
    return (c >= 0x3b1 && c <= 0x3c9 && c != 0x3bb) || (c >= 0x391 && c <= 0x3a9 && c != 0x3a0 && c != 0x3a3) ||
           (c >= 0x3ca && c <= 0x3fb) || (c >= 0x1f00 && c <= 0x1ffe) || (c >= 0x2100 && c <= 0x214f) ||
           (c >= 0x1d49c && c <= 0x1d59f) || (c >= 0xc0 && c <= 0xff && c != 0xd7 && c != 0xf7) ||
           (c >= 0x100 && c <= 0x17f);
}

static int lpf_id_first(uint32_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || lpf_letter_like(c);
}

static int lpf_id_rest(uint32_t c) {
    return lpf_id_first(c) || (c >= '0' && c <= '9') || c == '\'' || c == '!' || c == '?' ||
           (c >= 0x2080 && c <= 0x2089) || (c >= 0x2090 && c <= 0x209c) || (c >= 0x1d62 && c <= 0x1d6a) ||
           c == 0x2c7c;
}

static int lpf_needs_escape(const char *s) {
    const unsigned char *p = (const unsigned char *)s;
    if (*p == 0 || !lpf_id_first(lpf_utf8_next(&p))) return 1;
    while (*p)
        if (!lpf_id_rest(lpf_utf8_next(&p))) return 1;
    return 0;
}

/* Components the compiler adds to a declaration's name (`f._lam_0`,
 * `f._closed_3`, `f._redArg._boxed`, macro scopes `f._@.M._hyg.4`, ...).
 * Other components starting with '_' are user names (`Foo._bar`). */
static int lpf_compiler_part(const char *s) {
    static const char *const pre[] = {"_lam",     "_elam",        "_closed",     "_boxed", "_redArg",
                                      "_impl",    "_jp",          "_override",   "_spec",  "_unsafe_rec",
                                      "_regBuiltin", "_auto",     "_private",    "_@",     "_at_"};
    if (s[0] != '_') return 0;
    for (size_t i = 0; i < sizeof pre / sizeof pre[0]; i++)
        if (strncmp(s, pre[i], strlen(pre[i])) == 0) return 1;
    return 0;
}

/* Show components [a, b) of `nm` like Name.toString, without
 * `_private.<Module>.0.` prefixes and from the first compiler part on. */
static void lpf_show(const lpf_name *nm, int a, int b, char *out, size_t cap) {
    int idx[LPF_NAME_MAX], k = 0;
    for (int i = a; i < b; i++) {
        const char *s = lpf_comp(nm, i);
        if (!nm->num[i] && strcmp(s, "_private") == 0) {
            int j = i + 1;
            while (j < b && !(nm->num[j] && strcmp(lpf_comp(nm, j), "0") == 0)) j++;
            if (j + 1 < b) {
                i = j;
                continue;
            }
        }
        if (!nm->num[i] && strcmp(s, "_@") == 0) {
            /* a macro scope `_@.<Module>._hyg.<N>`, inside hygienic names
             * such as `Foo._@.M._hyg.1.ctorElim` */
            int j = i + 1;
            while (j < b && (nm->num[j] || strcmp(lpf_comp(nm, j), "_hyg") != 0)) j++;
            if (j + 1 < b && nm->num[j + 1]) {
                i = j + 1;
                while (i + 1 < b && nm->num[i + 1]) i++; /* `_hyg.3.5`: several scopes */
                continue;
            }
        }
        if (k > 0 && !nm->num[i] && lpf_compiler_part(s)) break;
        idx[k++] = i;
    }
    if (k == 0) {
        snprintf(out, cap, "?");
        return;
    }
    /* Name.toString does not escape names that may be pseudo-syntax
     * (`#0`, `?u`, `_`) or inaccessible (`x✝`) */
    int esc = 1;
    const char *root = lpf_comp(nm, idx[0]);
    if (!nm->num[idx[0]] && (root[0] == '#' || root[0] == '?' || (k == 1 && strcmp(root, "_") == 0))) esc = 0;
    for (int i = k - 1; i >= 0; i--) {
        if (nm->num[idx[i]]) continue;
        const char *s = lpf_comp(nm, idx[i]);
        if (strstr(s, "\xe2\x9c\x9d") != NULL || strcmp(s, "_inaccessible") == 0) esc = 0;
        break;
    }
    size_t n = 0;
    out[0] = 0;
    for (int i = 0; i < k && n < cap; i++) {
        const char *s = lpf_comp(nm, idx[i]);
        int wrap = esc && !nm->num[idx[i]] && lpf_needs_escape(s) && strstr(s, "\xc2\xbb") == NULL;
        int w = snprintf(out + n, cap - n, "%s%s%s%s", i > 0 ? "." : "", wrap ? "\xc2\xab" : "", s,
                         wrap ? "\xc2\xbb" : "");
        n += w > 0 ? (size_t)w : 0;
    }
}

/* `spec_N`, `_spec...` or another `_at_` ends a specialization's caller. */
static int lpf_spec_end(const char *s) {
    if (strncmp(s, "spec_", 5) == 0 && lpf_digit(s[5])) {
        const char *p = s + 5;
        while (lpf_digit(*p)) p++;
        if (*p == 0) return 1;
    }
    return strncmp(s, "_spec", 5) == 0 || strcmp(s, "_at_") == 0;
}

/* Drop `_private.<Module>.<N>.` prefixes of a name from an .ilean file. */
static void lpf_strip(char *name) {
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
}

/* What we show for a decoded name. A specialization
 * `Callee._at_.Caller.spec_N` is reported under the caller, because that is
 * the user code whose values were copied: `Caller (in Callee)`. */
static void lpf_name_show(const lpf_name *nm, char *out, size_t cap) {
    int at = -1;
    for (int i = 0; i < nm->n && at < 0; i++)
        if (!nm->num[i] && strcmp(lpf_comp(nm, i), "_at_") == 0) at = i;
    if (at < 0) {
        lpf_show(nm, 0, nm->n, out, cap);
        return;
    }
    int e = at + 1;
    while (e < nm->n && (nm->num[e] || !lpf_spec_end(lpf_comp(nm, e)))) e++;
    if (e == at + 1) {
        lpf_show(nm, 0, at, out, cap);
        return;
    }
    char callee[512], caller[512];
    lpf_show(nm, 0, at, callee, sizeof callee);
    lpf_show(nm, at + 1, e, caller, sizeof caller);
    snprintf(out, cap, "%s (in %s)", caller, callee);
}

/* `lp_<pkg>_<body>`: the package is the shortest prefix whose underscore
 * runs are all escapes (even length) and whose remainder can start a body. */
static void lpf_find_root_pkg(void);
static void lpf_mangle_module(const char *m, char *out, size_t cap);
static char lpf_root_pkg[256];

/* Mangled names of the packages this project knows (its own, from the
 * lakefile, and each in .lake/packages): `lp_<pkg>_` is ambiguous when a
 * package name has escapes (`lean-compiler-backend` is `lean_x2dcompiler_x2dbackend`). */
static char lpf_pkgs[64][256];
static int lpf_npkgs = -1;

/* String.Internal.mangle: a package name is mangled as one string, so a '.'
 * in it is an escape, not a separator. */
static void lpf_mangle_pkg(const char *m, char *out, size_t cap) {
    size_t n = 0;
    const unsigned char *p = (const unsigned char *)m;
    while (*p && n + 12 < cap) {
        uint32_t c = lpf_utf8_next(&p);
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) out[n++] = (char)c;
        else if (c == '_') { out[n++] = '_'; out[n++] = '_'; }
        else if (c < 0x100) n += (size_t)snprintf(out + n, cap - n, "_x%02x", c);
        else if (c < 0x10000) n += (size_t)snprintf(out + n, cap - n, "_u%04x", c);
        else n += (size_t)snprintf(out + n, cap - n, "_U%08x", c);
    }
    out[n] = 0;
}

static void lpf_load_pkgs(void) {
    lpf_npkgs = 0;
    if (lpf_root_pkg[0] == 0) lpf_find_root_pkg();
    if (lpf_root_pkg[0]) lpf_mangle_pkg(lpf_root_pkg, lpf_pkgs[lpf_npkgs++], 256);
    DIR *d = opendir(".lake/packages");
    struct dirent *e;
    while (d != NULL && (e = readdir(d)) != NULL && lpf_npkgs < 64) {
        if (e->d_name[0] == '.') continue;
        lpf_mangle_pkg(e->d_name, lpf_pkgs[lpf_npkgs++], 256);
    }
    if (d != NULL) closedir(d);
}

static const char *lpf_skip_package(const char *s) {
    if (lpf_npkgs < 0) lpf_load_pkgs();
    /* the longest known package: `foo__bar` before `foo` */
    size_t best = 0;
    for (int i = 0; i < lpf_npkgs; i++) {
        size_t n = strlen(lpf_pkgs[i]);
        if (n > best && strncmp(s, lpf_pkgs[i], n) == 0 && s[n] == '_') best = n;
    }
    if (best > 0) return s + best + 1;
    for (const char *p = s; *p; p++) {
        if (*p != '_') continue;
        /* `_xHH`, `_uHHHH`, `_UHHHHHHHH` inside a package name are escaped
         * characters, not the end */
        uint32_t c;
        if ((p[1] == 'x' && lpf_hex(p + 2, 2, &c)) || (p[1] == 'u' && lpf_hex(p + 2, 4, &c)) ||
            (p[1] == 'U' && lpf_hex(p + 2, 8, &c)))
            continue;
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

static void lpf_demangle(const char *s, char *out, size_t cap) {
#ifdef __APPLE__
    if (s[0] == '_') s++; /* Mach-O leading underscore */
#endif
    /* `f.cold.1`, `f.isra.0`, `f.llvm.42`: parts of `f` the C compiler split
     * off (mangled Lean names have no '.') */
    char sym[1024];
    const char *dot = strchr(s, '.');
    if (dot != NULL && dot > s) {
        size_t n = (size_t)(dot - s) < sizeof sym - 1 ? (size_t)(dot - s) : sizeof sym - 1;
        memcpy(sym, s, n);
        sym[n] = 0;
        s = sym;
    }
    if (strcmp(s, "_lean_main") == 0 || strcmp(s, "lean_main") == 0) {
        snprintf(out, cap, "main");
        return;
    }
    if (strncmp(s, "lp_", 3) == 0) {
        s = lpf_skip_package(s + 3);
    } else if (strncmp(s, "l_", 2) == 0) {
        s += 2;
    } else {
        snprintf(out, cap, "%s", s);
        return;
    }
    lpf_name nm;
    lpf_decode(s, &nm);
    lpf_name_show(&nm, out, cap);
}

static void lpf_symbol_raw(void *pc, char *out, size_t cap) {
    Dl_info info;
    if (!dladdr(pc, &info) || info.dli_sname == NULL) snprintf(out, cap, "%p", pc);
    else snprintf(out, cap, "%s", info.dli_sname);
}

static void lpf_symbol_name(void *pc, char *out, size_t cap) {
    Dl_info info;
    if (!dladdr(pc, &info) || info.dli_sname == NULL) {
        snprintf(out, cap, "%p", pc);
        return;
    }
    lpf_demangle(info.dli_sname, out, cap);
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
} lpf_decl;

static lpf_decl *lpf_decls;
static size_t lpf_ndecls, lpf_capdecls;
static int lpf_indexed;

static void lpf_add_decl(const char *name, const char *prefix, const char *module, unsigned line) {
    if (lpf_ndecls == lpf_capdecls) {
        size_t cap = lpf_capdecls ? lpf_capdecls * 2 : 256;
        lpf_decl *d = realloc(lpf_decls, cap * sizeof(lpf_decl));
        if (d == NULL) return;
        lpf_decls = d;
        lpf_capdecls = cap;
    }
    size_t np = strlen(prefix), n = strlen(module);
    char *file = malloc(np + n + 6);
    char *nm = strdup(name);
    if (file == NULL || nm == NULL) { free(file); free(nm); return; }
    memcpy(file, prefix, np);
    for (size_t i = 0; i < n; i++) file[np + i] = module[i] == '.' ? '/' : module[i];
    memcpy(file + np + n, ".lean", 6);
    lpf_strip(nm);
    lpf_decls[lpf_ndecls++] = (lpf_decl){nm, file, line};
}

/* Read a JSON string at `p` (just after the opening quote) into out. */
static const char *lpf_json_read_str(const char *p, char *out, size_t cap) {
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
static void lpf_mangle_module(const char *m, char *out, size_t cap) {
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

static void lpf_find_root_pkg(void) {
    FILE *f = fopen("lakefile.toml", "r");
    char line[512];
    if (f != NULL) {
        while (fgets(line, sizeof line, f)) {
            char *q;
            if (strncmp(line, "name", 4) == 0 && (q = strchr(line, '"')) != NULL) {
                lpf_json_read_str(q + 1, lpf_root_pkg, sizeof lpf_root_pkg);
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
            const char *esc = strstr(line + 8, "\xc2\xbb");
            if (strncmp(line + 8, "\xc2\xab", 2) == 0 && esc != NULL) { /* package «lean-compiler-backend» */
                n = (size_t)(esc - (line + 10)) < sizeof lpf_root_pkg - 1 ? (size_t)(esc - (line + 10))
                                                                          : sizeof lpf_root_pkg - 1;
                memcpy(lpf_root_pkg, line + 10, n);
                lpf_root_pkg[n] = 0;
                break;
            }
            for (const char *q = line + 8; n + 1 < sizeof lpf_root_pkg; q++) {
                char c = *q;
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' ||
                      c == '\'' || c == '-'))
                    break;
                lpf_root_pkg[n++] = c;
            }
            lpf_root_pkg[n] = 0;
            break;
        }
    }
    fclose(f);
}

/* Symbols of another binary (sorted), when positions are resolved for a
 * program other than this one (`leanprof sample`). */
static char **lpf_symbols;
static size_t lpf_nsymbols;

static int lpf_cmp_str(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

static int lpf_has_symbol(const char *name) {
    if (lpf_symbols != NULL) return bsearch(&name, lpf_symbols, lpf_nsymbols, sizeof(char *), lpf_cmp_str) != NULL;
    return dlsym(RTLD_DEFAULT, name) != NULL;
}

LEAN_EXPORT lean_obj_res leanprof_set_symbols(b_lean_obj_arg names) {
    size_t n = lean_array_size(names);
    char **v = calloc(n ? n : 1, sizeof(char *));
    if (v == NULL) return lean_box(0);
    for (size_t i = 0; i < n; i++) v[i] = strdup(lean_string_cstr(lean_array_get_core(names, i)));
    qsort(v, n, sizeof(char *), lpf_cmp_str);
    lpf_symbols = v;
    lpf_nsymbols = n;
    lpf_indexed = 0; /* re-index against these symbols */
    return lean_box(0);
}

/* Is `module` part of this program? Its initializer symbol tells us; this
 * keeps a test executable's `main` from matching an example's. Without
 * exported symbols (no -rdynamic) every module counts. */
static int lpf_module_linked(const char *module, const char *pkg) {
    static int symbols_visible = -1;
    if (symbols_visible < 0 || lpf_symbols != NULL)
        symbols_visible = lpf_has_symbol("lean_main") || lpf_has_symbol("_lean_main");
    if (!symbols_visible || pkg == NULL) return 1;
    char mm[512], mp[256], sym[1024];
    lpf_mangle_module(module, mm, sizeof mm);
    snprintf(sym, sizeof sym, "initialize_%s", mm);
    if (lpf_has_symbol(sym)) return 1;
    if (pkg != NULL && pkg[0]) {
        lpf_mangle_module(pkg, mp, sizeof mp);
        snprintf(sym, sizeof sym, "initialize_%s_%s", mp, mm);
        if (lpf_has_symbol(sym)) return 1;
    }
    return 0;
}

static void lpf_index_file(const char *path, const char *prefix, const char *pkg) {
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
    if (m != NULL) lpf_json_read_str(m + 10, module, sizeof module);
    const char *p = strstr(buf, "\"decls\":{");
    if (module[0] == 0 || p == NULL || !lpf_module_linked(module, pkg)) { free(buf); return; }
    p += 9;
    while (*p == '"') {
        char name[512];
        p = lpf_json_read_str(p + 1, name, sizeof name);
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
        lpf_add_decl(name, prefix, module, (k >= 5 ? v[4] : v[0]) + 1);
        if (*p == ',') p++;
    }
    free(buf);
}

static void lpf_index_dir(const char *dir, const char *prefix, const char *pkg, int depth) {
    if (depth > 32) return;
    DIR *d = opendir(dir);
    if (d == NULL) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        char path[4096];
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        size_t n = strlen(e->d_name);
        if (n > 6 && strcmp(e->d_name + n - 6, ".ilean") == 0) lpf_index_file(path, prefix, pkg);
        else lpf_index_dir(path, prefix, pkg, depth + 1); /* opendir fails quietly on files */
    }
    closedir(d);
}

/* file:line of a reported function name, or "" when unknown. */
static const char *lpf_where(const char *fn, char *out, size_t cap) {
    if (!lpf_indexed) {
        lpf_indexed = 1;
        const char *dir = getenv("LEANPROF_ILEAN_DIR");
        if (dir && dir[0]) {
            lpf_index_dir(dir, "", NULL, 0);
        } else {
            /* this package, then each dependency Lake checked out */
            lpf_find_root_pkg();
            lpf_index_dir(".lake/build/lib/lean", "", lpf_root_pkg, 0);
            DIR *d = opendir(".lake/packages");
            struct dirent *e;
            while (d != NULL && (e = readdir(d)) != NULL) {
                if (e->d_name[0] == '.') continue;
                char path[1024], prefix[1024];
                snprintf(path, sizeof path, ".lake/packages/%s/.lake/build/lib/lean", e->d_name);
                snprintf(prefix, sizeof prefix, ".lake/packages/%s/", e->d_name);
                lpf_index_dir(path, prefix, e->d_name, 0);
            }
            if (d != NULL) closedir(d);
        }
    }
    char name[256];
    snprintf(name, sizeof name, "%s", fn);
    char *in = strstr(name, " (in ");
    if (in != NULL) *in = 0;
    out[0] = 0;
    for (size_t i = 0; i < lpf_ndecls; i++) {
        if (strcmp(lpf_decls[i].name, name) == 0) {
            snprintf(out, cap, "%s:%u", lpf_decls[i].file, lpf_decls[i].line);
            break;
        }
    }
    return out;
}

/* "task <- parent": what spawned a task, by the spawning scope's kind. */
static void lpf_task_name(const void *parent, uint8_t parent_kind, char *out, size_t cap) {
    char p[256];
    if (parent == NULL) snprintf(p, sizeof p, "top level");
    else if (parent_kind == LP_FN) lpf_symbol_name((void *)parent, p, sizeof p);
    else lpf_label_name(lean_string_cstr((lean_object *)parent), p, sizeof p);
    snprintf(out, cap, "task <- %s", p);
}

/* ---------- queries, for tests and assertions ---------- */

/* Copies of non-constant values recorded so far, on all threads. */
LEAN_EXPORT lean_obj_res leanprof_copies(void) {
    uint64_t n = 0;
    pthread_mutex_lock(&lpf_lock);
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++)
            if (t->copies[i] != NULL && t->copies[i]->kind < LP_KINDS) /* not waits or allocations */
                n += t->copies[i]->count[LP_SHARED] + t->copies[i]->count[LP_MULTI_THREADED];
    pthread_mutex_unlock(&lpf_lock);
    return lean_uint64_to_nat(n);
}

/* Completed calls of scopes named `site` (positions ignored), on all threads. */
LEAN_EXPORT lean_obj_res leanprof_calls(b_lean_obj_arg site) {
    const char *want = lean_string_cstr(site);
    char name[128];
    uint64_t n = 0;
    pthread_mutex_lock(&lpf_lock);
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++) {
            if (t->scopes[i] == NULL || t->scopes[i]->kind != LP_LABEL) continue;
            lpf_label_name(lean_string_cstr((lean_object *)t->scopes[i]->key), name, sizeof name);
            if (strcmp(name, want) == 0) n += t->scopes[i]->calls;
        }
    pthread_mutex_unlock(&lpf_lock);
    return lean_uint64_to_nat(n);
}

/* Total time of scopes named `site` (outermost calls, overhead removed), in
 * ns, on all threads. */
LEAN_EXPORT double leanprof_total_ns(b_lean_obj_arg site) {
    __atomic_store_n(&lpf_calibrated, 1, __ATOMIC_RELEASE);
    lpf_calibrate();
    const char *want = lean_string_cstr(site);
    char name[128];
    double inner = (double)lpf_inner_fp / 1024.0, pair = (double)lpf_pair_fp / 1024.0, ticks = 0;
    pthread_mutex_lock(&lpf_lock);
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_scope *sc = t->scopes[i];
            if (sc == NULL || sc->kind != LP_LABEL) continue;
            lpf_label_name(lean_string_cstr((lean_object *)sc->key), name, sizeof name);
            if (strcmp(name, want) == 0)
                ticks += (double)sc->total - (double)sc->outer * inner - (double)sc->desc_total * pair;
        }
    pthread_mutex_unlock(&lpf_lock);
    return ticks > 0 ? ticks * lpf_ns_per_tick() : 0;
}

/* Allocations recorded so far (LEANPROF_ALLOCS builds), on all threads. */
LEAN_EXPORT lean_obj_res leanprof_allocs(void) {
    uint64_t n = 0;
    pthread_mutex_lock(&lpf_lock);
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++)
            if (t->copies[i] != NULL && t->copies[i]->kind == LP_ALLOC) n += t->copies[i]->count[0];
    pthread_mutex_unlock(&lpf_lock);
    return lean_uint64_to_nat(n);
}

/* Open scopes on the current thread. */
LEAN_EXPORT lean_obj_res leanprof_depth(void) {
    lpf_thread *t = lpf_self;
    return lean_box(t == NULL ? 0 : t->depth);
}

LEAN_EXPORT lean_obj_res leanprof_where(b_lean_obj_arg fn) {
    char out[512];
    lpf_where(lean_string_cstr(fn), out, sizeof out);
    return lean_mk_string(out);
}

LEAN_EXPORT lean_obj_res leanprof_demangle(b_lean_obj_arg sym) {
    char out[512];
    lpf_demangle(lean_string_cstr(sym), out, sizeof out);
    return lean_mk_string(out);
}

/* ---------- report ---------- */

/* `profile!` labels are "name\x1fFile.lean:line"; older or hand-written ones
 * have no position. */
#define LP_POS_SEP '\x1f'

static void lpf_label_name(const char *label, char *out, size_t cap) {
    const char *sep = strchr(label, LP_POS_SEP);
    size_t n = sep ? (size_t)(sep - label) : strlen(label);
    if (n >= cap) n = cap - 1;
    memcpy(out, label, n);
    out[n] = 0;
}

static const char *lpf_label_pos(const char *label) {
    const char *sep = strchr(label, LP_POS_SEP);
    return sep ? sep + 1 : "";
}

typedef struct {
    const char *label;         /* merge key: the label, or "\x01" + function name */
    char name[256], where[512];
    uint8_t is_fn, is_task;
    uint64_t wait, wait_max;   /* tasks: spawn to start */
    uint64_t allocs_self, bytes_self, allocs_total, bytes_total;
    uint64_t calls, total, self, sum, min, max;
    uint32_t hist[LP_BUCKETS];
} lpf_scope_sum;

typedef struct {
    char fn[256], sym[256], scope[128], where[512];
    const char *label;
    uint8_t kind;
    uint64_t count[LP_REASONS], bytes, total, ticks;
} lpf_copy_sum;

static int lpf_by_total(const void *a, const void *b) {
    const lpf_scope_sum *x = a, *y = b;
    return x->total < y->total ? 1 : x->total > y->total ? -1 : 0;
}

/* Costliest first; bytes break ties when the clock is too coarse. */
static int lpf_by_cost(const void *a, const void *b) {
    const lpf_copy_sum *x = a, *y = b;
    if (x->ticks != y->ticks) return x->ticks < y->ticks ? 1 : -1;
    if (x->bytes != y->bytes) return x->bytes < y->bytes ? 1 : -1;
    return x->total < y->total ? 1 : x->total > y->total ? -1 : 0;
}

static void lpf_fmt_time(double ns, char *buf, size_t n) {
    if (ns < 1e3) snprintf(buf, n, "%.0f ns", ns);
    else if (ns < 1e6) snprintf(buf, n, "%.1f µs", ns / 1e3);
    else if (ns < 1e9) snprintf(buf, n, "%.1f ms", ns / 1e6);
    else snprintf(buf, n, "%.2f s", ns / 1e9);
}

static void lpf_fmt_bytes(double b, char *buf, size_t n) {
    if (b < 1024) snprintf(buf, n, "%.0f B", b);
    else if (b < 1024 * 1024) snprintf(buf, n, "%.1f KiB", b / 1024);
    else if (b < 1024.0 * 1024 * 1024) snprintf(buf, n, "%.1f MiB", b / (1024 * 1024));
    else snprintf(buf, n, "%.2f GiB", b / (1024.0 * 1024 * 1024));
}

static void lpf_json_str(FILE *f, const char *s) {
    fputc('"', f);
    for (; *s; s++) {
        if (*s == '"' || *s == '\\') fprintf(f, "\\%c", *s);
        else if ((unsigned char)*s < 0x20) fprintf(f, "\\u%04x", *s);
        else fputc(*s, f);
    }
    fputc('"', f);
}

static int lpf_interesting(const lpf_copy_sum *c) {
    return c->kind < LP_KINDS && c->count[LP_SHARED] + c->count[LP_MULTI_THREADED] > 0;
}

static const lpf_scope_sum *lpf_find_scope(const lpf_scope_sum *S, size_t ns, const char *label) {
    for (size_t k = 0; k < ns; k++)
        if (strcmp(S[k].label, label) == 0) return &S[k];
    return NULL;
}

static void lpf_print(FILE *f, const lpf_scope_sum *S, size_t ns, const lpf_copy_sum *C, size_t nc, double tick,
                     double wall, uint64_t dropped) {
    char w[32];
    lpf_fmt_time(wall, w, sizeof w);
    fprintf(f, "\nleanprof: %zu scopes, wall %s, %.1f ns overhead per scope subtracted\n", ns, w,
            (double)lpf_pair_fp / 1024.0 * tick);
    int any_fn = 0;
    size_t ntasks = 0, nwaits = 0, nallocs = 0;
    for (size_t k = 0; k < ns; k++) {
        any_fn |= S[k].is_fn;
        ntasks += S[k].is_task;
    }
    for (size_t k = 0; k < nc; k++) {
        nwaits += C[k].kind == LP_WAIT;
        nallocs += C[k].kind == LP_ALLOC;
    }
    if (ns > 0) {
        fprintf(f, "\n%10s %10s %10s %6s %10s %10s %10s", "calls", "total", "self", "%wall", "mean", "p50", "p99");
        if (nallocs > 0) fprintf(f, " %10s %11s", "allocs", "alloc bytes");
        fprintf(f, "  %s\n", any_fn ? "function or \"scope\"  (where)" : "scope  (where)");
        for (size_t k = 0; k < ns; k++) {
            if (S[k].is_task) continue;
            char tt[32], st[32], mt[32], p50[32], p99[32];
            lpf_fmt_time((double)S[k].total * tick, tt, sizeof tt);
            lpf_fmt_time((double)S[k].self * tick, st, sizeof st);
            lpf_fmt_time((double)S[k].sum * tick / (double)S[k].calls, mt, sizeof mt);
            lpf_fmt_time((double)lpf_percentile(S[k].hist, S[k].calls, 0.50) * tick, p50, sizeof p50);
            lpf_fmt_time((double)lpf_percentile(S[k].hist, S[k].calls, 0.99) * tick, p99, sizeof p99);
            char shown[300];
            if (any_fn && !S[k].is_fn) snprintf(shown, sizeof shown, "\"%s\"", S[k].name); /* a profile! label */
            else snprintf(shown, sizeof shown, "%s", S[k].name);
            fprintf(f, "%10llu %10s %10s %5.1f%% %10s %10s %10s", (unsigned long long)S[k].calls, tt, st,
                    wall > 0 ? 100.0 * (double)S[k].total * tick / wall : 0.0, mt, p50, p99);
            if (nallocs > 0) {
                char ab[32];
                lpf_fmt_bytes((double)S[k].bytes_total, ab, sizeof ab);
                fprintf(f, " %10llu %11s", (unsigned long long)S[k].allocs_total, ab);
            }
            if (S[k].where[0]) fprintf(f, "  %s  (%s)\n", shown, S[k].where);
            else fprintf(f, "  %s\n", shown);
        }
    }
    const char *all = getenv("LEANPROF_ALL");
    int show_all = all != NULL && strcmp(all, "1") == 0;
    size_t shown = 0, hidden = 0;
    for (size_t k = 0; k < nc; k++) {
        if (C[k].kind >= LP_KINDS) continue;
        if (show_all || lpf_interesting(&C[k])) shown++;
        else hidden++;
    }
    if (shown > 0) {
        fprintf(f, "\ncopies of non-exclusive values (each one copied the whole value)\n");
        fprintf(f, "%8s %11s %10s %7s  %-11s %-14s %-18s %s\n", "copies", "bytes", "time", "%scope", "kind", "why",
                "in scope", "function  (where)");
        for (size_t k = 0; k < nc; k++) {
            if (C[k].kind >= LP_KINDS || (!show_all && !lpf_interesting(&C[k]))) continue;
            char bt[32], tt[32], share[16] = "-", why[64] = "";
            lpf_fmt_bytes((double)C[k].bytes, bt, sizeof bt);
            lpf_fmt_time((double)C[k].ticks * tick, tt, sizeof tt);
            const lpf_scope_sum *sc = C[k].label ? lpf_find_scope(S, ns, C[k].label) : NULL;
            if (sc != NULL && sc->total > 0)
                snprintf(share, sizeof share, "%.1f%%", 100.0 * (double)C[k].ticks / (double)sc->total);
            for (int r = 0; r < LP_REASONS; r++) {
                if (C[k].count[r] == 0) continue;
                /* copies of constants are expected; name them only when they are all there is */
                if (r == LP_PERSISTENT && lpf_interesting(&C[k])) continue;
                if (why[0]) strncat(why, "+", sizeof why - strlen(why) - 1);
                strncat(why, lpf_reason_name[r], sizeof why - strlen(why) - 1);
            }
            fprintf(f, "%8llu %11s %10s %7s  %-11s %-14s %-18s %s", (unsigned long long)C[k].total, bt, tt, share,
                    lpf_kind_name[C[k].kind], why, C[k].scope, C[k].fn);
            if (C[k].where[0]) fprintf(f, "  (%s)", C[k].where);
            fputc('\n', f);
        }
    }
    if (ntasks > 0) {
        fprintf(f, "\ntasks (run on worker threads; wait is spawn to start)\n");
        fprintf(f, "%8s %10s %10s %10s %10s  %s\n", "tasks", "run total", "run mean", "wait mean", "wait max",
                "spawned by");
        for (size_t k = 0; k < ns; k++) {
            if (!S[k].is_task) continue;
            char rt[32], rm[32], wm[32], wx[32];
            lpf_fmt_time((double)S[k].total * tick, rt, sizeof rt);
            lpf_fmt_time((double)S[k].sum * tick / (double)S[k].calls, rm, sizeof rm);
            lpf_fmt_time((double)S[k].wait * tick / (double)S[k].calls, wm, sizeof wm);
            lpf_fmt_time((double)S[k].wait_max * tick, wx, sizeof wx);
            fprintf(f, "%8llu %10s %10s %10s %10s  %s\n", (unsigned long long)S[k].calls, rt, rm, wm, wx,
                    S[k].name + 8 /* drop "task <- " */);
        }
    }
    if (nallocs > 0) {
        /* biggest allocation sites first */
        size_t *idx = malloc(nallocs * sizeof(size_t)), m = 0;
        for (size_t k = 0; k < nc && idx != NULL; k++)
            if (C[k].kind == LP_ALLOC) idx[m++] = k;
        for (size_t a = 0; idx != NULL && a < m; a++)
            for (size_t b = a + 1; b < m; b++)
                if (C[idx[b]].bytes > C[idx[a]].bytes) {
                    size_t tmp = idx[a];
                    idx[a] = idx[b];
                    idx[b] = tmp;
                }
        uint64_t all_n = 0, all_b = 0;
        for (size_t a = 0; a < m; a++) {
            all_n += C[idx[a]].total;
            all_b += C[idx[a]].bytes;
        }
        char tb[32];
        lpf_fmt_bytes((double)all_b, tb, sizeof tb);
        fprintf(f, "\nallocations: %llu, %s (from compiled Lean code; frees are not tracked)\n",
                (unsigned long long)all_n, tb);
        fprintf(f, "%10s %11s %7s  %-18s %s\n", "allocs", "bytes", "share", "in scope", "function  (where)");
        for (size_t a = 0; a < m && a < 20; a++) {
            const lpf_copy_sum *c = &C[idx[a]];
            char bb[32];
            lpf_fmt_bytes((double)c->bytes, bb, sizeof bb);
            fprintf(f, "%10llu %11s %6.1f%%  %-18s %s", (unsigned long long)c->total, bb,
                    all_b ? 100.0 * (double)c->bytes / (double)all_b : 0.0, c->scope, c->fn);
            if (c->where[0]) fprintf(f, "  (%s)", c->where);
            fputc('\n', f);
        }
        if (m > 20) fprintf(f, "(%zu more sites in the JSON report)\n", m - 20);
        free(idx);
    }
    if (nwaits > 0) {
        fprintf(f, "\nblocking waits (IO.wait, Task.get)\n");
        fprintf(f, "%8s %10s %10s  %-18s %s\n", "waits", "blocked", "mean", "in scope", "function  (where)");
        for (size_t k = 0; k < nc; k++) {
            if (C[k].kind != LP_WAIT) continue;
            char bt[32], mt[32];
            lpf_fmt_time((double)C[k].ticks * tick, bt, sizeof bt);
            lpf_fmt_time((double)C[k].ticks * tick / (double)(C[k].total ? C[k].total : 1), mt, sizeof mt);
            fprintf(f, "%8llu %10s %10s  %-18s %s", (unsigned long long)C[k].total, bt, mt, C[k].scope, C[k].fn);
            if (C[k].where[0]) fprintf(f, "  (%s)", C[k].where);
            fputc('\n', f);
        }
    }
    lpf_counters_print(f);
    if (hidden > 0)
        fprintf(f, "\nleanprof: %zu sites only copied compile-time constants (LEANPROF_ALL=1 shows them)\n", hidden);
    if (dropped > 0) fprintf(f, "\nleanprof: %llu events dropped (table full)\n", (unsigned long long)dropped);
    fprintf(f, "\n");
}

static void lpf_write_json(FILE *f, const lpf_scope_sum *S, size_t ns, const lpf_copy_sum *C, size_t nc, double tick,
                          double wall, uint64_t dropped) {
    fprintf(f, "{\"version\":3,\"wall_ns\":%.0f,\"overhead_ns\":%.1f,\"dropped\":%llu,\"scopes\":[", wall,
            (double)lpf_pair_fp / 1024.0 * tick, (unsigned long long)dropped);
    int first = 1;
    for (size_t k = 0; k < ns; k++) {
        if (S[k].is_task) continue;
        fprintf(f, "%s{\"name\":", first ? "" : ",");
        first = 0;
        lpf_json_str(f, S[k].name);
        fprintf(f, ",\"pos\":");
        lpf_json_str(f, S[k].where);
        fprintf(f, ",\"auto\":%s", S[k].is_fn ? "true" : "false");
        fprintf(f, ",\"calls\":%llu,\"total_ns\":%.0f,\"self_ns\":%.0f,\"min_ns\":%.0f,\"max_ns\":%.0f,"
                   "\"mean_ns\":%.0f,\"p50_ns\":%.0f,\"p99_ns\":%.0f,\"allocs\":%llu,\"alloc_bytes\":%llu,"
                   "\"allocs_self\":%llu,\"alloc_bytes_self\":%llu}",
                (unsigned long long)S[k].calls, (double)S[k].total * tick, (double)S[k].self * tick,
                (double)S[k].min * tick, (double)S[k].max * tick, (double)S[k].sum * tick / (double)S[k].calls,
                (double)lpf_percentile(S[k].hist, S[k].calls, 0.50) * tick,
                (double)lpf_percentile(S[k].hist, S[k].calls, 0.99) * tick, (unsigned long long)S[k].allocs_total,
                (unsigned long long)S[k].bytes_total, (unsigned long long)S[k].allocs_self,
                (unsigned long long)S[k].bytes_self);
    }
    fprintf(f, "],\"allocations\":[");
    first = 1;
    for (size_t k = 0; k < nc; k++) {
        if (C[k].kind != LP_ALLOC) continue;
        fprintf(f, "%s{\"function\":", first ? "" : ",");
        first = 0;
        lpf_json_str(f, C[k].fn);
        fprintf(f, ",\"scope\":");
        lpf_json_str(f, C[k].scope);
        fprintf(f, ",\"where\":");
        lpf_json_str(f, C[k].where);
        fprintf(f, ",\"allocs\":%llu,\"bytes\":%llu}", (unsigned long long)C[k].total,
                (unsigned long long)C[k].bytes);
    }
    fprintf(f, "],\"tasks\":[");
    first = 1;
    for (size_t k = 0; k < ns; k++) {
        if (!S[k].is_task) continue;
        fprintf(f, "%s{\"spawned_by\":", first ? "" : ",");
        first = 0;
        lpf_json_str(f, S[k].name + 8);
        fprintf(f, ",\"tasks\":%llu,\"run_total_ns\":%.0f,\"run_sum_ns\":%.0f,\"wait_ns\":%.0f,\"wait_max_ns\":%.0f}",
                (unsigned long long)S[k].calls, (double)S[k].total * tick, (double)S[k].sum * tick,
                (double)S[k].wait * tick, (double)S[k].wait_max * tick);
    }
    fprintf(f, "],\"waits\":[");
    first = 1;
    for (size_t k = 0; k < nc; k++) {
        if (C[k].kind != LP_WAIT) continue;
        fprintf(f, "%s{\"function\":", first ? "" : ",");
        first = 0;
        lpf_json_str(f, C[k].fn);
        fprintf(f, ",\"scope\":");
        lpf_json_str(f, C[k].scope);
        fprintf(f, ",\"where\":");
        lpf_json_str(f, C[k].where);
        fprintf(f, ",\"waits\":%llu,\"blocked_ns\":%.0f}", (unsigned long long)C[k].total,
                (double)C[k].ticks * tick);
    }
    fprintf(f, "],\"copies\":[");
    first = 1;
    for (size_t k = 0; k < nc; k++) {
        if (C[k].kind >= LP_KINDS) continue;
        fprintf(f, "%s{\"function\":", first ? "" : ",");
        first = 0;
        lpf_json_str(f, C[k].fn);
        fprintf(f, ",\"symbol\":");
        lpf_json_str(f, C[k].sym);
        fprintf(f, ",\"scope\":");
        lpf_json_str(f, C[k].scope);
        fprintf(f, ",\"where\":");
        lpf_json_str(f, C[k].where);
        fprintf(f, ",\"kind\":\"%s\",\"copies\":%llu,\"bytes\":%llu,\"copy_ns\":%.0f,\"shared\":%llu,"
                   "\"multi_threaded\":%llu,\"persistent\":%llu}",
                lpf_kind_name[C[k].kind], (unsigned long long)C[k].total, (unsigned long long)C[k].bytes,
                (double)C[k].ticks * tick, (unsigned long long)C[k].count[LP_SHARED],
                (unsigned long long)C[k].count[LP_MULTI_THREADED], (unsigned long long)C[k].count[LP_PERSISTENT]);
    }
    fprintf(f, "]");
    lpf_counters_json(f);
    fprintf(f, "}\n");
}

/* True when the only thread is the one calibration ran on, with nothing else
 * recorded. */
static int lpf_only_calibrated(void) {
    lpf_thread *t = lpf_threads;
    for (size_t i = 0; i < LP_TABLE; i++) {
        if (t->scopes[i] != NULL && t->scopes[i]->kind != LP_INTERNAL) return 0;
        if (t->copies[i] != NULL) return 0;
    }
    return 1;
}

static int lpf_show_all(void) {
    const char *all = getenv("LEANPROF_ALL");
    return all != NULL && strcmp(all, "1") == 0;
}

static uint64_t lpf_clamp(double v) { return v > 0 ? (uint64_t)(v + 0.5) : 0; }

/* Chrome trace format, for ui.perfetto.dev or chrome://tracing. */
static void lpf_write_trace(const char *path, double tick) {
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
    uint8_t *ckind = calloc(NCACHE, 1);
    char **cname = calloc(NCACHE, sizeof(char *));
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next) {
        dropped += t->events_dropped;
        if (t->nevents == 0) continue;
        fprintf(f, "%s{\"ph\":\"M\",\"name\":\"thread_name\",\"pid\":1,\"tid\":%u,\"args\":{\"name\":\"%s %u\"}}",
                first ? "" : ",", t->id, t->id == 0 ? "startup" : "thread", t->id);
        first = 0;
        for (size_t i = 0; i < t->nevents; i++) {
            lpf_event *e = &t->events[i];
            double us = (double)(e->ts - lpf_start) * tick / 1000.0;
            if (e->ph == 'E') {
                fprintf(f, ",{\"ph\":\"E\",\"pid\":1,\"tid\":%u,\"ts\":%.3f}", t->id, us);
                continue;
            }
            const char *nm = NULL;
            uint8_t ck = (uint8_t)(e->ph == 'C' ? 0x80 | e->kind : e->kind);
            size_t h = lpf_hash(e->key, (const void *)(uintptr_t)ck) & (NCACHE - 1);
            if (ckey != NULL && cname != NULL && ckind != NULL) {
                for (size_t n = 0; n < NCACHE; n++, h = (h + 1) & (NCACHE - 1)) {
                    if (ckey[h] == NULL) break;
                    if (ckey[h] == e->key && ckind[h] == ck && cname[h] != NULL) { nm = cname[h]; break; }
                }
            }
            if (nm == NULL) {
                if (e->ph == 'C') {
                    lpf_symbol_name((void *)e->key, buf, sizeof buf);
                    snprintf(name, sizeof name, "copy %s in %s", lpf_kind_name[e->kind], buf);
                } else if ((e->kind & 15) == LP_TASK) {
                    lpf_task_name(e->key, (uint8_t)(e->kind >> 4), name, sizeof name);
                } else if (e->kind == LP_FN) {
                    lpf_symbol_name((void *)e->key, name, sizeof name);
                } else {
                    lpf_label_name(lean_string_cstr((lean_object *)e->key), name, sizeof name);
                }
                nm = name;
                if (ckey != NULL && cname != NULL && ckind != NULL && ckey[h] == NULL && e->key != NULL) {
                    ckey[h] = e->key;
                    ckind[h] = ck;
                    cname[h] = strdup(name);
                }
            }
            if (e->ph == 'C') {
                fprintf(f, ",{\"ph\":\"i\",\"s\":\"t\",\"cat\":\"copy\",\"pid\":1,\"tid\":%u,\"ts\":%.3f,\"name\":",
                        t->id, us);
                lpf_json_str(f, nm);
                fprintf(f, ",\"args\":{\"bytes\":%llu}}", (unsigned long long)e->bytes);
            } else {
                fprintf(f, ",{\"ph\":\"B\",\"cat\":\"%s\",\"pid\":1,\"tid\":%u,\"ts\":%.3f,\"name\":",
                        e->kind == LP_FN ? "function" : (e->kind & 15) == LP_TASK ? "task" : "scope", t->id, us);
                lpf_json_str(f, nm);
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
    free(ckind);
    if (dropped > 0)
        fprintf(stderr, "leanprof: trace kept the first %zu events per thread; %llu dropped (LEANPROF_TRACE_MAX)\n",
                lpf_trace_max, (unsigned long long)dropped);
}

static void lpf_report(void) {
    if ((lpf_threads == NULL || (lpf_threads->next == NULL && lpf_only_calibrated())) && !lpf_ctr_any())
        return; /* linked but unused */
    __atomic_store_n(&lpf_calibrated, 1, __ATOMIC_RELEASE);
    lpf_calibrate(); /* the CPU is warm now; keeps the lower estimate */
    double tick = lpf_ns_per_tick();
    double wall = (double)(lpf_now() - lpf_start) * tick;
    size_t ns = 0, nc = 0, cap_s = 64, cap_c = 64;
    uint64_t dropped = 0;
    lpf_scope_sum *S = calloc(cap_s, sizeof(lpf_scope_sum));
    lpf_copy_sum *C = calloc(cap_c, sizeof(lpf_copy_sum));
    if (S == NULL || C == NULL) return;

    pthread_mutex_lock(&lpf_lock);
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next) {
        dropped += t->dropped;
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_scope *s = t->scopes[i];
            if (s == NULL || s->calls == 0 || s->kind == LP_INTERNAL) continue;
            char fn[256] = "", fnkey[260];
            const char *label;
            if (s->kind == LP_TASK) {
                lpf_task_name(s->key, s->parent_kind, fn, sizeof fn);
                snprintf(fnkey, sizeof fnkey, "\x02%s", fn);
                label = fnkey;
            } else if (s->kind == LP_FN) {
                /* only Lean declarations: not module initializers, closed-term
                 * initializers or C runtime glue, unless LEANPROF_ALL=1 */
                char raw[256];
                lpf_symbol_raw((void *)s->key, raw, sizeof raw);
                const char *r = raw;
#ifdef __APPLE__
                if (r[0] == '_') r++;
#endif
                int lean_decl = strncmp(r, "l_", 2) == 0 || strncmp(r, "lp_", 3) == 0 ||
                                strcmp(r, "_lean_main") == 0 || strcmp(r, "lean_main") == 0;
                if (!lean_decl && !lpf_show_all()) continue;
                lpf_symbol_name((void *)s->key, fn, sizeof fn);
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
                    S = realloc(S, cap_s * sizeof(lpf_scope_sum));
                    if (S == NULL) return;
                }
                memset(&S[k], 0, sizeof(lpf_scope_sum));
                S[k].is_fn = s->kind == LP_FN;
                S[k].is_task = s->kind == LP_TASK;
                if (S[k].is_task) {
                    S[k].label = strdup(fnkey);
                    snprintf(S[k].name, sizeof S[k].name, "%s", fn);
                } else if (S[k].is_fn) {
                    S[k].label = strdup(fnkey);
                    snprintf(S[k].name, sizeof S[k].name, "%s", fn);
                    lpf_where(fn, S[k].where, sizeof S[k].where);
                } else {
                    S[k].label = label;
                    lpf_label_name(label, S[k].name, sizeof S[k].name);
                    snprintf(S[k].where, sizeof S[k].where, "%s", lpf_label_pos(label));
                }
                if (S[k].label == NULL) return;
                S[k].min = UINT64_MAX;
                ns++;
            }
            /* remove leanprof's own cost (see calibration) */
            double inner = (double)lpf_inner_fp / 1024.0, pair = (double)lpf_pair_fp / 1024.0;
            S[k].calls += s->calls;
            S[k].total += lpf_clamp((double)s->total - (double)s->outer * inner - (double)s->desc_total * pair);
            S[k].self += lpf_clamp((double)s->self - (double)s->calls * inner - (double)s->kids * (pair - inner));
            S[k].sum += lpf_clamp((double)s->sum - (double)s->calls * inner - (double)s->desc_sum * pair);
            S[k].wait += s->wait;
            S[k].allocs_self += s->allocs_self;
            S[k].bytes_self += s->bytes_self;
            S[k].allocs_total += s->allocs_total;
            S[k].bytes_total += s->bytes_total;
            if (s->wait_max > S[k].wait_max) S[k].wait_max = s->wait_max;
            if (s->min < S[k].min) S[k].min = s->min;
            if (s->max > S[k].max) S[k].max = s->max;
            for (size_t b = 0; b < LP_BUCKETS; b++) S[k].hist[b] += s->hist[b];
        }
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_copy *c = t->copies[i];
            if (c == NULL) continue;
            char fn[256];
            lpf_symbol_name(c->pc, fn, sizeof fn);
            const char *label = c->site ? lean_string_cstr((lean_object *)c->site) : NULL;
            size_t k = 0;
            while (k < nc && !(C[k].kind == c->kind && strcmp(C[k].fn, fn) == 0 &&
                               (C[k].label == label || (C[k].label && label && strcmp(C[k].label, label) == 0))))
                k++;
            if (k == nc) {
                if (nc == cap_c) {
                    cap_c *= 2;
                    C = realloc(C, cap_c * sizeof(lpf_copy_sum));
                    if (C == NULL) return;
                }
                memset(&C[k], 0, sizeof(lpf_copy_sum));
                snprintf(C[k].fn, sizeof C[k].fn, "%s", fn);
                lpf_symbol_raw(c->pc, C[k].sym, sizeof C[k].sym);
                lpf_where(fn, C[k].where, sizeof C[k].where);
                C[k].label = label;
                if (label) lpf_label_name(label, C[k].scope, sizeof C[k].scope);
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
    pthread_mutex_unlock(&lpf_lock);

    qsort(S, ns, sizeof(lpf_scope_sum), lpf_by_total);
    qsort(C, nc, sizeof(lpf_copy_sum), lpf_by_cost);

    const char *quiet = getenv("LEANPROF_QUIET");
    if (quiet == NULL || strcmp(quiet, "1") != 0) lpf_print(stderr, S, ns, C, nc, tick, wall, dropped);

    const char *trace = getenv("LEANPROF_TRACE");
    if (trace != NULL && trace[0] != 0) lpf_write_trace(trace, tick);

    const char *path = getenv("LEANPROF_JSON");
    if (path != NULL && path[0] != 0) {
        FILE *f = fopen(path, "w");
        if (f == NULL) {
            fprintf(stderr, "leanprof: cannot write %s\n", path);
        } else {
            lpf_write_json(f, S, ns, C, nc, tick, wall, dropped);
            fclose(f);
        }
    }
    for (size_t k = 0; k < ns; k++)
        if (S[k].is_fn || S[k].is_task) free((void *)S[k].label);
    free(S);
    free(C);
}

__attribute__((constructor)) static void lpf_init(void) {
    const char *trace = getenv("LEANPROF_TRACE");
    lpf_tracing = trace != NULL && trace[0] != 0;
    const char *max = getenv("LEANPROF_TRACE_MAX");
    if (max != NULL) {
        size_t n = 0;
        for (const char *q = max; *q >= '0' && *q <= '9'; q++) n = n * 10 + (size_t)(*q - '0');
        if (n > 2 * LP_DEPTH) lpf_trace_max = n;
    }
    lpf_start = lpf_now();
    atexit(lpf_report);
}
