/* ---------- counters: constructor reuse and closure applications ----------
 * Included by leanprof.c. Opt-in: generated code reaches these shims only when
 * compiled with `-include c/counters.h` (LEANPROF_COUNTERS=1 through
 * scripts/leanprof-cc, `leanprof run --counters`, or `counterFlags`), so
 * programs built without it pay nothing.
 *
 * Reuse: Lean's reset/reuse turns `match x with | C a b => C a' b` into
 * `isSharedCheck = !lean_is_exclusive(x)`; when x is exclusive its cell is
 * updated in place, otherwise the fields are retained, x is released and a new
 * cell is allocated. Every check is counted per call site; failures also by
 * why the value was not exclusive and how many fields it had.
 *
 * Closures: every `lean_apply_N`/`lean_apply_m` from compiled code is counted
 * per (call site, closure function) and classified by the closure's arity and
 * fixed arguments: exact (calls the function), partial (builds a new closure)
 * or over (calls, then applies the result to the rest).
 */

enum { LPC_REUSE, LPC_APPLY };
enum { LPC_EXACT, LPC_PARTIAL, LPC_OVER };
#define LPC_TABLE (1u << 15)

typedef struct {
    void *pc;                  /* return address in the checking/applying function */
    void *fun;                 /* LPC_APPLY: the closure's function */
    uint8_t kind;
    uint64_t n[LP_REASONS];    /* REUSE: failures by reason; APPLY: by LPC_EXACT.. */
    uint64_t checks;           /* REUSE: all checks */
    uint64_t fields;           /* REUSE: fields of the cells that failed */
} lpf_ctr;

typedef struct lpf_ctr_thread {
    lpf_ctr *slots[LPC_TABLE];
    uint64_t dropped;
    struct lpf_ctr_thread *next;
} lpf_ctr_thread;

static _Thread_local lpf_ctr_thread *lpf_ctr_self;
static lpf_ctr_thread *lpf_ctr_threads;

static lpf_ctr *lpf_ctr_get(void *pc, void *fun, uint8_t kind) {
    lpf_ctr_thread *t = lpf_ctr_self;
    if (LEAN_UNLIKELY(t == NULL)) {
        t = calloc(1, sizeof(lpf_ctr_thread));
        if (t == NULL) abort();
        pthread_mutex_lock(&lpf_lock);
        t->next = lpf_ctr_threads;
        lpf_ctr_threads = t;
        pthread_mutex_unlock(&lpf_lock);
        lpf_ctr_self = t;
    }
    size_t i = lpf_hash(pc, fun) & (LPC_TABLE - 1);
    for (size_t n = 0; n < LPC_TABLE; n++, i = (i + 1) & (LPC_TABLE - 1)) {
        lpf_ctr *c = t->slots[i];
        if (LEAN_LIKELY(c != NULL && c->pc == pc && c->fun == fun && c->kind == kind)) return c;
        if (c == NULL) {
            c = calloc(1, sizeof(lpf_ctr));
            if (c == NULL) abort();
            c->pc = pc;
            c->fun = fun;
            c->kind = kind;
            t->slots[i] = c;
            return c;
        }
    }
    t->dropped++;
    return NULL;
}

/* lean.h's lean_is_exclusive, plus the count; the result is unchanged. */
LEAN_EXPORT bool leanprof_is_exclusive(lean_object *o) {
    bool ok = lean_is_st(o) && lean_internal_get_rc(o) == 1;
    lpf_ctr *c = lpf_ctr_get(LP_PC, NULL, LPC_REUSE);
    if (c != NULL) {
        c->checks++;
        if (!ok) {
            c->n[lpf_reason(o)]++;
            if (lean_ptr_tag(o) <= LeanMaxCtorTag) c->fields += lean_ctor_num_objs(o);
        }
    }
    return ok;
}

static inline void lpf_count_apply(void *pc, lean_object *f, unsigned n) {
    if (lean_is_scalar(f) || lean_ptr_tag(f) != LeanClosure) return; /* erased value; nothing to run */
    unsigned rest = lean_closure_arity(f) - lean_closure_num_fixed(f);
    lpf_ctr *c = lpf_ctr_get(pc, lean_closure_fun(f), LPC_APPLY);
    if (c != NULL) c->n[n == rest ? LPC_EXACT : n < rest ? LPC_PARTIAL : LPC_OVER]++;
}

#define LPF_P1 lean_object *a1
#define LPF_P2 LPF_P1, lean_object *a2
#define LPF_P3 LPF_P2, lean_object *a3
#define LPF_P4 LPF_P3, lean_object *a4
#define LPF_P5 LPF_P4, lean_object *a5
#define LPF_P6 LPF_P5, lean_object *a6
#define LPF_P7 LPF_P6, lean_object *a7
#define LPF_P8 LPF_P7, lean_object *a8
#define LPF_P9 LPF_P8, lean_object *a9
#define LPF_P10 LPF_P9, lean_object *a10
#define LPF_P11 LPF_P10, lean_object *a11
#define LPF_P12 LPF_P11, lean_object *a12
#define LPF_P13 LPF_P12, lean_object *a13
#define LPF_P14 LPF_P13, lean_object *a14
#define LPF_P15 LPF_P14, lean_object *a15
#define LPF_P16 LPF_P15, lean_object *a16
#define LPF_A1 a1
#define LPF_A2 LPF_A1, a2
#define LPF_A3 LPF_A2, a3
#define LPF_A4 LPF_A3, a4
#define LPF_A5 LPF_A4, a5
#define LPF_A6 LPF_A5, a6
#define LPF_A7 LPF_A6, a7
#define LPF_A8 LPF_A7, a8
#define LPF_A9 LPF_A8, a9
#define LPF_A10 LPF_A9, a10
#define LPF_A11 LPF_A10, a11
#define LPF_A12 LPF_A11, a12
#define LPF_A13 LPF_A12, a13
#define LPF_A14 LPF_A13, a14
#define LPF_A15 LPF_A14, a15
#define LPF_A16 LPF_A15, a16
#define LPF_APPLY(N)                                                       \
    LEAN_EXPORT lean_object *leanprof_apply_##N(lean_object *f, LPF_P##N) { \
        lpf_count_apply(LP_PC, f, N);                                      \
        return lean_apply_##N(f, LPF_A##N);                                \
    }
LPF_APPLY(1) LPF_APPLY(2) LPF_APPLY(3) LPF_APPLY(4) LPF_APPLY(5) LPF_APPLY(6) LPF_APPLY(7) LPF_APPLY(8)
LPF_APPLY(9) LPF_APPLY(10) LPF_APPLY(11) LPF_APPLY(12) LPF_APPLY(13) LPF_APPLY(14) LPF_APPLY(15) LPF_APPLY(16)

LEAN_EXPORT lean_object *leanprof_apply_n(lean_object *f, unsigned n, lean_object **args) {
    lpf_count_apply(LP_PC, f, n);
    return lean_apply_n(f, n, args);
}

LEAN_EXPORT lean_object *leanprof_apply_m(lean_object *f, unsigned n, lean_object **args) {
    lpf_count_apply(LP_PC, f, n);
    return lean_apply_m(f, n, args);
}

/* ---------- counters: queries ---------- */

static uint64_t lpf_ctr_total(uint8_t kind, int checks) {
    uint64_t n = 0;
    pthread_mutex_lock(&lpf_lock);
    for (lpf_ctr_thread *t = lpf_ctr_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LPC_TABLE; i++) {
            lpf_ctr *c = t->slots[i];
            if (c == NULL || c->kind != kind) continue;
            if (checks) n += c->checks;
            else if (kind == LPC_REUSE) n += c->n[LP_SHARED] + c->n[LP_MULTI_THREADED];
            else n += c->n[LPC_EXACT] + c->n[LPC_PARTIAL] + c->n[LPC_OVER];
        }
    pthread_mutex_unlock(&lpf_lock);
    return n;
}

/* Failed reuse checks on shared or multi-threaded values (not constants). */
LEAN_EXPORT lean_obj_res leanprof_reuse_failures(void) { return lean_uint64_to_nat(lpf_ctr_total(LPC_REUSE, 0)); }
LEAN_EXPORT lean_obj_res leanprof_reuse_checks(void) { return lean_uint64_to_nat(lpf_ctr_total(LPC_REUSE, 1)); }
LEAN_EXPORT lean_obj_res leanprof_closure_applications(void) {
    return lean_uint64_to_nat(lpf_ctr_total(LPC_APPLY, 0));
}

/* ---------- counters: report ----------
 * Sites are merged by function name (and, for closures, target name), like
 * copies. The helpers used here are defined further down in leanprof.c. */

static void lpf_symbol_name(void *pc, char *out, size_t cap);
static void lpf_symbol_raw(void *pc, char *out, size_t cap);
static const char *lpf_where(const char *fn, char *out, size_t cap);
static void lpf_json_str(FILE *f, const char *s);
static int lpf_show_all(void);

typedef struct {
    uint8_t kind;
    char fn[256], where[512];          /* the checking / applying function */
    char target[256], twhere[512], tsym[256]; /* APPLY: the closure's function */
    uint64_t n[LP_REASONS], checks, fields;
    uint64_t total;            /* REUSE: failures on shared or multi-threaded values; APPLY: applications */
    uint32_t sites;
} lpf_ctr_sum;

static lpf_ctr_sum *lpf_ctr_sums;
static size_t lpf_ctr_nsums;
static int lpf_ctr_collected;

static int lpf_ctr_by_total(const void *a, const void *b) {
    const lpf_ctr_sum *x = a, *y = b;
    if (x->kind != y->kind) return x->kind < y->kind ? -1 : 1;
    if (x->total != y->total) return x->total < y->total ? 1 : -1;
    return x->checks < y->checks ? 1 : x->checks > y->checks ? -1 : 0;
}

static size_t lpf_ctr_strhash(uint8_t kind, const char *a, const char *b) {
    uint64_t h = 1469598103934665603ull ^ kind;
    for (; *a; a++) h = (h ^ (uint8_t)*a) * 1099511628211ull;
    h = (h ^ 0xff) * 1099511628211ull;
    for (; *b; b++) h = (h ^ (uint8_t)*b) * 1099511628211ull;
    return (size_t)h;
}

/* Called with lpf_lock not held, once, at report time. */
static void lpf_ctr_collect(void) {
    if (lpf_ctr_collected) return;
    lpf_ctr_collected = 1;
    size_t cap = 0;
    pthread_mutex_lock(&lpf_lock);
    for (lpf_ctr_thread *t = lpf_ctr_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LPC_TABLE; i++) cap += t->slots[i] != NULL;
    if (cap == 0) { pthread_mutex_unlock(&lpf_lock); return; }
    size_t hcap = 16;
    while (hcap < 2 * cap) hcap <<= 1;
    size_t *index = malloc(hcap * sizeof(size_t)); /* name hash -> sum + 1 */
    lpf_ctr_sums = calloc(cap, sizeof(lpf_ctr_sum));
    if (index == NULL || lpf_ctr_sums == NULL) { pthread_mutex_unlock(&lpf_lock); free(index); return; }
    memset(index, 0, hcap * sizeof(size_t));
    for (lpf_ctr_thread *t = lpf_ctr_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LPC_TABLE; i++) {
            lpf_ctr *c = t->slots[i];
            if (c == NULL) continue;
            char fn[256], target[256] = "";
            lpf_symbol_name(c->pc, fn, sizeof fn);
            if (c->kind == LPC_APPLY) lpf_symbol_name(c->fun, target, sizeof target);
            size_t h = lpf_ctr_strhash(c->kind, fn, target) & (hcap - 1);
            lpf_ctr_sum *s = NULL;
            for (;; h = (h + 1) & (hcap - 1)) {
                if (index[h] == 0) break;
                lpf_ctr_sum *e = &lpf_ctr_sums[index[h] - 1];
                if (e->kind == c->kind && strcmp(e->fn, fn) == 0 && strcmp(e->target, target) == 0) { s = e; break; }
            }
            if (s == NULL) {
                s = &lpf_ctr_sums[lpf_ctr_nsums++];
                index[h] = lpf_ctr_nsums;
                s->kind = c->kind;
                snprintf(s->fn, sizeof s->fn, "%s", fn);
                snprintf(s->target, sizeof s->target, "%s", target);
                if (c->kind == LPC_APPLY) lpf_symbol_raw(c->fun, s->tsym, sizeof s->tsym);
            }
            s->sites++;
            s->checks += c->checks;
            s->fields += c->fields;
            for (int r = 0; r < LP_REASONS; r++) {
                s->n[r] += c->n[r];
                if (c->kind == LPC_APPLY || r != LP_PERSISTENT) s->total += c->n[r];
            }
        }
    pthread_mutex_unlock(&lpf_lock);
    free(index);
    for (size_t k = 0; k < lpf_ctr_nsums; k++) {
        lpf_ctr_sum *s = &lpf_ctr_sums[k];
        lpf_where(s->fn, s->where, sizeof s->where);
        if (s->kind == LPC_APPLY) lpf_where(s->target, s->twhere, sizeof s->twhere);
    }
    qsort(lpf_ctr_sums, lpf_ctr_nsums, sizeof(lpf_ctr_sum), lpf_ctr_by_total);
}

static int lpf_ctr_any(void) {
    for (lpf_ctr_thread *t = lpf_ctr_threads; t != NULL; t = t->next)
        for (size_t i = 0; i < LPC_TABLE; i++)
            if (t->slots[i] != NULL) return 1;
    return 0;
}

static void lpf_ctr_why(const lpf_ctr_sum *s, char *why, size_t cap) {
    why[0] = 0;
    for (int r = 0; r < LP_REASONS; r++) {
        if (s->n[r] == 0) continue;
        if (why[0]) strncat(why, "+", cap - strlen(why) - 1);
        strncat(why, lpf_reason_name[r], cap - strlen(why) - 1);
    }
}

#define LPC_ROWS 20

static void lpf_counters_print(FILE *f) {
    lpf_ctr_collect();
    if (lpf_ctr_nsums == 0) return;
    uint64_t checks = 0, failed = 0, constants = 0, apps[3] = {0, 0, 0};
    size_t nreuse = 0, napply = 0;
    for (size_t k = 0; k < lpf_ctr_nsums; k++) {
        const lpf_ctr_sum *s = &lpf_ctr_sums[k];
        if (s->kind == LPC_REUSE) {
            checks += s->checks;
            failed += s->total;
            constants += s->n[LP_PERSISTENT];
            nreuse += s->total > 0 || (lpf_show_all() && s->n[LP_PERSISTENT] > 0);
        } else {
            for (int r = 0; r < 3; r++) apps[r] += s->n[r];
            napply++;
        }
    }
    if (checks > 0) {
        fprintf(f, "\nconstructor reuse: %llu checks, %llu failed on shared values (%.1f%%), %llu on compile-time "
                   "constants%s\n(a failure allocates a new cell and retains every field instead of updating in place)\n",
                (unsigned long long)checks, (unsigned long long)failed, 100.0 * (double)failed / (double)checks,
                (unsigned long long)constants, constants > 0 && !lpf_show_all() ? " (LEANPROF_ALL=1 shows them)" : "");
        if (nreuse > 0)
            fprintf(f, "%10s %10s %6s %7s  %-24s %s\n", "failed", "checks", "rate", "fields", "why",
                    "function  (where)");
        size_t shown = 0;
        for (size_t k = 0; k < lpf_ctr_nsums; k++) {
            const lpf_ctr_sum *s = &lpf_ctr_sums[k];
            if (s->kind != LPC_REUSE || (s->total == 0 && !(lpf_show_all() && s->n[LP_PERSISTENT] > 0))) continue;
            if (shown++ == LPC_ROWS) break;
            char why[64];
            lpf_ctr_why(s, why, sizeof why);
            uint64_t all_failed = s->total + s->n[LP_PERSISTENT];
            fprintf(f, "%10llu %10llu %5.1f%% %7.1f  %-24s %s", (unsigned long long)all_failed,
                    (unsigned long long)s->checks, s->checks ? 100.0 * (double)all_failed / (double)s->checks : 0.0,
                    all_failed ? (double)s->fields / (double)all_failed : 0.0, why, s->fn);
            if (s->where[0]) fprintf(f, "  (%s)", s->where);
            fputc('\n', f);
        }
        if (nreuse > LPC_ROWS) fprintf(f, "(%zu more functions in the JSON report)\n", nreuse - LPC_ROWS);
    }
    if (napply == 0) return;
    uint64_t all = apps[0] + apps[1] + apps[2];
    fprintf(f, "\nclosure applications: %llu (exact %llu, partial %llu, over-applied %llu)\n",
            (unsigned long long)all, (unsigned long long)apps[0], (unsigned long long)apps[1],
            (unsigned long long)apps[2]);
    /* by target: merge the (site, target) rows */
    lpf_ctr_sum *T = calloc(napply, sizeof(lpf_ctr_sum));
    size_t nt = 0;
    for (size_t k = 0; T != NULL && k < lpf_ctr_nsums; k++) {
        const lpf_ctr_sum *s = &lpf_ctr_sums[k];
        if (s->kind != LPC_APPLY) continue;
        size_t j = 0;
        while (j < nt && strcmp(T[j].target, s->target) != 0) j++;
        if (j == nt) {
            T[nt] = *s;
            T[nt].sites = 1;
            nt++;
            continue;
        }
        for (int r = 0; r < 3; r++) T[j].n[r] += s->n[r];
        T[j].total += s->total;
        T[j].sites++;
    }
    if (T != NULL) {
        qsort(T, nt, sizeof(lpf_ctr_sum), lpf_ctr_by_total);
        fprintf(f, "closure targets (the function each applied closure runs)\n");
        fprintf(f, "%10s %7s %10s %10s %6s  %s\n", "applies", "share", "partial", "over", "sites", "target  (where)");
        for (size_t j = 0; j < nt && j < LPC_ROWS / 2; j++) {
            fprintf(f, "%10llu %6.1f%% %10llu %10llu %6u  %s", (unsigned long long)T[j].total,
                    all ? 100.0 * (double)T[j].total / (double)all : 0.0, (unsigned long long)T[j].n[LPC_PARTIAL],
                    (unsigned long long)T[j].n[LPC_OVER], T[j].sites, T[j].target);
            if (T[j].twhere[0]) fprintf(f, "  (%s)", T[j].twhere);
            fputc('\n', f);
        }
        free(T);
    }
    fprintf(f, "closure call sites (a hot site is a higher-order call that was not specialized or inlined)\n");
    fprintf(f, "%10s %7s %10s %10s  %s\n", "applies", "share", "partial", "over", "call site  (where)  ->  target");
    size_t shown = 0;
    for (size_t k = 0; k < lpf_ctr_nsums && shown < LPC_ROWS; k++) {
        const lpf_ctr_sum *s = &lpf_ctr_sums[k];
        if (s->kind != LPC_APPLY) continue;
        shown++;
        fprintf(f, "%10llu %6.1f%% %10llu %10llu  %s", (unsigned long long)s->total,
                all ? 100.0 * (double)s->total / (double)all : 0.0, (unsigned long long)s->n[LPC_PARTIAL],
                (unsigned long long)s->n[LPC_OVER], s->fn);
        if (s->where[0]) fprintf(f, "  (%s)", s->where);
        fprintf(f, "  ->  %s\n", s->target);
    }
    if (napply > shown) fprintf(f, "(%zu more in the JSON report)\n", napply - shown);
    fprintf(f, "hint: @[specialize] on the higher-order function (or @[inline] on a small one) lets Lean call the\n"
               "target directly; partial applications allocate a closure each time.\n");
}

/* `,"reuse":[...],"closures":[...]`, appended to the report object. */
static void lpf_counters_json(FILE *f) {
    lpf_ctr_collect();
    fprintf(f, ",\"reuse\":[");
    int first = 1;
    for (size_t k = 0; k < lpf_ctr_nsums; k++) {
        const lpf_ctr_sum *s = &lpf_ctr_sums[k];
        if (s->kind != LPC_REUSE) continue;
        fprintf(f, "%s{\"function\":", first ? "" : ",");
        first = 0;
        lpf_json_str(f, s->fn);
        fprintf(f, ",\"where\":");
        lpf_json_str(f, s->where);
        fprintf(f, ",\"checks\":%llu,\"failures\":%llu,\"shared\":%llu,\"multi_threaded\":%llu,\"persistent\":%llu,"
                   "\"fields\":%llu,\"sites\":%u}",
                (unsigned long long)s->checks, (unsigned long long)(s->total + s->n[LP_PERSISTENT]),
                (unsigned long long)s->n[LP_SHARED],
                (unsigned long long)s->n[LP_MULTI_THREADED], (unsigned long long)s->n[LP_PERSISTENT],
                (unsigned long long)s->fields, s->sites);
    }
    fprintf(f, "],\"closures\":[");
    first = 1;
    for (size_t k = 0; k < lpf_ctr_nsums; k++) {
        const lpf_ctr_sum *s = &lpf_ctr_sums[k];
        if (s->kind != LPC_APPLY) continue;
        fprintf(f, "%s{\"function\":", first ? "" : ",");
        first = 0;
        lpf_json_str(f, s->fn);
        fprintf(f, ",\"where\":");
        lpf_json_str(f, s->where);
        fprintf(f, ",\"target\":");
        lpf_json_str(f, s->target);
        fprintf(f, ",\"target_where\":");
        lpf_json_str(f, s->twhere);
        fprintf(f, ",\"target_symbol\":");
        lpf_json_str(f, s->tsym);
        fprintf(f, ",\"applications\":%llu,\"exact\":%llu,\"partial\":%llu,\"over\":%llu}",
                (unsigned long long)s->total, (unsigned long long)s->n[LPC_EXACT],
                (unsigned long long)s->n[LPC_PARTIAL], (unsigned long long)s->n[LPC_OVER]);
    }
    fprintf(f, "]");
}
