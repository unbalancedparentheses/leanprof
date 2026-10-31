#include <stdint.h>
__attribute__((noinline)) uint64_t tinyA(uint64_t i) { return i * 3 + 1; }
__attribute__((noinline)) uint64_t tinyB(uint64_t i) { return (i ^ (i >> 7)) * 5 + 2; }
__attribute__((noinline)) uint64_t penter(const void *k) { (void)k; return 0; }
__attribute__((noinline)) uint64_t pexit(uint64_t t, uint64_t v) { (void)t; return v; }
_Thread_local uint64_t fastw[4 + 3 * 64];
uint64_t *fast_global;
