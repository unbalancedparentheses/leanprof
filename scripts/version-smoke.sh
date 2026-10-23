#!/bin/sh
# Profile Tests/Smoke from outside with `leanprof run`, `sample` and `elab`
# under a given Lean version, and check the reports. Used by the Lean version
# matrix in CI (.github/workflows/lean-versions.yml); runs locally too:
#   sh scripts/version-smoke.sh LEANPROF TOOLCHAIN [--sample]
# e.g. sh scripts/version-smoke.sh .lake/build/bin/leanprof leanprover/lean4:v4.34.1
# --sample makes `leanprof sample` required (otherwise it runs only when
# samply is installed).
set -eu
lp="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
toolchain="$2"
need_sample="${3:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
check="$root/scripts/check-report.py"
work="${TMPDIR:-/tmp}/leanprof-smoke-$$"
rm -rf "$work"
mkdir -p "$work"
cp "$root"/Tests/Smoke/lakefile.toml "$root"/Tests/Smoke/lake-manifest.json "$root"/Tests/Smoke/Main.lean "$work/"
echo "$toolchain" > "$work/lean-toolchain"
cd "$work"
echo "== Lean: $(lake env lean --version)"

echo "== leanprof run"
LEANPROF_QUIET=1 "$lp" run --auto --json run.json smoke -- 2000 > run.out
python3 - <<'PY'
import json, sys
d = json.load(open('run.json'))
shared = {}
for c in d['copies']:
    shared[c['kind']] = shared.get(c['kind'], 0) + c.get('shared', 0)
scopes = {s['name']: s for s in d['scopes']}
print('shared copies', shared, 'scopes', sorted(scopes))
ok = (shared.get('Array') == 1999 and shared.get('String') == 999 and scopes.get('fib', {}).get('calls', 0) > 100000
      and scopes.get('buildWithHistory', {}).get('pos') == 'Main.lean:10')
sys.exit(0 if ok else 1)
PY
python3 "$check" run.json --min-pos 2 --expect buildWithHistory=Main.lean --expect fib=Main.lean --expect strings=Main.lean

echo "== leanprof run --allocs --counters --frees, explain --why"
LEANPROF_QUIET=1 "$lp" run --allocs --counters --frees --json all.json smoke -- 2000 > all.out
python3 - <<'PY'
import json, sys
d = json.load(open('all.json'))
allocs = sum(a['allocs'] for a in d['allocations'])
checks = sum(r['checks'] for r in d['reuse'])
print('allocations', allocs, 'reuse checks', checks, 'freed', d['frees']['objects'])
sys.exit(0 if allocs > 0 and checks > 0 and d['frees']['objects'] > 0 else 1)
PY
LEANPROF_QUIET=1 "$lp" explain --why smoke -- 2000 > why.txt
grep -q "1999×" why.txt

echo "== leanprof elab"
"$lp" elab --heartbeats Main.lean > elab.txt 2> elab.err
cat elab.err
head -12 elab.txt
python3 "$check" .lake/leanprof/elab.json --elab --min-pos 2
grep -q '"pos":"Main.lean:27"' .lake/leanprof/elab.json
# exact ranges on this Lean too: the driver is built for it (once) when it is not leanprof's
grep -q '"exact_ranges":true' .lake/leanprof/elab.json
"$lp" elab Main.lean > elab-time.txt
python3 "$root/scripts/check-elab-dataset.py" .lake/leanprof/elab --timeline
grep -q "costliest tactics, by exact source range" elab-time.txt

if command -v samply >/dev/null 2>&1 || [ "$need_sample" = --sample ]; then
  echo "== leanprof sample"
  "$lp" sample --top 10 smoke -- 30000 > sample.txt
  sed -n '/^leanprof sample/,$p' sample.txt
  grep -q "buildWithHistory  (Main.lean:10)" sample.txt
else
  echo "== leanprof sample: skipped (samply not installed)"
fi
cd /
rm -rf "$work"
echo "smoke test passed on $toolchain"
