/* ---------- memory: frees and memory over time ----------
 * Included once from leanprof.c (it uses that file's tables and helpers).
 *
 * Frees (opt-in, LEANPROF_FREES=1 with the wrapper, or `freeFlags`):
 * compiled code calls `lean_dec_ref_cold` when a reference count reaches
 * zero, and for every decrement of a multi-threaded object (negative count).
 * Redirected here, each call is charged to its call site (return address)
 * and the innermost scope: freeing cascades (count, objects freed, a latency
 * histogram) and atomic decrements of multi-threaded objects.
 *
 * Memory over time (always on): mimalloc's `mi_process_info` gives the
 * memory the Lean heap has committed and, with the OS, resident memory. It
 * is sampled at start and exit and at scope exits at most every ~1 ms, into
 * a global series used for "peak while active" per scope and a counter track
 * in the timeline.
 */

#include <sys/resource.h>
#ifdef __linux__
#include <fcntl.h>
#include <unistd.h>
#endif

static void lpf_symbol_name(void *pc, char *out, size_t cap);
static void lpf_symbol_raw(void *pc, char *out, size_t cap);
static const char *lpf_where(const char *fn, char *out, size_t cap);
static void lpf_task_name(const void *parent, uint8_t parent_kind, char *out, size_t cap);
static void lpf_fmt_time(double ns, char *buf, size_t n);
static void lpf_fmt_bytes(double b, char *buf, size_t n);
static void lpf_json_str(FILE *f, const char *s);
static const char *lpf_label_pos(const char *label);

/* ---- memory samples ---- */

typedef struct {
    uint64_t ts, commit, rss;
} lpf_mem_sample;

#define LP_MEM_CHUNK 4096 /* samples per chunk; chunks never move, so readers need no lock */
#define LP_MEM_CHUNKS 4096
#define LP_MEM_BLOCK 64   /* block maxima, for range maxima over long scopes */

typedef struct {
    lpf_mem_sample s[LP_MEM_CHUNK];
    uint64_t bmax[LP_MEM_CHUNK / LP_MEM_BLOCK];
} lpf_mem_chunk;

static lpf_mem_chunk *lpf_mem_chunks[LP_MEM_CHUNKS];
static size_t lpf_mem_n;           /* published samples (release/acquire) */
static uint64_t lpf_mem_next;      /* tick of the next sample due */
static uint64_t lpf_mem_last;      /* tick of the last sample */
static uint64_t lpf_mem_interval;  /* ~1 ms in ticks */
static uint64_t lpf_mem_peak_commit, lpf_mem_peak_rss; /* from mimalloc's own peaks */
static pthread_mutex_t lpf_mem_lock = PTHREAD_MUTEX_INITIALIZER;
#ifdef __linux__
static int lpf_statm = -1;
#endif

static void lpf_mem_read(uint64_t *commit, uint64_t *rss, uint64_t *peak_commit, uint64_t *peak_rss) {
    size_t elapsed = 0, user = 0, sys = 0, cur_rss = 0, pk_rss = 0, cur_commit = 0, pk_commit = 0, faults = 0;
#ifdef LEAN_MIMALLOC
    mi_process_info(&elapsed, &user, &sys, &cur_rss, &pk_rss, &cur_commit, &pk_commit, &faults);
#else
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    pk_rss = (size_t)ru.ru_maxrss * 1024;
#endif
#ifdef __linux__
    /* mimalloc reports its commit as RSS on Linux; read the real one */
    if (lpf_statm >= 0) {
        char buf[128];
        ssize_t n = pread(lpf_statm, buf, sizeof buf - 1, 0);
        if (n > 0) {
            buf[n] = 0;
            const char *p = buf;
            while (*p && *p != ' ') p++;
            uint64_t pages = 0;
            while (*p == ' ') p++;
            while (*p >= '0' && *p <= '9') pages = pages * 10 + (uint64_t)(*p++ - '0');
            cur_rss = (size_t)(pages * (uint64_t)sysconf(_SC_PAGESIZE));
        }
    }
#endif
    *commit = cur_commit;
    *rss = cur_rss;
    *peak_commit = pk_commit;
    *peak_rss = pk_rss;
}

static inline lpf_mem_sample *lpf_mem_at(size_t i) { return &lpf_mem_chunks[i / LP_MEM_CHUNK]->s[i % LP_MEM_CHUNK]; }

/* Take a sample now (at most one thread at a time; others skip). */
static __attribute__((noinline)) void lpf_mem_take(uint64_t now, int force) {
    if (force) pthread_mutex_lock(&lpf_mem_lock);
    else if (pthread_mutex_trylock(&lpf_mem_lock) != 0) return;
    if (!force && now < __atomic_load_n(&lpf_mem_next, __ATOMIC_RELAXED)) {
        pthread_mutex_unlock(&lpf_mem_lock);
        return;
    }
    uint64_t commit, rss, pc, pr;
    lpf_mem_read(&commit, &rss, &pc, &pr);
    if (pc > lpf_mem_peak_commit) lpf_mem_peak_commit = pc;
    if (pr > lpf_mem_peak_rss) lpf_mem_peak_rss = pr;
    size_t n = lpf_mem_n;
    size_t c = n / LP_MEM_CHUNK;
    if (c < LP_MEM_CHUNKS && (lpf_mem_chunks[c] != NULL || (lpf_mem_chunks[c] = calloc(1, sizeof(lpf_mem_chunk))))) {
        lpf_mem_chunk *ch = lpf_mem_chunks[c];
        size_t i = n % LP_MEM_CHUNK;
        /* timestamps stay ordered even if `now` was read before another sample */
        if (n > 0 && now < lpf_mem_at(n - 1)->ts) now = lpf_mem_at(n - 1)->ts;
        ch->s[i] = (lpf_mem_sample){now, commit, rss};
        if (commit > ch->bmax[i / LP_MEM_BLOCK]) ch->bmax[i / LP_MEM_BLOCK] = commit;
        __atomic_store_n(&lpf_mem_n, n + 1, __ATOMIC_RELEASE);
        __atomic_store_n(&lpf_mem_last, now, __ATOMIC_RELEASE);
    }
    /* About every 1 ms for the first minute, then spread over the run so far
     * (1/65536 of it): about 540,000 samples (13 MB) in a day instead of a
     * sample (24 bytes) every millisecond for as long as a server runs. */
    uint64_t every = (now - lpf_start) >> 16;
    __atomic_store_n(&lpf_mem_next, now + (every > lpf_mem_interval ? every : lpf_mem_interval), __ATOMIC_RELAXED);
    pthread_mutex_unlock(&lpf_mem_lock);
}

/* First sample index with ts >= t (n if none). */
static size_t lpf_mem_find(size_t n, uint64_t t) {
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (lpf_mem_at(mid)->ts < t) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

/* Largest commit among samples [a, b). */
static uint64_t lpf_mem_range_max(size_t a, size_t b) {
    uint64_t m = 0;
    while (a < b) {
        if (a % LP_MEM_BLOCK == 0 && a + LP_MEM_BLOCK <= b) {
            uint64_t v = lpf_mem_chunks[a / LP_MEM_CHUNK]->bmax[(a % LP_MEM_CHUNK) / LP_MEM_BLOCK];
            if (v > m) m = v;
            a += LP_MEM_BLOCK;
        } else {
            uint64_t v = lpf_mem_at(a)->commit;
            if (v > m) m = v;
            a++;
        }
    }
    return m;
}

/* ---- per-thread state ---- */

/* Memory while a scope was active, per scope (keyed by its lpf_scope). */
typedef struct {
    const lpf_scope *scope;
    uint64_t calls;     /* calls that contained a sample */
    uint64_t peak;      /* largest commit sampled while active */
    uint64_t rise;      /* largest (peak during a call - commit when it started) */
} lpf_mem_scope;

/* Frees per call site and innermost scope. */
typedef struct {
    void *pc;
    const void *scope;
    uint8_t scope_kind;
    uint64_t cascades, objects, ticks, max, mt_decs;
    uint64_t hist[LP_BUCKETS];
} lpf_free_site;

typedef struct {
    void *pc;
    uint64_t ts, dur, objects;
} lpf_slow_free;

typedef struct lpf_mem_thread {
    lpf_thread *lt;
    lpf_mem_scope *scopes[LP_TABLE];
    lpf_free_site *sites[LP_TABLE];
    size_t nscopes, nsites;    /* keys in each table (new keys stop at LP_TABLE_LIMIT) */
    uint64_t dropped;
    int in_free;
    /* the last site: a run of frees from one call site in one scope (a loop
     * dropping elements) skips the table */
    void *last_pc;
    const void *last_key;
    uint8_t last_kind;
    lpf_free_site *last_site;
    /* scratch for counting a cascade: a stack, and decrements seen per shared object */
    lean_object **stack;
    size_t nstack, capstack;
    lean_object **mkeys;
    uint32_t *mcount;
    size_t *mslots;            /* the slots in use, so clearing touches only those */
    size_t mcap, mused;
    lpf_slow_free *slow;
    size_t nslow, capslow;
    struct lpf_mem_thread *next;
} lpf_mem_thread;

static _Thread_local lpf_mem_thread *lpf_mem_self;
static lpf_mem_thread *lpf_mem_threads;
static int lpf_frees_seen; /* the free hook ran: this build tracks frees */
static uint64_t lpf_free_slow_ticks; /* frees at least this long go to the timeline */

static lpf_mem_thread *lpf_mem_thread_get(void) {
    lpf_mem_thread *m = lpf_mem_self;
    if (LEAN_LIKELY(m != NULL)) return m;
    lpf_thread *lt = lpf_thread_get(); /* an exited thread's tables come with its record */
    m = lt->mem;
    if (m == NULL) {
        m = calloc(1, sizeof(lpf_mem_thread));
        if (m == NULL) abort();
        m->lt = lt;
        pthread_mutex_lock(&lpf_lock);
        m->next = lpf_mem_threads;
        lpf_mem_threads = m;
        pthread_mutex_unlock(&lpf_lock);
        lt->mem = m;
    }
    lpf_mem_self = m;
    return m;
}

/* A memory sample was taken while the call that just ended was active. */
static __attribute__((noinline)) void lpf_mem_in_call(lpf_scope *s, uint64_t start, uint64_t now) {
    if (s->kind == LP_INTERNAL) return;
    size_t n = __atomic_load_n(&lpf_mem_n, __ATOMIC_ACQUIRE);
    size_t a = lpf_mem_find(n, start), b = lpf_mem_find(n, now + 1);
    if (a >= b) return;
    uint64_t peak = lpf_mem_range_max(a, b);
    /* the level just before it started; a sample from longer before than the
     * call lasted also counts what was allocated before it, so no rise then */
    const lpf_mem_sample *before = lpf_mem_at(a > 0 ? a - 1 : 0);
    uint64_t base = before->ts + (now - start) >= start ? before->commit : UINT64_MAX;
    lpf_mem_thread *m = lpf_mem_thread_get();
    size_t i = lpf_hash(s, NULL);
    for (size_t k = 0; k < LP_TABLE; k++, i = (i + 1) & (LP_TABLE - 1)) {
        lpf_mem_scope *ms = m->scopes[i];
        if (ms == NULL) {
            if (m->nscopes >= LP_TABLE_LIMIT) break;
            ms = m->scopes[i] = calloc(1, sizeof(lpf_mem_scope));
            if (ms == NULL) return;
            ms->scope = s;
            m->nscopes++;
        }
        if (ms->scope != s) continue;
        ms->calls++;
        if (peak > ms->peak) ms->peak = peak;
        if (peak > base && peak - base > ms->rise) ms->rise = peak - base;
        return;
    }
    m->dropped++;
}

/* Called from lpf_exit with the closing frame's scope and start tick. */
static inline __attribute__((always_inline)) void lpf_mem_on_exit(lpf_scope *s, uint64_t start, uint64_t now) {
    if (LEAN_UNLIKELY(now >= __atomic_load_n(&lpf_mem_next, __ATOMIC_RELAXED))) lpf_mem_take(now, 0);
    if (LEAN_UNLIKELY(__atomic_load_n(&lpf_mem_last, __ATOMIC_ACQUIRE) >= start)) lpf_mem_in_call(s, start, now);
}

/* ---- frees ---- */

static void lpf_walk_push(lpf_mem_thread *m, lean_object *o) {
    if (m->nstack == m->capstack) {
        size_t cap = m->capstack ? m->capstack * 2 : 1024;
        lean_object **s = realloc(m->stack, cap * sizeof(lean_object *));
        if (s == NULL) return;
        m->stack = s;
        m->capstack = cap;
    }
    m->stack[m->nstack++] = o;
}

/* One more reference to `o` dropped inside the cascade; true when that was
 * its last (all `refs` references came from objects being freed). */
static int lpf_walk_last(lpf_mem_thread *m, lean_object *o, uint32_t refs) {
    if (m->mused * 2 >= m->mcap) {
        size_t cap = m->mcap ? m->mcap * 2 : 1024;
        lean_object **keys = calloc(cap, sizeof(lean_object *));
        uint32_t *count = calloc(cap, sizeof(uint32_t));
        size_t *slots = calloc(cap / 2, sizeof(size_t));
        if (keys == NULL || count == NULL || slots == NULL) { free(keys); free(count); free(slots); return 0; }
        for (size_t k = 0; k < m->mused; k++) {
            size_t i = m->mslots[k];
            size_t h = lpf_hash(m->mkeys[i], NULL) & (cap - 1);
            while (keys[h] != NULL) h = (h + 1) & (cap - 1);
            keys[h] = m->mkeys[i];
            count[h] = m->mcount[i];
            slots[k] = h;
        }
        free(m->mkeys);
        free(m->mcount);
        free(m->mslots);
        m->mkeys = keys;
        m->mcount = count;
        m->mslots = slots;
        m->mcap = cap;
    }
    size_t h = lpf_hash(o, NULL) & (m->mcap - 1);
    while (m->mkeys[h] != NULL && m->mkeys[h] != o) h = (h + 1) & (m->mcap - 1);
    if (m->mkeys[h] == NULL) {
        m->mkeys[h] = o;
        m->mcount[h] = 0;
        m->mslots[m->mused++] = h;
    }
    return ++m->mcount[h] == refs;
}

static inline void lpf_walk_child(lpf_mem_thread *m, lean_object *c) {
    if (c == NULL || lean_is_scalar(c)) return;
    int rc = lean_internal_get_rc(c);
    if (rc == 0) return;                      /* persistent: never freed */
    if (rc == 1 || rc == -1) lpf_walk_push(m, c);
    else if (lpf_walk_last(m, c, (uint32_t)(rc > 0 ? rc : -rc))) lpf_walk_push(m, c);
}

/* How many objects dropping the last reference to `o` frees, following the
 * runtime's own rules: an object dies when every reference to it came from
 * objects that die. Tasks, promises and external objects count as one. */
static uint64_t lpf_cascade_size(lpf_mem_thread *m, lean_object *o) {
    uint8_t tag = lean_ptr_tag(o);
    if (tag >= LeanScalarArray && tag <= LeanMPZ) return 1; /* no children: the common case */
    uint64_t n = 0;
    m->nstack = 0;
    lpf_walk_push(m, o);
    while (m->nstack > 0) {
        lean_object *x = m->stack[--m->nstack];
        n++;
        tag = lean_ptr_tag(x);
        if (tag <= LeanMaxCtorTag) {
            unsigned k = lean_ctor_num_objs(x);
            lean_object **f = lean_ctor_obj_cptr(x);
            for (unsigned i = 0; i < k; i++) lpf_walk_child(m, f[i]);
        } else if (tag == LeanClosure) {
            unsigned k = lean_closure_num_fixed(x);
            lean_object **f = lean_closure_arg_cptr(x);
            for (unsigned i = 0; i < k; i++) lpf_walk_child(m, f[i]);
        } else if (tag == LeanArray) {
            size_t k = lean_array_size(x);
            lean_object **f = lean_array_cptr(x);
            for (size_t i = 0; i < k; i++) lpf_walk_child(m, f[i]);
        } else if (tag == LeanThunk) {
            lpf_walk_child(m, lean_to_thunk(x)->m_value);
            lpf_walk_child(m, lean_to_thunk(x)->m_closure);
        } else if (tag == LeanRef) {
            lpf_walk_child(m, lean_to_ref(x)->m_value);
        }
    }
    /* not a memset of the whole table: most cascades see one or two shared children */
    for (size_t k = 0; k < m->mused; k++) m->mkeys[m->mslots[k]] = NULL;
    m->mused = 0;
    return n;
}

static lpf_free_site *lpf_free_site_get(lpf_mem_thread *m, void *pc) {
    const void *key;
    uint8_t kind;
    lpf_current(m->lt, &key, &kind);
    if (pc == m->last_pc && key == m->last_key && kind == m->last_kind && m->last_site != NULL) return m->last_site;
    m->last_pc = pc;
    m->last_key = key;
    m->last_kind = kind;
    m->last_site = NULL;
    size_t i = lpf_hash(pc, key);
    for (size_t k = 0; k < LP_TABLE; k++, i = (i + 1) & (LP_TABLE - 1)) {
        lpf_free_site *s = m->sites[i];
        if (s != NULL && s->pc == pc && s->scope == key && s->scope_kind == kind) return m->last_site = s;
        if (s == NULL) {
            if (m->nsites >= LP_TABLE_LIMIT) break;
            s = calloc(1, sizeof(lpf_free_site));
            if (s == NULL) return NULL;
            m->nsites++;
            s->pc = pc;
            s->scope = key;
            s->scope_kind = kind;
            LP_PUBLISH(m->sites[i], s); /* leanprof_frees reads it from another thread */
            return m->last_site = s;
        }
    }
    m->dropped++;
    return NULL;
}

LEAN_EXPORT void leanprof_dec_ref_cold(lean_object *o) {
    void *pc = LP_PC;
    int rc = lean_internal_get_rc(o);
    lpf_mem_thread *m = lpf_mem_thread_get();
    if (LEAN_UNLIKELY(m->in_free)) { /* a finalizer running compiled code: part of the outer cascade */
        lean_dec_ref_cold(o);
        return;
    }
    if (LEAN_UNLIKELY(!LP_LD(lpf_frees_seen))) LP_ST(lpf_frees_seen, 1); /* not a store per free: one cache line for all threads */
    if (rc < -1) { /* an atomic decrement that does not free */
        lean_dec_ref_cold(o);
        lpf_free_site *s = lpf_free_site_get(m, pc);
        if (s != NULL) s->mt_decs++;
        return;
    }
    m->in_free = 1;
    uint64_t objects = lpf_cascade_size(m, o);
    uint64_t start = lpf_now();
    lean_dec_ref_cold(o);
    uint64_t now = lpf_now();
    m->in_free = 0;
    uint64_t d = now - start;
    lpf_free_site *s = lpf_free_site_get(m, pc);
    if (s != NULL) {
        s->mt_decs += rc < 0;
        s->cascades++;
        LP_ADD(s->objects, objects);
        s->ticks += d;
        if (d > s->max) s->max = d;
        s->hist[lpf_bucket(d)]++;
    }
    if (LEAN_UNLIKELY(d >= lpf_free_slow_ticks) && lpf_tracing && m->nslow < 65536) {
        if (m->nslow == m->capslow) {
            size_t cap = m->capslow ? m->capslow * 2 : 64;
            lpf_slow_free *v = realloc(m->slow, cap * sizeof(lpf_slow_free));
            if (v == NULL) return;
            m->slow = v;
            m->capslow = cap;
        }
        m->slow[m->nslow++] = (lpf_slow_free){pc, start, d, objects};
    }
    if (LEAN_UNLIKELY(now >= __atomic_load_n(&lpf_mem_next, __ATOMIC_RELAXED))) lpf_mem_take(now, 0);
}

/* ---- start, exit, queries ---- */

static void lpf_cpu_times(double *user_ns, double *sys_ns) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    *user_ns = (double)ru.ru_utime.tv_sec * 1e9 + (double)ru.ru_utime.tv_usec * 1e3;
    *sys_ns = (double)ru.ru_stime.tv_sec * 1e9 + (double)ru.ru_stime.tv_usec * 1e3;
}

/* The program's end, before leanprof's own report work. */
static uint64_t lpf_mem_end;
static double lpf_mem_user_ns, lpf_mem_sys_ns;

static double lpf_mem_user0, lpf_mem_sys0; /* CPU time before the program started */

static void lpf_mem_init(void) {
    lpf_cpu_times(&lpf_mem_user0, &lpf_mem_sys0);
#ifdef __linux__
    lpf_statm = open("/proc/self/statm", O_RDONLY);
#endif
    double tick = lpf_ns_per_tick_rough();
    lpf_mem_interval = (uint64_t)(1e6 / tick);
    lpf_free_slow_ticks = (uint64_t)(1e5 / tick); /* 100 µs */
    lpf_mem_take(lpf_start, 1);
}

static void lpf_mem_finish(void) {
    lpf_mem_end = lpf_now();
    lpf_cpu_times(&lpf_mem_user_ns, &lpf_mem_sys_ns);
    lpf_mem_user_ns -= lpf_mem_user0; /* the same span as the wall time */
    lpf_mem_sys_ns -= lpf_mem_sys0;
    lpf_mem_take(lpf_mem_end, 1);
}

/* Worth a report even when nothing else was recorded. */
static int lpf_mem_wanted(void) {
    const char *st = getenv("LEANPROF_STAT");
    return lpf_frees_seen || (st != NULL && strcmp(st, "1") == 0);
}

LEAN_EXPORT lean_obj_res leanprof_frees(void) {
    uint64_t n = 0;
    pthread_mutex_lock(&lpf_lock);
    for (lpf_mem_thread *m = lpf_mem_threads; m != NULL; m = m->next)
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_free_site *s = LP_GET(m->sites[i]);
            if (s != NULL) n += LP_LD(s->objects);
        }
    pthread_mutex_unlock(&lpf_lock);
    return lean_uint64_to_nat(n);
}

LEAN_EXPORT lean_obj_res leanprof_peak_memory(void) {
    lpf_mem_take(lpf_now(), 1);
    pthread_mutex_lock(&lpf_mem_lock); /* another thread's sample may raise it meanwhile */
    uint64_t peak = lpf_mem_peak_commit;
    pthread_mutex_unlock(&lpf_mem_lock);
    return lean_uint64_to_nat(peak);
}

/* ---- report ---- */

typedef struct {
    char name[300], where[512];
    uint64_t cascades, objects, ticks, max, mt_decs;
    uint64_t hist[LP_BUCKETS];
} lpf_free_sum;

typedef struct {
    char name[300], where[512];
    uint64_t calls, peak, rise;
} lpf_mem_scope_sum;

static void lpf_scope_display(const void *key, uint8_t kind, char *name, size_t cap, char *where, size_t wcap) {
    where[0] = 0;
    if (key == NULL) snprintf(name, cap, "-");
    else if (kind == LP_FN) {
        lpf_symbol_name((void *)key, name, cap);
        lpf_where(name, where, wcap);
    } else {
        lpf_label_name(lean_string_cstr((lean_object *)key), name, cap);
        snprintf(where, wcap, "%s", lpf_label_pos(lean_string_cstr((lean_object *)key)));
    }
}

/* Merged free sites (by_scope: merged per scope instead), costliest first. */
static lpf_free_sum *lpf_free_merge(int by_scope, size_t *out_n) {
    size_t n = 0, cap = 64;
    lpf_free_sum *F = calloc(cap, sizeof(lpf_free_sum));
    if (F == NULL) return NULL;
    pthread_mutex_lock(&lpf_lock);
    for (lpf_mem_thread *m = lpf_mem_threads; m != NULL; m = m->next)
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_free_site *s = m->sites[i];
            if (s == NULL) continue;
            char name[300], sname[300], where[512], swhere[512];
            lpf_scope_display(s->scope, s->scope_kind, sname, sizeof sname, swhere, sizeof swhere);
            if (by_scope) {
                snprintf(name, sizeof name, "%s", sname);
                snprintf(where, sizeof where, "%s", swhere);
            } else {
                char fn[256];
                lpf_symbol_name(s->pc, fn, sizeof fn);
                snprintf(name, sizeof name, "%s\x1f%s", fn, sname); /* site and scope */
                lpf_where(fn, where, sizeof where);
            }
            size_t k = 0;
            while (k < n && strcmp(F[k].name, name) != 0) k++;
            if (k == n) {
                if (n == cap) {
                    lpf_free_sum *G = realloc(F, 2 * cap * sizeof(lpf_free_sum));
                    if (G == NULL) break;
                    F = G;
                    cap *= 2;
                }
                memset(&F[k], 0, sizeof(lpf_free_sum));
                snprintf(F[k].name, sizeof F[k].name, "%s", name);
                snprintf(F[k].where, sizeof F[k].where, "%s", where);
                n++;
            }
            F[k].cascades += s->cascades;
            F[k].objects += s->objects;
            F[k].ticks += s->ticks;
            F[k].mt_decs += s->mt_decs;
            if (s->max > F[k].max) F[k].max = s->max;
            for (size_t b = 0; b < LP_BUCKETS; b++) F[k].hist[b] += s->hist[b];
        }
    pthread_mutex_unlock(&lpf_lock);
    /* by time, then atomic decrements */
    for (size_t a = 0; a < n; a++)
        for (size_t b = a + 1; b < n; b++)
            if (F[b].ticks > F[a].ticks || (F[b].ticks == F[a].ticks && F[b].mt_decs > F[a].mt_decs)) {
                lpf_free_sum t = F[a];
                F[a] = F[b];
                F[b] = t;
            }
    *out_n = n;
    return F;
}

static lpf_mem_scope_sum *lpf_mem_scope_merge(size_t *out_n) {
    size_t n = 0, cap = 64;
    lpf_mem_scope_sum *M = calloc(cap, sizeof(lpf_mem_scope_sum));
    if (M == NULL) return NULL;
    pthread_mutex_lock(&lpf_lock);
    for (lpf_mem_thread *m = lpf_mem_threads; m != NULL; m = m->next)
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_mem_scope *ms = m->scopes[i];
            if (ms == NULL) continue;
            const lpf_scope *s = ms->scope;
            char name[300], where[512];
            if (s->kind == LP_TASK) {
                lpf_task_name(s->key, s->parent_kind, name, sizeof name);
                where[0] = 0;
            } else {
                if (s->kind == LP_FN) { /* Lean declarations only, as in the scope table */
                    char raw[256];
                    lpf_symbol_raw((void *)s->key, raw, sizeof raw);
                    const char *r = raw[0] == '_' && strncmp(raw, "_lean_main", 10) != 0 ? raw + 1 : raw;
                    if (strncmp(r, "l_", 2) != 0 && strncmp(r, "lp_", 3) != 0 && strstr(r, "lean_main") == NULL)
                        continue;
                }
                lpf_scope_display(s->key, s->kind, name, sizeof name, where, sizeof where);
            }
            size_t k = 0;
            while (k < n && strcmp(M[k].name, name) != 0) k++;
            if (k == n) {
                if (n == cap) {
                    lpf_mem_scope_sum *G = realloc(M, 2 * cap * sizeof(lpf_mem_scope_sum));
                    if (G == NULL) break;
                    M = G;
                    cap *= 2;
                }
                memset(&M[k], 0, sizeof(lpf_mem_scope_sum));
                snprintf(M[k].name, sizeof M[k].name, "%s", name);
                snprintf(M[k].where, sizeof M[k].where, "%s", where);
                n++;
            }
            M[k].calls += ms->calls;
            if (ms->peak > M[k].peak) M[k].peak = ms->peak;
            if (ms->rise > M[k].rise) M[k].rise = ms->rise;
        }
    pthread_mutex_unlock(&lpf_lock);
    for (size_t a = 0; a < n; a++)
        for (size_t b = a + 1; b < n; b++)
            if (M[b].rise > M[a].rise || (M[b].rise == M[a].rise && M[b].peak > M[a].peak)) {
                lpf_mem_scope_sum t = M[a];
                M[a] = M[b];
                M[b] = t;
            }
    *out_n = n;
    return M;
}

static void lpf_free_totals(const lpf_free_sum *F, size_t n, lpf_free_sum *all) {
    memset(all, 0, sizeof *all);
    for (size_t k = 0; k < n; k++) {
        all->cascades += F[k].cascades;
        all->objects += F[k].objects;
        all->ticks += F[k].ticks;
        all->mt_decs += F[k].mt_decs;
        if (F[k].max > all->max) all->max = F[k].max;
        for (size_t b = 0; b < LP_BUCKETS; b++) all->hist[b] += F[k].hist[b];
    }
}

static void lpf_mem_print(FILE *f, double tick) {
    size_t nsamples = __atomic_load_n(&lpf_mem_n, __ATOMIC_ACQUIRE);
    char pc[32], pr[32], ec[32];
    lpf_fmt_bytes((double)lpf_mem_peak_commit, pc, sizeof pc);
    lpf_fmt_bytes((double)lpf_mem_peak_rss, pr, sizeof pr);
    lpf_fmt_bytes(nsamples > 0 ? (double)lpf_mem_at(nsamples - 1)->commit : 0, ec, sizeof ec);
    fprintf(f, "\nmemory: peak %s resident, peak %s committed by Lean's allocator (%s at exit), %zu samples\n", pr,
            pc, ec, nsamples);
    size_t nm = 0;
    lpf_mem_scope_sum *M = lpf_mem_scope_merge(&nm);
    size_t shown = 0;
    for (size_t k = 0; M != NULL && k < nm; k++) shown += M[k].rise > 0;
    if (shown > 0) {
        fprintf(f, "memory while scopes were active (committed; sampled about every 1 ms at scope exits)\n");
        fprintf(f, "%11s %11s %8s  %s\n", "peak", "max rise", "sampled", "scope  (where)");
        for (size_t k = 0, row = 0; k < nm && row < 10; k++) {
            if (M[k].rise == 0) continue;
            char p[32], r[32];
            lpf_fmt_bytes((double)M[k].peak, p, sizeof p);
            lpf_fmt_bytes((double)M[k].rise, r, sizeof r);
            fprintf(f, "%11s %11s %8llu  %s", p, r, (unsigned long long)M[k].calls, M[k].name);
            if (M[k].where[0]) fprintf(f, "  (%s)", M[k].where);
            fputc('\n', f);
            row++;
        }
    }
    free(M);
    if (!lpf_frees_seen) return;
    size_t nf = 0;
    lpf_free_sum *F = lpf_free_merge(0, &nf);
    if (F == NULL) return;
    lpf_free_sum all;
    lpf_free_totals(F, nf, &all);
    char tt[32], p50[32], p99[32], mx[32];
    lpf_fmt_time((double)all.ticks * tick, tt, sizeof tt);
    lpf_fmt_time((double)lpf_percentile(all.hist, all.cascades, 0.50) * tick, p50, sizeof p50);
    lpf_fmt_time((double)lpf_percentile(all.hist, all.cascades, 0.99) * tick, p99, sizeof p99);
    lpf_fmt_time((double)all.max * tick, mx, sizeof mx);
    fprintf(f,
            "\nfrees: %llu objects in %llu cascades took %s (pause p50 %s, p99 %s, max %s); "
            "%llu atomic decrements of multi-threaded objects\n",
            (unsigned long long)all.objects, (unsigned long long)all.cascades, tt, p50, p99, mx,
            (unsigned long long)all.mt_decs);
    fprintf(f, "%10s %10s %10s %9s %9s %9s %10s  %-18s %s\n", "cascades", "objects", "time", "p50", "p99", "max",
            "mt decs", "in scope", "function  (where)");
    for (size_t k = 0; k < nf && k < 20; k++) {
        lpf_fmt_time((double)F[k].ticks * tick, tt, sizeof tt);
        lpf_fmt_time((double)lpf_percentile(F[k].hist, F[k].cascades, 0.50) * tick, p50, sizeof p50);
        lpf_fmt_time((double)lpf_percentile(F[k].hist, F[k].cascades, 0.99) * tick, p99, sizeof p99);
        lpf_fmt_time((double)F[k].max * tick, mx, sizeof mx);
        char *sep = strchr(F[k].name, '\x1f');
        const char *scope = sep ? sep + 1 : "-";
        if (sep) *sep = 0;
        fprintf(f, "%10llu %10llu %10s %9s %9s %9s %10llu  %-18s %s", (unsigned long long)F[k].cascades,
                (unsigned long long)F[k].objects, tt, F[k].cascades ? p50 : "-", F[k].cascades ? p99 : "-",
                F[k].cascades ? mx : "-", (unsigned long long)F[k].mt_decs, scope, F[k].name);
        if (sep) *sep = '\x1f';
        if (F[k].where[0]) fprintf(f, "  (%s)", F[k].where);
        fputc('\n', f);
    }
    if (nf > 20) fprintf(f, "(%zu more sites in the JSON report)\n", nf - 20);
    free(F);
}

static void lpf_free_json(FILE *f, const lpf_free_sum *F, size_t n, double tick, int sites) {
    for (size_t k = 0; k < n; k++) {
        char name[300];
        snprintf(name, sizeof name, "%s", F[k].name);
        char *sep = strchr(name, '\x1f');
        if (sep) *sep = 0;
        fprintf(f, "%s{", k ? "," : "");
        if (sites) {
            fprintf(f, "\"function\":");
            lpf_json_str(f, name);
            fprintf(f, ",\"scope\":");
            lpf_json_str(f, sep ? sep + 1 : "-");
            fprintf(f, ",\"where\":");
        } else {
            fprintf(f, "\"scope\":");
            lpf_json_str(f, name);
            fprintf(f, ",\"pos\":");
        }
        lpf_json_str(f, F[k].where);
        fprintf(f, ",\"cascades\":%llu,\"objects\":%llu,\"free_ns\":%.0f,\"p50_ns\":%.0f,\"p99_ns\":%.0f,"
                   "\"max_ns\":%.0f,\"mt_decrements\":%llu}",
                (unsigned long long)F[k].cascades, (unsigned long long)F[k].objects, (double)F[k].ticks * tick,
                (double)lpf_percentile(F[k].hist, F[k].cascades, 0.50) * tick,
                (double)lpf_percentile(F[k].hist, F[k].cascades, 0.99) * tick, (double)F[k].max * tick,
                (unsigned long long)F[k].mt_decs);
    }
}

/* `,"memory":{...},"frees":{...}` inside the report object. */
static void lpf_mem_json(FILE *f, double tick) {
    size_t nsamples = __atomic_load_n(&lpf_mem_n, __ATOMIC_ACQUIRE);
    fprintf(f, ",\"memory\":{\"peak_rss\":%llu,\"peak_commit\":%llu,\"start_commit\":%llu,\"end_commit\":%llu,"
               "\"wall_ns\":%.0f,\"user_ns\":%.0f,\"sys_ns\":%.0f,\"samples\":%zu,\"scopes\":[",
            (unsigned long long)lpf_mem_peak_rss, (unsigned long long)lpf_mem_peak_commit,
            (unsigned long long)(nsamples > 0 ? lpf_mem_at(0)->commit : 0),
            (unsigned long long)(nsamples > 0 ? lpf_mem_at(nsamples - 1)->commit : 0),
            lpf_mem_end > lpf_start ? (double)(lpf_mem_end - lpf_start) * tick : 0, lpf_mem_user_ns, lpf_mem_sys_ns,
            nsamples);
    size_t nm = 0;
    lpf_mem_scope_sum *M = lpf_mem_scope_merge(&nm);
    for (size_t k = 0; M != NULL && k < nm; k++) {
        fprintf(f, "%s{\"name\":", k ? "," : "");
        lpf_json_str(f, M[k].name);
        fprintf(f, ",\"pos\":");
        lpf_json_str(f, M[k].where);
        fprintf(f, ",\"sampled_calls\":%llu,\"peak_commit\":%llu,\"max_rise\":%llu}", (unsigned long long)M[k].calls,
                (unsigned long long)M[k].peak, (unsigned long long)M[k].rise);
    }
    free(M);
    fprintf(f, "]}");
    if (!lpf_frees_seen) return;
    size_t nf = 0, nsc = 0;
    lpf_free_sum *F = lpf_free_merge(0, &nf);
    lpf_free_sum *FS = lpf_free_merge(1, &nsc);
    if (F == NULL || FS == NULL) { free(F); free(FS); return; }
    lpf_free_sum all;
    lpf_free_totals(F, nf, &all);
    fprintf(f, ",\"frees\":{\"cascades\":%llu,\"objects\":%llu,\"free_ns\":%.0f,\"p50_ns\":%.0f,\"p99_ns\":%.0f,"
               "\"max_ns\":%.0f,\"mt_decrements\":%llu,\"sites\":[",
            (unsigned long long)all.cascades, (unsigned long long)all.objects, (double)all.ticks * tick,
            (double)lpf_percentile(all.hist, all.cascades, 0.50) * tick,
            (double)lpf_percentile(all.hist, all.cascades, 0.99) * tick, (double)all.max * tick,
            (unsigned long long)all.mt_decs);
    lpf_free_json(f, F, nf, tick, 1);
    fprintf(f, "],\"scopes\":[");
    lpf_free_json(f, FS, nsc, tick, 0);
    fprintf(f, "]}");
    free(F);
    free(FS);
}

/* Timeline: a memory counter track and slices for frees over 100 µs. */
static void lpf_mem_trace(FILE *f, double tick, int *first) {
    size_t nsamples = __atomic_load_n(&lpf_mem_n, __ATOMIC_ACQUIRE);
    for (size_t i = 0; i < nsamples; i++) {
        lpf_mem_sample *s = lpf_mem_at(i);
        double us = s->ts > lpf_start ? (double)(s->ts - lpf_start) * tick / 1000.0 : 0;
        fprintf(f, "%s{\"ph\":\"C\",\"name\":\"memory (MiB)\",\"pid\":1,\"ts\":%.3f,\"args\":{\"committed\":%.3f,"
                   "\"resident\":%.3f}}",
                *first ? "" : ",", us, (double)s->commit / 1048576.0, (double)s->rss / 1048576.0);
        *first = 0;
    }
    for (lpf_mem_thread *m = lpf_mem_threads; m != NULL; m = m->next)
        for (size_t i = 0; i < m->nslow; i++) {
            lpf_slow_free *e = &m->slow[i];
            char fn[256], name[320];
            lpf_symbol_name(e->pc, fn, sizeof fn);
            snprintf(name, sizeof name, "free %llu objects in %s", (unsigned long long)e->objects, fn);
            fprintf(f, "%s{\"ph\":\"X\",\"cat\":\"free\",\"pid\":1,\"tid\":%u,\"ts\":%.3f,\"dur\":%.3f,\"name\":",
                    *first ? "" : ",", m->lt->id, (double)(e->ts - lpf_start) * tick / 1000.0,
                    (double)e->dur * tick / 1000.0);
            lpf_json_str(f, name);
            fprintf(f, ",\"args\":{\"objects\":%llu}}", (unsigned long long)e->objects);
            *first = 0;
        }
}
