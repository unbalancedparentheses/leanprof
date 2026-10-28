#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
uint64_t tinyA(uint64_t), tinyB(uint64_t), penter(const void *), pexit(uint64_t, uint64_t);
uint64_t enter_slow(const void *k) { return penter(k); }
static const char key1[16] = "tinyA", key2[16] = "tinyB";

#define FAST(k)                                                                                      \
    ({                                                                                               \
        extern _Thread_local uint64_t fastw[4 + 3 * 64];                                            \
        uint64_t *_f = fastw;                                                                        \
        uintptr_t _k = (uintptr_t)(k);                                                               \
        uint64_t *_e = _f + 4 + 3 * ((_k >> 4 ^ _k >> 10) & 63);                                     \
        (_e[0] == _k && --_f[0] != 0) ? (_e[1]++, ((uint64_t *)_f[1])[4] += _e[2], (uint64_t)1)      \
                                      : penter((const void *)_k);                                     \
    })
#define FASTX(t, v) ((t) == 1 ? (v) : pexit((t), (v)))

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e9 + ts.tv_nsec;
}
int main(int argc, char **argv) {
    uint64_t n = argc > 1 ? strtoull(argv[1], 0, 10) : 20000000;
    extern _Thread_local uint64_t fastw[4 + 3 * 64];
    static uint64_t frame[8];
    fastw[0] = 1ull << 62;
    fastw[1] = (uint64_t)frame;
    for (const char *k = key1; k; k = k == key1 ? key2 : NULL) {
        uintptr_t kk = (uintptr_t)k;
        uint64_t *e = fastw + 4 + 3 * ((kk >> 4 ^ kk >> 10) & 63);
        e[0] = kk;
        e[2] = 1;
    }
    for (int rep = 0; rep < 5; rep++) {
        double t0, best[6] = {1e30, 1e30, 1e30, 1e30, 1e30, 1e30};
        uint64_t acc = 0;
        for (int v = 0; v < 6; v++) {
            t0 = now();
            switch (v) {
            case 0: for (uint64_t i = 0; i < n; i++) acc += tinyA(i); break;
            case 1: for (uint64_t i = 0; i < n; i++) { uint64_t t = penter(key1); acc += pexit(t, tinyA(i)); } break;
            case 2: for (uint64_t i = 0; i < n; i++) { uint64_t t = FAST(key1); acc += FASTX(t, tinyA(i)); } break;
            case 3: for (uint64_t i = 0; i < n; i++) acc += tinyB(acc + i); break;
            case 4: for (uint64_t i = 0; i < n; i++) { uint64_t t = penter(key2); acc += pexit(t, tinyB(acc + i)); } break;
            case 5: for (uint64_t i = 0; i < n; i++) { uint64_t t = FAST(key2); acc += FASTX(t, tinyB(acc + i)); } break;
            }
            double d = (now() - t0) / n;
            if (d < best[v]) best[v] = d;
            printf("%s%.3f", v ? " " : "", d);
        }
        printf("  (A: plain, call pair, inline; B: plain, call pair, inline) acc %llu\n", (unsigned long long)acc % 10);
    }
    return 0;
}
