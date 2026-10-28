#!/bin/sh
# Profile the compile time of every Mathlib module with `leanprof elab --project
# --heartbeats`, as published in docs/profiles/mathlib-v4.35.0 (any Linux or macOS
# machine with git, curl, python3 and a C compiler; elan is installed if missing).
#
#   scripts/profile-mathlib.sh [WORKDIR]       (default: ./mathlib-profile)
#
# Environment:
#   MATHLIB_REF   Mathlib tag or commit (default v4.35.0)
#   LEANPROF_REF  leanprof branch, tag or commit to build (default: this checkout's commit)
#   JOBS          modules elaborated at a time (default 12)
#   NICE          niceness of the run (default 10)
#
# Steps, each skipped when already done, so the script can be stopped and run again:
#   1. leanprof at LEANPROF_REF, built in WORKDIR/leanprof;
#   2. Mathlib at MATHLIB_REF in WORKDIR/mathlib4, with `lake exe cache get` (the built
#      .olean files of Mathlib and its dependencies, for its own toolchain);
#   3. one shard per top-level folder of Mathlib (`--module-glob 'Mathlib.Algebra.*'`), each
#      module's result kept in WORKDIR/cache (`elab --cache`): a module profiled once is not
#      profiled again; logs and shard reports in WORKDIR/shards;
#   4. a last run over every module (those cached are only read): WORKDIR/mathlib.json;
#   5. WORKDIR/failures.tsv (modules that stopped at an error, with the first error) and
#      WORKDIR/summary.txt (totals);
#   6. the published form, as scripts/publish-profile.py makes it: WORKDIR/publish.
#
# Heartbeats do not depend on the machine or its load; wall times do, and are written with
# the load average next to them (WORKDIR/run.log).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=${1:-$PWD/mathlib-profile}
mkdir -p "$work"
work=$(cd "$work" && pwd)
mathlib_ref=${MATHLIB_REF:-v4.35.0}
leanprof_ref=${LEANPROF_REF:-$(git -C "$here" rev-parse HEAD)}
jobs=${JOBS:-12}
niceness=${NICE:-10}
log="$work/run.log"
say() { echo "$(date -u +%FT%TZ) load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || uptime | sed 's/.*load averages*: //') | $*" | tee -a "$log"; }

if ! command -v elan >/dev/null 2>&1 && [ ! -x "$HOME/.elan/bin/elan" ]; then
  curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none
fi
export PATH="$HOME/.elan/bin:$PATH"

# 1. leanprof
if [ ! -x "$work/leanprof/.lake/build/bin/leanprof" ] || [ "$(git -C "$work/leanprof" rev-parse HEAD)" != "$(git -C "$work/leanprof" rev-parse "$leanprof_ref^{commit}" 2>/dev/null || echo none)" ]; then
  say "leanprof $leanprof_ref"
  [ -d "$work/leanprof/.git" ] || git clone -q https://github.com/unbalancedparentheses/leanprof "$work/leanprof"
  git -C "$work/leanprof" fetch -q origin
  git -C "$work/leanprof" checkout -q "$leanprof_ref" 2>/dev/null || git -C "$work/leanprof" checkout -q "origin/$leanprof_ref"
  (cd "$work/leanprof" && nice -n "$niceness" lake build leanprof leanprof-elab-driver 2>&1 | tail -1)
fi
lp="$work/leanprof/.lake/build/bin/leanprof"

# 2. Mathlib, with the cache's .olean files
if [ ! -f "$work/mathlib4/.cache-done" ]; then
  say "mathlib $mathlib_ref"
  if [ ! -d "$work/mathlib4/.git" ]; then
    git clone -q --filter=blob:none https://github.com/leanprover-community/mathlib4 "$work/mathlib4"
  fi
  git -C "$work/mathlib4" checkout -q "$mathlib_ref"
  (cd "$work/mathlib4" && lake exe cache get 2>&1 | tail -2)
  touch "$work/mathlib4/.cache-done"
fi
cd "$work/mathlib4"
say "mathlib commit $(git rev-parse HEAD), $(cat lean-toolchain), leanprof $(git -C "$work/leanprof" rev-parse --short HEAD)"

# 3. shards: one per top-level folder
mkdir -p "$work/shards" "$work/cache"
for dir in $(ls -d Mathlib/*/ | sed 's|Mathlib/||; s|/$||'); do
  [ -f "$work/shards/$dir.done" ] && continue
  say "shard $dir: $(find "Mathlib/$dir" -name '*.lean' | wc -l | tr -d ' ') files"
  start=$(date +%s)
  if nice -n "$niceness" "$lp" elab --project --no-build --heartbeats --jobs "$jobs" --cache "$work/cache" \
      --module-glob "Mathlib.$dir.*" --out "$work/shards/$dir.json" > "$work/shards/$dir.out" 2> "$work/shards/$dir.err"; then
    touch "$work/shards/$dir.done"
    say "shard $dir done in $(( $(date +%s) - start )) s"
  else
    say "shard $dir stopped (exit $?): see shards/$dir.err; run the script again to resume"
    exit 1
  fi
done

# 4. every module; the shards' modules are read from the cache
if [ ! -f "$work/mathlib.json" ]; then
  say "all modules"
  start=$(date +%s)
  nice -n "$niceness" "$lp" elab --project --no-build --heartbeats --jobs "$jobs" --cache "$work/cache" \
    --out "$work/mathlib.json.tmp" > "$work/all.out" 2> "$work/all.err"
  mv "$work/mathlib.json.tmp" "$work/mathlib.json"
  say "all modules done in $(( $(date +%s) - start )) s"
fi

# 5. failures and totals
python3 - "$work" <<'EOF'
import json, os, sys
work = sys.argv[1]
d = json.load(open(os.path.join(work, "mathlib.json")))
files = d["files"]
bad = [f for f in files if f["errors"] > 0]
with open(os.path.join(work, "failures.tsv"), "w") as out:
    out.write("module\terrors\tfirst_error\n")
    for f in sorted(bad, key=lambda f: f["module"]):
        out.write(f"{f['module']}\t{f['errors']}\t{' '.join(f['first_error'].split())[:300]}\n")
wall = sum(f["wall_ns"] for f in files) / 1e9
with open(os.path.join(work, "summary.txt"), "w") as out:
    out.write(f"modules {len(files)}\nwith errors {len(bad)}\n")
    out.write(f"heartbeats {int(d['wall_ns'])}\n")
    out.write(f"declarations and commands with cost {len(d['scopes'])}\n")
    out.write(f"ranges {len(d['ranges'])}\nrepeated operations {len(d['repeated'])}\ndefinitions {len(d['constants'])}\n")
    out.write(f"sum of per-module wall time {wall:.0f} s\n")
print(open(os.path.join(work, "summary.txt")).read(), end="")
EOF

# 6. the published form
say "publish"
python3 "$work/leanprof/scripts/publish-profile.py" --leanprof "$lp" ${PUBLISH_ARGS:-} \
  --title "Mathlib $mathlib_ref, every module" "$work/mathlib4" "$work/mathlib.json" "$work/publish"
say "done: $work/mathlib.json, $work/failures.tsv, $work/summary.txt, $work/publish"
