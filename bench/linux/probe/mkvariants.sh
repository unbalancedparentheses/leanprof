#!/bin/sh
# Builds micro-<variant> from ../leanprof (or $SRC) with different runtime builds.
set -e
cd ~/leanprof-bench/linux/mb
export PATH=$HOME/.elan/bin:$PATH
SRC=${SRC:-../leanprof/c}
I=$(lean --print-prefix)/include
cc -O2 -fPIC -I "$I" -c ../micro.c -o micro.o
cc -O2 -fPIC -I "$I" -c "$SRC/selfcheck.c" -o sc.o
mkdir -p fake && cp "$SRC"/*.c "$SRC"/*.h fake/
sed -i 's/return __rdtsc();/static uint64_t lpf_fake_tsc; return lpf_fake_tsc += 37;/' fake/leanprof.c
grep -q lpf_fake_tsc fake/leanprof.c
v() { name=$1; shift; "$@" -w -I "$I" -o rt-$name.o; leanc -o micro-$name micro.o rt-$name.o sc.o; }
v ${PFX}gcc     cc -fPIC -O2 -Wall -c "$SRC/leanprof.c"
v ${PFX}gcc-nocet cc -fPIC -O2 -fcf-protection=none -c "$SRC/leanprof.c"
v ${PFX}gcc-ie  cc -fPIC -O2 -ftls-model=initial-exec -c "$SRC/leanprof.c"
v ${PFX}clang   clang -fPIC -O2 -c "$SRC/leanprof.c"
v ${PFX}gcc-fakeclock cc -fPIC -O2 -c fake/leanprof.c
ls micro-*
