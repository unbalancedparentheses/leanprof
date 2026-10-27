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

echo "== leanprof explain --static (this Lean version's C), checked against the --auto run"
"$lp" explain --static --no-build --report run.json --json > static.json
python3 - <<'PY'
import json, sys
d = json.load(open('static.json'))
flags = {(f['declaration'], f['kind']): f['runtime'] for f in d['flags']}
print('static flags', flags)
ok = all(flags.get(k, {}).get('status') == 'confirmed' for k in (('buildWithHistory', 'Array'), ('strings', 'String')))
sys.exit(0 if ok and len(flags) == 2 else 1)
PY

echo "== self-check: a missing shim is reported"
# leanprof as installed, but with the String.push shims taken out of the
# compiler wrapper (as Lean 4.36's inline lean_string_push once did to every
# String copy): the run, its JSON and doctor must warn
broken="$work/broken"
mkdir -p "$broken/.lake/build/bin" "$broken/scripts"
# the command itself, behind any launcher or install script: doctor says
# where its files are
real="$("$lp" doctor | sed -n 's/.*leanprof files at //p' | head -1)/.lake/build/bin/leanprof"
cp "$real" "$broken/.lake/build/bin/leanprof"
cp -R "$root/c" "$broken/"
grep -v -e '-Dlean_string_push=' -e '-Dlean_string_push_cold=' "$root/scripts/leanprof-cc" > "$broken/scripts/leanprof-cc"
chmod +x "$broken/scripts/leanprof-cc"
python3 - <<'PY'
import json, sys
d = json.load(open('run.json'))
print('self-check', d['self_check'])
sys.exit(0 if d['self_check']['ok'] and d['self_check']['warning'] == '' else 1)
PY
"$broken/.lake/build/bin/leanprof" run --json broken.json smoke -- 200 > broken.out 2> broken.err || true
grep -q "warning: copies of String may be undercounted with Lean" broken.err || { tail -40 broken.err; exit 1; }
python3 - <<'PY'
import json, sys
d = json.load(open('broken.json'))
sc = d['self_check']
print('self-check without the String.push shims:', sc['warning'])
strings = sum(c.get('shared', 0) for c in d['copies'] if c['kind'] == 'String')
sys.exit(0 if not sc['ok'] and 'copies of String may be undercounted' in sc['warning'] and 'Array' not in sc['warning'] and strings == 0 else 1)
PY
"$broken/.lake/build/bin/leanprof" doctor > broken-doctor.txt || true
grep -q "!!  copies of String may be undercounted" broken-doctor.txt || { cat broken-doctor.txt; exit 1; }
"$lp" doctor | grep "copy detection works"
rm -rf "$broken"

echo "== leanprof elab"
"$lp" elab --heartbeats Main.lean > elab.txt
head -12 elab.txt
python3 "$check" .lake/leanprof/elab.json --elab --min-pos 2
grep -q '"pos":"Main.lean:27"' .lake/leanprof/elab.json
# on any Lean: elaborated by leanprof's driver (built for this Lean if it is not
# leanprof's), with exact source ranges
grep -q '"exact_ranges":true' .lake/leanprof/elab.json
grep -q '"range":"Main.lean:27:65-27:71"' .lake/leanprof/elab.json

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
