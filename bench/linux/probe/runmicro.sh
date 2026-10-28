#!/bin/sh
# runmicro.sh VARIANT...: each variant three times, interleaved; default and LEANPROF_TIME_ALL=1.
cd ~/leanprof-bench/linux/mb
export LEANPROF_QUIET=1
./micro-gcc c
for r in 1 2 3; do
  for v in "$@"; do
    printf '%-18s r%s timed  ' "$v" "$r"; LEANPROF_TIME_ALL=1 ./micro-$v
  done
done
for v in "$@"; do printf '%-18s light  ' "$v"; ./micro-$v; done
