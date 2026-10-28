/* Probe microbenchmark: links a build of c/leanprof.c and times
 * counter reads and a profile! pair (leanprof_enter_pure +
 * leanprof_exit_pure_u64) around bodies of 0, 1, 4 and 16 rounds of a
 * dependent multiply-add chain. Each figure: the median over 21 rounds of
 * N iterations, ns per iteration; "net" subtracts the body alone. */
#include <lean/lean.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <x86intrin.h>

uint64_t leanprof_enter_pure(lean_object *site, lean_object *key);
uint64_t leanprof_exit_pure_u64(uint64_t tok, uint64_t v);
double leanprof_overhead_ns(void);
void lean_initialize_runtime_module(void);

static uint64_t mono(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

#define N 2000000
#define ROUNDS 21
static int cmpd(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static volatile uint64_t sink;
static lean_object *keys[8];
static int iters;

__attribute__((noinline)) static uint64_t body(uint64_t x) {
    for (int i = 0; i < iters; i++) x = x * 0x9E3779B97F4A7C15ull + (x >> 17);
    return x;
}

typedef double (*fn)(void);

static double t_rdtsc(void) {
    uint64_t t0 = mono(), s = 0;
    for (int i = 0; i < N; i++) s += __rdtsc();
    sink = s;
    return (double)(mono() - t0) / N;
}
static double t_rdtscp(void) {
    unsigned aux;
    uint64_t t0 = mono(), s = 0;
    for (int i = 0; i < N; i++) s += __rdtscp(&aux);
    sink = s;
    return (double)(mono() - t0) / N;
}
static double t_gettime(void) {
    uint64_t t0 = mono(), s = 0;
    for (int i = 0; i < N; i++) s += mono();
    sink = s;
    return (double)(mono() - t0) / N;
}
static double t_body(void) {
    uint64_t t0 = mono(), s = 1;
    for (int i = 0; i < N; i++) s = body(s);
    sink = s;
    return (double)(mono() - t0) / N;
}
static double t_body_rdtsc2(void) {
    uint64_t t0 = mono(), s = 1, a = 0;
    for (int i = 0; i < N; i++) { a += __rdtsc(); s = body(s); a += __rdtsc(); }
    sink = s + a;
    return (double)(mono() - t0) / N;
}
static double t_pair_body(void) {
    lean_object *site = lean_box(0);
    uint64_t t0 = mono(), s = 1;
    for (int i = 0; i < N; i++) {
        uint64_t tok = leanprof_enter_pure(site, keys[iters & 7]);
        s = leanprof_exit_pure_u64(tok, body(s));
    }
    sink = s;
    return (double)(mono() - t0) / N;
}

static double med(fn f) {
    double v[ROUNDS];
    for (int r = 0; r < ROUNDS; r++) v[r] = f();
    qsort(v, ROUNDS, sizeof v[0], cmpd);
    return v[ROUNDS / 2];
}

int main(int argc, char **argv) {
    lean_initialize_runtime_module();
    static const char *names[8] = {"k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7"};
    for (int i = 0; i < 8; i++) {
        keys[i] = lean_mk_string(names[i]);
        lean_mark_persistent(keys[i]);
    }
    int clocks = argc > 1 && argv[1][0] == 'c';
    if (clocks) {
        iters = 4;
        double b = med(t_body);
        printf("rdtsc %.2f  rdtscp %.2f  clock_gettime %.2f  body4+2rdtsc net %.2f ns\n", med(t_rdtsc),
               med(t_rdtscp), med(t_gettime), med(t_body_rdtsc2) - b);
        return 0;
    }
    printf("pair net, body 0/1/4/16:");
    static const int its[4] = {0, 1, 4, 16};
    for (int k = 0; k < 4; k++) {
        iters = its[k];
        double b = med(t_body);
        double p = med(t_pair_body);
        printf(" %.2f", p - b);
    }
    printf(" ns; calibrated pair %.2f ns\n", leanprof_overhead_ns());
    return 0;
}
