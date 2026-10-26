/*
 * leanprof runtime: scope timing, copy detection and the exit report.
 *
 * Each thread records into its own tables, so the hot path takes no lock.
 * Tables are registered once in a global list and merged at exit.
 */
#define _GNU_SOURCE /* dladdr on glibc */
#include <lean/lean.h>

/* Lean 4.33 added lean_internal_get_rc (an atomic load under TSan); before,
 * the count was read from the field. */
#if LEAN_VERSION_MAJOR == 4 && LEAN_VERSION_MINOR < 33
static inline int lean_internal_get_rc(lean_object *o) { return o->m_rc; }
#endif

#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach_time.h>
#endif

#define LP_TABLE 32768     /* slots per thread table, power of two (pages are touched lazily) */
/* Tables stop taking new keys at 7/8 full: open addressing stays fast, and a
 * full table costs a short probe instead of a scan of every slot. */
#define LP_TABLE_LIMIT (LP_TABLE / 8 * 7)
#define LP_DEPTH 512       /* scope frames per thread to start with; the stack grows */
#define LP_DEPTH_MAX (1u << 22) /* deepest scope nesting we keep frames for */
#define LP_SUB 16          /* histogram sub-buckets per power of two */
#define LP_BUCKETS (64 * LP_SUB)
#define LP_TRACE_LIMIT (1u << 28) /* events per thread at most (LEANPROF_TRACE_MAX): 8 GiB */

/* Records other threads read while their owner runs (the live thread in
 * live.inc.c, the queries below) are published with release stores, and
 * their counters written with relaxed atomic stores: on every target the same
 * plain store, but race-free, since only the owning thread writes them. */
#define LP_LD(x) __atomic_load_n(&(x), __ATOMIC_RELAXED)
#define LP_ST(x, v) __atomic_store_n(&(x), (v), __ATOMIC_RELAXED)
#define LP_ADD(x, v) LP_ST(x, (x) + (v))
#define LP_PUBLISH(slot, p) __atomic_store_n(&(slot), (p), __ATOMIC_RELEASE)
#define LP_GET(slot) __atomic_load_n(&(slot), __ATOMIC_ACQUIRE)

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

/* How a scope is entered. Each way costs differently (`Leanprof.scope`
 * allocates and applies a closure, `--auto` calls a hook from every
 * function), so calibration measures each one (see calibration).
 * LP_PATH_PURE is what `profile!` on a pure term compiles to: a call before
 * the term and one after it, with no closure (see leanprof_enter_pure). */
enum { LP_PATH_DIRECT, LP_PATH_HOOK, LP_PATH_SCOPE, LP_PATH_ENTER, LP_PATH_PURE, LP_PATHS };

typedef struct {
    /* What every enter and exit touches comes first, in the first two cache
     * lines (scopes are 64-byte aligned). */
    const void *key;
    uint8_t kind;              /* LP_LABEL, LP_FN, or LP_INTERNAL (calibration) */
    uint8_t path;              /* LP_PATH_*: how it is entered */
    uint8_t parent_kind;       /* LP_TASK: kind of the spawning scope (set before it is published) */
    uint8_t light;             /* too small to time every call: most calls are only counted (see lpf_light_check) */
    uint32_t active;           /* recursion depth, so totals count the outermost call */
    /* Raw times. `sum` is every call's own duration, `total` only outermost
     * calls (recursion). Overhead is removed at report time: `kids` and
     * `desc_sum`/`desc_total` are the overhead of direct children and of all
     * descendants (over all and over outermost calls), in 1/1024 of a direct
     * enter/exit pair (lpf_w_pair, lpf_w_kid); `outer` outermost calls;
     * `fwd` entries that were not calls (one C function of a declaration
     * calling another of the same declaration, such as `f___boxed` -> `f`). */
    uint64_t calls, total, self, sum, kids, desc_sum, desc_total, outer, fwd, min, max;
    /* Calls only counted, not timed (`light`): all of them, and outermost
     * ones; `est`, in 1/1024 ticks per call (a light call can take less than
     * one tick of a 24 MHz clock), is what each adds to its caller's time in
     * children (the timed calls' mean), so the caller's self time does not
     * take it in. `self` is a sum of differences that can be negative (a
     * light child cheaper than its estimate): read it signed (lpf_signed).
     * `chk_*`: the totals at the last lpf_light_check. */
    uint64_t lcalls, louter, est;
    uint64_t chk_total, chk_desc, chk_outer;
    /* The part of the sums above from calls timed while the scope was light:
     * a sample of about one call in LP_LIGHT_EVERY, kept apart from the calls
     * timed before it went light, which were all timed (lpf_light_est). */
    uint64_t st_total, st_desc_total, st_outer, st_self, st_kids, st_calls, st_fwd, st_sum, st_desc_sum;
    /* The scope it was first called from in a sampled light call (an
     * lpf_scope; lpf_exit_sampled), whose row the report marks as holding it;
     * and this scope's row in the report (1-based, 0 when it has none). */
    const void *lparent;
    uint32_t row;
    /* allocations (LEANPROF_ALLOCS builds): made while this scope was the
     * innermost (self), and including children over outermost calls (total) */
    uint64_t allocs_self, bytes_self, allocs_total, bytes_total;
    uint64_t wait, wait_max;   /* LP_TASK: time from spawn to start */
    /* LP_FN: the C function's name up to the first compiler-generated part
     * (`f___boxed`, `f___redArg`, `f___lam__0` are all `f`), hashed. All C
     * functions of one Lean declaration share one scope (see lpf_scope_get). */
    uint64_t decl;
    /* per call, overhead removed; 64-bit: a hot scope fills a 32-bit bucket
     * in about a minute, and wrapped buckets gave percentiles of 0 */
    uint64_t hist[LP_BUCKETS];
} lpf_scope;

typedef struct {
    void *pc;                  /* return address inside the copying function */
    const lean_object *site;   /* innermost scope at the time, or NULL */
    uint8_t kind;
    uint64_t count[LP_REASONS];
    uint64_t bytes, ticks;     /* ticks: time spent in the copying call */
} lpf_copy;

/* An open scope: one cache line (frames are 64-byte aligned). Deep
 * recursion keeps a frame per level, and at 104 bytes over two lines the
 * frames of 10,000 levels under `--auto` no longer fitted a 1 MiB L2. */
typedef struct {
    lpf_scope *scope;
    const void *key;           /* the key it was entered with (an alias of scope's, for LP_FN) */
    const void *label;         /* the innermost `profile!` label from this frame down, or NULL */
    uint64_t start;
    uint64_t child;            /* raw time in direct children, in 1/1024 ticks (see `est`) */
    uint64_t kids, desc;       /* overhead of direct children and of all completed
                                * descendants, in 1/1024 of a direct pair */
    uint8_t traced;            /* its begin event was recorded */
    uint8_t path;              /* LP_PATH_* */
    uint8_t fwd;               /* not a call: forwarded within one declaration */
    uint8_t counted;           /* allocations are counted (lpf_aframe) */
    uint8_t light;             /* only counted: no clock reads, `start` and `child` unused */
    uint8_t sampled;           /* timed while its scope was light: one of a sample */
} lpf_frame;
_Static_assert(sizeof(lpf_frame) == 64, "a frame is one cache line");

/* Allocations of an open frame (only once the program has made one through
 * leanprof's shims, `counted`), beside the frame stack: the thread's counts
 * when the frame opened, and what its completed children made. Without the
 * shims nothing here is touched, which was 2.5 ns of a 22 ns scope. */
typedef struct {
    uint64_t allocs0, bytes0;
    uint64_t allocs_kids, bytes_kids;
} lpf_aframe;

/* Timeline events, recorded only with LEANPROF_TRACE. */
typedef struct {
    const void *key;           /* scope key, or the copying pc */
    uint64_t ts, bytes;
    uint8_t ph, kind;          /* ph: 'B' begin, 'E' end, 'C' copy; kind: scope or copy kind */
} lpf_event;

typedef struct lpf_thread {
    /* scopes by key: several keys (the C functions of one declaration) can
     * map to one scope, so the key is kept beside it */
    const void *keys[LP_TABLE];
    lpf_scope *scopes[LP_TABLE];
    lpf_scope *decls[LP_TABLE]; /* LP_FN scopes by `decl` */
    lpf_copy *copies[LP_TABLE];
    size_t nscopes, ncopies;   /* keys in each table */
    /* Open scopes. The stack grows (to LP_DEPTH_MAX): with a fixed depth,
     * frames past it were not recorded, so deep recursion lost calls and its
     * overhead was left in the deepest recorded scope. */
    lpf_frame *stack;
    lpf_aframe *astack;        /* allocations per frame, `acap` of them (allocated when first needed) */
    uint32_t cap, acap;
    uint8_t nogrow;            /* growing failed once: frames from `cap` on are not kept */
    uint32_t depth;
    uint64_t allocs, bytes;    /* allocations made through the shims on this thread */
    uint64_t dropped;
    uint64_t pairs;            /* probe cost of completed outermost frames, in 1/1024 of a direct pair */
    lpf_event *events;
    size_t nevents, capevents;
    uint64_t events_dropped;
    uint8_t task_parent_kind;  /* lpf_task_run: the spawning scope's kind, for the task's scope and begin event */
    uint32_t id;               /* registration order, the trace's tid */
    uint32_t lcount;           /* light scopes entered before the next one is timed */
    uint64_t lrand;            /* xorshift state for lcount */
    /* The thread's records in the other parts (counters, memory, flight
     * recorder, explain) are kept with these: when the thread exits, all of
     * them go to the next new thread (lpf_thread_retire). */
    struct lpf_ctr_thread *ctr;
    struct lpf_mem_thread *mem;
    struct lpf_flight_thread *flight;
    void *shares;
    struct lpf_thread *free_next;
    uint8_t selfcheck;         /* the self-check is running: copies go to selfcheck_seen, not the report */
    uint32_t selfcheck_seen[LP_KINDS];
    struct lpf_thread *next;
} lpf_thread;

static _Thread_local lpf_thread *lpf_self;
static lpf_thread *lpf_threads;
static lpf_thread *lpf_free_threads; /* records of exited threads (under lpf_lock) */
static uint32_t lpf_nthreads;
static int lpf_tracing;                /* LEANPROF_TRACE is set */
static size_t lpf_trace_max = 1u << 20; /* events per thread, LEANPROF_TRACE_MAX */
static pthread_mutex_t lpf_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t lpf_start;

/* Calibration, in 1/1024 ticks, per way of entering a scope: `lpf_inner` is
 * what an empty scope measures itself, `lpf_pair` what a whole enter/exit
 * pair adds to the scope around it. Frames add up their descendants'
 * overhead as weights relative to the direct pair, fixed at the first
 * calibration (`lpf_w_pair`, and `lpf_w_kid` for the part outside the
 * child's own time), so that the report can still use the lower estimate the
 * calibration at exit finds: the ratios do not change with the clock speed. */
static uint64_t lpf_inner_fp[LP_PATHS], lpf_pair_fp[LP_PATHS];
/* (until the first calibration ends, which other threads may not wait for:
 * every pair counts as a direct one, half of it outside the child) */
static uint64_t lpf_w_pair[LP_PATHS] = {1024, 1024, 1024, 1024, 1024}, lpf_w_kid[LP_PATHS] = {512, 512, 512, 512, 512};
/* the part of a pair inside the scope's own time, in the same units (0 until
 * the first calibration: before it nothing is subtracted) */
static uint64_t lpf_w_inner[LP_PATHS];
/* A light call (lpf_light_check): what its enter/exit pair costs, all of it
 * outside any timed scope, in 1/1024 ticks and as a weight like lpf_w_pair */
static uint64_t lpf_light_fp[LP_PATHS], lpf_w_light[LP_PATHS];
static int lpf_light_ok; /* scopes may go light: calibrated, no timeline, LEANPROF_TIME_ALL unset */
static int lpf_weighted; /* weights set by the first calibration */
static int lpf_calibrated; /* first calibration started (atomic) */
/* One calibration at a time (first use, queries, exit); the hot path and the
 * live thread read the results with relaxed loads while it writes them. */
static pthread_mutex_t lpf_cal_lock = PTHREAD_MUTEX_INITIALIZER;
static void lpf_calibrate(void);

static void lpf_label_name(const char *label, char *out, size_t cap);

/* ---------- clock ---------- */

/* On Apple Silicon, mach_absolute_time reads the self-synchronizing
 * counter (CNTVCTSS_EL0), which waits for every earlier instruction to
 * finish: in real code that is most of a probe's cost, since each scope reads
 * the clock twice. leanprof reads the same 24 MHz counter (CNTVCT_EL0)
 * without waiting. The read may then happen a few cycles early, at both ends
 * of a scope alike, so durations are not biased; calibration measures the
 * probes with the same reads. LEANPROF_SYNC_CLOCK restores the old read.
 *
 * On Linux, clock_gettime goes through the vDSO: about 18 ns a read on a
 * Ryzen 7950X3D, two thirds of a scope. Where the kernel itself keeps time
 * with the CPU's counter (clocksource `tsc` on x86-64, `arch_sys_counter` on
 * arm64), leanprof reads that counter directly (RDTSC, 7 ns; CNTVCT_EL0),
 * unordered as on macOS. The kernel only uses the TSC when it is invariant
 * and synchronized between cores, and leanprof also checks the CPU's
 * invariant-TSC bit. The TSC's rate is measured against CLOCK_MONOTONIC (see
 * lpf_ns_per_tick). Anything else, or LEANPROF_CLOCK=monotonic, keeps
 * clock_gettime(CLOCK_MONOTONIC). */
#if defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__)) && !defined(LEANPROF_SYNC_CLOCK)
#define LP_LINUX_COUNTER 1
#if defined(__x86_64__)
#include <cpuid.h>
#include <x86intrin.h>
#endif
static int lpf_counter;            /* read the CPU's counter (set once, in lpf_clock_init) */
static uint64_t lpf_cal_mono, lpf_cal_ticks; /* CLOCK_MONOTONIC and the counter, read together */
static uint64_t lpf_tick_bits;     /* ns per tick (a double's bits), 0 until measured */
static double lpf_tick_rough;      /* the same over 50 µs at startup, for intervals and thresholds */
#endif

#ifndef __APPLE__
/* not inlined: its address-taken timespec put a stack check into every
 * function that reads the clock */
static __attribute__((noinline)) uint64_t lpf_mono_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
#endif

#ifdef LP_LINUX_COUNTER
static inline uint64_t lpf_counter_read(void) {
#if defined(__x86_64__)
    return __rdtsc();
#else
    uint64_t v;
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(v) : : "memory");
    return v;
#endif
}
#endif

static inline uint64_t lpf_now(void) {
#if defined(__APPLE__) && defined(__aarch64__) && !defined(LEANPROF_SYNC_CLOCK)
    uint64_t v;
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(v) : : "memory");
    return v;
#elif defined(__APPLE__)
    return mach_absolute_time();
#else
#ifdef LP_LINUX_COUNTER
    if (LEAN_LIKELY(lpf_counter)) return lpf_counter_read();
#endif
    return lpf_mono_ns();
#endif
}

#ifdef LP_LINUX_COUNTER
/* Before the first lpf_now (a constructor): whether to read the counter. */
static void lpf_clock_init(void) {
    const char *force = getenv("LEANPROF_CLOCK");
    if (force != NULL && strcmp(force, "monotonic") == 0) return;
    char cs[64] = {0};
    FILE *f = fopen("/sys/devices/system/clocksource/clocksource0/current_clocksource", "r");
    if (f == NULL) return;
    if (fgets(cs, sizeof cs, f) == NULL) cs[0] = 0;
    fclose(f);
    cs[strcspn(cs, "\n")] = 0;
#if defined(__x86_64__)
    unsigned ea, eb, ec, ed;
    /* CPUID 0x80000007, EDX bit 8: invariant TSC (constant rate, runs in deep sleep) */
    if (strcmp(cs, "tsc") != 0 || __get_cpuid_max(0x80000000u, NULL) < 0x80000007u) return;
    __cpuid(0x80000007u, ea, eb, ec, ed);
    (void)ea; (void)eb; (void)ec;
    if (!(ed & (1u << 8))) return;
#else
    if (strcmp(cs, "arch_sys_counter") != 0) return;
    uint64_t hz;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(hz));
    if (hz == 0) return;
    double t = 1e9 / (double)hz; /* the counter's rate is known: nothing to measure */
    memcpy(&lpf_tick_bits, &t, sizeof t);
    lpf_tick_rough = t;
#endif
    lpf_cal_mono = lpf_mono_ns();
    lpf_cal_ticks = lpf_counter_read();
#if defined(__x86_64__)
    uint64_t m;
    while ((m = lpf_mono_ns()) - lpf_cal_mono < 50000) {}
    uint64_t c = lpf_counter_read();
    if (c <= lpf_cal_ticks) return;
    lpf_tick_rough = (double)(m - lpf_cal_mono) / (double)(c - lpf_cal_ticks);
#endif
    lpf_counter = 1;
}
#else
static void lpf_clock_init(void) {}
#endif

static double lpf_ns_per_tick(void) {
#if defined(__APPLE__) && defined(__aarch64__) && !defined(LEANPROF_SYNC_CLOCK)
    uint64_t hz;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(hz));
    if (hz > 0) return 1e9 / (double)hz;
#endif
#ifdef __APPLE__
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (double)tb.numer / (double)tb.denom;
#else
#ifdef LP_LINUX_COUNTER
    if (lpf_counter) {
        double t;
        uint64_t bits = __atomic_load_n(&lpf_tick_bits, __ATOMIC_RELAXED);
        if (bits != 0) {
            memcpy(&t, &bits, sizeof t);
            return t;
        }
        /* The TSC's rate, over at least 5 ms since startup (most programs
         * have run that long by their first scope; otherwise this waits):
         * a read pair is within ~30 ns, so the rate is within 1e-5. The
         * clock reads between the counter reads bound the pair's skew. */
        uint64_t m0, m1, c;
        do {
            m0 = lpf_mono_ns();
            c = lpf_counter_read();
            m1 = lpf_mono_ns();
        } while (m0 - lpf_cal_mono < 5000000ull || m1 - m0 > 1000);
        t = ((double)(m0 - lpf_cal_mono) + (double)(m1 - m0) / 2) / (double)(c - lpf_cal_ticks);
        memcpy(&bits, &t, sizeof t);
        uint64_t zero = 0; /* the first thread to measure wins: every conversion uses one rate */
        if (!__atomic_compare_exchange_n(&lpf_tick_bits, &zero, bits, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED))
            memcpy(&t, &zero, sizeof t);
        return t;
    }
#endif
    return 1.0;
#endif
}

/* For intervals and thresholds, which need not wait for the measured rate
 * (on Linux with the TSC, within ~0.1%). */
static double lpf_ns_per_tick_rough(void) {
#ifdef LP_LINUX_COUNTER
    if (lpf_counter && lpf_tick_rough > 0) {
        uint64_t bits = __atomic_load_n(&lpf_tick_bits, __ATOMIC_RELAXED);
        double t;
        memcpy(&t, &bits, sizeof t);
        return bits != 0 ? t : lpf_tick_rough;
    }
#endif
    return lpf_ns_per_tick();
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

/* Over the timed calls, which the histogram holds (a light scope's are a
 * sample of its calls). */
static uint64_t lpf_percentile(const uint64_t *hist, double q) {
    uint64_t calls = 0, seen = 0;
    for (uint32_t b = 0; b < LP_BUCKETS; b++) calls += hist[b];
    uint64_t want = (uint64_t)(q * (double)calls);
    for (uint32_t b = 0; b < LP_BUCKETS; b++) {
        seen += hist[b];
        if (seen > want) return lpf_bucket_low(b);
    }
    return 0;
}

/* ---------- per-thread state ---------- */

static void lpf_thread_retire(void *p);
static pthread_key_t lpf_key; /* its destructor runs lpf_thread_retire when a thread exits */
static pthread_once_t lpf_key_once = PTHREAD_ONCE_INIT;
static void lpf_key_init(void) { pthread_key_create(&lpf_key, lpf_thread_retire); }

static __attribute__((noinline)) lpf_thread *lpf_thread_new(void) {
    lpf_thread *t;
    /* An exited thread's records are reused. Kept per thread, they grew
     * without bound with a new thread per dedicated task: about 1 MiB of
     * tables each, and 8 MiB more with the flight recorder on. */
    pthread_once(&lpf_key_once, lpf_key_init);
    pthread_mutex_lock(&lpf_lock);
    t = lpf_free_threads;
    if (t != NULL) lpf_free_threads = t->free_next;
    pthread_mutex_unlock(&lpf_lock);
    if (t == NULL) {
        t = calloc(1, sizeof(lpf_thread));
        if (t == NULL) abort();
        t->stack = aligned_alloc(64, LP_DEPTH * sizeof(lpf_frame));
        if (t->stack == NULL) abort();
        memset(t->stack, 0, LP_DEPTH * sizeof(lpf_frame));
        t->cap = LP_DEPTH;
        pthread_mutex_lock(&lpf_lock);
        t->id = lpf_nthreads;
        LP_ST(lpf_nthreads, t->id + 1);
        t->next = lpf_threads;
        LP_PUBLISH(lpf_threads, t); /* the live thread walks the list without the lock */
        pthread_mutex_unlock(&lpf_lock);
    }
    lpf_self = t;
    pthread_setspecific(lpf_key, t);
    return t;
}

static inline lpf_thread *lpf_thread_get(void) {
    lpf_thread *t = lpf_self;
    return LEAN_LIKELY(t != NULL) ? t : lpf_thread_new();
}

static double lpf_inner_ticks(const lpf_scope *s);
static double lpf_unit_ticks(void);
/* What a light scope's timed calls are multiplied by to stand for all of
 * its calls (lpf_light_check): `timed` calls, `light` more only counted. */
static double lpf_scale(uint64_t timed, uint64_t light) {
    return timed > 0 ? (double)(timed + light) / (double)timed : 1.0;
}
/* A sum of differences kept modulo 2^64 (a scope's `self`), as a signed number. */
static double lpf_signed(uint64_t v) { return (double)(int64_t)v; }
/* A light scope's time from its timed calls: `all` over every timed call
 * (`n` of them), `sampled` over those timed while it was light (`ns`), and
 * `light` calls only counted. The sample stands for itself and the light
 * calls; the calls timed before it went light stand for themselves (scaling
 * every timed call alike weighed those, all of a phase, like the sample of a
 * later and maybe costlier one). */
static double lpf_light_est(double all, double sampled, uint64_t n, uint64_t ns, uint64_t light) {
    if (light == 0) return all;
    if (ns > 0) return all + sampled * (double)light / (double)ns;
    return lpf_scale(n, light) * all;
}
/* A scope's times with leanprof's own cost removed, its light calls
 * included (in ticks; may be below 0): over outermost calls, as self time,
 * and over every call; and what its probes cost (lpf_report). */
static double lpf_total_est(const lpf_scope *s) {
    double inner = lpf_inner_ticks(s), unit = lpf_unit_ticks();
    return lpf_light_est(
        (double)LP_LD(s->total) - (double)LP_LD(s->outer) * inner - (double)LP_LD(s->desc_total) * unit,
        (double)LP_LD(s->st_total) - (double)LP_LD(s->st_outer) * inner - (double)LP_LD(s->st_desc_total) * unit,
        LP_LD(s->outer), LP_LD(s->st_outer), LP_LD(s->louter));
}
static double lpf_self_est(const lpf_scope *s) {
    double inner = lpf_inner_ticks(s), unit = lpf_unit_ticks();
    return lpf_light_est(
        lpf_signed(LP_LD(s->self)) - (double)(LP_LD(s->calls) + LP_LD(s->fwd)) * inner - (double)LP_LD(s->kids) * unit,
        lpf_signed(LP_LD(s->st_self)) - (double)(LP_LD(s->st_calls) + LP_LD(s->st_fwd)) * inner -
            (double)LP_LD(s->st_kids) * unit,
        LP_LD(s->calls), LP_LD(s->st_calls), LP_LD(s->lcalls));
}
static double lpf_sum_est(const lpf_scope *s) {
    double inner = lpf_inner_ticks(s), unit = lpf_unit_ticks();
    return lpf_light_est(
        (double)LP_LD(s->sum) - (double)LP_LD(s->calls) * inner - (double)LP_LD(s->desc_sum) * unit,
        (double)LP_LD(s->st_sum) - (double)LP_LD(s->st_calls) * inner - (double)LP_LD(s->st_desc_sum) * unit,
        LP_LD(s->calls), LP_LD(s->st_calls), LP_LD(s->lcalls));
}
static double lpf_probes_est(const lpf_scope *s) {
    double pair = (double)LP_LD(lpf_pair_fp[s->path]) / 1024.0, unit = lpf_unit_ticks();
    return lpf_light_est((double)LP_LD(s->outer) * pair + (double)LP_LD(s->desc_total) * unit,
                         (double)LP_LD(s->st_outer) * pair + (double)LP_LD(s->st_desc_total) * unit,
                         LP_LD(s->outer), LP_LD(s->st_outer), LP_LD(s->louter));
}
/* Copy rows of empty or tiny values (lpf_tiny below; live snapshots mark
 * them the same way, against the time so far) */
#define LP_TINY_BYTES 16
#define LP_TINY_SHARE 0.01
#include "live.inc.c" /* live snapshots (LEANPROF_LIVE), flight recorder (LEANPROF_FLIGHT, LEANPROF_SLOW_MS) */

/* Make room for frame `d`; 0 if the stack cannot grow.
 * The old stack is not freed: the live snapshot thread (live.inc.c) reads
 * other threads' stacks while they run, and must never see freed memory.
 * The stack only doubles, so what is kept is less than the final size. */
static __attribute__((noinline)) int lpf_grow(lpf_thread *t, uint32_t d) {
    uint32_t cap = t->cap * 2;
    if (cap > LP_DEPTH_MAX) cap = LP_DEPTH_MAX;
    lpf_frame *s = d < cap ? aligned_alloc(64, (size_t)cap * sizeof(lpf_frame)) : NULL;
    if (s == NULL) {
        t->nogrow = 1;
        return 0;
    }
    memcpy(s, t->stack, (size_t)t->cap * sizeof(lpf_frame));
    __atomic_store_n(&t->stack, s, __ATOMIC_RELEASE);
    t->cap = cap;
    return 1;
}

/* The allocation record of frame `d`, growing their stack to the frames'
 * (only the owning thread reads it); NULL when out of memory. */
static __attribute__((noinline)) lpf_aframe *lpf_aframe_grow(lpf_thread *t, uint32_t d) {
    uint32_t cap = t->cap;
    lpf_aframe *a = realloc(t->astack, (size_t)cap * sizeof(lpf_aframe));
    if (a == NULL) return NULL;
    t->astack = a;
    t->acap = cap;
    return &a[d];
}

static inline lpf_aframe *lpf_aframe_at(lpf_thread *t, uint32_t d) {
    return LEAN_LIKELY(d < t->acap) ? &t->astack[d] : lpf_aframe_grow(t, d);
}

/* Append a timeline event. Begin events stop short of the limit by the
 * frames open, so every recorded begin can still get its end. */
static __attribute__((noinline)) int lpf_trace(lpf_thread *t, uint8_t ph, const void *key, uint8_t kind, uint64_t ts, uint64_t bytes) {
    if (LEAN_UNLIKELY(lpf_flight)) return lpf_flight_trace(t, ph, key, kind, ts, bytes);
    size_t reserve = (size_t)t->depth + 1;
    size_t limit = ph == 'E' ? lpf_trace_max : (lpf_trace_max > reserve ? lpf_trace_max - reserve : 0);
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

/* ---------- symbols ----------
 * Names of code addresses. dladdr scans the whole symbol table on every
 * call: a Lean executable linked with -rdynamic has hundreds of thousands of
 * symbols (the standard library), so one call took ~0.3 ms, and `--auto`
 * spent most of its time there (once per function seen, and again for every
 * row of the report). The main executable's symbols are read once into a
 * sorted table instead; addresses outside it fall back to dladdr. */

typedef struct {
    uintptr_t addr;
    const char *name;
} lpf_sym;

static lpf_sym *lpf_syms;
static size_t lpf_nsyms;
static uintptr_t lpf_text_lo, lpf_text_hi; /* the main executable's code */
static pthread_once_t lpf_syms_once = PTHREAD_ONCE_INIT;

static int lpf_sym_cmp(const void *a, const void *b) {
    const lpf_sym *x = a, *y = b;
    return x->addr < y->addr ? -1 : x->addr > y->addr ? 1 : 0;
}

static void lpf_syms_push(size_t *cap, uintptr_t addr, const char *name) {
    if (lpf_nsyms == *cap) {
        size_t c = *cap ? *cap * 2 : 65536;
        lpf_sym *v = realloc(lpf_syms, c * sizeof(lpf_sym));
        if (v == NULL) return;
        lpf_syms = v;
        *cap = c;
    }
    lpf_syms[lpf_nsyms++] = (lpf_sym){addr, name};
}

#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

static void lpf_syms_load(void) {
    /* the image leanprof is linked into (the executable; image 0 need not
     * be it when libraries are inserted, as samply does) */
    Dl_info self;
    if (!dladdr((const void *)lpf_syms_load, &self) || self.dli_fbase == NULL) return;
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
            if (strcmp(sg->segname, SEG_TEXT) == 0) {
                lpf_text_lo = slide + sg->vmaddr;
                lpf_text_hi = lpf_text_lo + sg->vmsize;
            }
        } else if (lc->cmd == LC_SYMTAB) {
            st = (const struct symtab_command *)lc;
        }
    }
    if (linkedit == NULL || st == NULL || lpf_text_hi == 0) return;
    uintptr_t base = slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *nl = (const struct nlist_64 *)(base + st->symoff);
    const char *strs = (const char *)(base + st->stroff);
    size_t cap = 0;
    for (uint32_t k = 0; k < st->nsyms; k++) {
        if ((nl[k].n_type & N_STAB) || (nl[k].n_type & N_TYPE) != N_SECT || nl[k].n_un.n_strx == 0) continue;
        uintptr_t a = slide + nl[k].n_value;
        if (a < lpf_text_lo || a >= lpf_text_hi) continue;
        /* not read here: touching every name would page in the whole string table */
        lpf_syms_push(&cap, a, strs + nl[k].n_un.n_strx);
    }
}
#else
#include <elf.h>
#include <fcntl.h>
#include <link.h>
#include <sys/mman.h>
#include <sys/stat.h>

static int lpf_syms_main(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    /* the first object is the main program */
    for (int i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *p = &info->dlpi_phdr[i];
        if (p->p_type == PT_LOAD && (p->p_flags & PF_X)) {
            uintptr_t lo = info->dlpi_addr + p->p_vaddr, hi = lo + p->p_memsz;
            if (lpf_text_hi == 0 || lo < lpf_text_lo) lpf_text_lo = lo;
            if (hi > lpf_text_hi) lpf_text_hi = hi;
        }
    }
    *(uintptr_t *)data = info->dlpi_addr;
    return 1;
}

static void lpf_syms_load(void) {
    uintptr_t bias = 0;
    dl_iterate_phdr(lpf_syms_main, &bias);
    if (lpf_text_hi == 0) return;
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
    /* the full symbol table if the binary has one, else the dynamic one */
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
            (type != STT_FUNC && type != STT_NOTYPE))
            continue;
        uintptr_t a = bias + sy[i].st_value;
        if (a < lpf_text_lo || a >= lpf_text_hi) continue;
        lpf_syms_push(&cap, a, strs + sy[i].st_name);
    }
}
#endif

static void lpf_syms_init(void) {
    lpf_syms_load();
    if (lpf_nsyms == 0) {
        lpf_text_lo = lpf_text_hi = 0; /* dladdr for everything */
        return;
    }
    qsort(lpf_syms, lpf_nsyms, sizeof(lpf_sym), lpf_sym_cmp);
}

/* The name of the symbol containing `pc` (as dladdr names it), or NULL. */
static const char *lpf_sym_name(const void *pc) {
    pthread_once(&lpf_syms_once, lpf_syms_init);
    uintptr_t a = (uintptr_t)pc;
    if (a >= lpf_text_lo && a < lpf_text_hi) {
        size_t lo = 0, hi = lpf_nsyms; /* last symbol at or below a */
        while (lo < hi) {
            size_t mid = lo + (hi - lo) / 2;
            if (lpf_syms[mid].addr <= a) lo = mid + 1;
            else hi = mid;
        }
        if (lo > 0) {
            const char *nm = lpf_syms[lo - 1].name;
#ifdef __APPLE__
            if (nm[0] == '_') nm++; /* C names have a leading underscore; dladdr drops it too */
#endif
            return nm;
        }
    }
    Dl_info info;
    if (!dladdr(pc, &info)) return NULL;
    return info.dli_sname;
}

/* The Lean declaration a compiled function belongs to: its symbol up to the
 * first compiler-generated component (`f___boxed`, `f___redArg`,
 * `f___lam__0`, `f___closed__1` are all `f`; the demangler drops the same
 * parts, so they are one row of the report). Hashed; 0 when unknown. */
static uint64_t lpf_decl_of(const void *fn) {
    static const char *parts[] = {"lam__", "elam__", "closed__", "boxed", "redArg", "impl", "jp",
                                  "override", "unsafe__rec"};
    const char *s = lpf_sym_name(fn);
    if (s == NULL) return 0;
    const char *end = s + strlen(s);
    for (const char *p = strstr(s + 1, "___"); p != NULL && p < end; p = strstr(p + 1, "___")) {
        for (size_t k = 0; k < sizeof parts / sizeof parts[0]; k++)
            if (strncmp(p + 3, parts[k], strlen(parts[k])) == 0) { end = p; break; }
    }
    uint64_t h = 0xcbf29ce484222325ull;
    for (const char *p = s; p < end; p++) h = (h ^ (uint8_t)*p) * 0x100000001b3ull;
    return h | 1;
}

static lpf_scope *lpf_new_scope(const void *key, uint8_t kind, uint8_t path) {
    lpf_scope *s = aligned_alloc(64, (sizeof(lpf_scope) + 63) / 64 * 64);
    if (s == NULL) abort();
    memset(s, 0, sizeof(lpf_scope));
    s->key = key;
    s->kind = kind;
    s->path = path;
    s->min = UINT64_MAX;
    return s;
}

/* The scope for `key`, created on first use. In automatic mode the C
 * functions of one Lean declaration (a function, its boxed and reduced-arity
 * wrappers, its lambdas) share one scope: as separate scopes merged by name
 * in the report, a call through `f___boxed` counted twice, and the time of a
 * lambda run inside `f` twice. */
static __attribute__((noinline)) lpf_scope *lpf_scope_find(lpf_thread *t, const void *key, uint8_t kind,
                                                           uint8_t path, size_t i) {
    for (size_t n = 0; n < LP_TABLE; n++, i = (i + 1) & (LP_TABLE - 1)) {
        lpf_scope *s = t->scopes[i];
        if (LEAN_LIKELY(s != NULL && t->keys[i] == key && (s->kind == LP_TASK) == (kind == LP_TASK))) return s;
        if (s == NULL) {
            if (t->nscopes >= LP_TABLE_LIMIT) break;
            uint64_t decl = kind == LP_FN ? lpf_decl_of(key) : 0;
            if (decl != 0) {
                size_t j = (size_t)decl & (LP_TABLE - 1);
                for (size_t m = 0; m < LP_TABLE; m++, j = (j + 1) & (LP_TABLE - 1)) {
                    lpf_scope *c = t->decls[j];
                    if (c == NULL) {
                        s = t->decls[j] = lpf_new_scope(key, kind, path);
                        s->decl = decl;
                        break;
                    }
                    if (c->decl == decl) { s = c; break; } /* another function of the same declaration */
                }
            }
            if (s == NULL) {
                s = lpf_new_scope(key, kind, path);
                if (kind == LP_TASK) s->parent_kind = t->task_parent_kind;
            }
            t->keys[i] = key;
            LP_PUBLISH(t->scopes[i], s);
            t->nscopes++;
            return s;
        }
    }
    t->dropped++;
    return NULL;
}

static inline lpf_scope *lpf_scope_get(lpf_thread *t, const void *key, uint8_t kind, uint8_t path) {
    size_t i = lpf_hash(key, (const void *)(uintptr_t)(kind == LP_TASK));
    lpf_scope *s = t->scopes[i]; /* the first slot, nearly always */
    if (LEAN_LIKELY(s != NULL && t->keys[i] == key && (s->kind == LP_TASK) == (kind == LP_TASK))) return s;
    return lpf_scope_find(t, key, kind, path, i);
}

static lpf_copy *lpf_copy_get(lpf_thread *t, void *pc, const lean_object *site, uint8_t kind) {
    size_t i = lpf_hash(pc, site);
    for (size_t n = 0; n < LP_TABLE; n++, i = (i + 1) & (LP_TABLE - 1)) {
        lpf_copy *c = t->copies[i];
        if (c != NULL && c->pc == pc && c->site == site && c->kind == kind) return c;
        if (c == NULL) {
            if (t->ncopies >= LP_TABLE_LIMIT) break;
            c = calloc(1, sizeof(lpf_copy));
            if (c == NULL) abort();
            c->pc = pc;
            c->site = site;
            c->kind = kind;
            LP_PUBLISH(t->copies[i], c);
            t->ncopies++;
            return c;
        }
    }
    t->dropped++;
    return NULL;
}

/* ---------- scopes ---------- */

static int lpf_allocs_on; /* an allocation went through the shims (relaxed) */

/* Always inlined into the few functions that enter and exit scopes: a call
 * to a shared enter or exit pushed and popped half a dozen registers. */
#define LP_HOT __attribute__((no_instrument_function, always_inline)) static inline

/* Light scopes. A scope whose probes cost about as much as its calls
 * cannot be timed well (lpf_near_probe), and its probes, several times
 * the work of a 1 ns function, are what the subtraction gets wrong in
 * every scope around it. Every LP_LIGHT_WINDOW outermost calls such a
 * scope is checked; once it is near the probe cost (and not recursive) it
 * goes light: one call in about LP_LIGHT_EVERY, at random, is still timed,
 * and the rest are only counted, with no clock reads. Its time is the timed
 * calls' scaled up to all of them (lpf_scale); the light pairs' cost, a
 * fraction of a timed pair's, is subtracted from its callers like any other
 * probe. A light scope that grows past twice the threshold is timed again. */
#define LP_LIGHT_WINDOW 1024
#define LP_LIGHT_EVERY 64
#define LP_NEAR_PROBE 0.3
static __attribute__((noinline)) void lpf_light_check(lpf_scope *s) {
    uint64_t n = s->outer - s->chk_outer;
    double desc = (double)(s->desc_total - s->chk_desc), total = (double)(s->total - s->chk_total);
    s->chk_outer = s->outer;
    s->chk_desc = s->desc_total;
    s->chk_total = s->total;
    if (!LP_LD(lpf_light_ok) || s->kind == LP_INTERNAL || s->kind == LP_TASK || n == 0) return;
    double unit = lpf_unit_ticks();
    double probes = (double)n * (double)LP_LD(lpf_pair_fp[s->path]) / 1024.0 + desc * unit;
    double net = total - (double)n * lpf_inner_ticks(s) - desc * unit;
    if (s->light) {
        if (probes < LP_NEAR_PROBE / 2 * net) LP_ST(s->light, 0);
        else s->est = net > 0 ? (uint64_t)(net * 1024.0 / (double)n) : 0;
    } else if (s->calls == s->outer && probes >= LP_NEAR_PROBE * net) { /* never recursive */
        s->est = net > 0 ? (uint64_t)(net * 1024.0 / (double)n) : 0;
        LP_ST(s->light, 1);
    }
}

/* The next timed light call: about one in LP_LIGHT_EVERY, at random (a
 * fixed period could fall in step with a loop). Returns 0: this one. */
static __attribute__((noinline)) int lpf_light_reload(lpf_thread *t) {
    uint64_t x = t->lrand ? t->lrand : (uint64_t)(uintptr_t)t | 1;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    t->lrand = x;
    t->lcount = 1 + (uint32_t)(x % (2 * LP_LIGHT_EVERY - 1));
    return 0;
}

LP_HOT void lpf_enter(const void *key, uint8_t kind, uint8_t path) {
    /* Calibrate on first use, before any frame is open, so the cost lands in
     * no scope; programs that never profile never pay it. */
    if (LEAN_UNLIKELY(!__atomic_load_n(&lpf_calibrated, __ATOMIC_RELAXED)) && kind != LP_INTERNAL &&
        !__atomic_exchange_n(&lpf_calibrated, 1, __ATOMIC_ACQ_REL))
        lpf_calibrate();
    lpf_thread *t = lpf_thread_get();
    uint32_t d = t->depth;
    LP_ST(t->depth, d + 1);
    if (LEAN_UNLIKELY(d >= t->cap) && (t->nogrow || !lpf_grow(t, d))) return;
    lpf_scope *s = lpf_scope_get(t, key, kind, path);
    lpf_frame *f = &t->stack[d];
    /* One C function of a declaration entering another of the same one
     * (`f___boxed` -> `f`, `f` -> its lambda) continues the same call. */
    f->fwd = kind == LP_FN && s != NULL && d > 0 && t->stack[d - 1].scope == s && t->stack[d - 1].key != key;
    if (s != NULL) s->active++;
    LP_ST(f->scope, s); /* scope and start: read by the live thread */
    f->label = s != NULL && s->kind == LP_LABEL ? key : d > 0 ? t->stack[d - 1].label : NULL;
    f->key = key;
    f->path = path;
    f->kids = f->desc = 0;
    f->counted = (uint8_t)__atomic_load_n(&lpf_allocs_on, __ATOMIC_RELAXED);
    if (LEAN_UNLIKELY(f->counted)) {
        lpf_aframe *a = lpf_aframe_at(t, d);
        if (a == NULL) f->counted = 0;
        else {
            a->allocs0 = t->allocs;
            a->bytes0 = t->bytes;
            a->allocs_kids = a->bytes_kids = 0;
        }
    }
    /* A light scope: one call in about LP_LIGHT_EVERY is timed, picked at
     * random; the others are only counted. A call forwarded within one
     * declaration goes the way its first function's call went. */
    if (LEAN_UNLIKELY(s != NULL && s->light) &&
        (f->fwd ? t->stack[d - 1].light : t->lcount-- > 1 || lpf_light_reload(t))) {
        LP_ST(f->light, 1); /* read by the live thread */
        f->traced = 0;
        return;
    }
    LP_ST(f->light, 0);
    f->sampled = s != NULL && (f->fwd ? t->stack[d - 1].sampled : s->light);
    f->child = 0;
    uint64_t now = lpf_now();
    LP_ST(f->start, now);
    /* a task's begin event carries its spawning scope's kind from the start */
    f->traced = LEAN_UNLIKELY(lpf_tracing) && kind != LP_INTERNAL &&
                lpf_trace(t, 'B', key, kind == LP_TASK ? (uint8_t)(LP_TASK | t->task_parent_kind << 4) : kind, now, 0);
}

static inline uint64_t lpf_sub(uint64_t a, uint64_t b) { return a > b ? a - b : 0; }

static inline __attribute__((always_inline)) void lpf_mem_on_exit(lpf_scope *s, uint64_t start, uint64_t now); /* memory.inc.c */

/* A frame's allocations, when they are counted. */
static __attribute__((noinline)) void lpf_exit_allocs(lpf_thread *t, lpf_frame *f, lpf_scope *s, uint32_t d) {
    (void)f;
    lpf_aframe *a = &t->astack[d];
    uint64_t allocs = t->allocs - a->allocs0, bytes = t->bytes - a->bytes0; /* including children */
    if (d > 0 && t->stack[d - 1].counted) {
        a[-1].allocs_kids += allocs;
        a[-1].bytes_kids += bytes;
    }
    if (s == NULL) return;
    LP_ADD(s->allocs_self, allocs - a->allocs_kids);
    LP_ADD(s->bytes_self, bytes - a->bytes_kids);
    if (s->active == 0) { /* lpf_exit has already counted this call out */
        LP_ADD(s->allocs_total, allocs);
        LP_ADD(s->bytes_total, bytes);
    }
}

/* The exit of a light frame: count the call, and put what it cost in its
 * caller (the pair, all of it outside any timed scope, and the probes of
 * scopes inside it). */
LP_HOT void lpf_exit_light(lpf_thread *t, lpf_frame *f, uint32_t d) {
    lpf_scope *s = f->scope;
    uint64_t probes = LP_LD(lpf_w_light[f->path]) + f->desc;
    s->active--;
    if (LEAN_UNLIKELY(f->counted)) lpf_exit_allocs(t, f, s, d);
    /* read by the live thread and the queries: published like the other counters */
    if (s->active == 0) LP_ADD(s->louter, 1);
    if (!f->fwd) LP_ADD(s->lcalls, 1);
    if (d > 0) {
        lpf_frame *p = &t->stack[d - 1];
        if (!f->fwd) p->child += s->est;
        p->kids += probes;
        p->desc += probes;
    } else {
        t->pairs += probes;
    }
}

/* A call timed while its scope was light: its part of the sums, kept apart
 * (lpf_light_est); and the first scope it was sampled under, its caller
 * (`lparent`). */
static __attribute__((noinline)) void lpf_exit_sampled(lpf_scope *s, const lpf_frame *f, uint64_t raw,
                                                       const lpf_scope *caller) {
    if (LEAN_UNLIKELY(s->lparent == NULL) && caller != NULL && caller != s) LP_ST(s->lparent, caller);
    LP_ADD(s->st_self, raw - ((f->child + 512) >> 10));
    LP_ADD(s->st_kids, f->kids);
    if (s->active == 0) {
        LP_ADD(s->st_total, raw);
        LP_ADD(s->st_desc_total, f->desc);
        LP_ADD(s->st_outer, 1);
    }
    if (f->fwd) {
        LP_ADD(s->st_fwd, 1);
        return;
    }
    LP_ADD(s->st_calls, 1);
    LP_ADD(s->st_sum, raw);
    LP_ADD(s->st_desc_sum, f->desc);
}

LP_HOT void lpf_exit(void) {
    lpf_thread *t = lpf_self;
    if (t == NULL || t->depth == 0) return;
    uint32_t d = t->depth - 1;
    lpf_frame *f = &t->stack[d];
    if (LEAN_UNLIKELY(d < t->cap && f->light)) {
        LP_ST(t->depth, d);
        lpf_exit_light(t, f, d);
        return;
    }
    uint64_t now = lpf_now();
    LP_ST(t->depth, d);
    if (LEAN_UNLIKELY(d >= t->cap)) return;
    if (LEAN_UNLIKELY(f->traced)) lpf_trace(t, 'E', f->scope ? f->scope->key : NULL, 0, now, 0);
    uint64_t raw = now - f->start;
    if (d == 0 && (f->scope == NULL || f->scope->kind != LP_INTERNAL)) t->pairs += LP_LD(lpf_w_pair[f->path]) + f->desc;
    if (d > 0) {
        lpf_frame *p = &t->stack[d - 1];
        p->child += raw << 10;
        p->kids += LP_LD(lpf_w_kid[f->path]);
        p->desc += LP_LD(lpf_w_pair[f->path]) + f->desc;
    }
    lpf_scope *s = f->scope;
    if (s != NULL) s->active--;
    if (LEAN_UNLIKELY(f->counted)) lpf_exit_allocs(t, f, s, d);
    if (s == NULL) return;
    lpf_mem_on_exit(s, f->start, now);
    if (LEAN_UNLIKELY(f->sampled)) lpf_exit_sampled(s, f, raw, d > 0 ? t->stack[d - 1].scope : NULL);
    /* below 0 when light children were estimated at more than they took:
     * wraps, and is read back signed */
    LP_ADD(s->self, raw - ((f->child + 512) >> 10));
    LP_ADD(s->kids, f->kids);
    if (s->active == 0) {
        LP_ADD(s->total, raw);
        LP_ADD(s->desc_total, f->desc);
        LP_ADD(s->outer, 1);
    }
    if (f->fwd) {
        LP_ADD(s->fwd, 1);
        return;
    }
    LP_ADD(s->calls, 1);
    LP_ADD(s->sum, raw);
    LP_ADD(s->desc_sum, f->desc);
    /* per-call view for min/max/percentiles: clamped, so only approximate */
    uint64_t elapsed =
        lpf_sub(raw, ((LP_LD(lpf_inner_fp[f->path]) << 10) + f->desc * LP_LD(lpf_pair_fp[LP_PATH_DIRECT])) >> 20);
    if (elapsed < s->min) s->min = elapsed;
    if (elapsed > s->max) LP_ST(s->max, elapsed);
    LP_ADD(s->hist[lpf_bucket(elapsed)], 1);
    if (LEAN_UNLIKELY(s->active == 0 && (s->outer & (LP_LIGHT_WINDOW - 1)) == 0)) lpf_light_check(s);
}

/* `profile!` on a pure term: time `f ()`. `kind` is LP_INTERNAL when
 * calibration runs this same code. */
LP_HOT lean_obj_res lpf_scope_run(b_lean_obj_arg site, lean_obj_arg f,
                                                                                uint8_t kind) {
    lpf_enter(site, kind, LP_PATH_SCOPE);
    lean_object *r = lean_apply_1(f, lean_box(0));
    lpf_exit();
    return r;
}

/* ---------- automatic mode ----------
 * Code compiled with -finstrument-functions-after-inlining (see
 * scripts/leanprof-cc, LEANPROF_AUTO) calls these around every function. */

__attribute__((no_instrument_function)) LEAN_EXPORT void __cyg_profile_func_enter(void *fn, void *call_site) {
    (void)call_site;
    lpf_enter(fn, LP_FN, LP_PATH_HOOK);
}

__attribute__((no_instrument_function)) LEAN_EXPORT void __cyg_profile_func_exit(void *fn, void *call_site) {
    (void)fn;
    (void)call_site;
    lpf_exit();
}

/* ---------- calibration ----------
 * Each way of entering a scope is measured through the same code the
 * program runs: the hooks, `leanprof_enter`/`leanprof_exit`, and for a pure
 * `profile!` the closure it builds (allocated, applied and freed). The
 * calibration used to measure only the inlined enter/exit pair, which a pure
 * `profile!` exceeds by its closure and `--auto` by the call to the hook, so
 * tiny scopes were reported several times too slow. What remains unmeasured
 * depends on the program: boxing the scoped term's result or captured
 * scalars (a `UInt64` is allocated when it crosses the closure), and the
 * extra work around a hook call in an instrumented function. */

static char lpf_calibration_key[1 + LP_PATHS];

static lean_obj_res lpf_cal_noop(lean_obj_arg fixed, lean_obj_arg unit) {
    (void)fixed;
    (void)unit;
    return lean_box(0);
}
static __attribute__((noinline)) lean_obj_res lpf_cal_scope(b_lean_obj_arg key, lean_obj_arg f) {
    return lpf_scope_run(key, f, LP_INTERNAL);
}
static __attribute__((noinline)) void lpf_cal_hook_enter(void *fn, void *call_site) {
    (void)call_site;
    lpf_enter(fn, LP_INTERNAL, LP_PATH_HOOK);
}
static __attribute__((noinline)) void lpf_cal_hook_exit(void *fn, void *call_site) {
    (void)fn;
    (void)call_site;
    lpf_exit();
}
static __attribute__((noinline)) lean_obj_res lpf_cal_enter(b_lean_obj_arg key) {
    lpf_enter(key, LP_INTERNAL, LP_PATH_ENTER);
    return lean_box(0);
}
static __attribute__((noinline)) lean_obj_res lpf_cal_exit(lean_obj_arg unit) {
    (void)unit;
    lpf_exit();
    return lean_box(0);
}
static __attribute__((noinline)) uint64_t lpf_cal_enter_pure(lean_obj_arg site, b_lean_obj_arg key) {
    lean_dec(site);
    lpf_enter(key, LP_INTERNAL, LP_PATH_PURE);
    return 0;
}
static __attribute__((noinline)) uint64_t lpf_cal_exit_pure(uint64_t tok, uint64_t v) {
    (void)tok;
    lpf_exit();
    return v;
}

/* `n` empty scopes entered the way `path` enters them. */
static char lpf_calibration_light_key[LP_PATHS]; /* light scopes, one per path */

static __attribute__((noinline)) void lpf_cal_batch(int path, int n, void *k) {
    switch (path) {
    case LP_PATH_DIRECT:
        for (int i = 0; i < n; i++) {
            lpf_enter(k, LP_INTERNAL, LP_PATH_DIRECT);
            lpf_exit();
        }
        break;
    case LP_PATH_HOOK:
        for (int i = 0; i < n; i++) {
            lpf_cal_hook_enter(k, NULL);
            lpf_cal_hook_exit(k, NULL);
        }
        break;
    case LP_PATH_SCOPE:
        for (int i = 0; i < n; i++) {
            /* what `profile!` builds: a closure capturing one value */
            lean_object *c = lean_alloc_closure((void *)lpf_cal_noop, 2, 1);
            lean_closure_set(c, 0, lean_box(0));
            lean_dec(lpf_cal_scope((lean_object *)k, c));
        }
        break;
    case LP_PATH_ENTER:
        for (int i = 0; i < n; i++) lpf_cal_exit(lpf_cal_enter((lean_object *)k));
        break;
    case LP_PATH_PURE: {
        uint64_t v = 0;
        for (int i = 0; i < n; i++) v = lpf_cal_exit_pure(lpf_cal_enter_pure(lean_box(0), (lean_object *)k), v);
        break;
    }
    }
}

/* Measure one enter/exit pair per path. Noise only ever adds time, so after
 * a warm-up (the CPU may still be clocked down) keep the fastest of many
 * small batches. Runs at startup and again at exit, keeping the lower
 * estimate. */
static void lpf_calibrate(void) {
    const char *off = getenv("LEANPROF_NO_CALIBRATION");
    if (off != NULL && strcmp(off, "1") == 0) return;
    enum { BATCH = 2048, BATCHES = 48 };
    pthread_mutex_lock(&lpf_cal_lock);
    lpf_thread *t = lpf_thread_get();
    uint32_t depth = t->depth;
    /* A query inside an open scope: calibration's frames must not count as
     * that scope's children (they took its time and overhead units). */
    lpf_frame *up = depth > 0 && depth <= t->cap ? &t->stack[depth - 1] : NULL;
    uint64_t up_child = 0, up_kids = 0, up_desc = 0, up_allocs = 0, up_bytes = 0;
    if (up != NULL) {
        up_child = up->child;
        up_kids = up->kids;
        up_desc = up->desc;
        if (up->counted) {
            up_allocs = t->astack[depth - 1].allocs_kids;
            up_bytes = t->astack[depth - 1].bytes_kids;
        }
    }
    uint64_t best_pair[LP_PATHS], best_inner[LP_PATHS], best_light[LP_PATHS];
    /* light calls: their scopes are light from the start, and none is timed */
    uint32_t lcount = t->lcount;
    t->lcount = UINT32_MAX;
    for (int p = 0; p < LP_PATHS; p++) {
        lpf_scope *ls = lpf_scope_get(t, &lpf_calibration_light_key[p], LP_INTERNAL, (uint8_t)p);
        if (ls != NULL) ls->light = 1;
    }
    uint64_t warm_until = lpf_now() + (uint64_t)(3e6 / lpf_ns_per_tick_rough()); /* ~3 ms */
    lpf_enter(&lpf_calibration_key[0], LP_INTERNAL, LP_PATH_DIRECT); /* outer frame: sees the full pair cost */
    while (lpf_now() < warm_until)
        for (int p = 0; p < LP_PATHS; p++) {
            lpf_cal_batch(p, 64, &lpf_calibration_key[1 + p]);
            lpf_cal_batch(p, 64, &lpf_calibration_light_key[p]);
        }
    for (int p = 0; p < LP_PATHS; p++) {
        lpf_scope *inner = lpf_scope_get(t, &lpf_calibration_key[1 + p], LP_INTERNAL, (uint8_t)p);
        best_pair[p] = UINT64_MAX;
        best_inner[p] = 0;
        for (int b = 0; b < BATCHES; b++) {
            uint64_t sum0 = inner ? inner->sum : 0;
            uint64_t t0 = lpf_now();
            lpf_cal_batch(p, BATCH, &lpf_calibration_key[1 + p]);
            uint64_t pair = ((lpf_now() - t0) << 10) / BATCH;
            if (pair < best_pair[p]) {
                best_pair[p] = pair;
                best_inner[p] = inner ? ((inner->sum - sum0) << 10) / BATCH : 0;
            }
        }
        if (best_inner[p] > best_pair[p]) best_inner[p] = best_pair[p];
        best_light[p] = UINT64_MAX;
        for (int b = 0; b < BATCHES / 4; b++) { /* cheap pairs: fewer batches keep startup short */
            uint64_t t0 = lpf_now();
            lpf_cal_batch(p, BATCH, &lpf_calibration_light_key[p]);
            uint64_t pair = ((lpf_now() - t0) << 10) / BATCH;
            if (pair < best_light[p]) best_light[p] = pair;
        }
        if (best_light[p] > best_pair[p]) best_light[p] = best_pair[p];
    }
    lpf_exit();
    LP_ST(t->depth, depth);
    t->lcount = lcount;
    if (up != NULL) { /* the stack may have grown: the frame is in the current buffer */
        up = &t->stack[depth - 1];
        up->child = up_child;
        up->kids = up_kids;
        up->desc = up_desc;
        if (up->counted) {
            t->astack[depth - 1].allocs_kids = up_allocs;
            t->astack[depth - 1].bytes_kids = up_bytes;
        }
    }
    for (int p = 0; p < LP_PATHS; p++)
        if (lpf_pair_fp[p] == 0 || best_pair[p] < lpf_pair_fp[p]) {
            LP_ST(lpf_pair_fp[p], best_pair[p]);
            LP_ST(lpf_inner_fp[p], best_inner[p]);
        }
    for (int p = 0; p < LP_PATHS; p++)
        if (lpf_light_fp[p] == 0 || best_light[p] < lpf_light_fp[p]) LP_ST(lpf_light_fp[p], best_light[p]);
    if (!lpf_weighted && lpf_pair_fp[LP_PATH_DIRECT] > 0) {
        uint64_t base = lpf_pair_fp[LP_PATH_DIRECT];
        for (int p = 0; p < LP_PATHS; p++) {
            uint64_t w_pair = (lpf_pair_fp[p] << 10) / base;
            uint64_t w_inner = (lpf_inner_fp[p] << 10) / base;
            LP_ST(lpf_w_pair[p], w_pair);
            LP_ST(lpf_w_inner[p], w_inner);
            LP_ST(lpf_w_kid[p], w_pair - w_inner); /* exactly: see lpf_inner_ticks */
            LP_ST(lpf_w_light[p], (lpf_light_fp[p] << 10) / base);
        }
        lpf_weighted = 1;
        const char *all = getenv("LEANPROF_TIME_ALL");
        LP_ST(lpf_light_ok, !lpf_tracing && !(all != NULL && strcmp(all, "1") == 0));
    }
    pthread_mutex_unlock(&lpf_cal_lock);
}


/* The way most scopes were entered, whose pair cost the report and
 * `overheadNs` show. */
static int lpf_main_path(void) {
    uint64_t calls[LP_PATHS] = {0};
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_scope *s = LP_GET(t->scopes[i]);
            if (s != NULL && t->keys[i] == s->key && s->kind != LP_INTERNAL && s->kind != LP_TASK)
                calls[s->path] += LP_LD(s->calls);
        }
    int best = LP_PATH_PURE;
    for (int p = 0; p < LP_PATHS; p++)
        if (calls[p] > calls[best]) best = p;
    return best;
}

static double lpf_overhead_of(int path) { return (double)LP_LD(lpf_pair_fp[path]) / 1024.0 * lpf_ns_per_tick(); }

/* Queries refine the estimate (they are not on a hot path). */
LEAN_EXPORT double leanprof_overhead_ns(void) {
    __atomic_store_n(&lpf_calibrated, 1, __ATOMIC_RELEASE);
    lpf_calibrate();
    pthread_mutex_lock(&lpf_lock);
    int p = lpf_main_path();
    pthread_mutex_unlock(&lpf_lock);
    return lpf_overhead_of(p);
}

LEAN_EXPORT lean_obj_res leanprof_scope(b_lean_obj_arg site, lean_obj_arg f) {
    return lpf_scope_run(site, f, LP_LABEL);
}

LEAN_EXPORT lean_obj_res leanprof_enter(b_lean_obj_arg site) {
    lpf_enter(site, LP_LABEL, LP_PATH_ENTER);
    return lean_box(0);
}

LEAN_EXPORT lean_obj_res leanprof_exit(lean_obj_arg unit) {
    (void)unit;
    lpf_exit();
    return lean_box(0);
}

/* `profile!` on a pure term: `exitPure (enterPure site) e`. No closure is
 * built and nothing is boxed: the term runs between the two calls, its value
 * passes through `exit` unchanged (one variant per scalar type, so scalars
 * stay unboxed). The token only orders the calls. */
LEAN_EXPORT uint64_t leanprof_enter_pure(lean_obj_arg site, b_lean_obj_arg key) {
    lean_dec(site); /* a string literal: persistent, so this costs a compare */
    lpf_enter(key, LP_LABEL, LP_PATH_PURE);
    return 0;
}
#define LP_EXIT_PURE(name, T)                                    \
    LEAN_EXPORT T name(uint64_t tok, T v) {                      \
        (void)tok;                                               \
        lpf_exit();                                              \
        return v;                                                \
    }
LP_EXIT_PURE(leanprof_exit_pure, lean_object *)
LP_EXIT_PURE(leanprof_exit_pure_u8, uint8_t)
LP_EXIT_PURE(leanprof_exit_pure_u16, uint16_t)
LP_EXIT_PURE(leanprof_exit_pure_u32, uint32_t)
LP_EXIT_PURE(leanprof_exit_pure_u64, uint64_t)
LP_EXIT_PURE(leanprof_exit_pure_usize, size_t)
LP_EXIT_PURE(leanprof_exit_pure_f64, double)
LP_EXIT_PURE(leanprof_exit_pure_f32, float)


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

/* The innermost `profile!` scope's label (automatic-mode frames skipped),
 * kept in each frame: looking for it down the stack made every copy and
 * allocation cost the depth, quadratic in deep recursion under --auto. */
static inline const lean_object *lpf_site(const lpf_thread *t) {
    uint32_t d = t->depth < t->cap ? t->depth : t->cap;
    return d > 0 ? (const lean_object *)t->stack[d - 1].label : NULL;
}

static inline lpf_pending lpf_begin(void *pc, lean_object *o, uint8_t kind, size_t bytes) {
    lpf_pending p = {pc, kind, (uint8_t)lpf_reason(o), bytes, 0};
    p.start = lpf_now();
    return p;
}

static inline void lpf_end(const lpf_pending *p) {
    uint64_t elapsed = lpf_now() - p->start;
    lpf_thread *t = lpf_thread_get();
    if (LEAN_UNLIKELY(t->selfcheck)) { t->selfcheck_seen[p->kind]++; return; }
    const lean_object *site = lpf_site(t);
    if (LEAN_UNLIKELY(lpf_tracing)) lpf_trace(t, 'C', p->pc, p->kind, p->start, p->bytes);
    lpf_copy *c = lpf_copy_get(t, p->pc, site, p->kind);
    if (c == NULL) return;
    LP_ADD(c->count[p->reason], 1);
    LP_ADD(c->bytes, p->bytes);
    LP_ADD(c->ticks, elapsed);
}

static inline size_t lpf_sarray_bytes(lean_object *a) {
    return lean_sarray_size(a) * lean_sarray_elem_size(a);
}

#include "explain.inc.c"

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

/* Lean 4.28 added lean_copy_expand_array_nonlinear, behind Array.set! and the
 * other in-place updates. Before, lean.h's lean_copy_array called
 * lean_copy_expand_array itself (lean.h of later versions does not). */
#if LEAN_VERSION_MAJOR > 4 || (LEAN_VERSION_MAJOR == 4 && LEAN_VERSION_MINOR >= 28)
LEAN_EXPORT lean_obj_res leanprof_copy_expand_array_nonlinear(lean_obj_arg a, bool expand) {
    LP_COPY(LP_ARRAY, a, lean_array_size(a) * sizeof(void *), lean_copy_expand_array_nonlinear(a, expand));
}
#endif

LEAN_EXPORT lean_obj_res leanprof_copy_expand_array(lean_obj_arg a, bool expand) {
    LP_COPY(LP_ARRAY, a, lean_array_size(a) * sizeof(void *), lean_copy_expand_array(a, expand));
}

/* Lean 4.35 added non-linear copy gadgets for scalar arrays and strings. */
#if LEAN_VERSION_MAJOR > 4 || (LEAN_VERSION_MAJOR == 4 && LEAN_VERSION_MINOR >= 35)
LEAN_EXPORT lean_obj_res leanprof_copy_sarray_nonlinear(lean_obj_arg a, size_t cap) {
    LP_COPY(LP_SCALAR_ARRAY, a, lpf_sarray_bytes(a), lean_copy_sarray_nonlinear(a, cap));
}

LEAN_EXPORT lean_obj_res leanprof_copy_string_nonlinear(lean_obj_arg s, size_t cap) {
    LP_COPY(LP_STRING, s, lean_string_size(s), lean_copy_string_nonlinear(s, cap));
}
#else
/* Before, lean.h's ByteArray.set! and FloatArray.set! (lean_byte_array_uset,
 * lean_float_array_uset) copied with these. */
LEAN_EXPORT lean_obj_res leanprof_copy_byte_array(lean_obj_arg a) {
    LP_COPY(LP_SCALAR_ARRAY, a, lpf_sarray_bytes(a), lean_copy_byte_array(a));
}

LEAN_EXPORT lean_obj_res leanprof_copy_float_array(lean_obj_arg a) {
    LP_COPY(LP_SCALAR_ARRAY, a, lpf_sarray_bytes(a), lean_copy_float_array(a));
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

/* Lean 4.36 made lean_string_push inline: the in-place case is in the header
 * (renamed by the flag above, but no longer a call), and growing or copying is
 * in lean_string_push_cold. */
#if LEAN_VERSION_MAJOR > 4 || (LEAN_VERSION_MAJOR == 4 && LEAN_VERSION_MINOR >= 36)
LEAN_EXPORT lean_obj_res leanprof_string_push_cold(lean_obj_arg s, uint32_t c) {
    LP_MAYBE_COPY(LP_STRING, s, lean_string_size(s), lean_string_push_cold(s, c));
}
#endif

LEAN_EXPORT lean_obj_res leanprof_string_append(lean_obj_arg s1, b_lean_obj_arg s2) {
    LP_MAYBE_COPY(LP_STRING, s1, lean_string_size(s1), lean_string_append(s1, s2));
}

LEAN_EXPORT lean_obj_res leanprof_string_utf8_set(lean_obj_arg s, b_lean_obj_arg i, uint32_t c) {
    LP_MAYBE_COPY(LP_STRING, s, lean_string_size(s), lean_string_utf8_set(s, i, c));
}

/* ---------- self-check ----------
 * c/selfcheck.c is compiled with the copy flags, like the program's code.
 * Once, at exit (and for `leanprof doctor`), each of its operations runs on
 * a shared one-element value: the shims must see one copy each. A copy they
 * do not see means copies of that kind may be undercounted with this Lean
 * version (Lean 4.36 made lean_string_push inline, and String copies went
 * uncounted until leanprof also renamed lean_string_push_cold). The check's
 * copies go to per-thread counters (lpf_end), never into the report. It
 * costs six copies of one-element values and a few allocations. */
#include "selfcheck.h"

#ifndef LEAN_VERSION_STRING
#define LEAN_VERSION_STRING "?"
#endif

static const struct {
    uint8_t kind;
    const char *op, *call;
} lpf_sc_ops[LPS_OPS] = {
    [LPS_ARRAY_PUSH] = {LP_ARRAY, "Array.push", "lean_array_push"},
#if LEAN_VERSION_MAJOR == 4 && LEAN_VERSION_MINOR < 28
    [LPS_ARRAY_SET] = {LP_ARRAY, "Array.set!", "lean_copy_expand_array"},
#else
    [LPS_ARRAY_SET] = {LP_ARRAY, "Array.set!", "lean_copy_expand_array_nonlinear"},
#endif
#if LEAN_VERSION_MAJOR > 4 || (LEAN_VERSION_MAJOR == 4 && LEAN_VERSION_MINOR >= 36)
    [LPS_STRING_PUSH] = {LP_STRING, "String.push", "lean_string_push_cold"},
#else
    [LPS_STRING_PUSH] = {LP_STRING, "String.push", "lean_string_push"},
#endif
    [LPS_STRING_APPEND] = {LP_STRING, "String.append", "lean_string_append"},
    [LPS_BYTE_ARRAY_PUSH] = {LP_SCALAR_ARRAY, "ByteArray.push", "lean_byte_array_push"},
#if LEAN_VERSION_MAJOR > 4 || (LEAN_VERSION_MAJOR == 4 && LEAN_VERSION_MINOR >= 35)
    [LPS_BYTE_ARRAY_SET] = {LP_SCALAR_ARRAY, "ByteArray.set!", "lean_copy_sarray_nonlinear"},
#else
    [LPS_BYTE_ARRAY_SET] = {LP_SCALAR_ARRAY, "ByteArray.set!", "lean_copy_byte_array"},
#endif
};

static int lpf_sc_done;
static char lpf_sc_checked[256]; /* the operations run, for doctor */
static char lpf_sc_msg[768];     /* the warning; empty when every copy was seen */

static lean_object *lpf_sc_input(uint8_t kind) {
    if (kind == LP_ARRAY) return lean_array_push(lean_mk_empty_array_with_capacity(lean_box(2)), lean_box(0));
    if (kind == LP_STRING) return lean_mk_string("a");
    return lean_byte_array_push(lean_mk_empty_byte_array(lean_box(2)), 0);
}

static void lpf_sc_append(char *buf, size_t cap, const char *s) {
    size_t n = strlen(buf);
    if (n + 1 < cap) snprintf(buf + n, cap - n, "%s", s);
}

static void lpf_self_check(void) {
    if (__atomic_exchange_n(&lpf_sc_done, 1, __ATOMIC_ACQ_REL)) return;
    lpf_thread *t = lpf_thread_get();
    uint8_t missed[LPS_OPS] = {0};
    int any = 0;
    for (unsigned op = 0; op < LPS_OPS; op++) {
        uint8_t kind = lpf_sc_ops[op].kind;
        lean_object *x = lpf_sc_input(kind);
        lean_inc(x); /* shared: the operation must copy it */
        uint32_t before = t->selfcheck_seen[kind];
        t->selfcheck = 1;
        lean_object *r = leanprof_selfcheck_op(op, x);
        t->selfcheck = 0;
        lean_dec(x);
        if (r == NULL) continue; /* not in this Lean version */
        lean_dec(r);
        lpf_sc_append(lpf_sc_checked, sizeof lpf_sc_checked, lpf_sc_checked[0] ? ", " : "");
        lpf_sc_append(lpf_sc_checked, sizeof lpf_sc_checked, lpf_sc_ops[op].op);
        missed[op] = t->selfcheck_seen[kind] == before;
        any |= missed[op];
    }
    if (!any) return;
    /* "copies of String may be undercounted with Lean 4.36.0: ..." per kind */
    for (uint8_t kind = 0; kind < LP_KINDS; kind++) {
        int n = 0;
        for (unsigned op = 0; op < LPS_OPS; op++) {
            if (!missed[op] || lpf_sc_ops[op].kind != kind) continue;
            char part[192];
            if (n++ == 0)
                snprintf(part, sizeof part, "%scopies of %s may be undercounted with Lean %s: a known copy through %s (%s)",
                         lpf_sc_msg[0] ? "; " : "", lpf_kind_name[kind], LEAN_VERSION_STRING, lpf_sc_ops[op].op,
                         lpf_sc_ops[op].call);
            else
                snprintf(part, sizeof part, ", %s (%s)", lpf_sc_ops[op].op, lpf_sc_ops[op].call);
            lpf_sc_append(lpf_sc_msg, sizeof lpf_sc_msg, part);
        }
        if (n > 0) lpf_sc_append(lpf_sc_msg, sizeof lpf_sc_msg, " was not counted");
    }
    lpf_sc_append(lpf_sc_msg, sizeof lpf_sc_msg,
                  leanprof_selfcheck_flags()
                      ? " (leanprof's shims do not cover this Lean version; please report it at "
                        "https://github.com/unbalancedparentheses/leanprof/issues)"
                      : " (the self-check was compiled without leanprof's copy flags)");
}

/* The self-check's warning, or "" when every known copy was counted. */
LEAN_EXPORT lean_obj_res leanprof_self_check(void) {
    lpf_self_check();
    return lean_mk_string(lpf_sc_msg);
}

/* For `leanprof doctor`'s probe: the warning (or "") and what was checked. */
LEAN_EXPORT const char *leanprof_self_check_message(void) {
    lpf_self_check();
    return lpf_sc_msg;
}
LEAN_EXPORT const char *leanprof_self_check_ops(void) {
    lpf_self_check();
    return lpf_sc_checked;
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
    for (uint32_t k = t->depth < t->cap ? t->depth : t->cap; k > 0; k--) {
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
    /* known before the scope and its begin event exist: patching them after
     * lpf_enter raced with the live and flight readers that see both */
    t->task_parent_kind = parent_kind;
    lpf_enter(parent, LP_TASK, LP_PATH_DIRECT);
    uint32_t d = t->depth;
    if (d > 0 && d <= t->cap && t->stack[d - 1].scope != NULL) {
        lpf_scope *s = t->stack[d - 1].scope;
        uint64_t w = now > spawned ? now - spawned : 0;
        LP_ADD(s->wait, w);
        if (w > s->wait_max) LP_ST(s->wait_max, w);
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
    LP_ADD(c->count[0], 1);
    LP_ADD(c->ticks, elapsed);
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
    if (LEAN_UNLIKELY(!__atomic_load_n(&lpf_allocs_on, __ATOMIC_RELAXED)))
        __atomic_store_n(&lpf_allocs_on, 1, __ATOMIC_RELAXED);
    t->allocs++;
    t->bytes += sz;
    lpf_copy *c = lpf_copy_get(t, pc, lpf_site(t), LP_ALLOC);
    if (c == NULL) return;
    LP_ADD(c->count[0], 1);
    LP_ADD(c->bytes, sz);
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
#include "memory.inc.c" /* frees, memory over time */
#include "coverage.inc.c" /* Task.map/bind, IO.mapTask/bindTask; notes on --core */

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
#define LPF_NAME_MAX 256 /* nested specializations run to hundreds */
typedef struct {
    char text[4096];
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
    /* specializations made for other ones (`g._at_.(h._at_.f.spec_1).spec_2`)
     * nest: the user code they were made for is the last caller, `f` */
    int last = at;
    for (int i = at + 1; i < nm->n; i++)
        if (!nm->num[i] && strcmp(lpf_comp(nm, i), "_at_") == 0) last = i;
    int b = last + 1, e = b;
    while (e < nm->n && (nm->num[e] || !lpf_spec_end(lpf_comp(nm, e)))) e++;
    if (e == b) {
        lpf_show(nm, 0, at, out, cap);
        return;
    }
    char callee[512], caller[512];
    lpf_show(nm, 0, at, callee, sizeof callee);
    lpf_show(nm, b, e, caller, sizeof caller);
    snprintf(out, cap, "%s (in %s)", caller, callee);
}

/* `lp_<pkg>_<body>`: the package is the shortest prefix whose underscore
 * runs are all escapes (even length) and whose remainder can start a body. */
static void lpf_find_root_pkg(void);
static void lpf_mangle_module(const char *m, char *out, size_t cap);
static char lpf_root_pkg[256];

/* `rel` inside the project: the current directory, or LEANPROF_PROJECT when
 * the program runs elsewhere (`leanprof run --cwd`). */
static const char *lpf_proj_path(const char *rel, char *out, size_t cap) {
    const char *proj = getenv("LEANPROF_PROJECT");
    if (proj == NULL || proj[0] == 0 || rel[0] == '/') snprintf(out, cap, "%s", rel);
    else snprintf(out, cap, "%s/%s", proj, rel);
    return out;
}

/* Mangled names of the packages this project knows (its own, from the
 * lakefile, and each in .lake/packages): `lp_<pkg>_` is ambiguous when a
 * package name has escapes (`lean-compiler-backend` is `lean_x2dcompiler_x2dbackend`). */
static char lpf_pkgs[64][256];
static int lpf_npkgs = -1;
/* Read once, by whichever thread names a symbol first: the live thread, a
 * `demangle` or `whereIs` query, the report. */
static pthread_once_t lpf_pkgs_once = PTHREAD_ONCE_INIT;

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
    char path[1024];
    DIR *d = opendir(lpf_proj_path(".lake/packages", path, sizeof path));
    struct dirent *e;
    while (d != NULL && (e = readdir(d)) != NULL && lpf_npkgs < 64) {
        if (e->d_name[0] == '.') continue;
        lpf_mangle_pkg(e->d_name, lpf_pkgs[lpf_npkgs++], 256);
    }
    if (d != NULL) closedir(d);
}

static const char *lpf_skip_package(const char *s) {
    pthread_once(&lpf_pkgs_once, lpf_load_pkgs);
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
    char sym[4096];
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
    const char *nm = lpf_sym_name(pc);
    if (nm == NULL) snprintf(out, cap, "%p", pc);
    else snprintf(out, cap, "%s", nm);
}

static void lpf_symbol_name(void *pc, char *out, size_t cap) {
    const char *nm = lpf_sym_name(pc);
    if (nm == NULL) {
        snprintf(out, cap, "%p", pc);
        return;
    }
    lpf_demangle(nm, out, cap);
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
    char line[512];
    FILE *f = fopen(lpf_proj_path("lakefile.toml", line, sizeof line), "r");
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
    f = fopen(lpf_proj_path("lakefile.lean", line, sizeof line), "r");
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
/* The declaration index (lpf_where) is built on first use and rebuilt after
 * leanprof_set_symbols: one thread at a time (the live thread and a `whereIs`
 * query could both build it, reallocating the same array). */
static pthread_mutex_t lpf_where_lock = PTHREAD_MUTEX_INITIALIZER;

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
    for (size_t i = 0; i < n; i++)
        if ((v[i] = strdup(lean_string_cstr(lean_array_get_core(names, i)))) == NULL) {
            n = i; /* out of memory: the names so far (qsort must not see a NULL) */
            break;
        }
    qsort(v, n, sizeof(char *), lpf_cmp_str);
    pthread_mutex_lock(&lpf_where_lock);
    lpf_symbols = v;
    lpf_nsymbols = n;
    lpf_indexed = 0; /* re-index against these symbols */
    pthread_mutex_unlock(&lpf_where_lock);
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

/* The directory of `module`'s source in the package at `prefix`: the package
 * itself, or a library's `srcDir` one level down (`src/`, `scripts/`, ...),
 * found by looking for the file. The last one found is tried first. */
static void lpf_source_dir(const char *prefix, const char *module, char *out, size_t cap) {
    static char last[1024], last_prefix[1024];
    char rel[512], path[2048], probe[1024];
    size_t n = 0;
    for (const char *m = module; *m && n + 7 < sizeof rel; m++) rel[n++] = *m == '.' ? '/' : *m;
    memcpy(rel + n, ".lean", 6);
    snprintf(out, cap, "%s", prefix);
    snprintf(probe, sizeof probe, "%s%s", prefix, rel);
    if (access(lpf_proj_path(probe, path, sizeof path), F_OK) == 0) return;
    if (last[0] && strcmp(last_prefix, prefix) == 0) {
        snprintf(probe, sizeof probe, "%s%s", last, rel);
        if (access(lpf_proj_path(probe, path, sizeof path), F_OK) == 0) {
            snprintf(out, cap, "%s", last);
            return;
        }
    }
    DIR *d = opendir(lpf_proj_path(prefix[0] ? prefix : ".", path, sizeof path));
    struct dirent *e;
    while (d != NULL && (e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        snprintf(probe, sizeof probe, "%s%s/%s", prefix, e->d_name, rel);
        if (access(lpf_proj_path(probe, path, sizeof path), F_OK) == 0) {
            snprintf(out, cap, "%s%s/", prefix, e->d_name);
            snprintf(last, sizeof last, "%s", out);
            snprintf(last_prefix, sizeof last_prefix, "%s", prefix);
            break;
        }
    }
    if (d != NULL) closedir(d);
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
    char src[1024];
    lpf_source_dir(prefix, module, src, sizeof src);
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
        lpf_add_decl(name, src, module, (k >= 5 ? v[4] : v[0]) + 1);
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

/* Lean's own declarations (Init, Std, Lean, Lake): their `.ilean` files are in
 * a toolchain's lib/lean and their sources in its src/lean. They are read on
 * the first name the project does not know, from the toolchain prefix that
 * leanprof_set_core_dir or LEANPROF_CORE_DIR gives (`leanprof sample`, `run`). */
static char lpf_core_dir[1024];
static int lpf_core_indexed;

LEAN_EXPORT lean_obj_res leanprof_set_core_dir(b_lean_obj_arg dir) {
    snprintf(lpf_core_dir, sizeof lpf_core_dir, "%s", lean_string_cstr(dir));
    lpf_core_indexed = 0;
    return lean_box(0);
}

/* Index Lean's own declarations once; whether any were added. */
static int lpf_index_core(void) {
    if (lpf_core_indexed) return 0;
    lpf_core_indexed = 1;
    const char *dir = lpf_core_dir[0] ? lpf_core_dir : getenv("LEANPROF_CORE_DIR");
    if (dir == NULL || dir[0] == 0) return 0;
    char lib[1200], src[1200];
    snprintf(lib, sizeof lib, "%s/lib/lean", dir);
    snprintf(src, sizeof src, "%s/src/lean/", dir);
    size_t before = lpf_ndecls;
    lpf_index_dir(lib, src, NULL, 0);
    return lpf_ndecls > before;
}

/* file:line of a reported function name, or "" when unknown. */
static const char *lpf_where(const char *fn, char *out, size_t cap) {
    pthread_mutex_lock(&lpf_where_lock);
    if (!lpf_indexed) {
        lpf_indexed = 1;
        const char *dir = getenv("LEANPROF_ILEAN_DIR");
        if (dir && dir[0]) {
            lpf_index_dir(dir, "", NULL, 0);
        } else {
            /* this package, then each dependency Lake checked out */
            pthread_once(&lpf_pkgs_once, lpf_load_pkgs); /* finds the root package */
            char path[1024], prefix[1024];
            lpf_index_dir(lpf_proj_path(".lake/build/lib/lean", path, sizeof path), "", lpf_root_pkg, 0);
            DIR *d = opendir(lpf_proj_path(".lake/packages", path, sizeof path));
            struct dirent *e;
            while (d != NULL && (e = readdir(d)) != NULL) {
                if (e->d_name[0] == '.') continue;
                snprintf(prefix, sizeof prefix, ".lake/packages/%s/.lake/build/lib/lean", e->d_name);
                lpf_proj_path(prefix, path, sizeof path);
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
    for (int pass = 0; pass < 2 && out[0] == 0; pass++) {
        /* the second pass also looks among Lean's own declarations */
        if (pass == 1 && !lpf_index_core()) break;
        for (size_t i = 0; i < lpf_ndecls; i++) {
            if (strcmp(lpf_decls[i].name, name) == 0) {
                snprintf(out, cap, "%s:%u", lpf_decls[i].file, lpf_decls[i].line);
                break;
            }
        }
    }
    pthread_mutex_unlock(&lpf_where_lock);
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
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_copy *c = LP_GET(t->copies[i]); /* other threads may be adding records */
            if (c != NULL && c->kind < LP_KINDS) /* not waits or allocations */
                n += LP_LD(c->count[LP_SHARED]) + LP_LD(c->count[LP_MULTI_THREADED]);
        }
    pthread_mutex_unlock(&lpf_lock);
    return lean_uint64_to_nat(n);
}

/* Completed calls of scopes named `site` (positions ignored), on all
 * threads: all of them, or only the timed ones (a light scope's others are
 * only counted). */
static uint64_t lpf_calls_of(b_lean_obj_arg site, int timed) {
    const char *want = lean_string_cstr(site);
    char name[128];
    uint64_t n = 0;
    pthread_mutex_lock(&lpf_lock);
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_scope *sc = LP_GET(t->scopes[i]);
            if (sc == NULL || sc->kind != LP_LABEL) continue;
            lpf_label_name(lean_string_cstr((lean_object *)sc->key), name, sizeof name);
            if (strcmp(name, want) == 0) n += LP_LD(sc->calls) + (timed ? 0 : LP_LD(sc->lcalls));
        }
    pthread_mutex_unlock(&lpf_lock);
    return n;
}

LEAN_EXPORT lean_obj_res leanprof_calls(b_lean_obj_arg site) { return lean_uint64_to_nat(lpf_calls_of(site, 0)); }

LEAN_EXPORT lean_obj_res leanprof_timed_calls(b_lean_obj_arg site) { return lean_uint64_to_nat(lpf_calls_of(site, 1)); }

/* What a scope measures of its own bookkeeping per call, and what one unit
 * of the overhead weights in `kids`/`desc_*` is, in ticks. */
/* In the weights' units, like `kids` and `desc_*`, not from the latest
 * calibration: `self` subtracts (calls + fwd) inner parts plus the outside
 * parts of the direct children (`kids`), `total` one inner part per
 * outermost call plus every descendant's whole pair (`desc_total`). For a
 * recursive scope these are the same pairs counted two ways, and only agree
 * if inner + outside = pair in one set of units: with the inner part taken
 * from the calibration at exit and the rest from the weights fixed at the
 * first one, `fib` in copybug showed a self time larger than its total. */
static double lpf_inner_ticks(const lpf_scope *s) { return (double)LP_LD(lpf_w_inner[s->path]) * lpf_unit_ticks(); }
static double lpf_unit_ticks(void) { return (double)LP_LD(lpf_pair_fp[LP_PATH_DIRECT]) / (1024.0 * 1024.0); }

/* Total time of scopes named `site` (outermost calls, overhead removed), in
 * ns, on all threads. */
LEAN_EXPORT double leanprof_total_ns(b_lean_obj_arg site) {
    __atomic_store_n(&lpf_calibrated, 1, __ATOMIC_RELEASE);
    lpf_calibrate();
    const char *want = lean_string_cstr(site);
    char name[128];
    double ticks = 0;
    pthread_mutex_lock(&lpf_lock);
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_scope *sc = LP_GET(t->scopes[i]);
            if (sc == NULL || sc->kind != LP_LABEL) continue;
            lpf_label_name(lean_string_cstr((lean_object *)sc->key), name, sizeof name);
            if (strcmp(name, want) == 0) ticks += lpf_total_est(sc);
        }
    pthread_mutex_unlock(&lpf_lock);
    return ticks > 0 ? ticks * lpf_ns_per_tick() : 0;
}

/* Allocations recorded so far (LEANPROF_ALLOCS builds), on all threads. */
LEAN_EXPORT lean_obj_res leanprof_allocs(void) {
    uint64_t n = 0;
    pthread_mutex_lock(&lpf_lock);
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_copy *c = LP_GET(t->copies[i]);
            if (c != NULL && c->kind == LP_ALLOC) n += LP_LD(c->count[0]);
        }
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

/* `profile!` labels are "name\x1fFile.lean:line" ("name\x1f./File.lean:line"
 * with Lean before 4.31, see labelWithPos); older or hand-written ones have no
 * position. */
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
    if (!sep) return "";
    return sep[1] == '.' && sep[2] == '/' ? sep + 3 : sep + 1;
}

typedef struct {
    const char *label;         /* merge key: the label, or "\x01" + function name */
    char name[256], where[512];
    uint8_t is_fn, is_task;
    uint64_t wait, wait_max;   /* tasks: spawn to start */
    uint64_t allocs_self, bytes_self, allocs_total, bytes_total;
    uint64_t calls, total, self, sum, min, max;
    uint64_t timed;            /* calls timed: all but a light scope's untimed ones (lpf_light_check) */
    uint8_t light;             /* some calls were only counted: the times are the timed ones' scaled up */
    double probes;             /* ticks: probe cost in and around its outermost calls */
    char holds[256];           /* light scopes called from it, separated by LP_HOLDS_SEP (lpf_holds_add) */
    double lprobes;            /* ticks: what their only counted calls' probes cost (calibrated) */
    uint64_t hist[LP_BUCKETS];
} lpf_scope_sum;

/* A row is "near the probe cost" when the probes in and around its calls
 * (its own enter/exit pairs and its descendants') cost at least this share
 * of the time left after subtracting them: what the subtraction gets wrong,
 * a few ns per scope, is then a large part of its time. 0.3 is a function
 * that takes about three probe pairs per call (~25 ns on an M5 Max); in
 * bench/RESULTS.md the reported time of every component below that is off
 * by 10% to several times, and above it by noise only (see bench/README.md). */
static int lpf_near_probe(const lpf_scope_sum *s) {
    return !s->is_task && (s->light || (s->probes > 0 && s->probes >= LP_NEAR_PROBE * (double)s->total));
}

typedef struct {
    char fn[256], sym[256], scope[128], where[512];
    const char *label;
    uint8_t kind;
    uint64_t count[LP_REASONS], bytes, total, ticks;
} lpf_copy_sum;

/* A scope too small to time, called from row `r`: its probes change the code
 * of that row's scope (two calls around a nanosecond of work: in the benchmark
 * an empty pair cost 2.1 ns a call in one loop and 1.5 ns in another), by an
 * amount no calibration sees, so the row's time is off whatever is subtracted,
 * and a sample of the same build is off too (bench/README.md). */
#define LP_HOLDS_SEP '\x1e'
static void lpf_holds_add(lpf_scope_sum *r, const char *name) {
    size_t n = strlen(name), len = strlen(r->holds);
    for (const char *p = r->holds; *p;) { /* already listed (another thread's scope of the same name) */
        const char *e = strchr(p, LP_HOLDS_SEP);
        size_t m = e ? (size_t)(e - p) : strlen(p);
        if (m == n && strncmp(p, name, n) == 0) return;
        p += m + (e != NULL);
    }
    if (len + n + 2 > sizeof r->holds) return;
    if (len > 0) r->holds[len++] = LP_HOLDS_SEP;
    memcpy(r->holds + len, name, n + 1);
}
/* The row is marked when those probes are a large part of its time (like
 * lpf_near_probe): a row with real work around a few tiny calls is not. */
static int lpf_holds_tiny(const lpf_scope_sum *s) {
    return !s->is_task && s->holds[0] && s->lprobes >= LP_NEAR_PROBE * (double)s->total;
}

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

/* Times leanprof cannot tell from zero are never shown as 0. A scope's time
 * that is gone after subtracting the probes' cost is "< probe" (below what
 * the probes themselves cost); a copy or wait shorter than one clock tick is
 * "< tick" with the tick's length. */
#define LP_PROBE_LABEL "< probe"
static void lpf_fmt_scope_time(double ns, char *buf, size_t n) {
    if (ns < 0.5) snprintf(buf, n, LP_PROBE_LABEL);
    else lpf_fmt_time(ns, buf, n);
}
static void lpf_fmt_tick_time(double ns, double tick, char *buf, size_t n) {
    if (ns < 0.5) {
        char t[24];
        lpf_fmt_time(tick, t, sizeof t);
        snprintf(buf, n, "< %s", t);
    } else {
        lpf_fmt_time(ns, buf, n);
    }
}

/* The run that shares are against: the wall time without the probes'
 * calibrated cost (like the scopes' times), and never less than the longest
 * scope. */
static double lpf_run_base(const lpf_scope_sum *S, size_t ns, double tick, double wall);

/* A copy row of empty or tiny values: at most LP_TINY_BYTES per copy on
 * average (an empty array, an array of one or two elements, a short
 * string), such as the first push into an empty array slot, that took less
 * than LP_TINY_SHARE of the run. Such rows are summarized in one row unless
 * `--all-copies` (LEANPROF_ALL_COPIES=1, or LEANPROF_ALL=1) shows them. The
 * share matters: an empty array with a large capacity is copied with its
 * capacity, which can take long. (LP_TINY_BYTES and LP_TINY_SHARE are
 * defined above, before live.inc.c.) */
static double lpf_report_tick, lpf_report_base; /* set by lpf_report */
static int lpf_tiny(const lpf_copy_sum *c) {
    return c->kind < LP_KINDS && c->total > 0 && c->bytes <= (uint64_t)LP_TINY_BYTES * c->total &&
           (double)c->ticks * lpf_report_tick < LP_TINY_SHARE * lpf_report_base;
}

/* Calibrated cost of one small allocation and its free, in ns (set by
 * lpf_report when allocations were counted): an allocation site's time is
 * estimated as its count times this. Measured cache-warm on the reporting
 * thread, so it is a lower bound: the real cost adds cache misses on the
 * memory and the work of initializing it. */
static double lpf_alloc_ns;
static void lpf_calibrate_alloc(double tick) {
    enum { N = 512, R = 41 };
    static lean_object *v[N];
    double per[R];
    for (int r = 0; r < R; r++) {
        uint64_t t0 = lpf_now();
        for (int i = 0; i < N; i++) v[i] = lean_alloc_small_object(16 + 8 * (unsigned)(i % 7));
        for (int i = 0; i < N; i++) lean_free_small_object(v[i]);
        per[r] = (double)(lpf_now() - t0) * tick / N;
    }
    /* the median batch: the first ones warm the allocator's pages up */
    for (int a = 0; a < R; a++)
        for (int b = a + 1; b < R; b++)
            if (per[b] < per[a]) {
                double x = per[a];
                per[a] = per[b];
                per[b] = x;
            }
    lpf_alloc_ns = per[R / 2] > 0 ? per[R / 2] : tick;
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

/* The probes' own cost in the wall time: enter/exit pairs on the busiest
 * thread times the calibrated cost of a pair (set by lpf_report). */
static double lpf_probe_ns;

/* A share of the run, two decimals below 1% (a finding at 0.02% is not 0). */
static void lpf_fmt_pct(double pct, char *buf, size_t n) {
    snprintf(buf, n, pct < 1.0 ? "%.2f%%" : "%.1f%%", pct);
}

static double lpf_run_base(const lpf_scope_sum *S, size_t ns, double tick, double wall) {
    double base = wall - lpf_probe_ns;
    for (size_t k = 0; k < ns; k++)
        if (!S[k].is_task && (double)S[k].total * tick > base) base = (double)S[k].total * tick;
    return base;
}

/* Copies shown row by row: those of shared or multi-threaded values, unless
 * empty or tiny; with --all-copies (or LEANPROF_ALL=1) every row. */
static int lpf_all_copies(void) {
    const char *a = getenv("LEANPROF_ALL_COPIES");
    return lpf_show_all() || (a != NULL && strcmp(a, "1") == 0);
}

/* The allocation rows, costliest (estimated) first: count, then bytes. */
static int lpf_by_allocs(const void *a, const void *b) {
    const lpf_copy_sum *x = *(const lpf_copy_sum *const *)a, *y = *(const lpf_copy_sum *const *)b;
    if (x->total != y->total) return x->total < y->total ? 1 : -1;
    return x->bytes < y->bytes ? 1 : x->bytes > y->bytes ? -1 : 0;
}

/* Functions `--auto` left untimed as too small to time: each C file that
 * has some registers their addresses from a constructor
 * (scripts/leanprof-tiny.awk), before main and before any other thread. */
#define LP_UNTIMED_FILES 4096
static struct {
    void *const *fns;
    size_t n;
} lpf_untimed_files[LP_UNTIMED_FILES];
static size_t lpf_nuntimed_files, lpf_nuntimed_fns;

LEAN_EXPORT void leanprof_untimed_register(void *const *fns, size_t n) {
    if (lpf_nuntimed_files == LP_UNTIMED_FILES) return;
    lpf_untimed_files[lpf_nuntimed_files].fns = fns;
    lpf_untimed_files[lpf_nuntimed_files++].n = n;
    lpf_nuntimed_fns += n;
}

/* Their names, sorted, once. */
static char **lpf_untimed;
static size_t lpf_nuntimed;
static void lpf_untimed_load(void) {
    static int done;
    if (done) return;
    done = 1;
    if (lpf_nuntimed_fns == 0 || (lpf_untimed = calloc(lpf_nuntimed_fns, sizeof(char *))) == NULL) return;
    for (size_t k = 0; k < lpf_nuntimed_files; k++)
        for (size_t i = 0; i < lpf_untimed_files[k].n; i++) {
            char name[256];
            lpf_symbol_name(lpf_untimed_files[k].fns[i], name, sizeof name);
            if (name[0] && (lpf_untimed[lpf_nuntimed] = strdup(name)) != NULL) lpf_nuntimed++;
        }
    qsort(lpf_untimed, lpf_nuntimed, sizeof(char *), lpf_cmp_str);
    size_t m = 0; /* `f` and `f___boxed` are one name */
    for (size_t i = 0; i < lpf_nuntimed; i++) {
        if (m > 0 && strcmp(lpf_untimed[m - 1], lpf_untimed[i]) == 0) free(lpf_untimed[i]);
        else lpf_untimed[m++] = lpf_untimed[i];
    }
    lpf_nuntimed = m;
}

static void lpf_print(FILE *f, const lpf_scope_sum *S, size_t ns, const lpf_copy_sum *C, size_t nc, double tick,
                     double wall, uint64_t dropped) {
    char w[32], wp[32];
    lpf_fmt_time(wall, w, sizeof w);
    /* %wall is against the wall time without the probes, like the times */
    double base = lpf_run_base(S, ns, tick, wall);
    lpf_fmt_time(base, wp, sizeof wp);
    int any_fn = 0, any_small = 0;
    size_t ntasks = 0, nwaits = 0, nallocs = 0, nnear = 0;
    for (size_t k = 0; k < ns; k++) {
        any_fn |= S[k].is_fn;
        ntasks += S[k].is_task;
    }
    fprintf(f, "\nleanprof: %zu scopes, wall %s", ns - ntasks, w);
    if (lpf_probe_ns > 0.01 * wall) fprintf(f, " (%s without the probes' calibrated cost)", wp);
    fprintf(f, ", %.1f ns overhead per scope subtracted\n", lpf_overhead_of(lpf_main_path()));
    wall = base;
    for (size_t k = 0; k < nc; k++) {
        nwaits += C[k].kind == LP_WAIT;
        nallocs += C[k].kind == LP_ALLOC;
    }
    if (ns > ntasks) { /* tasks have their own table */
        fprintf(f, "\n%10s %10s %10s %6s %10s %10s %10s", "calls", "total", "self", "%wall", "mean", "p50", "p99");
        if (nallocs > 0) fprintf(f, " %10s %11s", "allocs", "alloc bytes");
        fprintf(f, "  %s\n", any_fn ? "function or \"scope\"  (where)" : "scope  (where)");
        for (size_t k = 0; k < ns; k++) {
            if (S[k].is_task) continue;
            char tt[32], st[32], mt[32], p50[32], p99[32];
            double v[5] = {(double)S[k].total * tick, (double)S[k].self * tick,
                           (double)S[k].sum * tick / (double)S[k].calls,
                           (double)lpf_percentile(S[k].hist, 0.50) * tick,
                           (double)lpf_percentile(S[k].hist, 0.99) * tick};
            for (int i = 0; i < 5; i++) any_small |= v[i] < 0.5;
            lpf_fmt_scope_time(v[0], tt, sizeof tt);
            if (lpf_near_probe(&S[k])) {
                strncat(tt, "*", sizeof tt - strlen(tt) - 1);
                nnear++;
            }
            lpf_fmt_scope_time(v[1], st, sizeof st);
            lpf_fmt_scope_time(v[2], mt, sizeof mt);
            lpf_fmt_scope_time(v[3], p50, sizeof p50);
            lpf_fmt_scope_time(v[4], p99, sizeof p99);
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
        if (nnear > 0)
            fprintf(f, "* near the probe cost: use `leanprof sample` for this function's time\n");
        /* rows holding scopes too small to time (lpf_holds_add), the largest three */
        char rows[400] = "", held[400] = "";
        size_t nholds = 0;
        for (size_t k = 0; k < ns; k++) {
            if (!lpf_holds_tiny(&S[k])) continue;
            if (nholds++ >= 3) continue;
            size_t m = strcspn(S[k].holds, "\x1e");
            size_t lr = strlen(rows), lh = strlen(held);
            snprintf(rows + lr, sizeof rows - lr, "%s%s", lr ? ", " : "", S[k].name);
            char one[130];
            snprintf(one, sizeof one, "%.*s", (int)(m < 128 ? m : 128), S[k].holds);
            int dup = 0; /* the same scope under several rows (one per thread, say) is named once */
            for (const char *p = held; *p && !dup; p += strcspn(p, ",") + (p[strcspn(p, ",")] ? 2 : 0))
                dup = strncmp(p, one, strlen(one)) == 0 && (p[strlen(one)] == ',' || p[strlen(one)] == 0);
            if (!dup) snprintf(held + lh, sizeof held - lh, "%s%s", lh ? ", " : "", one);
        }
        if (nholds > 0)
            fprintf(f,
                    "%s%s call%s scopes too small to time (%s): the calls around them change the code they sit in, "
                    "so %s time is off whatever leanprof subtracts, and so is a sample of this build; remove "
                    "those profile! (or `set_option leanprof.enabled false`) and use `leanprof sample`\n",
                    rows, nholds > 3 ? " and others" : "", nholds == 1 ? "s" : "", held,
                    nholds == 1 ? "its" : "their");
        /* self time also holds what runs inside a scope without probes: Lean's
           precompiled libraries, the C runtime, system calls */
        const lpf_scope_sum *big = NULL;
        for (size_t k = 0; k < ns; k++)
            if (!S[k].is_task && (big == NULL || S[k].self > big->self)) big = &S[k];
        if (big != NULL && wall > 0 && (double)big->self * tick >= 0.5 * wall)
            fprintf(f, "note: %.0f%% of the run is %s's self time, which includes the code it calls that "
                       "leanprof does not time (Lean's own libraries, system calls): `leanprof sample` "
                       "shows where it goes\n",
                    100.0 * (double)big->self * tick / wall, big->name);
        if (any_small)
            fprintf(f, "%s: less than the probes' own cost (%.1f ns per scope), too small to measure\n",
                    LP_PROBE_LABEL, lpf_overhead_of(lpf_main_path()));
    }
    int show_all = lpf_all_copies();
    size_t shown = 0, hidden = 0, ntiny = 0;
    uint64_t tiny_n = 0, tiny_b = 0, tiny_t = 0;
    for (size_t k = 0; k < nc; k++) {
        if (C[k].kind >= LP_KINDS) continue;
        if (!show_all && !lpf_interesting(&C[k])) hidden++;
        else if (!show_all && lpf_tiny(&C[k])) {
            ntiny++;
            tiny_n += C[k].count[LP_SHARED] + C[k].count[LP_MULTI_THREADED];
            tiny_b += C[k].bytes;
            tiny_t += C[k].ticks;
        } else shown++;
    }
    if (shown + ntiny > 0) {
        fprintf(f, "\ncopies of non-exclusive values (each one copied the whole value; costliest first)\n");
        fprintf(f, "%8s %11s %10s %6s %7s  %-11s %-14s %-18s %s\n", "copies", "bytes", "time", "%run", "%scope", "kind",
                "why", "in scope", "function  (where)");
        for (size_t k = 0; k < nc; k++) {
            if (C[k].kind >= LP_KINDS || (!show_all && (!lpf_interesting(&C[k]) || lpf_tiny(&C[k])))) continue;
            char bt[32], tt[32], share[16] = "-", why[64] = "";
            lpf_fmt_bytes((double)C[k].bytes, bt, sizeof bt);
            lpf_fmt_tick_time((double)C[k].ticks * tick, tick, tt, sizeof tt);
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
            char pr[16];
            lpf_fmt_pct(wall > 0 ? 100.0 * (double)C[k].ticks * tick / wall : 0.0, pr, sizeof pr);
            fprintf(f, "%8llu %11s %10s %6s %7s  %-11s %-14s %-18s %s", (unsigned long long)C[k].total, bt, tt, pr,
                    share, lpf_kind_name[C[k].kind], why, C[k].scope, C[k].fn);
            if (C[k].where[0]) fprintf(f, "  (%s)", C[k].where);
            fputc('\n', f);
        }
        if (ntiny > 0) {
            char bt[32], tt[32], pr[16];
            lpf_fmt_bytes((double)tiny_b, bt, sizeof bt);
            lpf_fmt_tick_time((double)tiny_t * tick, tick, tt, sizeof tt);
            lpf_fmt_pct(wall > 0 ? 100.0 * (double)tiny_t * tick / wall : 0.0, pr, sizeof pr);
            fprintf(f, "%8llu %11s %10s %6s %7s  %zu site%s copied only empty or tiny values (at most %d bytes "
                       "each, such as a first push into an empty array; under %.0f%% of the run each; "
                       "--all-copies shows them)\n",
                    (unsigned long long)tiny_n, bt, tt, pr, "-",
                    ntiny, ntiny == 1 ? "" : "s", LP_TINY_BYTES, LP_TINY_SHARE * 100);
        }
    }
    if (ntasks > 0) {
        fprintf(f, "\ntasks (run on worker threads; wait is spawn to start)\n");
        fprintf(f, "%8s %10s %10s %10s %10s  %s\n", "tasks", "run total", "run mean", "wait mean", "wait max",
                "spawned by");
        for (size_t k = 0; k < ns; k++) {
            if (!S[k].is_task) continue;
            char rt[32], rm[32], wm[32], wx[32];
            lpf_fmt_tick_time((double)S[k].total * tick, tick, rt, sizeof rt);
            lpf_fmt_tick_time((double)S[k].sum * tick / (double)S[k].calls, tick, rm, sizeof rm);
            lpf_fmt_tick_time((double)S[k].wait * tick / (double)S[k].calls, tick, wm, sizeof wm);
            lpf_fmt_tick_time((double)S[k].wait_max * tick, tick, wx, sizeof wx);
            fprintf(f, "%8llu %10s %10s %10s %10s  %s\n", (unsigned long long)S[k].calls, rt, rm, wm, wx,
                    S[k].name + 8 /* drop "task <- " */);
        }
    }
    if (nallocs > 0) {
        /* costliest (estimated) allocation sites first */
        const lpf_copy_sum **idx = malloc(nallocs * sizeof(*idx));
        size_t m = 0;
        for (size_t k = 0; k < nc && idx != NULL; k++)
            if (C[k].kind == LP_ALLOC) idx[m++] = &C[k];
        if (idx != NULL) qsort(idx, m, sizeof(*idx), lpf_by_allocs);
        uint64_t all_n = 0, all_b = 0;
        for (size_t a = 0; a < m; a++) {
            all_n += idx[a]->total;
            all_b += idx[a]->bytes;
        }
        char tb[32], te[32];
        lpf_fmt_bytes((double)all_b, tb, sizeof tb);
        lpf_fmt_time((double)all_n * lpf_alloc_ns, te, sizeof te);
        char ap[16];
        lpf_fmt_pct(wall > 0 ? 100.0 * (double)all_n * lpf_alloc_ns / wall : 0.0, ap, sizeof ap);
        fprintf(f, "\nallocations: %llu, %s, est. %s (%s of the run at %.1f ns each, allocation and free; "
                   "from compiled Lean code)\n",
                (unsigned long long)all_n, tb, te, ap, lpf_alloc_ns);
        fprintf(f, "%10s %11s %10s %6s  %-18s %s\n", "allocs", "bytes", "est. time", "%run", "in scope",
                "function  (where)");
        for (size_t a = 0; a < m && a < 20; a++) {
            const lpf_copy_sum *c = idx[a];
            char bb[32], et[32], pr[16];
            lpf_fmt_bytes((double)c->bytes, bb, sizeof bb);
            lpf_fmt_time((double)c->total * lpf_alloc_ns, et, sizeof et);
            lpf_fmt_pct(wall > 0 ? 100.0 * (double)c->total * lpf_alloc_ns / wall : 0.0, pr, sizeof pr);
            fprintf(f, "%10llu %11s %10s %6s  %-18s %s", (unsigned long long)c->total, bb, et, pr, c->scope, c->fn);
            if (c->where[0]) fprintf(f, "  (%s)", c->where);
            fputc('\n', f);
        }
        if (m > 20) fprintf(f, "(%zu more sites in the JSON report)\n", m - 20);
        free(idx);
    } else {
        fprintf(f, "\nallocations: not counted (`leanprof run --allocs` counts them, at a cost of about 6 ns per "
                   "allocation that is not subtracted from the times)\n");
    }
    if (nwaits > 0) {
        fprintf(f, "\nblocking waits (IO.wait, Task.get)\n");
        fprintf(f, "%8s %10s %10s  %-18s %s\n", "waits", "blocked", "mean", "in scope", "function  (where)");
        for (size_t k = 0; k < nc; k++) {
            if (C[k].kind != LP_WAIT) continue;
            char bt[32], mt[32];
            lpf_fmt_tick_time((double)C[k].ticks * tick, tick, bt, sizeof bt);
            lpf_fmt_tick_time((double)C[k].ticks * tick / (double)(C[k].total ? C[k].total : 1), tick, mt, sizeof mt);
            fprintf(f, "%8llu %10s %10s  %-18s %s", (unsigned long long)C[k].total, bt, mt, C[k].scope, C[k].fn);
            if (C[k].where[0]) fprintf(f, "  (%s)", C[k].where);
            fputc('\n', f);
        }
    }
    lpf_counters_print(f);
    lpf_mem_print(f, tick);
    if (hidden > 0)
        fprintf(f, "\nleanprof: %zu sites only copied compile-time constants (--all-copies shows them)\n", hidden);
    lpf_untimed_load();
    if (lpf_nuntimed > 0) {
        fprintf(f, "\nleanprof: %zu function%s too small to time left untimed (their time is in their callers'; "
                   "`leanprof sample` has their share, `run --auto --time-tiny` counts their calls):",
                lpf_nuntimed, lpf_nuntimed == 1 ? "" : "s");
        for (size_t i = 0; i < lpf_nuntimed && i < 8; i++) fprintf(f, "%s %s", i ? "," : "", lpf_untimed[i]);
        if (lpf_nuntimed > 8) fprintf(f, ", ... (%zu more in the JSON report)", lpf_nuntimed - 8);
        fputc('\n', f);
    }
    if (dropped > 0) fprintf(f, "\nleanprof: %llu events dropped (table full)\n", (unsigned long long)dropped);
    fprintf(f, "\n");
}

/* `,"too_small":["total_ns",...]`: the time fields too small to measure
 * (written as 0), when there are any. */
static void lpf_json_too_small(FILE *f, const char *const *names, const double *v, int n) {
    int any = 0;
    for (int i = 0; i < n; i++) {
        if (v[i] >= 0.5) continue;
        fprintf(f, "%s\"%s\"", any ? "," : ",\"too_small\":[", names[i]);
        any = 1;
    }
    if (any) fputc(']', f);
}

static void lpf_write_json(FILE *f, const lpf_scope_sum *S, size_t ns, const lpf_copy_sum *C, size_t nc, double tick,
                          double wall, uint64_t dropped) {
    double base = lpf_run_base(S, ns, tick, wall);
    fprintf(f, "{\"version\":3,\"wall_ns\":%.0f,\"probe_ns\":%.0f,\"overhead_ns\":%.1f,", wall, lpf_probe_ns, lpf_overhead_of(lpf_main_path()));
    fprintf(f, "\"run_ns\":%.0f,\"resolution_ns\":%.3f,", base, tick);
    if (lpf_alloc_ns > 0) fprintf(f, "\"alloc_ns\":%.2f,", lpf_alloc_ns);
    fprintf(f, "\"self_check\":{\"ok\":%s,\"lean\":", lpf_sc_msg[0] ? "false" : "true");
    lpf_json_str(f, LEAN_VERSION_STRING);
    fprintf(f, ",\"checked\":");
    lpf_json_str(f, lpf_sc_checked);
    fprintf(f, ",\"warning\":");
    lpf_json_str(f, lpf_sc_msg);
    fprintf(f, "},");
    fprintf(f, "\"overhead_by_path_ns\":{\"direct\":%.1f,\"auto\":%.1f,\"pure\":%.1f,\"closure\":%.1f,\"monadic\":%.1f},",
            lpf_overhead_of(LP_PATH_DIRECT), lpf_overhead_of(LP_PATH_HOOK), lpf_overhead_of(LP_PATH_PURE),
            lpf_overhead_of(LP_PATH_SCOPE), lpf_overhead_of(LP_PATH_ENTER));
    /* a light scope's untimed calls (lpf_light_check) */
    double lt = lpf_ns_per_tick() / 1024.0;
    fprintf(f, "\"light_overhead_by_path_ns\":{\"auto\":%.1f,\"pure\":%.1f,\"closure\":%.1f,\"monadic\":%.1f},",
            (double)lpf_light_fp[LP_PATH_HOOK] * lt, (double)lpf_light_fp[LP_PATH_PURE] * lt,
            (double)lpf_light_fp[LP_PATH_SCOPE] * lt, (double)lpf_light_fp[LP_PATH_ENTER] * lt);
    fprintf(f, "\"dropped\":%llu,\"scopes\":[", (unsigned long long)dropped);
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
                   "\"allocs_self\":%llu,\"alloc_bytes_self\":%llu,\"probes_ns\":%.0f,\"near_probe_cost\":%s",
                (unsigned long long)S[k].calls, (double)S[k].total * tick, (double)S[k].self * tick,
                (double)S[k].min * tick, (double)S[k].max * tick, (double)S[k].sum * tick / (double)S[k].calls,
                (double)lpf_percentile(S[k].hist, 0.50) * tick,
                (double)lpf_percentile(S[k].hist, 0.99) * tick, (unsigned long long)S[k].allocs_total,
                (unsigned long long)S[k].bytes_total, (unsigned long long)S[k].allocs_self,
                (unsigned long long)S[k].bytes_self, S[k].probes * tick, lpf_near_probe(&S[k]) ? "true" : "false");
        if (S[k].light) fprintf(f, ",\"timed_calls\":%llu", (unsigned long long)S[k].timed);
        if (lpf_holds_tiny(&S[k])) {
            fprintf(f, ",\"holds_tiny\":[");
            char buf[sizeof S[k].holds];
            memcpy(buf, S[k].holds, sizeof buf);
            int one = 1;
            for (char *p = buf; p != NULL;) {
                char *e = strchr(p, LP_HOLDS_SEP);
                if (e != NULL) *e = 0;
                if (!one) fputc(',', f);
                one = 0;
                lpf_json_str(f, p);
                p = e ? e + 1 : NULL;
            }
            fputc(']', f);
        }
        static const char *const tn[] = {"total_ns", "self_ns", "mean_ns", "p50_ns", "p99_ns"};
        double tv[] = {(double)S[k].total * tick, (double)S[k].self * tick, (double)S[k].sum * tick / (double)S[k].calls,
                       (double)lpf_percentile(S[k].hist, 0.50) * tick,
                       (double)lpf_percentile(S[k].hist, 0.99) * tick};
        lpf_json_too_small(f, tn, tv, 5);
        fputc('}', f);
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
        fprintf(f, ",\"allocs\":%llu,\"bytes\":%llu,\"est_ns\":%.0f,\"pct_run\":%.3f}", (unsigned long long)C[k].total,
                (unsigned long long)C[k].bytes, (double)C[k].total * lpf_alloc_ns,
                base > 0 ? 100.0 * (double)C[k].total * lpf_alloc_ns / base : 0.0);
    }
    fprintf(f, "],\"tasks\":[");
    first = 1;
    for (size_t k = 0; k < ns; k++) {
        if (!S[k].is_task) continue;
        fprintf(f, "%s{\"spawned_by\":", first ? "" : ",");
        first = 0;
        lpf_json_str(f, S[k].name + 8);
        fprintf(f, ",\"tasks\":%llu,\"run_total_ns\":%.0f,\"run_sum_ns\":%.0f,\"wait_ns\":%.0f,\"wait_max_ns\":%.0f",
                (unsigned long long)S[k].calls, (double)S[k].total * tick, (double)S[k].sum * tick,
                (double)S[k].wait * tick, (double)S[k].wait_max * tick);
        static const char *const tn[] = {"run_total_ns", "run_sum_ns", "wait_ns", "wait_max_ns"};
        double tv[] = {(double)S[k].total * tick, (double)S[k].sum * tick, (double)S[k].wait * tick,
                       (double)S[k].wait_max * tick};
        lpf_json_too_small(f, tn, tv, 4);
        fputc('}', f);
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
        fprintf(f, ",\"waits\":%llu,\"blocked_ns\":%.0f", (unsigned long long)C[k].total,
                (double)C[k].ticks * tick);
        static const char *const tn[] = {"blocked_ns"};
        double tv[] = {(double)C[k].ticks * tick};
        lpf_json_too_small(f, tn, tv, 1);
        fputc('}', f);
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
                   "\"multi_threaded\":%llu,\"persistent\":%llu,\"pct_run\":%.3f,\"tiny\":%s",
                lpf_kind_name[C[k].kind], (unsigned long long)C[k].total, (unsigned long long)C[k].bytes,
                (double)C[k].ticks * tick, (unsigned long long)C[k].count[LP_SHARED],
                (unsigned long long)C[k].count[LP_MULTI_THREADED], (unsigned long long)C[k].count[LP_PERSISTENT],
                base > 0 ? 100.0 * (double)C[k].ticks * tick / base : 0.0, lpf_tiny(&C[k]) ? "true" : "false");
        static const char *const tn[] = {"copy_ns"};
        double tv[] = {(double)C[k].ticks * tick};
        lpf_json_too_small(f, tn, tv, 1);
        fputc('}', f);
    }
    fprintf(f, "]");
    lpf_untimed_load();
    if (lpf_nuntimed > 0) {
        fprintf(f, ",\"untimed\":[");
        for (size_t i = 0; i < lpf_nuntimed; i++) {
            if (i) fputc(',', f);
            lpf_json_str(f, lpf_untimed[i]);
        }
        fputc(']', f);
    }
    lpf_counters_json(f);
    lpf_mem_json(f, tick);
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
    lpf_mem_trace(f, tick, &first);
    fprintf(f, "]}\n");
    int bad = ferror(f);
    if (fclose(f) != 0 || bad) fprintf(stderr, "leanprof: cannot write %s\n", path);
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
    if ((lpf_threads == NULL || (lpf_threads->next == NULL && lpf_only_calibrated())) && !lpf_ctr_any() &&
        !lpf_mem_wanted())
        return; /* linked but unused */
    lpf_mem_finish();
    __atomic_store_n(&lpf_calibrated, 1, __ATOMIC_RELEASE);
    lpf_calibrate(); /* the CPU is warm now; keeps the lower estimate */
    double tick = lpf_ns_per_tick();
    double wall = (double)(lpf_now() - lpf_start) * tick;
    lpf_self_check(); /* after the wall time: its ~20 µs are not the program's */
    uint64_t pairs = 0;
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next)
        if (t->pairs > pairs) pairs = t->pairs;
    lpf_probe_ns = (double)pairs * lpf_unit_ticks() * tick; /* `desc` was counted in 1/1024 of a pair */
    size_t ns = 0, nc = 0, cap_s = 64, cap_c = 64;
    uint64_t dropped = 0;
    lpf_scope_sum *S = calloc(cap_s, sizeof(lpf_scope_sum));
    lpf_copy_sum *C = calloc(cap_c, sizeof(lpf_copy_sum));
    if (S == NULL || C == NULL) {
        free(S);
        free(C);
        return;
    }

    pthread_mutex_lock(&lpf_lock);
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next) {
        dropped += t->dropped;
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_scope *s = t->scopes[i];
            if (s != NULL) s->row = 0;
            /* skip a declaration's other functions: they share its scope */
            if (s == NULL || t->keys[i] != s->key || s->calls == 0 || s->kind == LP_INTERNAL) continue;
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
                    /* out of memory: unlock, and free what was built (returning
                     * with lpf_lock held deadlocked any later query) */
                    lpf_scope_sum *S2 = realloc(S, 2 * cap_s * sizeof(lpf_scope_sum));
                    if (S2 == NULL) goto fail;
                    S = S2;
                    cap_s *= 2;
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
                if (S[k].label == NULL) goto fail;
                S[k].min = UINT64_MAX;
                ns++;
            }
            s->row = (uint32_t)k + 1;
            /* leanprof's own cost removed (see calibration); a light scope's
             * timed calls stand for all of them */
            S[k].calls += s->calls + s->lcalls;
            S[k].timed += s->calls;
            S[k].light |= s->lcalls > 0;
            /* the probes of its descendants, and its own whole pair (part of
             * which lands in its caller) */
            S[k].probes += lpf_probes_est(s);
            S[k].total += lpf_clamp(lpf_total_est(s));
            S[k].self += lpf_clamp(lpf_self_est(s));
            S[k].sum += lpf_clamp(lpf_sum_est(s));
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
                    lpf_copy_sum *C2 = realloc(C, 2 * cap_c * sizeof(lpf_copy_sum));
                    if (C2 == NULL) goto fail;
                    C = C2;
                    cap_c *= 2;
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
    /* the rows that call scopes too small to time (all rows are numbered now) */
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_scope *s = t->scopes[i];
            const lpf_scope *up = s != NULL ? LP_LD(s->lparent) : NULL;
            if (s == NULL || t->keys[i] != s->key || s->row == 0 || s->lcalls == 0 || up == NULL || up->row == 0 ||
                up->row == s->row)
                continue;
            lpf_holds_add(&S[up->row - 1], S[s->row - 1].name);
            S[up->row - 1].lprobes += (double)s->lcalls * (double)LP_LD(lpf_light_fp[s->path]) / 1024.0;
        }
    pthread_mutex_unlock(&lpf_lock);

    /* Self is total minus the children. When the children run for about what
     * their probes cost, subtracting the probes can leave them below zero, and
     * the parent's self above its total; that excess is subtraction error, not
     * time, so self stops at the total. */
    for (size_t k = 0; k < ns; k++)
        if (S[k].self > S[k].total) S[k].self = S[k].total;

    qsort(S, ns, sizeof(lpf_scope_sum), lpf_by_total);
    qsort(C, nc, sizeof(lpf_copy_sum), lpf_by_cost);
    for (size_t k = 0; k < nc; k++)
        if (C[k].kind == LP_ALLOC) {
            lpf_calibrate_alloc(tick);
            break;
        }
    lpf_report_tick = tick;
    lpf_report_base = lpf_run_base(S, ns, tick, wall);

    const char *quiet = getenv("LEANPROF_QUIET");
    if (quiet == NULL || strcmp(quiet, "1") != 0) lpf_print(stderr, S, ns, C, nc, tick, wall, dropped);
    if (lpf_sc_msg[0] && (quiet == NULL || strcmp(quiet, "1") != 0))
        fprintf(stderr, "leanprof: warning: %s\n", lpf_sc_msg);

    const char *trace = getenv("LEANPROF_TRACE");
    if (trace != NULL && trace[0] != 0) lpf_write_trace(trace, tick);

    const char *path = getenv("LEANPROF_JSON");
    if (path != NULL && path[0] != 0) {
        FILE *f = fopen(path, "w");
        if (f == NULL) {
            fprintf(stderr, "leanprof: cannot write %s\n", path);
        } else {
            lpf_write_json(f, S, ns, C, nc, tick, wall, dropped);
            int bad = ferror(f);
            if (fclose(f) != 0 || bad) fprintf(stderr, "leanprof: cannot write %s\n", path);
        }
    }
done:
    for (size_t k = 0; k < ns; k++)
        if (S[k].is_fn || S[k].is_task) free((void *)S[k].label);
    free(S);
    free(C);
    return;
fail:
    pthread_mutex_unlock(&lpf_lock);
    fprintf(stderr, "leanprof: out of memory for the report\n");
    goto done;
}

/* A thread exits (lpf_key's destructor): close the scopes it left open and
 * hand all its records to the next new thread (lpf_thread_get). They keep
 * their contents, which the report and the live view merge by name anyway,
 * and their id, so one timeline row can show several threads one after
 * another. Instrumented code running later on the exiting thread (another
 * key's destructor) gets a record again, and gives it back the same way. */
static void lpf_thread_retire(void *p) {
    lpf_thread *t = p;
    lpf_self = t; /* thread-local storage may already be torn down, and come back zeroed */
    while (t->depth > 0) lpf_exit();
    lpf_self = NULL;
    lpf_ctr_self = NULL;
    lpf_mem_self = NULL;
    lpf_flight_self = NULL;
    lpf_shares = NULL;
    pthread_mutex_lock(&lpf_lock);
    t->free_next = lpf_free_threads;
    lpf_free_threads = t;
    pthread_mutex_unlock(&lpf_lock);
}

__attribute__((constructor)) static void lpf_init(void) {
    /* `leanprof stat` launches a freshly linked program once with this set:
     * loading (and, on macOS, the first launch's signature check of a new
     * binary, seconds for a large one) without running any of it */
    const char *launch = getenv("LEANPROF_LAUNCH_ONLY");
    if (launch != NULL && strcmp(launch, "1") == 0) _exit(0);
    const char *trace = getenv("LEANPROF_TRACE");
    lpf_tracing = trace != NULL && trace[0] != 0;
    const char *max = getenv("LEANPROF_TRACE_MAX");
    if (max != NULL) {
        size_t n = 0;
        /* capped: a huge value wrapped `n * sizeof(lpf_event)` to a tiny buffer */
        for (const char *q = max; *q >= '0' && *q <= '9' && n <= LP_TRACE_LIMIT; q++) n = n * 10 + (size_t)(*q - '0');
        if (n > LP_TRACE_LIMIT) n = LP_TRACE_LIMIT;
        if (n > 2 * LP_DEPTH) lpf_trace_max = n;
    }
    lpf_clock_init();
    lpf_start = lpf_now();
    lpf_mem_init();
    atexit(lpf_report);
    lpf_live_init(); /* after atexit(lpf_report): the live thread stops before the report */
}
