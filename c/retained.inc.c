/* ---------- retained memory: live objects by allocation site ----------
 * Included once from leanprof.c, before the allocation shims.
 *
 * Opt-in: LEANPROF_RETAINED=1 when the program runs, in a program built with
 * the allocation, free and retained shims (`leanprof run --retained` does
 * both; `retainedFlags` in the lakefile). Every object compiled code
 * allocates is entered, by address, in a table with its allocation site and
 * size. It leaves the table when leanprof sees it freed:
 *   - in a freeing cascade started by compiled code (lean_dec_ref_cold, which
 *     memory.inc.c walks the way the runtime will free it);
 *   - by lean_free_object from compiled code (a constructor taken apart);
 *   - when the runtime grows an exclusive array or string into a new object
 *     (the object moves: the new one keeps the site that made the old one);
 *   - when the runtime consumes a list (Array.mk, String.mk) or an array
 *     (Array.toList), or drops an IO.Ref's old value on `set`.
 * Objects the runtime makes for some calls (Array.replicate, Array.mk,
 * Array.toList, String.mk, IO.mkRef, the arrays and strings above) are
 * entered at the call site.
 *
 * Frees inside Lean's precompiled libraries and runtime are not seen (with
 * `--core` the libraries' are). Such an entry stays until its address is
 * allocated again through the shims, or until a heap walk reads its header
 * and finds a freed block; both are counted as unseen frees, per site.
 *
 * Live bytes per site are kept as counters, with each site's value at the
 * whole program's peak (an epoch per peak: a site's first change after a new
 * peak saves the value it had at that peak). Exact for single-threaded
 * programs.
 *
 * What keeps objects alive: a heap walk (lpf_ret_walk) reads every tracked
 * object, follows constructor fields, array elements, closure arguments,
 * thunks, refs and task results, gives every object one holder (the first
 * found) and names the root of each chain: a global variable (the program's
 * writable data, scanned for pointers), a local on the stack of the thread
 * that walks (scanned conservatively, at peak and snapshot walks only), a
 * module constant (persistent), or nothing leanprof can see (another
 * thread's stack, the runtime, an object made in precompiled code). Walks
 * run at exit, at `Leanprof.retainedSnapshot`, and when tracked live bytes
 * first pass 256 KiB and then each 25% above the last walk (single-threaded
 * programs only: another thread could free what is being read;
 * LEANPROF_RETAINED_WALKS=0 turns these off).
 *
 * Growth: every site's live bytes are sampled over the run (64 points, the
 * interval doubling when they fill), for sites whose live bytes keep rising.
 */

#include <setjmp.h>
#include <signal.h>
#include <sched.h>
#include <unwind.h>

static void lpf_symbol_name(void *pc, char *out, size_t cap);
static const char *lpf_where(const char *fn, char *out, size_t cap);
static void lpf_demangle(const char *s, char *out, size_t cap);
static void lpf_label_name(const char *label, char *out, size_t cap);
static const char *lpf_label_pos(const char *label);
static void lpf_fmt_bytes(double b, char *buf, size_t n);
static void lpf_fmt_time(double ns, char *buf, size_t n);
static void lpf_json_str(FILE *f, const char *s);
static const char *lpf_sym_name(const void *pc);

static int lpf_frees_seen;      /* memory.inc.c: the free hook ran */
static int lpf_ret_on;          /* LEANPROF_RETAINED=1: 1 while tracking, 2 once the exit walk ran (report only) */
#define LP_RET_TRACKING() (LP_LD(lpf_ret_on) == 1)
static int lpf_ret_auto = 1;    /* walks near the peak: 1 within a time budget, 2 all (LEANPROF_RETAINED_WALKS=all), 0 none */

/* ---- sites ---- */

#define LP_RET_SER 64           /* growth samples per site */

typedef struct lpf_ret_site {
    void *pc;                   /* the allocating call in compiled code */
    const void *label;          /* innermost `profile!` label then, or NULL */
    int64_t live_n, live_b;     /* tracked objects alive now */
    int64_t peak_n, peak_b;     /* at the last whole-program peak, once changed since (lpf_ret_upd) */
    uint64_t epoch;
    int64_t max_b;              /* largest live_b */
    uint64_t made_n, made_b;    /* objects entered */
    uint64_t unseen_n, unseen_b;/* entries found freed without leanprof seeing the free */
    int64_t ser[LP_RET_SER];    /* live_b over the run (lpf_ret_sample) */
    struct lpf_ret_site *hnext;
    uint32_t id;
    uint32_t canon;             /* walks: 1 + the first site of the same function and scope (lpf_ret_canon) */
} lpf_ret_site;

#define LP_RET_CHUNK 1024
#define LP_RET_CHUNKS 4096      /* up to 4M sites */
#define LP_RET_BUCKETS 8192
static lpf_ret_site **lpf_ret_chunks[LP_RET_CHUNKS];
static lpf_ret_site *lpf_ret_buckets[LP_RET_BUCKETS];
static uint32_t lpf_ret_nsites;
static pthread_mutex_t lpf_ret_lock = PTHREAD_MUTEX_INITIALIZER;

static inline lpf_ret_site *lpf_ret_site_at(uint32_t id) {
    lpf_ret_site **c = LP_GET(lpf_ret_chunks[id / LP_RET_CHUNK]);
    return c != NULL ? LP_GET(c[id % LP_RET_CHUNK]) : NULL;
}

static lpf_ret_site *lpf_ret_site_get(void *pc, const void *label) {
    size_t h = lpf_hash(pc, label) & (LP_RET_BUCKETS - 1);
    pthread_mutex_lock(&lpf_ret_lock);
    lpf_ret_site *s = lpf_ret_buckets[h];
    while (s != NULL && !(s->pc == pc && s->label == label)) s = s->hnext;
    if (s == NULL && lpf_ret_nsites < (uint32_t)LP_RET_CHUNK * LP_RET_CHUNKS) {
        uint32_t id = lpf_ret_nsites;
        lpf_ret_site **c = lpf_ret_chunks[id / LP_RET_CHUNK];
        if (c == NULL) {
            c = calloc(LP_RET_CHUNK, sizeof(lpf_ret_site *));
            if (c != NULL) LP_PUBLISH(lpf_ret_chunks[id / LP_RET_CHUNK], c);
        }
        if (c != NULL && (s = calloc(1, sizeof(lpf_ret_site))) != NULL) {
            s->pc = pc;
            s->label = label;
            s->id = id;
            s->hnext = lpf_ret_buckets[h];
            lpf_ret_buckets[h] = s;
            LP_PUBLISH(c[id % LP_RET_CHUNK], s);
            __atomic_store_n(&lpf_ret_nsites, id + 1, __ATOMIC_RELEASE);
        }
    }
    pthread_mutex_unlock(&lpf_ret_lock);
    return s;
}

/* ---- whole-program counters ---- */

static int64_t lpf_ret_live_n, lpf_ret_live_b, lpf_ret_peak_n, lpf_ret_peak_b;
static uint64_t lpf_ret_peak_t, lpf_ret_epoch;
static uint64_t lpf_ret_dropped;          /* objects not entered: the table could not grow */
static uint64_t lpf_ret_unseen_n, lpf_ret_unseen_b, lpf_ret_seen_frees;
static unsigned lpf_ret_threads;          /* threads that allocated or freed tracked objects */
static _Thread_local uint8_t lpf_ret_here;
/* The thread using tracked objects now (its lpf_ret_here), and whether two
 * threads ever did at once: a thread came back after another took over, or a
 * task was spawned. Lean 4.35 runs `main` on a second thread after the module
 * initializers ran on the first: a hand-over, not sharing. */
static void *lpf_ret_owner;
static int lpf_ret_shared;
static _Thread_local uint32_t lpf_ret_count;

/* A site's live objects change by (dn, db). The first change after a new
 * whole-program peak saves the value the site had at that peak. */
static inline void lpf_ret_upd(lpf_ret_site *s, int64_t dn, int64_t db) {
    uint64_t e = LP_LD(lpf_ret_epoch);
    if (LP_LD(s->epoch) != e) {
        LP_ST(s->peak_n, LP_LD(s->live_n));
        LP_ST(s->peak_b, LP_LD(s->live_b));
        LP_ST(s->epoch, e);
    }
    int64_t b = __atomic_add_fetch(&s->live_b, db, __ATOMIC_RELAXED);
    __atomic_add_fetch(&s->live_n, dn, __ATOMIC_RELAXED);
    if (b > LP_LD(s->max_b)) LP_ST(s->max_b, b);
    int64_t g = __atomic_add_fetch(&lpf_ret_live_b, db, __ATOMIC_RELAXED);
    int64_t gn = __atomic_add_fetch(&lpf_ret_live_n, dn, __ATOMIC_RELAXED);
    if (db > 0 && g > LP_LD(lpf_ret_peak_b)) {
        LP_ST(lpf_ret_peak_b, g);
        LP_ST(lpf_ret_peak_n, gn);
        LP_ST(lpf_ret_peak_t, lpf_now());
        __atomic_add_fetch(&lpf_ret_epoch, 1, __ATOMIC_RELAXED);
    }
}

/* A site's value at the peak: saved, or (no change since) its value now. */
static int64_t lpf_ret_at_peak(const lpf_ret_site *s, int bytes) {
    if (LP_LD(s->epoch) != LP_LD(lpf_ret_epoch)) return bytes ? LP_LD(s->live_b) : LP_LD(s->live_n);
    return bytes ? LP_LD(s->peak_b) : LP_LD(s->peak_n);
}

/* ---- the table: object address -> site and size ---- */

typedef struct {
    uintptr_t key;
    uint32_t site;
    uint32_t size;              /* bytes; LP_RET_SMALL: m_cs_sz holds the size (small-object path) */
} lpf_ret_ent;

#define LP_RET_SMALL 0x80000000u
#define LP_RET_SIZE(x) ((x) & ~LP_RET_SMALL)

#define LP_RET_SHARDS 64
typedef struct {
    int lock;
    size_t cap, n;
    lpf_ret_ent *e;
} __attribute__((aligned(64))) lpf_ret_shard;
static lpf_ret_shard lpf_ret_shards[LP_RET_SHARDS];

/* A hash of the whole address. (Keeping each 64 KiB of addresses in one
 * block of consecutive slots shares cache lines, but dense blocks made linear
 * probing chains thousands of slots long: a run took 20 times longer.) */
static inline uint64_t lpf_ret_mix(uintptr_t a) { return (uint64_t)(a >> 3) * 0x9e3779b97f4a7c15ull; }
static inline lpf_ret_shard *lpf_ret_shard_of(uintptr_t a) { return &lpf_ret_shards[lpf_ret_mix(a) >> 58]; }
static inline size_t lpf_ret_home(uintptr_t a, size_t mask) { return (size_t)(lpf_ret_mix(a) >> 16) & mask; }

static inline void lpf_ret_lock_shard(lpf_ret_shard *s) {
    while (__atomic_exchange_n(&s->lock, 1, __ATOMIC_ACQUIRE))
        while (__atomic_load_n(&s->lock, __ATOMIC_RELAXED)) sched_yield();
}
static inline void lpf_ret_unlock_shard(lpf_ret_shard *s) { __atomic_store_n(&s->lock, 0, __ATOMIC_RELEASE); }

static int lpf_ret_grow(lpf_ret_shard *s) {
    size_t cap = s->cap ? s->cap * 2 : 4096;
    lpf_ret_ent *e = calloc(cap, sizeof(lpf_ret_ent));
    if (e == NULL) return 0;
    for (size_t i = 0; i < s->cap; i++) {
        if (s->e[i].key == 0) continue;
        size_t j = lpf_ret_home(s->e[i].key, cap - 1);
        while (e[j].key != 0) j = (j + 1) & (cap - 1);
        e[j] = s->e[i];
    }
    free(s->e);
    s->e = e;
    s->cap = cap;
    return 1;
}

/* Enter `key`: 0 new, 1 replaced an entry (returned in *old), -1 not entered. */
static int lpf_ret_put(uintptr_t key, uint32_t site, uint32_t size, lpf_ret_ent *old) {
    lpf_ret_shard *s = lpf_ret_shard_of(key);
    lpf_ret_lock_shard(s);
    if ((s->n + 1) * 10 > s->cap * 7 && !lpf_ret_grow(s)) {
        lpf_ret_unlock_shard(s);
        return -1;
    }
    size_t m = s->cap - 1;
    for (size_t i = lpf_ret_home(key, m);; i = (i + 1) & m) {
        if (s->e[i].key == 0) {
            s->e[i] = (lpf_ret_ent){key, site, size};
            s->n++;
            lpf_ret_unlock_shard(s);
            return 0;
        }
        if (s->e[i].key == key) {
            *old = s->e[i];
            s->e[i] = (lpf_ret_ent){key, site, size};
            lpf_ret_unlock_shard(s);
            return 1;
        }
    }
}

/* Remove `key`, returning its entry. Linear probing with backward-shift
 * deletion: no tombstones. */
static int lpf_ret_take(uintptr_t key, lpf_ret_ent *out) {
    lpf_ret_shard *s = lpf_ret_shard_of(key);
    lpf_ret_lock_shard(s);
    if (s->cap == 0) {
        lpf_ret_unlock_shard(s);
        return 0;
    }
    size_t m = s->cap - 1, i = lpf_ret_home(key, m);
    while (s->e[i].key != key) {
        if (s->e[i].key == 0) {
            lpf_ret_unlock_shard(s);
            return 0;
        }
        i = (i + 1) & m;
    }
    *out = s->e[i];
    for (size_t j = i;;) {
        j = (j + 1) & m;
        if (s->e[j].key == 0) break;
        size_t k = lpf_ret_home(s->e[j].key, m);
        /* the entry at j stays if its home lies cyclically in (i, j] */
        if (i <= j ? (i < k && k <= j) : (i < k || k <= j)) continue;
        s->e[i] = s->e[j];
        i = j;
    }
    s->e[i].key = 0;
    s->n--;
    lpf_ret_unlock_shard(s);
    return 1;
}

/* Change the size of an entry (an object resized in place). */
static void lpf_ret_resize(uintptr_t key, uint32_t size) {
    lpf_ret_shard *s = lpf_ret_shard_of(key);
    lpf_ret_lock_shard(s);
    uint32_t site = UINT32_MAX, was = 0;
    if (s->cap > 0)
        for (size_t m = s->cap - 1, i = lpf_ret_home(key, m); s->e[i].key != 0; i = (i + 1) & m)
            if (s->e[i].key == key) {
                site = s->e[i].site;
                was = LP_RET_SIZE(s->e[i].size);
                s->e[i].size = size;
                break;
            }
    lpf_ret_unlock_shard(s);
    lpf_ret_site *st = site != UINT32_MAX ? lpf_ret_site_at(site) : NULL;
    if (st != NULL) lpf_ret_upd(st, 0, (int64_t)LP_RET_SIZE(size) - (int64_t)was);
}

/* ---- growth samples ---- */

static uint32_t lpf_ret_nser;               /* samples taken (of LP_RET_SER) */
static uint64_t lpf_ret_ser_every, lpf_ret_ser_next, lpf_ret_ser_t0;
static int64_t lpf_ret_ser_all[LP_RET_SER]; /* all tracked live bytes */
static pthread_mutex_t lpf_ret_ser_lock = PTHREAD_MUTEX_INITIALIZER;

static __attribute__((noinline)) void lpf_ret_sample(uint64_t now) {
    if (pthread_mutex_trylock(&lpf_ret_ser_lock) != 0) return;
    if (now < LP_LD(lpf_ret_ser_next)) {
        pthread_mutex_unlock(&lpf_ret_ser_lock);
        return;
    }
    uint32_t n = __atomic_load_n(&lpf_ret_nsites, __ATOMIC_ACQUIRE);
    if (lpf_ret_nser == LP_RET_SER) { /* full: keep every second sample, sample half as often */
        for (uint32_t id = 0; id < n; id++) {
            lpf_ret_site *s = lpf_ret_site_at(id);
            if (s == NULL) continue;
            for (uint32_t k = 0; k < LP_RET_SER / 2; k++) s->ser[k] = s->ser[2 * k + 1];
        }
        for (uint32_t k = 0; k < LP_RET_SER / 2; k++) lpf_ret_ser_all[k] = lpf_ret_ser_all[2 * k + 1];
        lpf_ret_nser = LP_RET_SER / 2;
        lpf_ret_ser_every *= 2;
    }
    for (uint32_t id = 0; id < n; id++) {
        lpf_ret_site *s = lpf_ret_site_at(id);
        if (s != NULL) s->ser[lpf_ret_nser] = LP_LD(s->live_b);
    }
    lpf_ret_ser_all[lpf_ret_nser] = LP_LD(lpf_ret_live_b);
    lpf_ret_nser++;
    LP_ST(lpf_ret_ser_next, now + lpf_ret_ser_every);
    pthread_mutex_unlock(&lpf_ret_ser_lock);
}

/* ---- object shapes ---- */

enum { RK_CTOR, RK_CLOSURE, RK_ARRAY, RK_SARRAY, RK_STRING, RK_MPZ, RK_THUNK, RK_TASK, RK_REF, RK_EXTERNAL,
       RK_PROMISE, RK_OTHER, RK_KINDS };
static const char *const lpf_rk_name[RK_KINDS] = {"constructor", "closure", "Array", "scalar array", "String",
                                                  "big Nat", "Thunk", "Task", "IO.Ref", "external",
                                                  "Promise", "object"};

static inline uint8_t lpf_ret_kind(unsigned tag) {
    if (tag <= LeanMaxCtorTag) return RK_CTOR;
    switch (tag) {
    case LeanClosure: return RK_CLOSURE;
    case LeanArray: return RK_ARRAY;
    case LeanScalarArray: return RK_SARRAY;
    case LeanString: return RK_STRING;
    case LeanMPZ: return RK_MPZ;
    case LeanThunk: return RK_THUNK;
    case LeanTask: return RK_TASK;
    case LeanRef: return RK_REF;
    case LeanExternal: return RK_EXTERNAL;
    case LeanPromise: return RK_PROMISE;
    default: return RK_OTHER;
    }
}

static inline size_t lpf_ret_align8(size_t n) { return (n + 7) & ~(size_t)7; }

/* Bytes an array, scalar array or string occupies (0 for other objects). */
static size_t lpf_ret_var_bytes(lean_object *o) {
    switch (o->m_tag) {
    case LeanArray: return sizeof(lean_array_object) + sizeof(void *) * lean_array_capacity(o);
    case LeanScalarArray: return sizeof(lean_sarray_object) + lean_sarray_elem_size(o) * lean_sarray_capacity(o);
    case LeanString: return sizeof(lean_string_object) + lean_string_capacity(o);
    default: return 0;
    }
}

/* Does the header at `o` describe a live object of `size` bytes? A block the
 * allocator took back starts with its free-list link (a pointer, or 0): to
 * the header that is a constructor of tag 0 with no fields, a reference
 * count of the pointer's low half and m_cs_sz of bits 32-47, which the size
 * check rejects. Reads only the header and the first words after it. */
static int lpf_ret_plausible(lean_object *o, uint32_t size_flags) {
    int rc = o->m_rc;
    unsigned tag = o->m_tag, other = o->m_other, cs = o->m_cs_sz;
    size_t size = LP_RET_SIZE(size_flags);
    if (tag == LeanReserved || tag == LeanStructArray) return 0;
    if (rc == 0 && tag == 0 && other == 0 && cs == 0) return 0; /* zeroed, or the end of a free list */
    if (rc > (1 << 30) || rc < -(1 << 30)) return 0;
    if (size_flags == 0) return 1; /* untracked: only the tag and count were checked */
    if ((size_flags & LP_RET_SMALL) && size < 65536 && cs != size) return 0;
    /* the other path (lean_alloc_object, or an array or string the runtime
     * made) only makes arrays, scalar arrays, strings and closures */
    if (!(size_flags & LP_RET_SMALL) && tag != LeanArray && tag != LeanScalarArray && tag != LeanString &&
        tag != LeanClosure)
        return 0;
    size_t need, var = 0;
    switch (tag) {
    case LeanArray:
        if (lean_array_size(o) > lean_array_capacity(o)) return 0;
        var = need = lpf_ret_var_bytes(o);
        break;
    case LeanScalarArray:
        if (lean_sarray_size(o) > lean_sarray_capacity(o)) return 0;
        var = need = lpf_ret_var_bytes(o);
        break;
    case LeanString:
        if (lean_string_size(o) > lean_string_capacity(o)) return 0;
        var = need = lpf_ret_var_bytes(o);
        break;
    case LeanClosure: {
        lean_closure_object *c = (lean_closure_object *)o;
        if (c->m_num_fixed >= c->m_arity && c->m_arity != 0) return 0;
        var = need = sizeof(lean_closure_object) + sizeof(void *) * c->m_num_fixed;
        break;
    }
    case LeanThunk: need = sizeof(lean_thunk_object); break;
    case LeanRef: need = sizeof(lean_ref_object); break;
    case LeanTask: need = sizeof(lean_task_object); break;
    case LeanExternal: need = sizeof(lean_external_object); break;
    case LeanMPZ: case LeanPromise: need = 16; break;
    default:
        if (tag > LeanMaxCtorTag) return 0;
        need = sizeof(lean_object) + sizeof(void *) * other;
    }
    if (need > size) return 0;
    if (var > 0 && size > lpf_ret_align8(var)) return 0; /* sized objects: exactly their contents */
    return 1;
}

/* ---- entering and leaving ---- */

static void lpf_ret_auto_walk(void);
static uint64_t lpf_ret_walk_at = 256 * 1024; /* tracked live bytes that start the next walk */

static __attribute__((noinline)) void lpf_ret_note_slow(void) {
    if (lpf_ret_here) {
        LP_ST(lpf_ret_shared, 1);
    } else {
        lpf_ret_here = 1;
        __atomic_add_fetch(&lpf_ret_threads, 1, __ATOMIC_RELAXED);
    }
    LP_ST(lpf_ret_owner, (void *)&lpf_ret_here);
}

static inline void lpf_ret_note_thread(void) {
    if (LEAN_UNLIKELY(LP_LD(lpf_ret_owner) != (void *)&lpf_ret_here)) lpf_ret_note_slow();
}

/* Enter object `o` (already initialized, or about to be by inline code that
 * makes no other allocation first) for site `s`. */
static void lpf_ret_enter(lpf_ret_site *s, lean_object *o, size_t sz, int small) {
    if (s == NULL || o == NULL) return;
    lpf_ret_note_thread();
    /* a walk sees the heap as it was before this object: its header may not be set yet */
    if (LEAN_UNLIKELY(LP_LD(lpf_ret_live_b) + (int64_t)sz >= (int64_t)LP_LD(lpf_ret_walk_at))) lpf_ret_auto_walk();
    if (LEAN_UNLIKELY(++lpf_ret_count >= 1024)) {
        lpf_ret_count = 0;
        uint64_t now = lpf_now();
        if (now >= LP_LD(lpf_ret_ser_next)) lpf_ret_sample(now);
    }
    uint32_t size = sz >= LP_RET_SMALL ? LP_RET_SMALL - 1 : (uint32_t)sz;
    lpf_ret_ent old;
    int r = lpf_ret_put((uintptr_t)o, s->id, size | (small ? LP_RET_SMALL : 0), &old);
    if (r < 0) {
        __atomic_add_fetch(&lpf_ret_dropped, 1, __ATOMIC_RELAXED);
        return;
    }
    if (r == 1) { /* the address was freed where leanprof does not look, and is in use again */
        lpf_ret_site *os = lpf_ret_site_at(old.site);
        if (os != NULL) {
            __atomic_add_fetch(&os->unseen_n, 1, __ATOMIC_RELAXED);
            __atomic_add_fetch(&os->unseen_b, LP_RET_SIZE(old.size), __ATOMIC_RELAXED);
            lpf_ret_upd(os, -1, -(int64_t)LP_RET_SIZE(old.size));
        }
        __atomic_add_fetch(&lpf_ret_unseen_n, 1, __ATOMIC_RELAXED);
        __atomic_add_fetch(&lpf_ret_unseen_b, LP_RET_SIZE(old.size), __ATOMIC_RELAXED);
    }
    __atomic_add_fetch(&s->made_n, 1, __ATOMIC_RELAXED);
    __atomic_add_fetch(&s->made_b, sz, __ATOMIC_RELAXED);
    lpf_ret_upd(s, 1, (int64_t)size);
}

/* Object `o` is about to be freed. */
static inline void lpf_ret_free(lean_object *o) {
    lpf_ret_ent e;
    if (!lpf_ret_take((uintptr_t)o, &e)) return;
    lpf_ret_note_thread();
    __atomic_add_fetch(&lpf_ret_seen_frees, 1, __ATOMIC_RELAXED);
    lpf_ret_site *s = lpf_ret_site_at(e.site);
    if (s != NULL) lpf_ret_upd(s, -1, -(int64_t)LP_RET_SIZE(e.size));
}

/* The site of a call from compiled code, through its allocation record. */
static lpf_ret_site *lpf_ret_site_here(void *pc) {
    lpf_thread *t = lpf_thread_get();
    return lpf_ret_site_get(pc, lpf_site(t));
}

/* The runtime made `r` for a call at `pc`: an array, scalar array or string
 * (sized by its header), or an IO.Ref (a small object, m_cs_sz set). */
static void lpf_ret_fresh(void *pc, lean_object *r) {
    if (r == NULL || lean_is_scalar(r)) return;
    size_t b = lpf_ret_var_bytes(r);
    if (b > 0) lpf_ret_enter(lpf_ret_site_here(pc), r, b, 0);
    else lpf_ret_enter(lpf_ret_site_here(pc), r, r->m_cs_sz, 1);
}

/* `a` went into a call that may grow or copy it into `r`. `ex`: `a` was
 * exclusive, so the runtime freed it if `r` is new; `before`: its bytes. */
static void lpf_ret_moved(void *pc, lean_object *a, int ex, size_t before, lean_object *r) {
    if (r == NULL || lean_is_scalar(r)) return;
    if (r == a) {
        size_t now = lpf_ret_var_bytes(r);
        if (now != before && now > 0) lpf_ret_resize((uintptr_t)r, (uint32_t)(now >= LP_RET_SMALL ? LP_RET_SMALL - 1 : now));
        return;
    }
    lpf_ret_ent e;
    if (ex && lpf_ret_take((uintptr_t)a, &e)) {
        lpf_ret_site *s = lpf_ret_site_at(e.site);
        if (s != NULL) {
            lpf_ret_upd(s, -1, -(int64_t)LP_RET_SIZE(e.size));
            lpf_ret_enter(s, r, lpf_ret_var_bytes(r), 0);
            return;
        }
    }
    lpf_ret_fresh(pc, r);
}

/* A list the runtime consumes: the cells it frees are those of the spine
 * held only through it. */
static void lpf_ret_consume_list(lean_object *l) {
    while (!lean_is_scalar(l) && lean_internal_get_rc(l) == 1 && lean_ptr_tag(l) == 1) {
        lean_object *next = lean_ctor_get(l, 1);
        lpf_ret_free(l);
        l = next;
    }
}

/* Enter each cell of a list the runtime made. */
static void lpf_ret_fresh_list(void *pc, lean_object *l) {
    lpf_ret_site *s = NULL;
    while (!lean_is_scalar(l) && lean_ptr_tag(l) == 1) {
        if (s == NULL && (s = lpf_ret_site_here(pc)) == NULL) return;
        lpf_ret_enter(s, l, sizeof(lean_object) + 2 * sizeof(void *), 1);
        l = lean_ctor_get(l, 1);
    }
}

/* ---- heap walks ---- */

enum { LR_NONE, LR_GLOBAL, LR_STACK, LR_CONST, LR_CYCLE };

typedef struct {
    void *id;                   /* the site (tracked), the closure's code (closures), or NULL */
    uint8_t kind;
    uint8_t tracked;
} lpf_ret_step;

#define LP_RET_STEPS 4
/* A chain of holders, outermost first: the root, then up to LP_RET_STEPS
 * holders nearest the object (`elided`: more were in between). */
typedef struct {
    void *where;                /* LR_GLOBAL: the global's address; LR_STACK: the function's pc */
    uint8_t root, n, elided;
    lpf_ret_step step[LP_RET_STEPS];
} lpf_ret_path;

typedef struct {
    uint32_t site, path;
    uint8_t kind;
    uint64_t n, b;
} lpf_ret_row;

typedef struct {
    const char *when;           /* "peak", "snapshot", "exit" */
    uint64_t ts;
    int64_t live_n, live_b;     /* tracked live objects when it ran */
    uint64_t nodes, untracked, stale_n, stale_b, faults;
    double ns;                  /* how long it took */
    int truncated, stack;
    lpf_ret_path *paths;
    size_t npaths;
    lpf_ret_row *rows;
    size_t nrows;
} lpf_ret_walk;

static lpf_ret_walk *lpf_ret_peak_walk, *lpf_ret_exit_walk;
#define LP_RET_SNAPS 8
static lpf_ret_walk *lpf_ret_snaps[LP_RET_SNAPS];
static unsigned lpf_ret_nsnaps, lpf_ret_snaps_dropped;
static pthread_mutex_t lpf_ret_walk_lock = PTHREAD_MUTEX_INITIALIZER;

static void lpf_ret_walk_free(lpf_ret_walk *w) {
    if (w == NULL) return;
    free(w->paths);
    free(w->rows);
    free(w);
}

/* Reads of objects that may have been freed are guarded: a fault returns
 * to the reading loop instead of ending the program. */
static sigjmp_buf *volatile lpf_ret_jb;
static pthread_t lpf_ret_walker;
static struct sigaction lpf_ret_old_segv, lpf_ret_old_bus;

static void lpf_ret_fault(int sig, siginfo_t *si, void *uc) {
    (void)si;
    (void)uc;
    if (lpf_ret_jb != NULL && pthread_equal(pthread_self(), lpf_ret_walker)) siglongjmp(*lpf_ret_jb, 1);
    /* not ours: the previous handler takes the fault when it repeats */
    sigaction(SIGSEGV, &lpf_ret_old_segv, NULL);
    sigaction(SIGBUS, &lpf_ret_old_bus, NULL);
    (void)sig;
}

static void lpf_ret_guard(int on) {
    if (on) {
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = lpf_ret_fault;
        sa.sa_flags = SA_SIGINFO | SA_NODEFER;
        sigemptyset(&sa.sa_mask);
        lpf_ret_walker = pthread_self();
        sigaction(SIGSEGV, &sa, &lpf_ret_old_segv);
        sigaction(SIGBUS, &sa, &lpf_ret_old_bus);
    } else {
        lpf_ret_jb = NULL;
        sigaction(SIGSEGV, &lpf_ret_old_segv, NULL);
        sigaction(SIGBUS, &lpf_ret_old_bus, NULL);
    }
}

/* An object in a walk, in one record (each is read and written several
 * times: one cache line, not ten arrays). */
typedef struct {
    uintptr_t addr;
    void *sid;                  /* the step's id (see lpf_ret_step) */
    void *rootw;                /* LR_GLOBAL: the global's address; LR_STACK: the function */
    uint32_t site;              /* site id + 1 (lpf_ret_canon); 0: not tracked */
    uint32_t size;              /* bytes (as in the table, with LP_RET_SMALL, until checked) */
    uint32_t parent;            /* LP_NONE: no holder found */
    uint32_t path;              /* LP_NONE: not computed */
    uint8_t kind, state, rootk, dead;
} lpf_ret_node;

typedef struct {
    uintptr_t key;
    uint32_t idx;
} lpf_ret_slot;

/* The graph being walked. */
typedef struct {
    lpf_ret_node *nodes;
    size_t n, cap;
    lpf_ret_slot *map;          /* address -> node */
    size_t mcap;
    uintptr_t lo, hi;           /* address range of the nodes */
    /* interned paths */
    lpf_ret_path *paths;
    size_t npaths, cappaths;
    uint32_t *pmap;
    size_t pmcap;
    uint32_t *strip;            /* per path: the path less its last step (LP_NONE: not computed) */
} lpf_ret_graph;

#define LP_NONE UINT32_MAX

static int lpf_ret_map_grow(lpf_ret_graph *g, size_t want) {
    size_t cap = g->mcap ? g->mcap : 1 << 16;
    while (cap < 2 * want) cap *= 2;
    if (cap == g->mcap) cap *= 2;
    lpf_ret_slot *m = calloc(cap, sizeof(lpf_ret_slot));
    if (m == NULL) return 0;
    for (size_t i = 0; i < g->mcap; i++) {
        if (g->map[i].key == 0) continue;
        size_t j = lpf_ret_home(g->map[i].key, cap - 1);
        while (m[j].key != 0) j = (j + 1) & (cap - 1);
        m[j] = g->map[i];
    }
    free(g->map);
    g->map = m;
    g->mcap = cap;
    return 1;
}

static inline uint32_t lpf_ret_map_get(const lpf_ret_graph *g, uintptr_t a) {
    if (a < g->lo || a > g->hi || g->mcap == 0) return LP_NONE;
    size_t m = g->mcap - 1;
    for (size_t i = lpf_ret_home(a, m);; i = (i + 1) & m) {
        if (g->map[i].key == a) return g->map[i].idx;
        if (g->map[i].key == 0) return LP_NONE;
    }
}

static uint32_t lpf_ret_node_add(lpf_ret_graph *g, uintptr_t a, uint32_t site, uint32_t size, uint8_t kind) {
    if (g->n >= LP_NONE - 1) return LP_NONE;
    if ((g->n + 1) * 2 > g->mcap && !lpf_ret_map_grow(g, g->n + 1)) return LP_NONE;
    if (g->n == g->cap) {
        size_t cap = g->cap ? g->cap * 2 : 1 << 15;
        lpf_ret_node *v = realloc(g->nodes, cap * sizeof(lpf_ret_node));
        if (v == NULL) return LP_NONE;
        g->nodes = v;
        g->cap = cap;
    }
    uint32_t i = (uint32_t)g->n++;
    g->nodes[i] = (lpf_ret_node){a, NULL, NULL, site, size, LP_NONE, LP_NONE, kind, 0, LR_NONE, 0};
    size_t m = g->mcap - 1, j = lpf_ret_home(a, m);
    while (g->map[j].key != 0) j = (j + 1) & m;
    g->map[j] = (lpf_ret_slot){a, i};
    if (g->lo == 0 || a < g->lo) g->lo = a;
    if (a > g->hi) g->hi = a;
    return i;
}

static void lpf_ret_graph_free(lpf_ret_graph *g) {
    free(g->nodes);
    free(g->map);
    free(g->paths);
    free(g->pmap);
    free(g->strip);
}

_Static_assert(sizeof(lpf_ret_path) % sizeof(uint64_t) == 0, "paths hash by words");

static uint64_t lpf_ret_path_hash(const lpf_ret_path *p) {
    uint64_t h = 0, w;
    for (size_t i = 0; i < sizeof *p; i += sizeof w) {
        memcpy(&w, (const char *)p + i, sizeof w);
        h = (h ^ w) * 0x9e3779b97f4a7c15ull;
        h ^= h >> 29;
    }
    return h;
}

/* The id of path `p` (built zeroed, so padding compares equal). */
static uint32_t lpf_ret_intern(lpf_ret_graph *g, const lpf_ret_path *p) {
    if ((g->npaths + 1) * 2 > g->pmcap) {
        size_t cap = g->pmcap ? g->pmcap * 2 : 1024;
        uint32_t *m = malloc(cap * sizeof(uint32_t));
        if (m == NULL) return 0;
        memset(m, 0xff, cap * sizeof(uint32_t));
        for (size_t k = 0; k < g->npaths; k++) {
            size_t j = (size_t)lpf_ret_path_hash(&g->paths[k]) & (cap - 1);
            while (m[j] != LP_NONE) j = (j + 1) & (cap - 1);
            m[j] = (uint32_t)k;
        }
        free(g->pmap);
        g->pmap = m;
        g->pmcap = cap;
    }
    size_t j = (size_t)lpf_ret_path_hash(p) & (g->pmcap - 1);
    for (; g->pmap[j] != LP_NONE; j = (j + 1) & (g->pmcap - 1))
        if (memcmp(&g->paths[g->pmap[j]], p, sizeof *p) == 0) return g->pmap[j];
    if (g->npaths == g->cappaths) {
        size_t cap = g->cappaths ? g->cappaths * 2 : 256;
        lpf_ret_path *v = realloc(g->paths, cap * sizeof(lpf_ret_path));
        uint32_t *st = v != NULL ? realloc(g->strip, cap * sizeof(uint32_t)) : NULL;
        if (v != NULL) g->paths = v;
        if (st == NULL) return 0;
        g->strip = st;
        g->cappaths = cap;
    }
    g->paths[g->npaths] = *p;
    g->strip[g->npaths] = LP_NONE;
    g->pmap[j] = (uint32_t)g->npaths;
    return (uint32_t)g->npaths++;
}

static inline lpf_ret_step lpf_ret_step_of(const lpf_ret_graph *g, uint32_t i) {
    lpf_ret_step s;
    memset(&s, 0, sizeof s);
    s.kind = g->nodes[i].kind;
    s.tracked = g->nodes[i].site != 0;
    s.id = g->nodes[i].sid;
    return s;
}

static uint32_t lpf_ret_extend(lpf_ret_graph *g, uint32_t pid, lpf_ret_step s) {
    lpf_ret_path p = g->paths[pid];
    if (p.n > 0 && memcmp(&p.step[p.n - 1], &s, sizeof s) == 0) return pid; /* runs of one kind of holder */
    if (p.n == LP_RET_STEPS) {
        memmove(&p.step[0], &p.step[1], (LP_RET_STEPS - 1) * sizeof(lpf_ret_step));
        p.n--;
        p.elided = 1;
    }
    p.step[p.n++] = s;
    return lpf_ret_intern(g, &p);
}

/* Node i holds `c`: c gets i as its holder if it has none yet. An object
 * not tracked becomes a node when reached (up to `limit` nodes). */
static void lpf_ret_link(lpf_ret_graph *g, uint32_t i, lean_object *c, size_t limit, int *truncated) {
    if (c == NULL || lean_is_scalar(c) || ((uintptr_t)c & 7) != 0) return;
    uint32_t j = lpf_ret_map_get(g, (uintptr_t)c);
    if (j == LP_NONE) {
        if (g->n >= limit) {
            *truncated = 1;
            return;
        }
        if (!lpf_ret_plausible(c, 0)) return;
        j = lpf_ret_node_add(g, (uintptr_t)c, 0, 0, lpf_ret_kind(c->m_tag));
        if (j == LP_NONE) return;
        if (c->m_tag == LeanClosure) g->nodes[j].sid = lean_closure_fun(c);
    }
    if (j != i && g->nodes[j].parent == LP_NONE) g->nodes[j].parent = i;
}

/* Check node i (tracked: is it still the object entered?) and link what it
 * holds. Reads under the guard. */
static void lpf_ret_visit(lpf_ret_graph *g, uint32_t i, size_t limit, int *truncated) {
    lean_object *x = (lean_object *)g->nodes[i].addr;
    if (g->nodes[i].site != 0) {
        if (!lpf_ret_plausible(x, g->nodes[i].size)) {
            g->nodes[i].dead = 1;
            return;
        }
        g->nodes[i].size = LP_RET_SIZE(g->nodes[i].size);
        g->nodes[i].kind = lpf_ret_kind(x->m_tag);
        if (x->m_tag == LeanClosure) g->nodes[i].sid = lean_closure_fun(x);
    }
    if (x->m_rc == 0) g->nodes[i].rootk = LR_CONST; /* persistent: a module constant */
    unsigned tag = x->m_tag;
    if (tag <= LeanMaxCtorTag) {
        unsigned k = lean_ctor_num_objs(x);
        lean_object **f = lean_ctor_obj_cptr(x);
        for (unsigned a = 0; a < k; a++) lpf_ret_link(g, i, f[a], limit, truncated);
    } else if (tag == LeanClosure) {
        unsigned k = lean_closure_num_fixed(x);
        lean_object **f = lean_closure_arg_cptr(x);
        for (unsigned a = 0; a < k; a++) lpf_ret_link(g, i, f[a], limit, truncated);
    } else if (tag == LeanArray) {
        size_t k = lean_array_size(x);
        lean_object **f = lean_array_cptr(x);
        for (size_t a = 0; a < k; a++) lpf_ret_link(g, i, f[a], limit, truncated);
    } else if (tag == LeanThunk) {
        lpf_ret_link(g, i, lean_to_thunk(x)->m_value, limit, truncated);
        lpf_ret_link(g, i, lean_to_thunk(x)->m_closure, limit, truncated);
    } else if (tag == LeanRef) {
        lpf_ret_link(g, i, lean_to_ref(x)->m_value, limit, truncated);
    } else if (tag == LeanTask) {
        lpf_ret_link(g, i, lean_to_task(x)->m_value, limit, truncated);
    }
}

/* ---- roots: the program's globals and the walking thread's stack ---- */

typedef struct {
    uintptr_t lo, hi;
} lpf_ret_range;

static lpf_ret_range lpf_ret_data[16];
static size_t lpf_ret_ndata;
typedef struct {
    uintptr_t addr, size;
    const char *name;
} lpf_ret_dsym;
static lpf_ret_dsym *lpf_ret_dsyms;
static size_t lpf_ret_ndsyms;
static pthread_once_t lpf_ret_data_once = PTHREAD_ONCE_INIT;

static int lpf_ret_dsym_cmp(const void *a, const void *b) {
    const lpf_ret_dsym *x = a, *y = b;
    return x->addr < y->addr ? -1 : x->addr > y->addr ? 1 : 0;
}

static void lpf_ret_dsym_push(size_t *cap, uintptr_t addr, uintptr_t size, const char *name) {
    if (lpf_ret_ndsyms == *cap) {
        size_t c = *cap ? *cap * 2 : 4096;
        lpf_ret_dsym *v = realloc(lpf_ret_dsyms, c * sizeof(lpf_ret_dsym));
        if (v == NULL) return;
        lpf_ret_dsyms = v;
        *cap = c;
    }
    lpf_ret_dsyms[lpf_ret_ndsyms++] = (lpf_ret_dsym){addr, size, name};
}

static int lpf_ret_in_data(uintptr_t a) {
    for (size_t k = 0; k < lpf_ret_ndata; k++)
        if (a >= lpf_ret_data[k].lo && a < lpf_ret_data[k].hi) return 1;
    return 0;
}

#ifdef __APPLE__
static void lpf_ret_data_load(void) {
    Dl_info self;
    if (!dladdr((const void *)lpf_ret_data_load, &self) || self.dli_fbase == NULL) return;
    const struct mach_header_64 *h = (const struct mach_header_64 *)self.dli_fbase;
    if (h->magic != MH_MAGIC_64) return;
    uintptr_t slide = 0;
    uint32_t n = _dyld_image_count(), i = 0;
    for (; i < n; i++)
        if ((const void *)_dyld_get_image_header(i) == (const void *)h) {
            slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            break;
        }
    if (i == n) return;
    const struct load_command *lc = (const struct load_command *)(h + 1);
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *st = NULL;
    for (uint32_t k = 0; k < h->ncmds; k++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (strcmp(sg->segname, SEG_LINKEDIT) == 0) linkedit = sg;
            else if ((sg->initprot & VM_PROT_WRITE) && sg->vmsize > 0 && lpf_ret_ndata < 16)
                lpf_ret_data[lpf_ret_ndata++] = (lpf_ret_range){slide + sg->vmaddr, slide + sg->vmaddr + sg->vmsize};
        } else if (lc->cmd == LC_SYMTAB) {
            st = (const struct symtab_command *)lc;
        }
    }
    if (linkedit == NULL || st == NULL) return;
    uintptr_t base = slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *nl = (const struct nlist_64 *)(base + st->symoff);
    const char *strs = (const char *)(base + st->stroff);
    size_t cap = 0;
    for (uint32_t k = 0; k < st->nsyms; k++) {
        if ((nl[k].n_type & N_STAB) || (nl[k].n_type & N_TYPE) != N_SECT || nl[k].n_un.n_strx == 0) continue;
        uintptr_t a = slide + nl[k].n_value;
        if (lpf_ret_in_data(a)) lpf_ret_dsym_push(&cap, a, 0, strs + nl[k].n_un.n_strx);
    }
    if (lpf_ret_ndsyms > 0) qsort(lpf_ret_dsyms, lpf_ret_ndsyms, sizeof(lpf_ret_dsym), lpf_ret_dsym_cmp);
    /* Mach-O symbols have no sizes: each runs to the next */
    for (size_t k = 0; k + 1 < lpf_ret_ndsyms; k++)
        lpf_ret_dsyms[k].size = lpf_ret_dsyms[k + 1].addr - lpf_ret_dsyms[k].addr;
    if (lpf_ret_ndsyms > 0) lpf_ret_dsyms[lpf_ret_ndsyms - 1].size = 8;
}
#else
static int lpf_ret_data_main(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    for (int i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *p = &info->dlpi_phdr[i];
        if (p->p_type == PT_LOAD && (p->p_flags & PF_W) && lpf_ret_ndata < 16)
            lpf_ret_data[lpf_ret_ndata++] =
                (lpf_ret_range){info->dlpi_addr + p->p_vaddr, info->dlpi_addr + p->p_vaddr + p->p_memsz};
    }
    *(uintptr_t *)data = info->dlpi_addr;
    return 1; /* the main program only */
}

static void lpf_ret_data_load(void) {
    uintptr_t bias = 0;
    dl_iterate_phdr(lpf_ret_data_main, &bias);
    if (lpf_ret_ndata == 0) return;
    int fd = open("/proc/self/exe", O_RDONLY);
    if (fd < 0) return;
    struct stat sb;
    void *m = fstat(fd, &sb) == 0 ? mmap(NULL, (size_t)sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0) : MAP_FAILED;
    close(fd);
    if (m == MAP_FAILED) return;
    const char *f = m;
    const ElfW(Ehdr) *eh = m;
    if ((size_t)sb.st_size < sizeof *eh || memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 ||
        eh->e_shoff + (size_t)eh->e_shnum * sizeof(ElfW(Shdr)) > (size_t)sb.st_size)
        return;
    const ElfW(Shdr) *sh = (const ElfW(Shdr) *)(f + eh->e_shoff);
    const ElfW(Shdr) *tab = NULL;
    for (int k = 0; k < eh->e_shnum; k++)
        if (sh[k].sh_type == SHT_SYMTAB) tab = &sh[k];
    if (tab == NULL)
        for (int k = 0; k < eh->e_shnum; k++)
            if (sh[k].sh_type == SHT_DYNSYM) tab = &sh[k];
    if (tab == NULL || tab->sh_link >= eh->e_shnum) return;
    const ElfW(Shdr) *strsec = &sh[tab->sh_link];
    if (tab->sh_offset + tab->sh_size > (size_t)sb.st_size || strsec->sh_offset + strsec->sh_size > (size_t)sb.st_size)
        return;
    const ElfW(Sym) *sy = (const ElfW(Sym) *)(f + tab->sh_offset);
    size_t n = tab->sh_size / sizeof(ElfW(Sym)), cap = 0;
    const char *strs = f + strsec->sh_offset;
    for (size_t i = 0; i < n; i++) {
        int type = ELF64_ST_TYPE(sy[i].st_info);
        if (sy[i].st_shndx == SHN_UNDEF || sy[i].st_name == 0 || sy[i].st_name >= strsec->sh_size ||
            (type != STT_OBJECT && type != STT_NOTYPE))
            continue;
        uintptr_t a = bias + sy[i].st_value;
        if (lpf_ret_in_data(a)) lpf_ret_dsym_push(&cap, a, sy[i].st_size ? sy[i].st_size : 8, strs + sy[i].st_name);
    }
    if (lpf_ret_ndsyms > 0) qsort(lpf_ret_dsyms, lpf_ret_ndsyms, sizeof(lpf_ret_dsym), lpf_ret_dsym_cmp);
}
#endif

/* The data symbol holding address `a`, or NULL. */
static const char *lpf_ret_dsym_at(uintptr_t a) {
    size_t lo = 0, hi = lpf_ret_ndsyms;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (lpf_ret_dsyms[mid].addr <= a) lo = mid + 1;
        else hi = mid;
    }
    if (lo == 0) return NULL;
    const lpf_ret_dsym *d = &lpf_ret_dsyms[lo - 1];
    return a < d->addr + (d->size ? d->size : 8) ? d->name : NULL;
}

/* Is `pc` in leanprof's own code (whose frames hold the walk's own locals
 * and the registers of the code that called into leanprof)? */
static int lpf_ret_own_pc(void *pc) {
    const char *s = lpf_sym_name(pc);
    if (s == NULL) return 0;
    if (s[0] == '_') s++;
    return strncmp(s, "lpf_", 4) == 0 || strncmp(s, "leanprof_", 9) == 0;
}

/* A copy of the walking thread's stack, taken before the walk touches any
 * object (afterwards its own locals would point at them), with the frames,
 * to say whose local each word is: frame k (code at ret[k]) ends at top[k],
 * its caller's stack pointer at the call, and starts at top[k - 1]. */
typedef struct {
    uintptr_t base;             /* address of words[0] */
    uintptr_t *words;
    size_t nwords;
    uintptr_t top[512];
    void *ret[512];
    size_t nframes;
} lpf_ret_stack;

/* The frames from the unwinder: the canonical frame address (CFA) of each
 * is where its frame ends. Works without frame pointers (x86-64 Linux
 * builds omit them), from the unwind tables. */
static _Unwind_Reason_Code lpf_ret_unwind(struct _Unwind_Context *ctx, void *arg) {
    lpf_ret_stack *st = arg;
    if (st->nframes >= 512) return _URC_END_OF_STACK;
    uintptr_t cfa = (uintptr_t)_Unwind_GetCFA(ctx);
    if (cfa == 0 || (st->nframes > 0 && cfa < st->top[st->nframes - 1])) return _URC_END_OF_STACK;
    st->top[st->nframes] = cfa;
    st->ret[st->nframes] = (void *)_Unwind_GetIP(ctx);
    st->nframes++;
    return _URC_NO_REASON;
}

static __attribute__((noinline, no_sanitize("address"))) void lpf_ret_stack_take(lpf_ret_stack *st) {
    memset(st, 0, sizeof *st);
    uintptr_t top = 0;
#ifdef __APPLE__
    top = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
#else
    pthread_attr_t attr;
    void *addr;
    size_t size;
    if (pthread_getattr_np(pthread_self(), &attr) == 0) {
        if (pthread_attr_getstack(&attr, &addr, &size) == 0) top = (uintptr_t)addr + size;
        pthread_attr_destroy(&attr);
    }
#endif
    volatile uintptr_t here = 0;
    uintptr_t lo = (uintptr_t)&here & ~(uintptr_t)7;
    /* the compiler must not take `lo` for a pointer to `here` (reading past
     * it would then be undefined, and clang read `here` in every iteration) */
    __asm__ volatile("" : "+r"(lo));
    if (top <= lo || top - lo > ((size_t)1 << 30)) return;
    size_t n = (top - lo) / sizeof(uintptr_t);
    st->words = malloc(n * sizeof(uintptr_t));
    if (st->words == NULL) return;
    /* word by word, not memcpy: under ASan the stack has poisoned redzones */
    for (size_t k = 0; k < n; k++) st->words[k] = ((const volatile uintptr_t *)lo)[k];
    st->base = lo;
    st->nwords = n;
    _Unwind_Backtrace(lpf_ret_unwind, st);
    if (st->nframes >= 2) return;
    /* no unwind information: the frame-pointer chain, read from the copy
     * (each record is the caller's frame pointer and the return address) */
    st->nframes = 0;
    uintptr_t fp = (uintptr_t)__builtin_frame_address(0);
    while (st->nframes < 512 && fp >= lo && fp + 2 * sizeof(uintptr_t) <= top && (fp & 7) == 0) {
        const uintptr_t *w = &st->words[(fp - lo) / sizeof(uintptr_t)];
        st->top[st->nframes] = fp + 2 * sizeof(uintptr_t);
        st->ret[st->nframes] = (void *)w[1];
        st->nframes++;
        if (w[0] <= fp) break;
        fp = w[0];
    }
    /* frame k's record is at its frame's top; its code is the return
     * address the record below it holds */
    for (size_t k = st->nframes; k-- > 1;) st->ret[k] = st->ret[k - 1];
}

/* The function whose frame holds stack address `a` (NULL: not known).
 * leanprof's own frames are given to the code that called into leanprof
 * (they hold the registers it saved). */
static void *lpf_ret_stack_owner(const lpf_ret_stack *st, uintptr_t a) {
    for (size_t k = 0; k < st->nframes; k++) {
        if (a >= st->top[k]) continue;
        for (size_t j = k; j < st->nframes; j++)
            if (!lpf_ret_own_pc(st->ret[j])) return st->ret[j];
        return NULL;
    }
    return NULL;
}

/* Roots of the nodes no other node holds: words of the program's data and
 * (st != NULL) of the stack copy equal to their addresses. A global is
 * named over a module constant; the stack only names what has no root. */
static __attribute__((no_sanitize("address"))) void lpf_ret_roots(lpf_ret_graph *g, const lpf_ret_stack *st) {
    pthread_once(&lpf_ret_data_once, lpf_ret_data_load);
    for (size_t k = 0; k < lpf_ret_ndata; k++) {
        sigjmp_buf jb;
        volatile uintptr_t p = lpf_ret_data[k].lo;
        lpf_ret_jb = &jb;
        if (sigsetjmp(jb, 0)) { /* an unmapped part (a guard page): skip a page */
            p = (p + 4096) & ~(uintptr_t)4095;
        }
        for (; p + sizeof(uintptr_t) <= lpf_ret_data[k].hi; p += sizeof(uintptr_t)) {
            uintptr_t w = *(const uintptr_t *)p;
            uint32_t j = lpf_ret_map_get(g, w);
            if (j == LP_NONE) continue;
            lpf_ret_node *nd = &g->nodes[j];
            if (nd->parent != LP_NONE || nd->rootk == LR_GLOBAL) continue;
            nd->rootk = LR_GLOBAL;
            nd->rootw = (void *)p;
        }
        lpf_ret_jb = NULL;
    }
    if (st == NULL || st->words == NULL) return;
    for (size_t k = 0; k < st->nwords; k++) {
        uint32_t j = lpf_ret_map_get(g, st->words[k]);
        if (j == LP_NONE) continue;
        lpf_ret_node *nd = &g->nodes[j];
        if (nd->parent != LP_NONE || nd->rootk != LR_NONE) continue;
        nd->rootk = LR_STACK;
        nd->rootw = lpf_ret_stack_owner(st, st->base + k * sizeof(uintptr_t));
    }
}

static size_t lpf_ret_row_hash(const lpf_ret_row *r) {
    uint64_t h = ((uint64_t)r->site * 0x9e3779b97f4a7c15ull) ^ ((uint64_t)r->path * 0xbf58476d1ce4e5b9ull) ^ r->kind;
    return (size_t)(h ^ (h >> 31));
}

static int lpf_ret_row_cmp(const void *a, const void *b) {
    const lpf_ret_row *x = a, *y = b;
    return x->b < y->b ? 1 : x->b > y->b ? -1 : 0;
}

#define LP_RET_ROWS 256

/* Zero the stack below the caller before a walk: the walk's own frames then
 * hold no stale values from earlier calls (pointers to objects, which the
 * stack scan would take for roots), only the registers they save. */
static __attribute__((noinline)) void lpf_ret_clear_stack(void) {
    volatile char buf[32768];
    for (size_t k = 0; k < sizeof buf; k += 8) *(volatile uint64_t *)&buf[k] = 0;
}

/* Walk the heap from every tracked object; `when` names the walk. */
/* Sites of one function and scope are one in a walk: a list's cells and
 * the pairs in them, made by two calls of one function, are one holder.
 * (Under lpf_ret_walk_lock.) */
typedef struct {
    uint64_t h;
    uint32_t id;
} lpf_ret_canon_ent;
static lpf_ret_canon_ent *lpf_ret_canons;
static size_t lpf_ret_ncanon, lpf_ret_capcanon;

static uint32_t lpf_ret_canon(lpf_ret_site *s) {
    if (s->canon != 0) return s->canon - 1;
    char name[256];
    lpf_symbol_name(s->pc, name, sizeof name);
    uint64_t h = 0xcbf29ce484222325ull;
    for (const char *p = name; *p; p++) h = (h ^ (uint8_t)*p) * 0x100000001b3ull;
    h ^= (uint64_t)(uintptr_t)s->label * 0x9e3779b97f4a7c15ull;
    h |= 1;
    if ((lpf_ret_ncanon + 1) * 2 > lpf_ret_capcanon) {
        size_t cap = lpf_ret_capcanon ? lpf_ret_capcanon * 2 : 1024;
        lpf_ret_canon_ent *t = calloc(cap, sizeof(lpf_ret_canon_ent));
        if (t == NULL) return s->id;
        for (size_t k = 0; k < lpf_ret_capcanon; k++) {
            if (lpf_ret_canons[k].h == 0) continue;
            size_t j = (size_t)lpf_ret_canons[k].h & (cap - 1);
            while (t[j].h != 0) j = (j + 1) & (cap - 1);
            t[j] = lpf_ret_canons[k];
        }
        free(lpf_ret_canons);
        lpf_ret_canons = t;
        lpf_ret_capcanon = cap;
    }
    size_t j = (size_t)h & (lpf_ret_capcanon - 1);
    while (lpf_ret_canons[j].h != 0 && lpf_ret_canons[j].h != h) j = (j + 1) & (lpf_ret_capcanon - 1);
    if (lpf_ret_canons[j].h == 0) {
        lpf_ret_canons[j] = (lpf_ret_canon_ent){h, s->id};
        lpf_ret_ncanon++;
    }
    s->canon = lpf_ret_canons[j].id + 1;
    return lpf_ret_canons[j].id;
}

static __attribute__((noinline)) lpf_ret_walk *lpf_ret_walk_now(const char *when, int stack) {
    uint64_t t0 = lpf_now();
    lpf_ret_stack st;
    __builtin_unwind_init(); /* the callers' registers, onto this frame: scanned with the stack */
    if (stack) lpf_ret_stack_take(&st);
    lpf_ret_walk *w = calloc(1, sizeof(lpf_ret_walk));
    lpf_ret_graph g;
    memset(&g, 0, sizeof g);
    if (w == NULL) {
        if (stack) free(st.words);
        return NULL;
    }
    w->when = when;
    w->ts = t0;
    w->stack = stack && st.words != NULL;
    /* 1. the tracked objects, copied out of the table (the map sized for them) */
    size_t want = 0;
    for (int k = 0; k < LP_RET_SHARDS; k++) want += __atomic_load_n(&lpf_ret_shards[k].n, __ATOMIC_RELAXED);
    lpf_ret_map_grow(&g, want + want / 4 + 1024);
    size_t ntr = 0;
    for (int k = 0; k < LP_RET_SHARDS; k++) {
        lpf_ret_shard *s = &lpf_ret_shards[k];
        lpf_ret_lock_shard(s);
        size_t cap = s->cap, n = s->n, m = 0;
        lpf_ret_ent *copy = n ? malloc(n * sizeof(lpf_ret_ent)) : NULL;
        for (size_t i = 0; copy != NULL && i < cap; i++)
            if (s->e[i].key != 0) copy[m++] = s->e[i];
        lpf_ret_unlock_shard(s);
        for (size_t i = 0; i < m; i++) {
            lpf_ret_site *site = lpf_ret_site_at(copy[i].site);
            uint32_t cid = site != NULL ? lpf_ret_canon(site) : copy[i].site;
            uint32_t j = lpf_ret_node_add(&g, copy[i].key, cid + 1, copy[i].size, RK_OTHER);
            if (j == LP_NONE) {
                w->truncated = 1;
                continue;
            }
            g.nodes[j].sid = lpf_ret_site_at(cid);
            ntr++;
        }
        free(copy);
    }
    /* 2. each object checked (an entry whose object was freed where leanprof
     * does not look is dropped) and linked to what it holds; objects leanprof
     * did not see made are added as they are reached (up to twice the
     * tracked ones, at least a million) */
    size_t limit = ntr * 3 > ntr + 1000000 ? ntr * 3 : ntr + 1000000;
    int truncated = 0;
    lpf_ret_guard(1);
    for (volatile size_t i = 0; i < g.n; i++) {
        sigjmp_buf jb;
        lpf_ret_jb = &jb;
        if (sigsetjmp(jb, 0) == 0) {
            lpf_ret_visit(&g, (uint32_t)i, limit, &truncated);
        } else {
            w->faults++;
            if (g.nodes[i].site != 0 && g.nodes[i].kind == RK_OTHER) g.nodes[i].dead = 1; /* unreadable */
        }
        lpf_ret_jb = NULL;
    }
    w->truncated |= truncated;
    for (size_t i = 0; i < g.n; i++) {
        if (!g.nodes[i].dead) continue;
        lpf_ret_ent e;
        if (!lpf_ret_take(g.nodes[i].addr, &e)) continue;
        lpf_ret_site *os = lpf_ret_site_at(e.site);
        if (os != NULL) {
            __atomic_add_fetch(&os->unseen_n, 1, __ATOMIC_RELAXED);
            __atomic_add_fetch(&os->unseen_b, LP_RET_SIZE(e.size), __ATOMIC_RELAXED);
            lpf_ret_upd(os, -1, -(int64_t)LP_RET_SIZE(e.size));
        }
        __atomic_add_fetch(&lpf_ret_unseen_n, 1, __ATOMIC_RELAXED);
        __atomic_add_fetch(&lpf_ret_unseen_b, LP_RET_SIZE(e.size), __ATOMIC_RELAXED);
        w->stale_n++;
        w->stale_b += LP_RET_SIZE(e.size);
        ntr--;
    }
    w->live_n = LP_LD(lpf_ret_live_n);
    w->live_b = LP_LD(lpf_ret_live_b);
    w->nodes = g.n - w->stale_n;
    w->untracked = w->nodes - ntr;
    /* 3. the roots of the objects nothing seen holds */
    lpf_ret_roots(&g, stack && st.words != NULL ? &st : NULL);
    lpf_ret_guard(0);
    if (stack) free(st.words);
    /* 4. each object's chain of holders, interned */
    uint32_t *todo = malloc((g.n ? g.n : 1) * sizeof(uint32_t));
    lpf_ret_path none;
    memset(&none, 0, sizeof none);
    lpf_ret_intern(&g, &none); /* path 0: no holder */
    for (size_t i = 0; todo != NULL && i < g.n; i++) {
        if (g.nodes[i].site == 0 || g.nodes[i].dead || g.nodes[i].state == 2) continue;
        size_t sp = 0;
        todo[sp++] = (uint32_t)i;
        g.nodes[i].state = 1;
        while (sp > 0) {
            uint32_t u = todo[sp - 1], p = g.nodes[u].parent;
            if (p == LP_NONE || g.nodes[p].state == 1) { /* a root, or a cycle closed here */
                lpf_ret_path r;
                memset(&r, 0, sizeof r);
                r.root = p != LP_NONE ? LR_CYCLE : g.nodes[u].rootk;
                r.where = p == LP_NONE ? g.nodes[u].rootw : NULL;
                g.nodes[u].path = lpf_ret_extend(&g, lpf_ret_intern(&g, &r), lpf_ret_step_of(&g, u));
                g.nodes[u].state = 2;
                sp--;
            } else if (g.nodes[p].state == 2) {
                g.nodes[u].path = lpf_ret_extend(&g, g.nodes[p].path, lpf_ret_step_of(&g, u));
                g.nodes[u].state = 2;
                sp--;
            } else {
                g.nodes[p].state = 1;
                todo[sp++] = p;
            }
        }
    }
    free(todo);
    /* 5. bytes by (site, kind, chain above the object) */
    size_t cap = 1024, n = 0, hcap = 4096;
    lpf_ret_row *rows = calloc(cap, sizeof(lpf_ret_row));
    uint32_t *hm = malloc(hcap * sizeof(uint32_t));
    if (hm != NULL) memset(hm, 0xff, hcap * sizeof(uint32_t));
    for (size_t i = 0; rows != NULL && hm != NULL && i < g.n; i++) {
        const lpf_ret_node *nd = &g.nodes[i];
        if (nd->site == 0 || nd->dead || nd->path == LP_NONE) continue;
        /* the chain above it: its own path less its own step (the last,
         * when it is its own: every path is built ending with its object) */
        uint32_t pid = nd->path;
        lpf_ret_step me = lpf_ret_step_of(&g, (uint32_t)i);
        const lpf_ret_path *own = &g.paths[pid];
        if (own->n > 0 && memcmp(&own->step[own->n - 1], &me, sizeof me) == 0) {
            if (g.strip[pid] == LP_NONE) {
                lpf_ret_path p = *own;
                memset(&p.step[p.n - 1], 0, sizeof(lpf_ret_step));
                p.n--;
                uint32_t q = lpf_ret_intern(&g, &p);
                g.strip[pid] = q;
            }
            pid = g.strip[pid];
        }
        lpf_ret_row key = {nd->site - 1, pid, nd->kind, 0, 0};
        if ((n + 1) * 2 > hcap) { /* grow the index */
            size_t c2 = hcap * 2;
            uint32_t *h2 = malloc(c2 * sizeof(uint32_t));
            if (h2 == NULL) break;
            memset(h2, 0xff, c2 * sizeof(uint32_t));
            for (size_t r = 0; r < n; r++) {
                size_t q = lpf_ret_row_hash(&rows[r]) & (c2 - 1);
                while (h2[q] != LP_NONE) q = (q + 1) & (c2 - 1);
                h2[q] = (uint32_t)r;
            }
            free(hm);
            hm = h2;
            hcap = c2;
        }
        size_t j = lpf_ret_row_hash(&key) & (hcap - 1);
        while (hm[j] != LP_NONE && !(rows[hm[j]].site == key.site && rows[hm[j]].path == key.path &&
                                     rows[hm[j]].kind == key.kind))
            j = (j + 1) & (hcap - 1);
        if (hm[j] == LP_NONE) {
            if (n == cap) {
                lpf_ret_row *r2 = realloc(rows, 2 * cap * sizeof(lpf_ret_row));
                if (r2 == NULL) break;
                rows = r2;
                cap *= 2;
            }
            rows[n] = key;
            hm[j] = (uint32_t)n++;
        }
        rows[hm[j]].n++;
        rows[hm[j]].b += nd->size;
    }
    free(hm);
    if (rows != NULL) {
        qsort(rows, n, sizeof(lpf_ret_row), lpf_ret_row_cmp);
        if (n > LP_RET_ROWS) n = LP_RET_ROWS;
        /* keep the paths these rows use, renumbered */
        lpf_ret_path *paths = malloc((n ? n : 1) * sizeof(lpf_ret_path));
        if (paths != NULL) {
            for (size_t r = 0; r < n; r++) {
                paths[r] = g.paths[rows[r].path];
                rows[r].path = (uint32_t)r;
            }
            w->paths = paths;
            w->npaths = n;
            w->rows = rows;
            w->nrows = n;
        } else {
            free(rows);
        }
    }
    lpf_ret_graph_free(&g);
    w->ns = (double)(lpf_now() - t0) * lpf_ns_per_tick_rough();
    return w;
}

/* A walk near the peak: tracked live bytes passed the threshold. Only while
 * one thread uses tracked objects (another could free what is read), and
 * only while walks so far took under a quarter of the run (each costs time
 * in proportion to the live objects; LEANPROF_RETAINED_WALKS=all lifts this). */
static double lpf_ret_walks_ns, lpf_ret_walk_cost = 100; /* total, and ns per object of the last */
static unsigned lpf_ret_walks, lpf_ret_walks_skipped;

static void lpf_ret_auto_walk(void) {
    if (!lpf_ret_auto || LP_LD(lpf_ret_shared) || pthread_mutex_trylock(&lpf_ret_walk_lock) != 0) return;
    int64_t live = LP_LD(lpf_ret_live_b), live_n = LP_LD(lpf_ret_live_n);
    double elapsed = (double)(lpf_now() - lpf_start) * lpf_ns_per_tick_rough();
    if (lpf_ret_auto == 1 && lpf_ret_walks_ns + (double)live_n * lpf_ret_walk_cost > 0.25 * elapsed) {
        lpf_ret_walks_skipped++;
        uint64_t next = (uint64_t)(live > 0 ? live : 0) * 5 / 4 + 1;
        LP_ST(lpf_ret_walk_at, next);
        pthread_mutex_unlock(&lpf_ret_walk_lock);
        return;
    }
    lpf_ret_clear_stack();
    lpf_ret_walk *w = lpf_ret_walk_now("peak", 1);
    /* the walk dropped stale entries: the next one is 25% above what is left */
    int64_t left = LP_LD(lpf_ret_live_b);
    uint64_t next = (uint64_t)(left > 0 ? left : 0) * 5 / 4 + 1;
    LP_ST(lpf_ret_walk_at, next < 256 * 1024 ? 256 * 1024 : next);
    if (w != NULL) {
        lpf_ret_walks++;
        lpf_ret_walks_ns += w->ns;
        if (w->nodes > 1000) lpf_ret_walk_cost = w->ns / (double)w->nodes;
    }
    /* keep the walk that saw the most live bytes */
    if (w != NULL && (lpf_ret_peak_walk == NULL || w->live_b >= lpf_ret_peak_walk->live_b)) {
        lpf_ret_walk_free(lpf_ret_peak_walk);
        lpf_ret_peak_walk = w;
    } else {
        lpf_ret_walk_free(w);
    }
    pthread_mutex_unlock(&lpf_ret_walk_lock);
}

/* `Leanprof.retainedSnapshot`: a walk now (the first LP_RET_SNAPS are kept). */
LEAN_EXPORT lean_obj_res leanprof_retained_snapshot(void) {
    if (!LP_RET_TRACKING()) return lean_box(0);
    pthread_mutex_lock(&lpf_ret_walk_lock);
    if (lpf_ret_nsnaps < LP_RET_SNAPS) {
        lpf_ret_clear_stack();
        lpf_ret_walk *w = lpf_ret_walk_now("snapshot", 1);
        if (w != NULL) lpf_ret_snaps[lpf_ret_nsnaps++] = w;
    } else {
        lpf_ret_snaps_dropped++;
    }
    pthread_mutex_unlock(&lpf_ret_walk_lock);
    return lean_box(0);
}

/* `Leanprof.retainedLive`: bytes of tracked objects alive now (none when not tracking). */
LEAN_EXPORT lean_obj_res leanprof_retained_live(void) {
    if (!LP_LD(lpf_ret_on)) return lean_box(0);
    int64_t b = LP_LD(lpf_ret_live_b);
    lean_object *r = lean_alloc_ctor(1, 1, 0);
    lean_ctor_set(r, 0, lean_uint64_to_nat(b > 0 ? (uint64_t)b : 0));
    return r;
}

static void lpf_ret_init(void) {
    const char *on = getenv("LEANPROF_RETAINED");
    if (on == NULL || strcmp(on, "1") != 0) return;
    const char *walks = getenv("LEANPROF_RETAINED_WALKS");
    if (walks != NULL && strcmp(walks, "0") == 0) {
        lpf_ret_auto = 0;
        lpf_ret_walk_at = UINT64_MAX >> 1;
    }
    if (walks != NULL && strcmp(walks, "all") == 0) lpf_ret_auto = 2;
    double tick = lpf_ns_per_tick_rough();
    double ms = 20;
    const char *every = getenv("LEANPROF_RETAINED_SAMPLE_MS");
    if (every != NULL && atof(every) > 0) ms = atof(every);
    lpf_ret_ser_every = (uint64_t)(ms * 1e6 / tick);
    lpf_ret_ser_t0 = lpf_start;
    lpf_ret_ser_next = lpf_start + lpf_ret_ser_every;
    LP_ST(lpf_ret_on, 1);
}

/* At exit, before the report: the last walk, and the last sample. */
static void lpf_ret_finish(void) {
    if (!LP_LD(lpf_ret_on)) return;
    pthread_mutex_lock(&lpf_ret_walk_lock);
    lpf_ret_exit_walk = lpf_ret_walk_now("exit", 0);
    pthread_mutex_unlock(&lpf_ret_walk_lock);
    LP_ST(lpf_ret_ser_next, 0);
    lpf_ret_sample(lpf_now());
    LP_ST(lpf_ret_on, 2); /* the report's own work (the self-check) is not the program's */
}

/* ---- report ---- */

/* Leak-like growth: live bytes that rose through the second half of the
 * samples (in two of three), ending near their largest, by at least 64 KiB
 * and 10%. A batch program that builds its result until the end also grows. */
typedef struct {
    int growing;
    int64_t from, to;           /* at the middle sample, and at the last */
    unsigned rises, steps;      /* samples that rose, of the second half's steps */
} lpf_ret_trend;

static lpf_ret_trend lpf_ret_trend_of(const int64_t *ser, uint32_t n) {
    lpf_ret_trend t;
    memset(&t, 0, sizeof t);
    if (n < 8) return t;
    int64_t mx = 0;
    for (uint32_t k = 0; k < n; k++)
        if (ser[k] > mx) mx = ser[k];
    t.from = ser[n / 2];
    t.to = ser[n - 1];
    for (uint32_t k = n / 2 + 1; k < n; k++) {
        t.steps++;
        t.rises += ser[k] > ser[k - 1];
    }
    /* rising in two of every three samples: a one-time build-up rises in a few */
    t.growing = t.to - t.from >= 65536 && t.to - t.from >= t.to / 10 && t.to * 10 >= mx * 9 &&
                t.rises * 3 >= t.steps * 2;
    return t;
}

typedef struct {
    char fn[256], where[512], scope[256];
    int64_t peak_n, peak_b, exit_n, exit_b, max_b;
    uint64_t made_n, made_b, unseen_n, unseen_b;
    int64_t ser[LP_RET_SER];
    lpf_ret_trend trend;
} lpf_ret_sum;

static void lpf_ret_site_names(const lpf_ret_site *s, char *fn, size_t fcap, char *where, size_t wcap, char *scope,
                               size_t scap) {
    lpf_symbol_name(s->pc, fn, fcap);
    lpf_where(fn, where, wcap);
    if (s->label != NULL) lpf_label_name(lean_string_cstr((lean_object *)s->label), scope, scap);
    else snprintf(scope, scap, "-");
}

static int lpf_ret_sum_cmp(const void *a, const void *b) {
    const lpf_ret_sum *x = a, *y = b;
    int64_t kx = x->peak_b > x->exit_b ? x->peak_b : x->exit_b, ky = y->peak_b > y->exit_b ? y->peak_b : y->exit_b;
    return kx < ky ? 1 : kx > ky ? -1 : strcmp(x->fn, y->fn);
}

/* Sites merged by function and scope, largest first. */
static lpf_ret_sum *lpf_ret_merge(size_t *out_n) {
    uint32_t ns = __atomic_load_n(&lpf_ret_nsites, __ATOMIC_ACQUIRE);
    size_t n = 0;
    lpf_ret_sum *R = calloc(ns ? ns : 1, sizeof(lpf_ret_sum));
    if (R == NULL) {
        *out_n = 0;
        return NULL;
    }
    for (uint32_t id = 0; id < ns; id++) {
        const lpf_ret_site *s = lpf_ret_site_at(id);
        if (s == NULL) continue;
        char fn[256], where[512], scope[256];
        lpf_ret_site_names(s, fn, sizeof fn, where, sizeof where, scope, sizeof scope);
        size_t k = 0;
        while (k < n && !(strcmp(R[k].fn, fn) == 0 && strcmp(R[k].scope, scope) == 0)) k++;
        if (k == n) {
            snprintf(R[k].fn, sizeof R[k].fn, "%s", fn);
            snprintf(R[k].where, sizeof R[k].where, "%s", where);
            snprintf(R[k].scope, sizeof R[k].scope, "%s", scope);
            n++;
        }
        R[k].peak_n += lpf_ret_at_peak(s, 0);
        R[k].peak_b += lpf_ret_at_peak(s, 1);
        R[k].exit_n += LP_LD(s->live_n);
        R[k].exit_b += LP_LD(s->live_b);
        R[k].max_b += LP_LD(s->max_b);
        R[k].made_n += LP_LD(s->made_n);
        R[k].made_b += LP_LD(s->made_b);
        R[k].unseen_n += LP_LD(s->unseen_n);
        R[k].unseen_b += LP_LD(s->unseen_b);
        for (uint32_t q = 0; q < lpf_ret_nser; q++) R[k].ser[q] += s->ser[q];
    }
    for (size_t k = 0; k < n; k++) R[k].trend = lpf_ret_trend_of(R[k].ser, lpf_ret_nser);
    qsort(R, n, sizeof(lpf_ret_sum), lpf_ret_sum_cmp);
    *out_n = n;
    return R;
}

/* A step of a chain, in words. */
static void lpf_ret_step_text(const lpf_ret_step *s, char *fn, size_t fcap, char *where, size_t wcap) {
    fn[0] = where[0] = 0;
    if (s->id == NULL) return;
    if (s->kind == RK_CLOSURE) {
        lpf_symbol_name(s->id, fn, fcap);
        lpf_where(fn, where, wcap);
    } else if (s->tracked) {
        lpf_symbol_name(((const lpf_ret_site *)s->id)->pc, fn, fcap);
        lpf_where(fn, where, wcap);
    }
}

static const char *const lpf_root_name[] = {"unknown", "global", "stack", "constant", "cycle"};

static void lpf_ret_root_text(const lpf_ret_path *p, char *name, size_t ncap, char *where, size_t wcap) {
    name[0] = where[0] = 0;
    if (p->root == LR_GLOBAL) {
        pthread_once(&lpf_ret_data_once, lpf_ret_data_load);
        const char *sym = lpf_ret_dsym_at((uintptr_t)p->where);
        if (sym != NULL) {
            lpf_demangle(sym, name, ncap);
            lpf_where(name, where, wcap);
        } else {
            snprintf(name, ncap, "%p", p->where);
        }
    } else if (p->root == LR_STACK && p->where != NULL) {
        lpf_symbol_name(p->where, name, ncap);
        lpf_where(name, where, wcap);
    }
}

/* A known cause, and its fix, for a chain: what the nearest notable holder
 * does, then what the root does (NULL: nothing known). */
static const char *lpf_ret_hint(const lpf_ret_path *p, uint8_t kind, char *buf, size_t cap) {
    const char *near = NULL, *root = NULL;
    int ref = 0;
    for (int k = (int)p->n - 1; k >= 0 && near == NULL; k--) {
        switch (p->step[k].kind) {
        case RK_THUNK:
            near = "Held by a Thunk: a forced Thunk keeps its value, and an unforced one what its closure "
                   "captured, as long as the Thunk lives. Compute the value eagerly, or drop the Thunk once used.";
            break;
        case RK_CLOSURE:
            near = "Captured by a closure, which keeps every value it captured alive as long as it lives. "
                   "Capture only what the closure uses (a field, not the whole structure).";
            break;
        case RK_TASK:
            near = "The result of a Task, which keeps its value as long as the Task is referenced. Drop the Task "
                   "once its value is taken.";
            break;
        default: break;
        }
    }
    if (near == NULL && kind == RK_THUNK)
        near = "A Thunk keeps its value once forced, and what its closure captured until then.";
    for (unsigned k = 0; k < p->n; k++) ref |= p->step[k].kind == RK_REF;
    if (p->root == LR_GLOBAL && ref)
        root = "Kept in a global IO.Ref (an `initialize` value): it lives until the Ref is set to something "
               "else, for the rest of the run otherwise. Clear or bound what the Ref holds, or keep the data in a "
               "value passed to where it is used.";
    else if (p->root == LR_GLOBAL)
        root = "Reachable from a global (an `initialize` value or a cached constant): it lives for the rest of "
               "the run.";
    else if (ref)
        root = "Kept in an IO.Ref: it lives until the Ref is set again or the Ref itself is dropped.";
    if (near == NULL && root == NULL) return NULL;
    snprintf(buf, cap, "%s%s%s", near ? near : "", near && root ? " " : "", root ? root : "");
    return buf;
}

static void lpf_ret_print_walk(FILE *f, const lpf_ret_walk *w, double tick, size_t max) {
    if (w == NULL) return;
    char lb[32], at[32], took[32];
    lpf_fmt_bytes((double)w->live_b, lb, sizeof lb);
    lpf_fmt_time(w->ts > lpf_start ? (double)(w->ts - lpf_start) * tick : 0, at, sizeof at);
    lpf_fmt_time(w->ns, took, sizeof took);
    fprintf(f, "what keeps it alive (%s heap walk at %s, %s of tracked objects live; took %s%s)\n", w->when, at, lb,
            took, w->truncated ? "; stopped early, the heap was too large" : "");
    if (w->nrows == 0) {
        fprintf(f, "    no tracked objects were alive\n");
        return;
    }
    for (size_t r = 0; r < w->nrows && r < max; r++) {
        const lpf_ret_row *row = &w->rows[r];
        const lpf_ret_path *p = &w->paths[row->path];
        const lpf_ret_site *s = lpf_ret_site_at(row->site);
        char b[32], fn[256], where[512];
        lpf_fmt_bytes((double)row->b, b, sizeof b);
        if (s != NULL) lpf_symbol_name(s->pc, fn, sizeof fn);
        else snprintf(fn, sizeof fn, "?");
        lpf_where(fn, where, sizeof where);
        fprintf(f, "  %10s  %llu %s from %s%s%s%s\n", b, (unsigned long long)row->n, lpf_rk_name[row->kind], fn,
                where[0] ? " (" : "", where, where[0] ? ")" : "");
        fprintf(f, "              held by ");
        for (int k = (int)p->n - 1; k >= 0; k--) {
            char sf[256], sw[512];
            lpf_ret_step_text(&p->step[k], sf, sizeof sf, sw, sizeof sw);
            if (p->step[k].kind == RK_CLOSURE && sf[0]) fprintf(f, "closure of %s", sf);
            else if (sf[0]) fprintf(f, "%s from %s", lpf_rk_name[p->step[k].kind], sf);
            else fprintf(f, "%s (made where leanprof does not look)", lpf_rk_name[p->step[k].kind]);
            if (sw[0]) fprintf(f, " (%s)", sw);
            fprintf(f, " <- ");
        }
        if (p->elided) fprintf(f, "... <- ");
        char rn[300], rw[512];
        lpf_ret_root_text(p, rn, sizeof rn, rw, sizeof rw);
        switch (p->root) {
        case LR_GLOBAL: fprintf(f, "global %s", rn); break;
        case LR_STACK: fprintf(f, "a local of %s (stack)", rn[0] ? rn : "an unknown function"); break;
        case LR_CONST: fprintf(f, "a module constant (persistent)"); break;
        case LR_CYCLE: fprintf(f, "a reference cycle"); break;
        default: fprintf(f, "nothing leanprof can see (another thread's stack, the runtime, or an object made in precompiled code)");
        }
        if (rw[0]) fprintf(f, " (%s)", rw);
        fputc('\n', f);
        char hb[1024];
        const char *hint = lpf_ret_hint(p, row->kind, hb, sizeof hb);
        if (hint != NULL) fprintf(f, "              fix: %s\n", hint);
    }
    if (w->nrows > max) fprintf(f, "  (%zu more in the JSON report)\n", w->nrows - max);
}

static void lpf_ret_print(FILE *f, double tick, int allocs_counted) {
    if (!LP_LD(lpf_ret_on)) {
        if (allocs_counted)
            fprintf(f, "\nretained memory: not tracked (`leanprof run --retained` says which allocation sites hold "
                       "memory at the peak and at exit, and what keeps it alive)\n");
        return;
    }
    size_t n = 0;
    lpf_ret_sum *R = lpf_ret_merge(&n);
    char pb[32], eb[32], ub[32], pt[32];
    lpf_fmt_bytes((double)LP_LD(lpf_ret_peak_b), pb, sizeof pb);
    lpf_fmt_bytes((double)LP_LD(lpf_ret_live_b), eb, sizeof eb);
    lpf_fmt_bytes((double)LP_LD(lpf_ret_unseen_b), ub, sizeof ub);
    lpf_fmt_time(LP_LD(lpf_ret_peak_t) > lpf_start ? (double)(LP_LD(lpf_ret_peak_t) - lpf_start) * tick : 0, pt,
                 sizeof pt);
    fprintf(f, "\nretained memory (objects compiled Lean code allocated, by allocation site; --retained)\n");
    fprintf(f, "  live: peak %s in %lld objects at %s; at exit %s in %lld objects\n", pb,
            (long long)LP_LD(lpf_ret_peak_n), pt, eb, (long long)LP_LD(lpf_ret_live_n));
    if (!lpf_frees_seen)
        fprintf(f, "  frees: not seen (the program was built without the free shims): live counts are upper bounds\n");
    else
        fprintf(f, "  frees not seen: %llu objects (%s) were freed in precompiled code or the runtime; found when their "
                   "address was reused or a walk read them\n",
                (unsigned long long)LP_LD(lpf_ret_unseen_n), ub);
    if (LP_LD(lpf_ret_dropped) > 0)
        fprintf(f, "  not tracked: %llu objects (out of memory for the table)\n",
                (unsigned long long)LP_LD(lpf_ret_dropped));
    if (R != NULL && n > 0) {
        fprintf(f, "%11s %10s %11s %10s  %-8s  %-18s %s\n", "at peak", "objects", "at exit", "objects", "trend",
                "in scope", "function  (where)");
        size_t shown = 0;
        for (size_t k = 0; k < n && shown < 20; k++) {
            if (R[k].peak_b == 0 && R[k].exit_b == 0) continue;
            char a[32], b[32];
            lpf_fmt_bytes((double)R[k].peak_b, a, sizeof a);
            lpf_fmt_bytes((double)R[k].exit_b, b, sizeof b);
            fprintf(f, "%11s %10lld %11s %10lld  %-8s  %-18s %s", a, (long long)R[k].peak_n, b, (long long)R[k].exit_n,
                    R[k].trend.growing ? "growing" : lpf_ret_nser < 8 ? "-" : "", R[k].scope, R[k].fn);
            if (R[k].where[0]) fprintf(f, "  (%s)", R[k].where);
            fputc('\n', f);
            shown++;
        }
        if (n > shown) fprintf(f, "(%zu more sites in the JSON report)\n", n - shown);
        for (size_t k = 0; k < n; k++) {
            if (!R[k].trend.growing) continue;
            char a[32], b[32];
            lpf_fmt_bytes((double)R[k].trend.from, a, sizeof a);
            lpf_fmt_bytes((double)R[k].trend.to, b, sizeof b);
            fprintf(f, "  growing: %s kept rising over the second half of the run, %s -> %s (rose in %u of %u "
                       "samples)\n",
                    R[k].fn, a, b, R[k].trend.rises, R[k].trend.steps);
        }
    }
    free(R);
    if (lpf_ret_peak_walk != NULL) {
        fputc('\n', f);
        lpf_ret_print_walk(f, lpf_ret_peak_walk, tick, 8);
        if (lpf_ret_walks_skipped > 0)
            fprintf(f, "  (%u walks closer to the peak were skipped to keep walks under a quarter of the run; "
                       "LEANPROF_RETAINED_WALKS=all takes them)\n", lpf_ret_walks_skipped);
    } else {
        fprintf(f, "\n(no heap walk near the peak: %s)\n",
                !lpf_ret_auto ? "turned off by LEANPROF_RETAINED_WALKS=0"
                : LP_LD(lpf_ret_shared) ? "threads or tasks used tracked objects at the same time, and another thread could free what a walk reads"
                : lpf_ret_walks_skipped > 0 ? "each would have taken walks past a quarter of the run; LEANPROF_RETAINED_WALKS=all takes them"
                                            : "tracked live bytes stayed under 256 KiB");
    }
    for (unsigned k = 0; k < lpf_ret_nsnaps; k++) {
        fputc('\n', f);
        lpf_ret_print_walk(f, lpf_ret_snaps[k], tick, 8);
    }
    if (lpf_ret_exit_walk != NULL && lpf_ret_exit_walk->nrows > 0) {
        fputc('\n', f);
        lpf_ret_print_walk(f, lpf_ret_exit_walk, tick, 5);
    }
}

static void lpf_ret_json_walk(FILE *f, const lpf_ret_walk *w, double tick) {
    fprintf(f, "{\"when\":\"%s\",\"at_ns\":%.0f,\"took_ns\":%.0f,\"live_bytes\":%lld,\"live_objects\":%lld,"
               "\"nodes\":%llu,\"untracked\":%llu,\"stale_objects\":%llu,\"stale_bytes\":%llu,\"faults\":%llu,"
               "\"truncated\":%s,\"stack_scanned\":%s,\"paths\":[",
            w->when, w->ts > lpf_start ? (double)(w->ts - lpf_start) * tick : 0, w->ns, (long long)w->live_b,
            (long long)w->live_n, (unsigned long long)w->nodes, (unsigned long long)w->untracked,
            (unsigned long long)w->stale_n, (unsigned long long)w->stale_b, (unsigned long long)w->faults,
            w->truncated ? "true" : "false", w->stack ? "true" : "false");
    for (size_t r = 0; r < w->nrows; r++) {
        const lpf_ret_row *row = &w->rows[r];
        const lpf_ret_path *p = &w->paths[row->path];
        const lpf_ret_site *s = lpf_ret_site_at(row->site);
        char fn[256] = "?", where[512] = "", scope[256] = "-";
        if (s != NULL) lpf_ret_site_names(s, fn, sizeof fn, where, sizeof where, scope, sizeof scope);
        fprintf(f, "%s{\"kind\":\"%s\",\"function\":", r ? "," : "", lpf_rk_name[row->kind]);
        lpf_json_str(f, fn);
        fprintf(f, ",\"where\":");
        lpf_json_str(f, where);
        fprintf(f, ",\"scope\":");
        lpf_json_str(f, scope);
        fprintf(f, ",\"objects\":%llu,\"bytes\":%llu,\"held_by\":[", (unsigned long long)row->n,
                (unsigned long long)row->b);
        for (int k = (int)p->n - 1, first = 1; k >= 0; k--, first = 0) {
            char sf[256], sw[512];
            lpf_ret_step_text(&p->step[k], sf, sizeof sf, sw, sizeof sw);
            fprintf(f, "%s{\"kind\":\"%s\",\"function\":", first ? "" : ",", lpf_rk_name[p->step[k].kind]);
            lpf_json_str(f, sf);
            fprintf(f, ",\"where\":");
            lpf_json_str(f, sw);
            fprintf(f, ",\"seen_made\":%s}", p->step[k].tracked ? "true" : "false");
        }
        char rn[300], rw[512];
        lpf_ret_root_text(p, rn, sizeof rn, rw, sizeof rw);
        fprintf(f, "],\"elided\":%s,\"root\":{\"kind\":\"%s\",\"name\":", p->elided ? "true" : "false",
                lpf_root_name[p->root]);
        lpf_json_str(f, rn);
        fprintf(f, ",\"where\":");
        lpf_json_str(f, rw);
        fprintf(f, "},\"hint\":");
        char hb[1024];
        const char *hint = lpf_ret_hint(p, row->kind, hb, sizeof hb);
        if (hint != NULL) lpf_json_str(f, hint);
        else fprintf(f, "null");
        fputc('}', f);
    }
    fprintf(f, "]}");
}

/* `"retained":{...},` in a live snapshot (`leanprof top`): live bytes now,
 * and the sites holding the most, from the counters (the live thread reads
 * no objects). Nothing when not tracking. */
static void lpf_ret_live_json(FILE *f) {
    if (!LP_LD(lpf_ret_on)) return;
    uint32_t ns = __atomic_load_n(&lpf_ret_nsites, __ATOMIC_ACQUIRE);
    enum { TOP = 16 };
    const lpf_ret_site *top[TOP] = {0};
    for (uint32_t id = 0; id < ns; id++) {
        const lpf_ret_site *s = lpf_ret_site_at(id);
        if (s == NULL || LP_LD(s->live_b) <= 0) continue;
        for (int k = 0; k < TOP; k++)
            if (top[k] == NULL || LP_LD(s->live_b) > LP_LD(top[k]->live_b)) {
                memmove(&top[k + 1], &top[k], (TOP - 1 - k) * sizeof top[0]);
                top[k] = s;
                break;
            }
    }
    fprintf(f, "\"retained\":{\"live_bytes\":%lld,\"live_objects\":%lld,\"peak_bytes\":%lld,\"sites\":[",
            (long long)LP_LD(lpf_ret_live_b), (long long)LP_LD(lpf_ret_live_n), (long long)LP_LD(lpf_ret_peak_b));
    for (int k = 0; k < TOP && top[k] != NULL; k++) {
        char fn[256], where[512];
        lpf_symbol_name(top[k]->pc, fn, sizeof fn);
        lpf_where(fn, where, sizeof where);
        fprintf(f, "%s{\"name\":", k ? "," : "");
        lpf_json_str(f, fn);
        fprintf(f, ",\"where\":");
        lpf_json_str(f, where);
        fprintf(f, ",\"live_bytes\":%lld,\"live_objects\":%lld}", (long long)LP_LD(top[k]->live_b),
                (long long)LP_LD(top[k]->live_n));
    }
    fprintf(f, "]},");
}

/* `,"retained":{...}` inside the report object (only when tracking). */
static void lpf_ret_json(FILE *f, double tick) {
    if (!LP_LD(lpf_ret_on)) return;
    size_t n = 0;
    lpf_ret_sum *R = lpf_ret_merge(&n);
    fprintf(f, ",\"retained\":{\"peak_bytes\":%lld,\"peak_objects\":%lld,\"peak_at_ns\":%.0f,\"exit_bytes\":%lld,"
               "\"exit_objects\":%lld,\"frees_seen\":%s,\"freed_seen\":%llu,\"unseen_objects\":%llu,"
               "\"unseen_bytes\":%llu,\"not_tracked\":%llu,\"sample_ns\":%.0f,\"samples\":%u,\"series\":[",
            (long long)LP_LD(lpf_ret_peak_b), (long long)LP_LD(lpf_ret_peak_n),
            LP_LD(lpf_ret_peak_t) > lpf_start ? (double)(LP_LD(lpf_ret_peak_t) - lpf_start) * tick : 0,
            (long long)LP_LD(lpf_ret_live_b), (long long)LP_LD(lpf_ret_live_n), lpf_frees_seen ? "true" : "false",
            (unsigned long long)LP_LD(lpf_ret_seen_frees), (unsigned long long)LP_LD(lpf_ret_unseen_n),
            (unsigned long long)LP_LD(lpf_ret_unseen_b), (unsigned long long)LP_LD(lpf_ret_dropped),
            (double)lpf_ret_ser_every * tick, lpf_ret_nser);
    for (uint32_t q = 0; q < lpf_ret_nser; q++) fprintf(f, "%s%lld", q ? "," : "", (long long)lpf_ret_ser_all[q]);
    fprintf(f, "],\"sites\":[");
    for (size_t k = 0; R != NULL && k < n; k++) {
        fprintf(f, "%s{\"function\":", k ? "," : "");
        lpf_json_str(f, R[k].fn);
        fprintf(f, ",\"scope\":");
        lpf_json_str(f, R[k].scope);
        fprintf(f, ",\"where\":");
        lpf_json_str(f, R[k].where);
        fprintf(f, ",\"peak_bytes\":%lld,\"peak_objects\":%lld,\"exit_bytes\":%lld,\"exit_objects\":%lld,"
                   "\"max_bytes\":%lld,\"made_objects\":%llu,\"made_bytes\":%llu,\"unseen_objects\":%llu,"
                   "\"unseen_bytes\":%llu,\"growing\":%s,\"growth\":{\"from\":%lld,\"to\":%lld,\"rises\":%u,"
                   "\"steps\":%u},\"series\":[",
                (long long)R[k].peak_b, (long long)R[k].peak_n, (long long)R[k].exit_b, (long long)R[k].exit_n,
                (long long)R[k].max_b, (unsigned long long)R[k].made_n, (unsigned long long)R[k].made_b,
                (unsigned long long)R[k].unseen_n, (unsigned long long)R[k].unseen_b,
                R[k].trend.growing ? "true" : "false", (long long)R[k].trend.from, (long long)R[k].trend.to,
                R[k].trend.rises, R[k].trend.steps);
        for (uint32_t q = 0; q < lpf_ret_nser; q++) fprintf(f, "%s%lld", q ? "," : "", (long long)R[k].ser[q]);
        fprintf(f, "]}");
    }
    free(R);
    fprintf(f, "],\"walks\":[");
    int first = 1;
    if (lpf_ret_peak_walk != NULL) {
        lpf_ret_json_walk(f, lpf_ret_peak_walk, tick);
        first = 0;
    }
    for (unsigned k = 0; k < lpf_ret_nsnaps; k++) {
        if (!first) fputc(',', f);
        lpf_ret_json_walk(f, lpf_ret_snaps[k], tick);
        first = 0;
    }
    if (lpf_ret_exit_walk != NULL) {
        if (!first) fputc(',', f);
        lpf_ret_json_walk(f, lpf_ret_exit_walk, tick);
    }
    fprintf(f, "],\"walks_skipped\":%u,\"peak_walk\":\"%s\",\"snapshots_dropped\":%u}", lpf_ret_walks_skipped,
            lpf_ret_peak_walk != NULL ? "taken"
            : !lpf_ret_auto           ? "off"
            : LP_LD(lpf_ret_shared) ? "threads"
                                         : "small",
            lpf_ret_snaps_dropped);
}
