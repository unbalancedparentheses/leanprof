#!/bin/sh
# Wall time per verdict and one-time setup, for docs/case-studies/leanbench.md.
# Run from the leanprof checkout, on a quiet machine; on a shared host wrap
# the whole script: flock ~/bench.lock taskset -c 0-7 sh bench/leanbench/cost.sh
# (lock waits are then outside the timings, unlike run.py's per-command wall).
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
lp=$root/.lake/build/bin/leanprof
proj=$root/bench/leanbench/project
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
now() { python3 -c 'import time; print(time.monotonic())'; }
el() { python3 -c "print(f'{$2 - $1:.2f}')"; }
echo "load: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg)"

# one-time setup on a fresh copy of the project (no .lake): LeanBench and
# lean4-cli are fetched and built with the workload; leanprof's first measure
# builds the workload with copy shims (leanprof itself is built once, apart)
cp -R "$proj" "$tmp/p"; rm -rf "$tmp/p/.lake"
cd "$tmp/p"
t0=$(now); lake build bench >/dev/null 2>&1; t1=$(now)
echo "setup LeanBench: lake build bench from scratch (fetch + LeanBench + Cli + workload): $(el $t0 $t1) s"
t0=$(now); lake build work >/dev/null 2>&1; t1=$(now)
echo "setup plain exe: lake build work after that: $(el $t0 $t1) s"
t0=$(now); LB_VARIANT=base "$lp" measure --out "$tmp/warm.json" work >/dev/null 2>&1; t1=$(now)
echo "setup leanprof: first measure (builds runtime + shims): $(el $t0 $t1) s"
lake build bench work >/dev/null 2>&1

for i in 1 2 3 4 5; do
  t0=$(now)
  LB_VARIANT=base lake exe bench --match work --format json --json-out "$tmp/b.json" >/dev/null 2>&1
  LB_VARIANT=slow10 lake exe bench --match work --compare "$tmp/b.json" --fail-on-regressions --regress-pct 10 >/dev/null 2>&1 || true
  t1=$(now)
  LB_VARIANT=base "$lp" measure --out "$tmp/lb.json" work >/dev/null 2>&1
  LB_VARIANT=slow10 "$lp" measure --out "$tmp/ln.json" work >/dev/null 2>&1
  "$lp" judge "$tmp/lb.json" "$tmp/ln.json" >/dev/null || true
  t2=$(now)
  # the rebuild lake does for LeanBench after leanprof restored the plain build
  t3=$(now); lake build bench >/dev/null 2>&1; t4=$(now)
  echo "verdict $i: LeanBench $(el $t0 $t1) s, leanprof $(el $t1 $t2) s, lake rebuild after leanprof $(el $t3 $t4) s"
done
echo "load: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg)"
