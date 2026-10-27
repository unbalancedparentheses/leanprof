#!/bin/sh
# End-to-end test of `leanprof build-memory` on a small project made here
# (three modules, one of them heavier), on leanprof's own Lean:
#
#   a clean build, --mem-limit, --decls 1   every module measured (peak RSS,
#                                           private memory, imports apart),
#                                           memory per command of the heaviest
#   --max-memory below the peaks            exit 1, the modules named
#   --jobs 1                                one `lean` at a time
#   leanprof html                           the report's page
#
# With a toolchain, the project uses that Lean (the wrapper and the driver are
# then those built for it). Exits 1 on any unexpected result. CI runs it:
#   sh scripts/build-memory-check.sh [LEANPROF TOOLCHAIN]
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
if [ $# -ge 1 ]; then
  lp="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
else
  (cd "$root" && lake build leanprof >/dev/null)
  lp="$root/.lake/build/bin/leanprof"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/leanprof-build-memory.XXXXXX")
cd "$work"
if [ $# -ge 2 ]; then echo "$2" > lean-toolchain; else cp "$root/lean-toolchain" .; fi
mkdir -p M
printf 'name = "m"\ndefaultTargets = ["M"]\n\n[[lean_lib]]\nname = "M"\n' > lakefile.toml
printf 'import M.Heavy\n' > M.lean
printf 'def base : Nat := 2\n' > M/Base.lean
cat > M/Heavy.lean <<'EOF'
import M.Base

/-- A proof the kernel checks by evaluation: its terms take memory. -/
theorem big : (List.range 2000).foldl (· + ·) base = 1999002 := by decide +kernel

def small : Nat := base + 1
EOF
echo "project in $work"
fail() { echo "FAIL: $1"; exit 1; }

"$lp" build-memory --clean --mem-limit 4G --decls 1 --out bm.json > bm.txt 2>&1 || { cat bm.txt; fail "build-memory exited with an error"; }
grep -q "peak memory of each module" bm.txt || fail "no module table"
grep -q "memory limit 4.00 GiB" bm.txt || fail "no memory limit section"
python3 - <<'PY' || exit 1
import json, sys
d = json.load(open("bm.json"))
ms = {m["module"]: m for m in d["modules"]}
def need(ok, what):
    if not ok:
        print("FAIL:", what); print(json.dumps(d, indent=1)[:3000]); sys.exit(1)
need(d["kind"] == "build-memory" and d["build_exit"] == 0, "kind and exit code")
need({"M", "M.Base", "M.Heavy"} <= set(ms), f"modules: {sorted(ms)}")
for m in ms.values():
    need(m["peak_rss"] > 50 * 2**20, f"{m['module']}: a plausible peak RSS ({m['peak_rss']})")
    need(m["private_peak"] is not None and 0 < m["private_peak"] <= m["peak_rss"], f"{m['module']}: private memory")
    need(m["imports_rss"] is not None and m["imports_rss"] <= m["peak_rss"] + 2**20, f"{m['module']}: imports apart")
need(d["max_concurrent"] >= 1 and d["concurrent_peak"]["sum_of_peaks"] >= max(m["peak_rss"] for m in ms.values()), "concurrency")
need(d["sampled"] is not None and d["sampled"]["samples"] > 0, "samples during the build")
need(d["mem_limit"]["safe_jobs"] >= 1, "jobs under the limit")
decls = d["declarations"]
need(len(decls) == 1 and not decls[0]["error"], "one module per command")
names = [c["name"] for c in decls[0]["commands"]]
need(decls[0]["imports_rss"] > 0 and decls[0]["peak_rss"] >= decls[0]["imports_rss"], "the serial run's imports and peak")
need(any(n for n in names), f"declarations named: {names}")
print("build-memory: modules", sorted(ms), "per command:", names)
PY

# a budget below the peaks: exit 1, naming the modules
if "$lp" build-memory --clean --no-imports --no-sample --max-memory 10M --out budget.json > budget.txt 2>&1; then
  cat budget.txt; fail "--max-memory below the peaks passed"
fi
grep -q "memory budget: 3 modules above 10 MiB" budget.txt || { cat budget.txt; fail "the budget's modules"; }

# one job at a time
"$lp" build-memory --clean --no-imports --jobs 1 --out j1.json > j1.txt 2>&1 || { cat j1.txt; fail "--jobs 1"; }
python3 -c 'import json,sys; d=json.load(open("j1.json")); sys.exit(0 if d["max_concurrent"] == 1 and d["jobs"] == 1 else 1)' ||
  fail "--jobs 1 ran more than one lean at a time"

# the HTML report
"$lp" html -o bm.html bm.json > /dev/null
python3 "$root/scripts/check-html.py" bm.html --expect '"kind":"build-memory"' --expect '"peak_rise"'
echo "build-memory-check: all checks passed"
