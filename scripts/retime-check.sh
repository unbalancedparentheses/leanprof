#!/bin/sh
# End-to-end test of `leanprof run --retime`: a project that depends on
# leanprof, with a scope too small to time (`step`, called 2M times) inside
# one with real work (`loop`). The first run finds `step` too small to time;
# the second compiles it out of the C code and runs again. Checks: the
# report has `loop` and not `step`, lists `step` under `compiled_out` with
# its exact call count, and the program's output is unchanged. CI runs it;
# run it from the repository root.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
(cd "$root" && lake build leanprof >/dev/null)
lp="$root/.lake/build/bin/leanprof"
work=$(mktemp -d "${TMPDIR:-/tmp}/leanprof-retime.XXXXXX")
cd "$work"
cp "$root/lean-toolchain" .
cat > lakefile.toml <<EOF
name = "retime"

[[require]]
name = "leanprof"
path = "$root"

[[lean_exe]]
name = "retime"
root = "Main"
EOF
cat > Main.lean <<'EOF'
import Leanprof

@[noinline] def mix (i : UInt64) : UInt64 := (i ^^^ (i >>> 7)) * 5 + 2

@[noinline] def loop (n : Nat) : UInt64 := profile! "loop" (Id.run do
  let mut acc : UInt64 := 0
  for i in [0:n] do
    acc := acc + profile! "step" (mix (acc + i.toUInt64))
  return acc)

def main : IO Unit := IO.println s!"result {loop 2000000}"
EOF
lake build retime >/dev/null
want=$(.lake/build/bin/retime)
LEANPROF_QUIET=1 "$lp" run --retime --json out.json retime > run.out 2> run.err || { cat run.err; exit 1; }
grep -q "$want" run.out || { echo "output changed: $(cat run.out)"; exit 1; }
python3 - <<'PY'
import json, sys
d = json.load(open('out.json'))
names = {s['name'] for s in d['scopes']}
out = {s['name']: s for s in d.get('compiled_out', [])}
problems = []
if 'loop' not in names: problems.append('loop missing from the second report')
if 'step' in names: problems.append('step still timed in the second report')
if 'step' not in out: problems.append(f"step not under compiled_out: {d.get('compiled_out')}")
elif out['step']['calls'] != 2000000: problems.append(f"step calls {out['step']['calls']}, want 2000000")
if d.get('retime', {}).get('calls_differ'): problems.append(f"calls differ: {d['retime']['calls_differ']}")
if problems:
    print('retime-check: ' + '; '.join(problems))
    sys.exit(1)
PY
rm -rf "$work"
echo "retime-check: passed"
