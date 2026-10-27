/* ---------- live view and flight recorder ----------
 * Included once from leanprof.c, after the per-thread state and before the
 * timeline's lpf_trace, which hands every event to lpf_flight_trace while the
 * flight recorder is on. Nothing here runs unless LEANPROF_LIVE,
 * LEANPROF_FLIGHT or LEANPROF_SLOW_MS is set: lpf_live_init then returns at
 * once, and lpf_trace is only reached when a timeline is recorded.
 *
 * Live channel (LEANPROF_LIVE=path, or 1 for $TMPDIR/leanprof-<pid>.live.json):
 * a background thread rewrites a JSON snapshot of the current aggregates every
 * LEANPROF_LIVE_MS (default 250) ms. It writes `path.tmp` and renames it over
 * `path`, so a reader always sees a whole snapshot. A file rather than a
 * socket: rename is atomic on every POSIX system, the program never blocks on
 * or waits for a reader, any number of readers (`leanprof top`, the MCP
 * server, `cat`, a script) can attach and detach at any time, and nothing
 * listens on a port or needs cleaning up when the program is killed.
 *
 * Reading other threads' tables without stopping them: table slots only ever
 * go from NULL to a scope or copy record, and records are never freed. A slot
 * is published with a plain store, so a record is only read once its slot was
 * already seen one snapshot earlier (by then its initialization is long
 * visible); at exit, when the report reads the same tables, every record is
 * read. Counters are read with relaxed atomic loads: a snapshot may be a few
 * events behind, never torn. Scope stacks are shown only through records that
 * passed the same check. (Their owners publish slots with release stores and
 * write counters with relaxed atomic stores, so ThreadSanitizer finds no race;
 * see LP_PUBLISH in leanprof.c.)
 *
 * Flight recorder (LEANPROF_FLIGHT=dir, 1 for the current directory, or
 * LEANPROF_SLOW_MS=ms): the timeline is recorded into a fixed buffer per
 * thread (LEANPROF_TRACE_MAX events, default 262,144 here). When it fills,
 * the older half is dropped, keeping the begin events of scopes still open so
 * the rest stays balanced (each event is moved at most once on average).
 * SIGUSR1 (`leanprof dump PID`) or a scope slower than LEANPROF_SLOW_MS
 * writes the last LEANPROF_FLIGHT_SECS (default 10) seconds to
 * `dir/leanprof-<pid>-<n>.trace.json` for Perfetto. Dumps are written by the
 * background thread, never by the program's threads: a buffer is copied
 * under a per-thread sequence count (odd while it is being compacted).
 * `$TMPDIR/leanprof-<pid>.flight` says where dumps go and how many were
 * written, so `leanprof dump` only signals programs that handle SIGUSR1.
 */

#include <errno.h>
#include <sched.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/resource.h>

static void lpf_symbol_name(void *pc, char *out, size_t cap);
static void lpf_symbol_raw(void *pc, char *out, size_t cap);
static const char *lpf_where(const char *fn, char *out, size_t cap);
static void lpf_task_name(const void *parent, uint8_t parent_kind, char *out, size_t cap);
static void lpf_json_str(FILE *f, const char *s);
static const char *lpf_label_pos(const char *label);
static int lpf_show_all(void);
static int lpf_all_copies(void);
static uint64_t lpf_clamp(double v);
static const char *lpf_skip_package(const char *s);
static void lpf_mem_read(uint64_t *commit, uint64_t *rss, uint64_t *peak_commit, uint64_t *peak_rss);

/* Non-negative decimal number at the start of `v`, or -1. Not strtol/atoi:
 * newer glibc renames them, and Lean links an older one. */
static double lpf_parse_num(const char *v) {
    double x = 0, scale = 0;
    int any = 0;
    for (; v != NULL && ((*v >= '0' && *v <= '9') || (*v == '.' && scale == 0)); v++) {
        if (*v == '.') { scale = 1; continue; }
        any = 1;
        if (scale > 0) { scale /= 10; x += (*v - '0') * scale; }
        else x = x * 10 + (*v - '0');
    }
    return any ? x : -1;
}

static int lpf_flight;                  /* the flight recorder is on: lpf_trace calls lpf_flight_trace */
static char lpf_live_path[1024];        /* snapshot file ("" when off) */
static uint64_t lpf_live_ms = 250;
static void lpf_ret_live_json(FILE *f); /* retained.inc.c */
static char lpf_flight_dir[1024];       /* where dumps go */
static char lpf_flight_marker[1100];    /* $TMPDIR/leanprof-<pid>.flight */
static char lpf_flight_last[1200];      /* the last dump written */
static double lpf_flight_secs = 10;
static uint64_t lpf_slow_ticks;         /* LEANPROF_SLOW_MS in ticks, 0 when off */
static char lpf_slow_only[256];         /* LEANPROF_SLOW_SCOPE: only scopes with this name */
static unsigned lpf_slow_max = 10, lpf_slow_dumps, lpf_dumps;
/* Set by the SIGUSR1 handler, taken by the background thread: a lock-free
 * atomic (async-signal-safe), exchanged so a signal between test and clear
 * is not lost. */
static int lpf_dump_signal;
/* A slow scope waiting to be dumped: 0 none, 2 being filled in, 1 ready. */
static int lpf_slow_pending;
static const void *lpf_slow_key;
static uint8_t lpf_slow_kind, lpf_slow_parent;
static uint64_t lpf_slow_dur, lpf_slow_covered; /* covered: end of the last slow scope dumped */
static uint32_t lpf_slow_tid;

static pthread_t lpf_live_tid;
static int lpf_live_running, lpf_live_quit;
static pthread_mutex_t lpf_live_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t lpf_live_cv = PTHREAD_COND_INITIALIZER;

/* ---- flight recorder: recording (on the program's threads) ---- */

typedef struct lpf_flight_thread {
    lpf_thread *t;
    uint64_t seq;                       /* odd while compacting */
    lpf_event *keep;                    /* scratch: begins kept at a compaction */
    struct lpf_flight_thread *next;
} lpf_flight_thread;

static _Thread_local lpf_flight_thread *lpf_flight_self;
static lpf_flight_thread *lpf_flight_threads; /* prepended under lpf_lock, read with acquire */

/* Events the background thread may be copying are written field by field
 * with relaxed atomics: a copy torn by a compaction is caught by the sequence
 * count and retried, and a plain memcpy on either side was a data race. */
static inline void lpf_event_put(lpf_event *d, const lpf_event *s) {
    LP_ST(d->key, s->key);
    LP_ST(d->ts, s->ts);
    LP_ST(d->bytes, s->bytes);
    LP_ST(d->ph, s->ph);
    LP_ST(d->kind, s->kind);
}

static inline void lpf_event_get(lpf_event *d, const lpf_event *s) {
    d->key = LP_LD(s->key);
    d->ts = LP_LD(s->ts);
    d->bytes = LP_LD(s->bytes);
    d->ph = LP_LD(s->ph);
    d->kind = LP_LD(s->kind);
}

/* Drop the older half of a full buffer, keeping the begins still open there. */
static void lpf_flight_compact(lpf_thread *t, lpf_flight_thread *ft) {
    size_t n = t->nevents, cut = n / 2, open[LP_DEPTH], no = 0, deeper = 0;
    for (size_t i = 0; i < cut; i++) {
        uint8_t ph = t->events[i].ph;
        if (ph == 'B') {
            if (no < LP_DEPTH) open[no++] = i;
            else deeper++;
        } else if (ph == 'E') {
            if (deeper > 0) deeper--;
            else if (no > 0) no--;
        }
    }
    for (size_t k = 0; k < no; k++) ft->keep[k] = t->events[open[k]];
    __atomic_store_n(&ft->seq, ft->seq + 1, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    for (size_t k = 0; k < no; k++) lpf_event_put(&t->events[k], &ft->keep[k]);
    for (size_t k = 0; k < n - cut; k++) lpf_event_put(&t->events[no + k], &t->events[cut + k]); /* no <= cut */
    __atomic_store_n(&t->nevents, no + (n - cut), __ATOMIC_RELAXED);
    __atomic_store_n(&ft->seq, ft->seq + 1, __ATOMIC_RELEASE);
}

static void lpf_slow_hit(lpf_thread *t, lpf_frame *f, uint64_t now);

static int lpf_flight_trace(lpf_thread *t, uint8_t ph, const void *key, uint8_t kind, uint64_t ts, uint64_t bytes) {
    lpf_flight_thread *ft = lpf_flight_self;
    if (LEAN_UNLIKELY(ft == NULL && t->flight != NULL)) /* an exited thread's buffer, with its record */
        lpf_flight_self = ft = t->flight;
    if (LEAN_UNLIKELY(ft == NULL)) {
        ft = calloc(1, sizeof(lpf_flight_thread));
        if (ft == NULL) abort();
        ft->t = t;
        ft->keep = malloc(LP_DEPTH * sizeof(lpf_event));
        lpf_event *ev = ft->keep != NULL ? malloc(lpf_trace_max * sizeof(lpf_event)) : NULL;
        pthread_mutex_lock(&lpf_lock);
        if (ev != NULL) {
            free(t->events);
            t->capevents = lpf_trace_max;
            t->nevents = 0;
            LP_PUBLISH(t->events, ev);
        }
        ft->next = lpf_flight_threads;
        __atomic_store_n(&lpf_flight_threads, ft, __ATOMIC_RELEASE);
        pthread_mutex_unlock(&lpf_lock);
        t->flight = ft;
        lpf_flight_self = ft;
    }
    if (LEAN_UNLIKELY(t->events == NULL || t->capevents != lpf_trace_max)) {
        t->events_dropped++;
        return 0;
    }
    if (LEAN_UNLIKELY(t->nevents >= t->capevents)) lpf_flight_compact(t, ft);
    lpf_event e = {key, ts, bytes, ph, kind};
    lpf_event_put(&t->events[t->nevents], &e);
    __atomic_store_n(&t->nevents, t->nevents + 1, __ATOMIC_RELEASE);
    /* lpf_exit has popped the frame: it is the one just above the depth */
    if (ph == 'E' && lpf_slow_ticks != 0) {
        lpf_frame *f = &t->stack[t->depth];
        if (ts - f->start >= lpf_slow_ticks) lpf_slow_hit(t, f, ts);
    }
    return 1;
}

/* The name a scope key is reported under. */
static void lpf_live_key_name(const void *key, uint8_t kind, uint8_t parent_kind, char *out, size_t cap) {
    if (kind == LP_TASK) lpf_task_name(key, parent_kind, out, cap);
    else if (kind == LP_FN) lpf_symbol_name((void *)key, out, cap);
    else lpf_label_name(lean_string_cstr((lean_object *)key), out, cap);
}

/* A scope ran longer than LEANPROF_SLOW_MS: hand it to the background
 * thread, unless it contains the last one handed over (its parents end later
 * and would only dump the same moment again). */
static void lpf_slow_hit(lpf_thread *t, lpf_frame *f, uint64_t now) {
    lpf_scope *s = f->scope;
    if (s == NULL || s->kind == LP_INTERNAL) return;
    if (f->start <= __atomic_load_n(&lpf_slow_covered, __ATOMIC_RELAXED)) return;
    if (lpf_slow_only[0]) {
        char name[300];
        lpf_live_key_name(s->key, s->kind, s->parent_kind, name, sizeof name);
        if (strcmp(name, lpf_slow_only) != 0) return;
    }
    int z = 0;
    if (!__atomic_compare_exchange_n(&lpf_slow_pending, &z, 2, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) return;
    lpf_slow_key = s->key;
    lpf_slow_kind = s->kind;
    lpf_slow_parent = s->parent_kind;
    lpf_slow_dur = now - f->start;
    lpf_slow_tid = t->id;
    __atomic_store_n(&lpf_slow_covered, now, __ATOMIC_RELAXED);
    __atomic_store_n(&lpf_slow_pending, 1, __ATOMIC_RELEASE);
}

static void lpf_on_sigusr1(int sig) {
    (void)sig;
    __atomic_store_n(&lpf_dump_signal, 1, __ATOMIC_RELAXED);
}

/* ---- flight recorder: dumps (on the background thread) ---- */

/* Memory over time, sampled by the background thread for dumps. */
#define LP_LIVE_MEM 8192
static struct { uint64_t ts, commit, rss; } lpf_live_mem[LP_LIVE_MEM];
static size_t lpf_live_nmem;

/* Names by (key, kind), kept across dumps. */
typedef struct {
    const void *key;
    unsigned kind;
    char *name;
} lpf_name_slot;
static lpf_name_slot *lpf_names;
static size_t lpf_names_cap, lpf_names_n;

static size_t lpf_ptr_hash(const void *p, unsigned salt) {
    uint64_t h = (uint64_t)(uintptr_t)p ^ ((uint64_t)salt * 0x9e3779b97f4a7c15ull);
    h ^= h >> 31;
    h *= 0xbf58476d1ce4e5b9ull;
    h ^= h >> 29;
    return (size_t)h;
}

static const char *lpf_event_name(const lpf_event *e) {
    unsigned ck = e->ph == 'C' ? 0x100u | e->kind : e->kind;
    if (lpf_names_n * 2 >= lpf_names_cap) {
        size_t cap = lpf_names_cap ? lpf_names_cap * 2 : 1024;
        lpf_name_slot *v = calloc(cap, sizeof(lpf_name_slot));
        if (v == NULL) return "?";
        for (size_t i = 0; i < lpf_names_cap; i++) {
            if (lpf_names[i].name == NULL) continue;
            size_t h = lpf_ptr_hash(lpf_names[i].key, lpf_names[i].kind) & (cap - 1);
            while (v[h].name != NULL) h = (h + 1) & (cap - 1);
            v[h] = lpf_names[i];
        }
        free(lpf_names);
        lpf_names = v;
        lpf_names_cap = cap;
    }
    size_t h = lpf_ptr_hash(e->key, ck) & (lpf_names_cap - 1);
    for (; lpf_names[h].name != NULL; h = (h + 1) & (lpf_names_cap - 1))
        if (lpf_names[h].key == e->key && lpf_names[h].kind == ck) return lpf_names[h].name;
    char name[300], buf[300];
    if (e->ph == 'C') {
        lpf_symbol_name((void *)e->key, buf, sizeof buf);
        snprintf(name, sizeof name, "copy %s in %s", lpf_kind_name[e->kind < LP_KINDS ? e->kind : 0], buf);
    } else if ((e->kind & 15) == LP_TASK) {
        lpf_task_name(e->key, (uint8_t)(e->kind >> 4), name, sizeof name);
    } else if (e->key == NULL) {
        snprintf(name, sizeof name, "?");
    } else {
        lpf_live_key_name(e->key, e->kind, 0, name, sizeof name);
    }
    lpf_names[h] = (lpf_name_slot){e->key, ck, strdup(name)};
    if (lpf_names[h].name == NULL) return "?";
    lpf_names_n++;
    return lpf_names[h].name;
}

/* A consistent copy of a thread's events, or NULL. */
static lpf_event *lpf_flight_copy(lpf_flight_thread *ft, size_t *out_n) {
    lpf_thread *t = ft->t;
    size_t cap = lpf_trace_max;
    if (LP_GET(t->events) == NULL) return NULL;
    lpf_event *buf = malloc(cap * sizeof(lpf_event));
    if (buf == NULL) return NULL;
    for (int tries = 0; tries < 1000; tries++) {
        uint64_t s1 = __atomic_load_n(&ft->seq, __ATOMIC_ACQUIRE);
        if (s1 & 1) {
            sched_yield();
            continue;
        }
        size_t n = __atomic_load_n(&t->nevents, __ATOMIC_ACQUIRE);
        if (n > cap) n = cap;
        for (size_t k = 0; k < n; k++) lpf_event_get(&buf[k], &t->events[k]);
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (__atomic_load_n(&ft->seq, __ATOMIC_RELAXED) == s1) {
            *out_n = n;
            return buf;
        }
    }
    free(buf);
    return NULL;
}

static void lpf_tmpdir(char *out, size_t cap) {
    const char *d = getenv("TMPDIR");
    if (d == NULL || d[0] == 0) d = "/tmp";
    snprintf(out, cap, "%s", d);
    size_t n = strlen(out);
    while (n > 1 && out[n - 1] == '/') out[--n] = 0;
}

static void lpf_write_marker(void) {
    if (!lpf_flight_marker[0]) return;
    char tmp[1200];
    snprintf(tmp, sizeof tmp, "%s.tmp", lpf_flight_marker);
    FILE *f = fopen(tmp, "w");
    if (f == NULL) return;
    fprintf(f, "dir %s\ndumps %u\nlast %s\nsecs %g\n", lpf_flight_dir, lpf_dumps, lpf_flight_last, lpf_flight_secs);
    int bad = ferror(f);
    if (fclose(f) != 0 || bad) unlink(tmp); /* keep the last whole marker */
    else rename(tmp, lpf_flight_marker);
}

/* Write the last LEANPROF_FLIGHT_SECS seconds of every thread's timeline. */
static void lpf_flight_dump(const char *why) {
    double tick = lpf_ns_per_tick();
    uint64_t now = lpf_now();
    uint64_t window = (uint64_t)(lpf_flight_secs * 1e9 / tick);
    uint64_t cutoff = now - lpf_start > window ? now - window : lpf_start;
    char path[1200], tmp[1300];
    snprintf(path, sizeof path, "%s/leanprof-%d-%u.trace.json", lpf_flight_dir, (int)getpid(), lpf_dumps + 1);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (f == NULL) {
        fprintf(stderr, "leanprof: cannot write %s: %s\n", tmp, strerror(errno));
        return;
    }
    fprintf(f, "{\"displayTimeUnit\":\"ns\",\"otherData\":{\"trigger\":");
    lpf_json_str(f, why);
    fprintf(f, ",\"window_s\":%g},\"traceEvents\":[", lpf_flight_secs);
    fprintf(f, "{\"ph\":\"M\",\"name\":\"process_name\",\"pid\":1,\"args\":{\"name\":\"pid %d\"}}", (int)getpid());
    uint64_t kept = 0;
    for (lpf_flight_thread *ft = __atomic_load_n(&lpf_flight_threads, __ATOMIC_ACQUIRE); ft != NULL; ft = ft->next) {
        size_t n = 0;
        lpf_event *ev = lpf_flight_copy(ft, &n);
        if (ev == NULL || n == 0) {
            free(ev);
            continue;
        }
        uint32_t tid = ft->t->id;
        fprintf(f, ",{\"ph\":\"M\",\"name\":\"thread_name\",\"pid\":1,\"tid\":%u,\"args\":{\"name\":\"%s %u\"}}", tid,
                tid == 0 ? "startup" : "thread", tid);
        /* Begins open when the window starts are written first (at their own
         * time); ends without a begin in the buffer are skipped; scopes still
         * open now are closed at the dump. */
        size_t open[LP_DEPTH], no = 0, deeper = 0, i = 0;
        for (; i < n && ev[i].ts < cutoff; i++) {
            if (ev[i].ph == 'B') {
                if (no < LP_DEPTH) open[no++] = i;
                else deeper++;
            } else if (ev[i].ph == 'E') {
                if (deeper > 0) deeper--;
                else if (no > 0) no--;
            }
        }
        size_t depth = 0;
        deeper = 0;
        for (size_t k = 0; k < no + (n - i); k++) {
            lpf_event *e = k < no ? &ev[open[k]] : &ev[i + (k - no)];
            double us = (double)(e->ts - lpf_start) * tick / 1000.0;
            if (e->ph == 'E') {
                if (depth == 0) continue;
                depth--;
                fprintf(f, ",{\"ph\":\"E\",\"pid\":1,\"tid\":%u,\"ts\":%.3f}", tid, us);
            } else if (e->ph == 'B') {
                depth++;
                fprintf(f, ",{\"ph\":\"B\",\"cat\":\"%s\",\"pid\":1,\"tid\":%u,\"ts\":%.3f,\"name\":",
                        e->kind == LP_FN ? "function" : (e->kind & 15) == LP_TASK ? "task" : "scope", tid, us);
                lpf_json_str(f, lpf_event_name(e));
                fputc('}', f);
            } else {
                fprintf(f, ",{\"ph\":\"i\",\"s\":\"t\",\"cat\":\"copy\",\"pid\":1,\"tid\":%u,\"ts\":%.3f,\"name\":", tid,
                        us);
                lpf_json_str(f, lpf_event_name(e));
                fprintf(f, ",\"args\":{\"bytes\":%llu}}", (unsigned long long)e->bytes);
            }
            kept++;
        }
        for (; depth > 0; depth--)
            fprintf(f, ",{\"ph\":\"E\",\"pid\":1,\"tid\":%u,\"ts\":%.3f}", tid,
                    (double)(now - lpf_start) * tick / 1000.0);
        free(ev);
    }
    size_t m0 = lpf_live_nmem > LP_LIVE_MEM ? lpf_live_nmem - LP_LIVE_MEM : 0;
    for (size_t k = m0; k < lpf_live_nmem; k++) {
        size_t j = k % LP_LIVE_MEM;
        if (lpf_live_mem[j].ts < cutoff) continue;
        fprintf(f, ",{\"ph\":\"C\",\"name\":\"memory (MiB)\",\"pid\":1,\"ts\":%.3f,\"args\":{\"committed\":%.3f,"
                   "\"resident\":%.3f}}",
                (double)(lpf_live_mem[j].ts - lpf_start) * tick / 1000.0, (double)lpf_live_mem[j].commit / 1048576.0,
                (double)lpf_live_mem[j].rss / 1048576.0);
    }
    fprintf(f, ",{\"ph\":\"i\",\"s\":\"g\",\"pid\":1,\"tid\":0,\"ts\":%.3f,\"name\":",
            (double)(now - lpf_start) * tick / 1000.0);
    lpf_json_str(f, why);
    fprintf(f, "}]}\n");
    int bad = ferror(f);
    if (fclose(f) != 0 || bad || rename(tmp, path) != 0) {
        fprintf(stderr, "leanprof: cannot write %s\n", path);
        return;
    }
    lpf_dumps++;
    snprintf(lpf_flight_last, sizeof lpf_flight_last, "%s", path);
    lpf_write_marker();
    fprintf(stderr, "leanprof: %s: wrote the last %g s (%llu events) to %s\n", why, lpf_flight_secs,
            (unsigned long long)kept, path);
}

/* ---- live snapshots (on the background thread) ---- */

enum { LV_SCOPE, LV_TASK, LV_COPY, LV_ALLOC, LV_WAIT, LV_CLASSES };

/* One row of the snapshot: records of all threads merged by name, as in the
 * report. Counters are recomputed at every snapshot. */
typedef struct {
    char *key;
    char name[256], where[512], scope[128];
    uint8_t cls, is_fn, kind;
    uint64_t calls, total, self, max, wait, wait_max, allocs, bytes, ticks, persistent;
    uint64_t metric, prev;              /* what rows are ordered by, now and at the last snapshot */
    uint64_t *hist;                     /* scopes only */
    uint64_t *base_old, *base_new;      /* hist at the last two window turns, for recent percentiles */
} lpf_lv;

static lpf_lv *lpf_lv_rows;
static size_t lpf_lv_n, lpf_lv_cap;
static int32_t *lpf_lv_index;            /* row by key hash */
static size_t lpf_lv_index_cap;

/* Records seen so far: when first seen, and their row (-1 unresolved, -2 not shown). */
typedef struct {
    const void *p;
    uint32_t seen;
    int32_t row;
} lpf_rec_slot;
static lpf_rec_slot *lpf_recs;
static size_t lpf_recs_cap, lpf_recs_n;
static uint32_t lpf_lv_scan;
static unsigned lpf_lv_seq;
static uint64_t lpf_lv_window, lpf_lv_turned; /* LEANPROF_LIVE_WINDOW_MS in ticks; last window turn */
static uint64_t *lpf_lv_diff;

static size_t lpf_str_hash(const char *s) {
    uint64_t h = 1469598103934665603ull;
    for (; *s; s++) h = (h ^ (unsigned char)*s) * 1099511628211ull;
    return (size_t)h;
}

static size_t lpf_rec_find(const void *p) {
    if (lpf_recs_cap == 0) return SIZE_MAX;
    size_t h = lpf_ptr_hash(p, 7) & (lpf_recs_cap - 1);
    for (; lpf_recs[h].p != NULL; h = (h + 1) & (lpf_recs_cap - 1))
        if (lpf_recs[h].p == p) return h;
    return SIZE_MAX;
}

static size_t lpf_rec_get(const void *p) {
    if (lpf_recs_n * 2 >= lpf_recs_cap) {
        size_t cap = lpf_recs_cap ? lpf_recs_cap * 2 : 4096;
        lpf_rec_slot *v = calloc(cap, sizeof(lpf_rec_slot));
        if (v == NULL) return SIZE_MAX;
        for (size_t i = 0; i < lpf_recs_cap; i++) {
            if (lpf_recs[i].p == NULL) continue;
            size_t h = lpf_ptr_hash(lpf_recs[i].p, 7) & (cap - 1);
            while (v[h].p != NULL) h = (h + 1) & (cap - 1);
            v[h] = lpf_recs[i];
        }
        free(lpf_recs);
        lpf_recs = v;
        lpf_recs_cap = cap;
    }
    size_t h = lpf_ptr_hash(p, 7) & (lpf_recs_cap - 1);
    for (; lpf_recs[h].p != NULL; h = (h + 1) & (lpf_recs_cap - 1))
        if (lpf_recs[h].p == p) return h;
    lpf_recs[h] = (lpf_rec_slot){p, lpf_lv_scan, -1};
    lpf_recs_n++;
    return h;
}

/* The row for `key`, created with `init` filled in by the caller. */
static int32_t lpf_lv_row(const char *key, uint8_t cls, int *created) {
    *created = 0;
    if (lpf_lv_n * 2 >= lpf_lv_index_cap) {
        size_t cap = lpf_lv_index_cap ? lpf_lv_index_cap * 2 : 1024;
        int32_t *v = malloc(cap * sizeof(int32_t));
        if (v == NULL) return -1;
        for (size_t i = 0; i < cap; i++) v[i] = -1;
        for (size_t r = 0; r < lpf_lv_n; r++) {
            size_t h = lpf_str_hash(lpf_lv_rows[r].key) & (cap - 1);
            while (v[h] >= 0) h = (h + 1) & (cap - 1);
            v[h] = (int32_t)r;
        }
        free(lpf_lv_index);
        lpf_lv_index = v;
        lpf_lv_index_cap = cap;
    }
    size_t h = lpf_str_hash(key) & (lpf_lv_index_cap - 1);
    for (; lpf_lv_index[h] >= 0; h = (h + 1) & (lpf_lv_index_cap - 1))
        if (strcmp(lpf_lv_rows[lpf_lv_index[h]].key, key) == 0) return lpf_lv_index[h];
    if (lpf_lv_n == lpf_lv_cap) {
        size_t cap = lpf_lv_cap ? lpf_lv_cap * 2 : 256;
        lpf_lv *v = realloc(lpf_lv_rows, cap * sizeof(lpf_lv));
        if (v == NULL) return -1;
        lpf_lv_rows = v;
        lpf_lv_cap = cap;
    }
    lpf_lv *r = &lpf_lv_rows[lpf_lv_n];
    memset(r, 0, sizeof *r);
    r->key = strdup(key);
    r->cls = cls;
    if (cls == LV_SCOPE) r->hist = calloc(LP_BUCKETS, sizeof(uint64_t));
    if (r->key == NULL || (cls == LV_SCOPE && r->hist == NULL)) {
        free(r->key);
        free(r->hist);
        return -1;
    }
    lpf_lv_index[h] = (int32_t)lpf_lv_n;
    *created = 1;
    return (int32_t)lpf_lv_n++;
}

/* The row a scope record is merged into (as in lpf_report), -1 if it is too
 * new to read, -2 if it is not shown. */
static int32_t lpf_lv_scope_row(lpf_scope *s, int final) {
    size_t slot = lpf_rec_get(s);
    if (slot == SIZE_MAX) return -1;
    if (lpf_recs[slot].row != -1) return lpf_recs[slot].row;
    if (lpf_recs[slot].seen == lpf_lv_scan && !final) return -1;
    char fn[256] = "", key[300];
    int32_t row = -2;
    int created = 0;
    uint8_t kind = s->kind;
    if (kind == LP_INTERNAL) {
        row = -2;
    } else if (kind == LP_TASK) {
        lpf_task_name(s->key, s->parent_kind, fn, sizeof fn);
        snprintf(key, sizeof key, "\x02%s", fn);
        row = lpf_lv_row(key, LV_TASK, &created);
        if (created) snprintf(lpf_lv_rows[row].name, sizeof lpf_lv_rows[row].name, "%s", fn + 8);
    } else if (kind == LP_FN) {
        char raw[256];
        lpf_symbol_raw((void *)s->key, raw, sizeof raw);
        const char *r = raw;
#ifdef __APPLE__
        if (r[0] == '_') r++;
#endif
        int lean_decl = strncmp(r, "l_", 2) == 0 || strncmp(r, "lp_", 3) == 0 || strcmp(r, "_lean_main") == 0 ||
                        strcmp(r, "lean_main") == 0;
        if (lean_decl || lpf_show_all()) {
            lpf_symbol_name((void *)s->key, fn, sizeof fn);
            snprintf(key, sizeof key, "\x01%s", fn);
            row = lpf_lv_row(key, LV_SCOPE, &created);
            if (created) {
                lpf_lv *rw = &lpf_lv_rows[row];
                rw->is_fn = 1;
                snprintf(rw->name, sizeof rw->name, "%s", fn);
                lpf_where(fn, rw->where, sizeof rw->where);
            }
        }
    } else {
        const char *label = lean_string_cstr((lean_object *)s->key);
        row = lpf_lv_row(label, LV_SCOPE, &created);
        if (created) {
            lpf_lv *rw = &lpf_lv_rows[row];
            lpf_label_name(label, rw->name, sizeof rw->name);
            snprintf(rw->where, sizeof rw->where, "%s", lpf_label_pos(label));
        }
    }
    if (row == -1) return -1;
    lpf_recs[slot].row = row;
    return row;
}

static int32_t lpf_lv_copy_row(lpf_copy *c, int final) {
    size_t slot = lpf_rec_get(c);
    if (slot == SIZE_MAX) return -1;
    if (lpf_recs[slot].row != -1) return lpf_recs[slot].row;
    if (lpf_recs[slot].seen == lpf_lv_scan && !final) return -1;
    char fn[256], key[700];
    lpf_symbol_name(c->pc, fn, sizeof fn);
    const char *label = c->site ? lean_string_cstr((lean_object *)c->site) : "";
    uint8_t cls = c->kind == LP_ALLOC ? LV_ALLOC : c->kind == LP_WAIT ? LV_WAIT : LV_COPY;
    snprintf(key, sizeof key, "\x03%u\x1f%s\x1f%s", (unsigned)c->kind, fn, label);
    int created = 0;
    int32_t row = lpf_lv_row(key, cls, &created);
    if (row < 0) return -1;
    if (created) {
        lpf_lv *rw = &lpf_lv_rows[row];
        rw->kind = c->kind;
        snprintf(rw->name, sizeof rw->name, "%s", fn);
        lpf_where(fn, rw->where, sizeof rw->where);
        if (c->site) lpf_label_name(label, rw->scope, sizeof rw->scope);
        else snprintf(rw->scope, sizeof rw->scope, "-");
    }
    lpf_recs[slot].row = row;
    return row;
}

/* Merge every thread's records into the rows. */
static void lpf_lv_collect(int final) {
    lpf_lv_scan++;
    for (size_t r = 0; r < lpf_lv_n; r++) {
        lpf_lv *rw = &lpf_lv_rows[r];
        rw->calls = rw->total = rw->self = rw->max = rw->wait = rw->wait_max = 0;
        rw->allocs = rw->bytes = rw->ticks = rw->persistent = 0;
        if (rw->hist) memset(rw->hist, 0, LP_BUCKETS * sizeof(uint64_t));
    }
    double pair = lpf_unit_ticks(); /* leanprof's own cost, removed as the exit report does */
    pthread_mutex_lock(&lpf_lock);
    for (lpf_thread *t = lpf_threads; t != NULL; t = t->next) {
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_scope *s = LP_GET(t->scopes[i]);
            if (s == NULL) continue;
            int32_t row = lpf_lv_scope_row(s, final);
            if (row < 0) continue;
            lpf_lv *rw = &lpf_lv_rows[row];
            uint64_t calls = LP_LD(s->calls);
            if (calls == 0) continue;
            double inner = lpf_inner_ticks(s);
            if (rw->cls == LV_TASK) {
                rw->calls += calls;
                rw->total += lpf_clamp((double)LP_LD(s->sum) - (double)calls * inner - (double)LP_LD(s->desc_sum) * pair);
                rw->wait += LP_LD(s->wait);
                uint64_t wm = LP_LD(s->wait_max);
                if (wm > rw->wait_max) rw->wait_max = wm;
                continue;
            }
            /* a light scope's timed calls stand for all of them, as at exit */
            rw->calls += calls + LP_LD(s->lcalls);
            rw->total += lpf_clamp(lpf_total_est(s));
            rw->self += lpf_clamp(lpf_self_est(s));
            uint64_t mx = LP_LD(s->max);
            if (mx > rw->max) rw->max = mx;
            rw->allocs += LP_LD(s->allocs_total);
            rw->bytes += LP_LD(s->bytes_total);
            for (size_t b = 0; b < LP_BUCKETS; b++) rw->hist[b] += LP_LD(s->hist[b]);
        }
        for (size_t i = 0; i < LP_TABLE; i++) {
            lpf_copy *c = LP_GET(t->copies[i]);
            if (c == NULL) continue;
            int32_t row = lpf_lv_copy_row(c, final);
            if (row < 0) continue;
            lpf_lv *rw = &lpf_lv_rows[row];
            uint64_t n = LP_LD(c->count[LP_SHARED]) + LP_LD(c->count[LP_MULTI_THREADED]);
            if (rw->cls == LV_COPY) {
                rw->calls += n;
                rw->persistent += LP_LD(c->count[LP_PERSISTENT]);
            } else {
                rw->calls += LP_LD(c->count[0]);
            }
            rw->bytes += LP_LD(c->bytes);
            rw->ticks += LP_LD(c->ticks);
        }
    }
    pthread_mutex_unlock(&lpf_lock);
    for (size_t r = 0; r < lpf_lv_n; r++) {
        lpf_lv *rw = &lpf_lv_rows[r];
        rw->metric = rw->cls == LV_ALLOC ? rw->bytes : rw->cls == LV_COPY || rw->cls == LV_WAIT ? rw->ticks
                                                                                               : rw->total;
    }
}

static const lpf_lv *lpf_lv_sort_rows;

/* Busiest since the last snapshot first, then by the whole run. */
static int lpf_lv_cmp(const void *a, const void *b) {
    const lpf_lv *x = &lpf_lv_sort_rows[*(const size_t *)a], *y = &lpf_lv_sort_rows[*(const size_t *)b];
    uint64_t dx = x->metric - (x->prev < x->metric ? x->prev : x->metric);
    uint64_t dy = y->metric - (y->prev < y->metric ? y->prev : y->metric);
    if (dx != dy) return dx < dy ? 1 : -1;
    if (x->metric != y->metric) return x->metric < y->metric ? 1 : -1;
    return x->calls < y->calls ? 1 : x->calls > y->calls ? -1 : 0;
}

static const char *const lpf_lv_section[LV_CLASSES] = {"scopes", "tasks", "copies", "allocations", "waits"};

static void lpf_live_write(int final) {
    if (!lpf_live_path[0]) return;
    lpf_lv_collect(final);
    double tick = lpf_ns_per_tick();
    uint64_t now = lpf_now();
    char tmp[1100];
    snprintf(tmp, sizeof tmp, "%s.tmp", lpf_live_path);
    FILE *f = fopen(tmp, "w");
    if (f == NULL) {
        static int warned;
        if (!warned++) fprintf(stderr, "leanprof: cannot write %s: %s\n", tmp, strerror(errno));
        return;
    }
    uint64_t commit, rss, pc, pr;
    lpf_mem_read(&commit, &rss, &pc, &pr);
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    unsigned nthreads = __atomic_load_n(&lpf_nthreads, __ATOMIC_RELAXED);
    size_t max_rows = 100;
    const char *mr = getenv("LEANPROF_LIVE_ROWS");
    if (lpf_parse_num(mr) >= 1) max_rows = (size_t)lpf_parse_num(mr);
    fprintf(f,
            "{\"leanprof_live\":1,\"pid\":%d,\"seq\":%u,\"exited\":%s,\"interval_ms\":%llu,\"ts_ns\":%.0f,"
            "\"overhead_ns\":%.1f,\"threads\":%u,",
            (int)getpid(), ++lpf_lv_seq, final ? "true" : "false", (unsigned long long)lpf_live_ms,
            (double)(now - lpf_start) * tick, lpf_unit_ticks() * tick, nthreads);
    fprintf(f, "\"memory\":{\"rss\":%llu,\"commit\":%llu,\"peak_rss\":%llu,\"peak_commit\":%llu},",
            (unsigned long long)rss, (unsigned long long)commit, (unsigned long long)pr, (unsigned long long)pc);
    lpf_ret_live_json(f);
    fprintf(f, "\"cpu\":{\"user_ns\":%.0f,\"sys_ns\":%.0f},",
            (double)ru.ru_utime.tv_sec * 1e9 + (double)ru.ru_utime.tv_usec * 1e3,
            (double)ru.ru_stime.tv_sec * 1e9 + (double)ru.ru_stime.tv_usec * 1e3);
    if (lpf_flight) {
        fprintf(f, "\"flight\":{\"dir\":");
        lpf_json_str(f, lpf_flight_dir);
        fprintf(f, ",\"secs\":%g,\"slow_ms\":%.0f,\"dumps\":%u,\"last\":", lpf_flight_secs,
                (double)lpf_slow_ticks * tick / 1e6, lpf_dumps);
        lpf_json_str(f, lpf_flight_last);
        fprintf(f, "},");
    } else {
        fprintf(f, "\"flight\":null,");
    }
    size_t *idx = malloc((lpf_lv_n ? lpf_lv_n : 1) * sizeof(size_t));
    if (idx == NULL) { /* no sections: keep the last whole snapshot rather than publish broken JSON */
        fclose(f);
        unlink(tmp);
        return;
    }
    for (int cls = 0; cls < LV_CLASSES; cls++) {
        size_t m = 0;
        for (size_t r = 0; r < lpf_lv_n; r++) {
            const lpf_lv *rw = &lpf_lv_rows[r];
            if (rw->cls == cls && (rw->calls > 0 || (cls == LV_COPY && rw->persistent > 0 && lpf_show_all())))
                idx[m++] = r;
        }
        lpf_lv_sort_rows = lpf_lv_rows;
        qsort(idx, m, sizeof(size_t), lpf_lv_cmp);
        fprintf(f, "%s\"%s\":[", cls ? "]," : "", lpf_lv_section[cls]);
        for (size_t k = 0; k < m && k < max_rows; k++) {
            const lpf_lv *rw = &lpf_lv_rows[idx[k]];
            fprintf(f, "%s{\"name\":", k ? "," : "");
            lpf_json_str(f, rw->name);
            fprintf(f, ",\"where\":");
            lpf_json_str(f, rw->where);
            switch (cls) {
            case LV_SCOPE: {
                /* calls since the older window turn: the last one to two windows */
                uint64_t rc = 0;
                if (lpf_lv_diff == NULL) lpf_lv_diff = calloc(LP_BUCKETS, sizeof(uint64_t));
                if (lpf_lv_diff != NULL) {
                    for (size_t b = 0; b < LP_BUCKETS; b++) {
                        uint64_t o = rw->base_old ? rw->base_old[b] : 0;
                        lpf_lv_diff[b] = rw->hist[b] > o ? rw->hist[b] - o : 0;
                        rc += lpf_lv_diff[b];
                    }
                    fprintf(f, ",\"recent\":{\"calls\":%llu,\"p50_ns\":%.0f,\"p99_ns\":%.0f}", (unsigned long long)rc,
                            (double)lpf_percentile(lpf_lv_diff, 0.50) * tick,
                            (double)lpf_percentile(lpf_lv_diff, 0.99) * tick);
                }
                fprintf(f, ",\"auto\":%s,\"calls\":%llu,\"total_ns\":%.0f,\"self_ns\":%.0f,\"max_ns\":%.0f,"
                           "\"p50_ns\":%.0f,\"p99_ns\":%.0f,\"allocs\":%llu,\"alloc_bytes\":%llu}",
                        rw->is_fn ? "true" : "false", (unsigned long long)rw->calls, (double)rw->total * tick,
                        (double)rw->self * tick, (double)rw->max * tick,
                        (double)lpf_percentile(rw->hist, 0.50) * tick,
                        (double)lpf_percentile(rw->hist, 0.99) * tick, (unsigned long long)rw->allocs,
                        (unsigned long long)rw->bytes);
                break;
            }
            case LV_TASK:
                fprintf(f, ",\"tasks\":%llu,\"run_ns\":%.0f,\"wait_ns\":%.0f,\"wait_max_ns\":%.0f}",
                        (unsigned long long)rw->calls, (double)rw->total * tick, (double)rw->wait * tick,
                        (double)rw->wait_max * tick);
                break;
            case LV_COPY: {
                /* empty or tiny values, as the report's lpf_tiny, but against
                 * the time so far: `top` and the MCP tools summarize them */
                uint64_t all = rw->calls + rw->persistent;
                int tiny = !lpf_all_copies() && rw->kind < LP_KINDS && all > 0 && rw->bytes <= (uint64_t)LP_TINY_BYTES * all &&
                           (double)rw->ticks < LP_TINY_SHARE * (double)(now - lpf_start);
                fprintf(f, ",\"scope\":");
                lpf_json_str(f, rw->scope);
                fprintf(f, ",\"kind\":\"%s\",\"copies\":%llu,\"persistent\":%llu,\"bytes\":%llu,\"copy_ns\":%.0f,"
                           "\"tiny\":%s}",
                        lpf_kind_name[rw->kind < LP_KINDS ? rw->kind : 0], (unsigned long long)rw->calls,
                        (unsigned long long)rw->persistent, (unsigned long long)rw->bytes, (double)rw->ticks * tick,
                        tiny ? "true" : "false");
                break;
            }
            case LV_ALLOC:
                fprintf(f, ",\"scope\":");
                lpf_json_str(f, rw->scope);
                fprintf(f, ",\"allocs\":%llu,\"bytes\":%llu}", (unsigned long long)rw->calls,
                        (unsigned long long)rw->bytes);
                break;
            default:
                fprintf(f, ",\"scope\":");
                lpf_json_str(f, rw->scope);
                fprintf(f, ",\"waits\":%llu,\"blocked_ns\":%.0f}", (unsigned long long)rw->calls,
                        (double)rw->ticks * tick);
            }
        }
    }
    free(idx);
    for (size_t r = 0; r < lpf_lv_n; r++) lpf_lv_rows[r].prev = lpf_lv_rows[r].metric;
    if (now - lpf_lv_turned >= lpf_lv_window) {
        lpf_lv_turned = now;
        for (size_t r = 0; r < lpf_lv_n; r++) {
            lpf_lv *rw = &lpf_lv_rows[r];
            if (rw->hist == NULL) continue;
            uint64_t *t = rw->base_old;
            rw->base_old = rw->base_new;
            if (t == NULL) t = malloc(LP_BUCKETS * sizeof(uint64_t));
            if (t != NULL) memcpy(t, rw->hist, LP_BUCKETS * sizeof(uint64_t));
            rw->base_new = t;
        }
    }
    /* what each thread is inside now, outermost first */
    fprintf(f, "],\"stacks\":[");
    int first = 1;
    for (lpf_thread *t = LP_GET(lpf_threads); t != NULL && !final; t = t->next) {
        uint32_t d = LP_LD(t->depth);
        if (d > LP_DEPTH) d = LP_DEPTH; /* every stack buffer holds at least LP_DEPTH frames */
        /* one load: the owner may grow its stack meanwhile (old buffers stay valid) */
        lpf_frame *stack = LP_GET(t->stack);
        int any = 0;
        for (uint32_t k = 0; k < d && k < 64; k++) {
            lpf_scope *s = LP_LD(stack[k].scope);
            uint64_t start = LP_LD(stack[k].start);
            if (LP_LD(stack[k].light)) continue; /* only counted: no start time */
            size_t slot = s ? lpf_rec_find(s) : SIZE_MAX;
            if (slot == SIZE_MAX || lpf_recs[slot].row < 0) continue;
            if (!any) fprintf(f, "%s{\"thread\":%u,\"frames\":[", first ? "" : ",", t->id);
            fprintf(f, "%s{\"name\":", any ? "," : "");
            lpf_json_str(f, lpf_lv_rows[lpf_recs[slot].row].name);
            fprintf(f, ",\"elapsed_ns\":%.0f}", now > start ? (double)(now - start) * tick : 0.0);
            any = 1;
            first = 0;
        }
        if (any) fprintf(f, "]}");
    }
    fprintf(f, "]}\n");
    int bad = ferror(f);
    if (fclose(f) != 0 || bad || rename(tmp, lpf_live_path) != 0) unlink(tmp);
}

/* ---- the background thread ---- */

static void *lpf_live_main(void *arg) {
    (void)arg;
    double tick = lpf_ns_per_tick_rough();
    uint64_t live_every = (uint64_t)((double)lpf_live_ms * 1e6 / tick);
    uint64_t next = lpf_now() + live_every;
    uint64_t poll_ms = lpf_live_path[0] && !lpf_flight ? lpf_live_ms : lpf_live_ms < 50 ? lpf_live_ms : 50;
    pthread_mutex_lock(&lpf_live_mu);
    while (!lpf_live_quit) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        uint64_t ns = (uint64_t)ts.tv_nsec + poll_ms * 1000000ull;
        ts.tv_sec += (time_t)(ns / 1000000000ull);
        ts.tv_nsec = (long)(ns % 1000000000ull);
        pthread_cond_timedwait(&lpf_live_cv, &lpf_live_mu, &ts);
        if (lpf_live_quit) break;
        pthread_mutex_unlock(&lpf_live_mu);
        uint64_t now = lpf_now();
        if (lpf_flight) {
            uint64_t commit, rss, pc, pr;
            lpf_mem_read(&commit, &rss, &pc, &pr);
            size_t j = lpf_live_nmem++ % LP_LIVE_MEM;
            lpf_live_mem[j].ts = now;
            lpf_live_mem[j].commit = commit;
            lpf_live_mem[j].rss = rss;
            if (__atomic_exchange_n(&lpf_dump_signal, 0, __ATOMIC_RELAXED)) lpf_flight_dump("SIGUSR1");
            if (__atomic_load_n(&lpf_slow_pending, __ATOMIC_ACQUIRE) == 1) {
                char name[300], why[400];
                lpf_live_key_name(lpf_slow_key, lpf_slow_kind, lpf_slow_parent, name, sizeof name);
                snprintf(why, sizeof why, "%s on thread %u took %.1f ms (LEANPROF_SLOW_MS=%.0f)", name, lpf_slow_tid,
                         (double)lpf_slow_dur * tick / 1e6, (double)lpf_slow_ticks * tick / 1e6);
                if (lpf_slow_dumps < lpf_slow_max) {
                    lpf_slow_dumps++;
                    lpf_flight_dump(why);
                    if (lpf_slow_dumps == lpf_slow_max)
                        fprintf(stderr, "leanprof: %u slow-scope dumps written; no more (LEANPROF_SLOW_MAX)\n",
                                lpf_slow_max);
                }
                __atomic_store_n(&lpf_slow_pending, 0, __ATOMIC_RELEASE);
            }
        }
        if (lpf_live_path[0] && now >= next) {
            lpf_live_write(0);
            next = now + live_every;
        }
        pthread_mutex_lock(&lpf_live_mu);
    }
    pthread_mutex_unlock(&lpf_live_mu);
    /* a dump asked for just before the program ended is still written */
    if (lpf_flight && __atomic_exchange_n(&lpf_dump_signal, 0, __ATOMIC_RELAXED)) lpf_flight_dump("SIGUSR1");
    return NULL;
}

/* At exit, before the report: stop the thread, write the final snapshot. */
static void lpf_live_stop(void) {
    if (!lpf_live_running) return;
    pthread_mutex_lock(&lpf_live_mu);
    lpf_live_quit = 1;
    pthread_cond_signal(&lpf_live_cv);
    pthread_mutex_unlock(&lpf_live_mu);
    pthread_join(lpf_live_tid, NULL);
    lpf_live_running = 0;
    lpf_live_write(1);
    if (lpf_flight_marker[0]) unlink(lpf_flight_marker);
}

static double lpf_env_num(const char *name, double dflt) {
    const char *v = getenv(name);
    if (v == NULL || v[0] == 0) return dflt;
    double x = lpf_parse_num(v);
    return x >= 0 ? x : dflt;
}

static void lpf_abs_path(const char *p, char *out, size_t cap) {
    char cwd[900];
    if (p[0] == '/' || getcwd(cwd, sizeof cwd) == NULL) snprintf(out, cap, "%s", p);
    else snprintf(out, cap, "%s/%s", cwd, p);
}

/* Called at the end of lpf_init (so lpf_live_stop runs before the report). */
static void lpf_live_init(void) {
    const char *live = getenv("LEANPROF_LIVE");
    const char *flight = getenv("LEANPROF_FLIGHT");
    double slow_ms = lpf_env_num("LEANPROF_SLOW_MS", 0);
    int want_live = live != NULL && live[0] != 0 && strcmp(live, "0") != 0;
    int want_flight = (flight != NULL && flight[0] != 0 && strcmp(flight, "0") != 0) || slow_ms > 0;
    if (!want_live && !want_flight) return;
    struct sigaction old_sa;
    /* `leanprof top` runs the program through `leanprof run`, which links
     * this runtime too: only its child, the program, takes part */
    const char *skip = getenv("LEANPROF_LIVE_SKIP_CHILD_OF");
    if (skip != NULL && lpf_parse_num(skip) == (double)getppid()) return;
    char tmpdir[900];
    lpf_tmpdir(tmpdir, sizeof tmpdir);
    /* the project's package names, read once here, before any other thread
     * runs: this thread and LEANPROF_SLOW_SCOPE's checks name scopes (it was
     * read on the background thread, while a program thread could too) */
    lpf_skip_package("x_y");
    if (want_live) {
        if (strcmp(live, "1") == 0)
            snprintf(lpf_live_path, sizeof lpf_live_path, "%s/leanprof-%d.live.json", tmpdir, (int)getpid());
        else lpf_abs_path(live, lpf_live_path, sizeof lpf_live_path);
        double ms = lpf_env_num("LEANPROF_LIVE_MS", 250);
        lpf_live_ms = ms >= 10 ? (uint64_t)ms : 10;
        lpf_lv_window = (uint64_t)(lpf_env_num("LEANPROF_LIVE_WINDOW_MS", 1000) * 1e6 / lpf_ns_per_tick_rough());
        lpf_lv_turned = lpf_now();
    }
    if (want_flight) {
        lpf_flight = 1;
        lpf_tracing = 1;
        if (getenv("LEANPROF_TRACE_MAX") == NULL) lpf_trace_max = 1u << 18;
        lpf_abs_path(flight != NULL && flight[0] != 0 && strcmp(flight, "1") != 0 ? flight : ".", lpf_flight_dir,
                     sizeof lpf_flight_dir);
        lpf_flight_secs = lpf_env_num("LEANPROF_FLIGHT_SECS", 10);
        lpf_slow_ticks = (uint64_t)(slow_ms * 1e6 / lpf_ns_per_tick_rough());
        lpf_slow_max = (unsigned)lpf_env_num("LEANPROF_SLOW_MAX", 10);
        const char *only = getenv("LEANPROF_SLOW_SCOPE");
        if (only != NULL) snprintf(lpf_slow_only, sizeof lpf_slow_only, "%s", only);
        snprintf(lpf_flight_marker, sizeof lpf_flight_marker, "%s/leanprof-%d.flight", tmpdir, (int)getpid());
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_handler = lpf_on_sigusr1;
        sa.sa_flags = SA_RESTART;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGUSR1, &sa, &old_sa);
        lpf_write_marker();
    }
    /* the thread takes no signals: SIGUSR1 and the program's own go elsewhere */
    sigset_t all, old;
    sigfillset(&all);
    pthread_sigmask(SIG_SETMASK, &all, &old);
    lpf_live_running = pthread_create(&lpf_live_tid, NULL, lpf_live_main, NULL) == 0;
    pthread_sigmask(SIG_SETMASK, &old, NULL);
    if (lpf_live_running) {
        atexit(lpf_live_stop);
        return;
    }
    /* Nothing would write snapshots or dumps: turn them off rather than fill
     * a flight buffer per thread and claim (marker, SIGUSR1) to dump them. */
    fprintf(stderr, "leanprof: cannot start the live thread: no live snapshots or flight dumps\n");
    lpf_live_path[0] = 0;
    if (want_flight) {
        sigaction(SIGUSR1, &old_sa, NULL);
        unlink(lpf_flight_marker);
        lpf_flight_marker[0] = 0;
        lpf_slow_ticks = 0;
        lpf_flight = 0;
        const char *trace = getenv("LEANPROF_TRACE");
        lpf_tracing = trace != NULL && trace[0] != 0;
    }
}
