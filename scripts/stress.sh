#!/bin/sh
# Stress test of leanprof's runtime (CI, and locally after `lake build stress`):
# runs Examples/Stress.lean with live snapshots every 10 ms and the flight
# recorder on, sends SIGUSR1 for dumps while it runs, and checks that it
# finishes in time with exact counts, a final snapshot that agrees with them,
# and whole, balanced dumps. The flight buffers are small (STRESS_RING events
# per thread), so they are compacted constantly and dumps stay quick. Then
# it runs again with live snapshots only, so tiny scopes go light (sampled)
# while the live thread reads them.
#   scripts/stress.sh [OUTDIR] [stress args...]   (STRESS_TIMEOUT: seconds, default 600)
set -u
out=${1:-.lake/leanprof/stress}
[ $# -gt 0 ] && shift
bin=${STRESS_BIN:-.lake/build/bin/stress}
rm -rf "$out" && mkdir -p "$out/flight"
LEANPROF_QUIET=1 LEANPROF_JSON="$out/report.json" LEANPROF_LIVE="$out/live.json" LEANPROF_LIVE_MS=10 \
  LEANPROF_FLIGHT="$out/flight" LEANPROF_FLIGHT_SECS=1 LEANPROF_SLOW_MS=50 LEANPROF_SLOW_SCOPE=stress.slow \
  LEANPROF_SLOW_MAX=3 LEANPROF_TRACE_MAX=${STRESS_RING:-5000} \
  "$bin" "$@" > "$out/stdout.txt" 2> "$out/stderr.txt" &
pid=$!
# dumps on demand under load, and a watchdog: a deadlock fails instead of hanging
n=0
limit=$((${STRESS_TIMEOUT:-600} * 10))
while kill -0 $pid 2>/dev/null; do
  sleep 0.1
  n=$((n + 1))
  # only once it handles SIGUSR1 (its marker exists), as `leanprof dump` does:
  # macOS can take a while to start a freshly built binary
  if [ $n -le 40 ] && [ -e "${TMPDIR:-/tmp}/leanprof-$pid.flight" ]; then kill -USR1 $pid 2>/dev/null; fi
  if [ $n -ge "$limit" ]; then
    echo "stress: still running after ${STRESS_TIMEOUT:-600} s (deadlock?)"
    kill -ABRT $pid
    break
  fi
done
wait $pid
rc=$?
cat "$out/stdout.txt"
grep -v "^leanprof: .*wrote the last" "$out/stderr.txt" | head -50
if [ $rc != 0 ]; then echo "stress: exit code $rc"; exit 1; fi
python3 - "$out" <<'PY'
import glob, json, sys
out = sys.argv[1]
expected = {}
for line in open(f'{out}/stdout.txt'):
    if '(expected' in line:
        name, rest = line.split(':', 1)
        expected[name] = int(rest.split('(expected')[1].strip(' )\n'))
live = json.load(open(f'{out}/live.json'))
report = json.load(open(f'{out}/report.json'))
calls = {s['name']: s['calls'] for s in live['scopes']}
rcalls = {s['name']: s['calls'] for s in report['scopes']}
copies = sum(c['copies'] for c in live['copies'] if c['scope'] == '-')
ok = live['exited']
for name in ('stress.leaf', 'stress.deep', 'stress.io'):
    # the final snapshot and the report count every call of the run
    print(name, calls.get(name), rcalls.get(name), '>=', expected[name])
    ok = ok and calls.get(name, 0) >= expected[name] and calls.get(name) == rcalls.get(name)
print('copies', copies, '>=', expected['copies'])
ok = ok and copies >= expected['copies']
dumps = sorted(glob.glob(f'{out}/flight/*.trace.json'))
triggers = []
for f in dumps:
    d = json.load(open(f))
    ev = d['traceEvents']
    b = sum(e['ph'] == 'B' for e in ev)
    e = sum(e['ph'] == 'E' for e in ev)
    triggers.append(d['otherData']['trigger'])
    if b != e or b == 0:
        print('unbalanced or empty dump', f, b, e)
        ok = False
print(len(dumps), 'dumps:', sorted(set(t.split(' on ')[0] for t in triggers)))
ok = ok and 'SIGUSR1' in triggers and any('stress.slow' in t for t in triggers)
sys.exit(0 if ok else 1)
PY
[ $? = 0 ] || exit 1
# Again with live snapshots only: the flight recorder keeps every scope fully
# timed, so this is the run in which tiny scopes (stress.leaf) go light while
# the live thread reads their counters.
LEANPROF_QUIET=1 LEANPROF_JSON="$out/light.json" LEANPROF_LIVE="$out/light-live.json" LEANPROF_LIVE_MS=1 \
  "$bin" "$@" > "$out/light-stdout.txt" 2> "$out/light-stderr.txt"
rc=$?
if [ $rc != 0 ]; then echo "stress (light scopes): exit code $rc"; head -50 "$out/light-stderr.txt"; exit 1; fi
python3 - "$out" <<'PY'
import json, sys
out = sys.argv[1]
expected = {}
for line in open(f'{out}/light-stdout.txt'):
    if '(expected' in line:
        name, rest = line.split(':', 1)
        expected[name] = int(rest.split('(expected')[1].strip(' )\n'))
live = {s['name']: s for s in json.load(open(f'{out}/light-live.json'))['scopes']}
leaf = {s['name']: s for s in json.load(open(f'{out}/light.json'))['scopes']}.get('stress.leaf', {})
calls, timed = leaf.get('calls', 0), leaf.get('timed_calls', leaf.get('calls', 0))
print('light scopes: stress.leaf', calls, 'calls,', timed, 'timed; live snapshot',
      live.get('stress.leaf', {}).get('calls'))
# every call counted, the same in the last snapshot, and only a sample timed
sys.exit(0 if calls >= expected['stress.leaf'] and live.get('stress.leaf', {}).get('calls') == calls
         and 0 < timed < calls else 1)
PY
