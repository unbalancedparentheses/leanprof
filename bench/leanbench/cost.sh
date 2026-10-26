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

# measure-pair on two real builds: a copy of the project as base, another
# whose Work.lean hard-codes the variant (as an edit would), rebuilt each time
lake build bench work >/dev/null 2>&1
cp -R "$tmp/p" "$tmp/base"; cp -R "$tmp/p" "$tmp/cand"
for i in 1 2 3 4 5; do
  sed "s/(← IO.getEnv \"LB_VARIANT\").getD \"base\"/\"slow10\"/" "$proj/Work.lean" > "$tmp/cand/Work.lean"
  echo "-- cost $i" >> "$tmp/cand/Work.lean"
  cd "$tmp/cand"
  t0=$(now); lake build work >/dev/null 2>&1; t1=$(now)
  # what LeanBench's bench exe costs to rebuild after the same edit
  lake build bench >/dev/null 2>&1; t2=$(now)
  cd "$tmp/base"
  t3=$(now); lake build work >/dev/null 2>&1; t4=$(now)
  line="verdict $i: rebuild after an edit: work $(el $t0 $t1) s, bench $(el $t1 $t2) s; unchanged base $(el $t3 $t4) s; measure-pair"
  for n in 20 10 6; do
    t0=$(now)
    "$lp" measure-pair --base "$tmp/base/.lake/build/bin/work" --candidate "$tmp/cand/.lake/build/bin/work" \
      --base-cwd "$tmp/base" --candidate-cwd "$tmp/cand" --runs $n --out "$tmp/pair.json" >/dev/null 2>&1
    t1=$(now)
    line="$line $n pairs $(el $t0 $t1) s,"
  done
  echo "$line"
done

# the fast-verdict defaults, end to end per verdict: edit Work.lean, then one
# measure-pair command that builds the candidate (lake build), takes the base
# from its cache (--base-rev HEAD, built by the first verdict of each exe) and
# stops when the verdict is settled; with --scope on `workbench` (one action
# per run) and on `work` (20 actions per run, the whole process)
cp -R "$tmp/p" "$tmp/git"; cd "$tmp/git"
printf '.lake\n' > .gitignore
git init -q; git add -A; git -c user.name=lb -c user.email=lb@example.com commit -qm base
for v in slow10 base; do
  for exe in workbench work; do
    sc=""; [ $exe = workbench ] && sc="--scope work"
    line="fast $v $exe:"
    for i in 1 2 3 4 5 6; do
      sed "s/(← IO.getEnv \"LB_VARIANT\").getD \"base\"/\"$v\"/" "$proj/Work.lean" > Work.lean
      echo "-- cost $v $exe $i" >> Work.lean
      t0=$(now)
      "$lp" measure-pair --base-rev HEAD --exe $exe $sc --out "$tmp/fast.json" > "$tmp/fast.txt" 2>&1
      t1=$(now)
      info=$(python3 -c "import json; j=json.load(open('$tmp/fast.json')); b=j['builds']; print(j['runs'], 'pairs, base', b['cache'], ', candidate build', round(b['candidate_build_s'], 2))")
      line="$line $(el $t0 $t1) s ($info),"
    done
    echo "$line"
  done
done
# LeanBench after the same kind of edit: lake build bench, then a baseline
# run (the case study's verdict measures both sides) and a compare run (a
# saved baseline would skip the first)
line="LeanBench after an edit: build + baseline + compare:"
for i in 1 2 3 4 5 6; do
  sed "s/(← IO.getEnv \"LB_VARIANT\").getD \"base\"/\"slow10\"/" "$proj/Work.lean" > Work.lean
  echo "-- cost lb $i" >> Work.lean
  t0=$(now)
  lake build bench >/dev/null 2>&1
  t1=$(now)
  lake exe bench --match work --format json --json-out "$tmp/b.json" >/dev/null 2>&1
  t2=$(now)
  lake exe bench --match work --compare "$tmp/b.json" --fail-on-regressions --regress-pct 10 >/dev/null 2>&1 || true
  t3=$(now)
  line="$line $(el $t0 $t1) + $(el $t1 $t2) + $(el $t2 $t3) s,"
done
echo "$line"

# measure --scope (../scoped: the 20 actions in one profile! scope)
cd "$root/bench/leanbench/scoped"
lake build workscope >/dev/null 2>&1
for i in 1 2 3; do
  t0=$(now)
  LB_VARIANT=base "$lp" measure --scope work --out "$tmp/sb.json" workscope >/dev/null 2>&1
  LB_VARIANT=slow10 "$lp" measure --scope work --out "$tmp/sn.json" workscope >/dev/null 2>&1
  "$lp" judge "$tmp/sb.json" "$tmp/sn.json" >/dev/null || true
  t1=$(now)
  t2=$(now); lake build workscope >/dev/null 2>&1; t3=$(now)
  echo "verdict $i: measure --scope + judge $(el $t0 $t1) s, lake build workscope after it $(el $t2 $t3) s"
done
echo "load: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg)"
