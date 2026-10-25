#!/bin/sh
# Reproduce a published claim: scripts/reproduce.sh CLAIM [OPTIONS]
#
#   scripts/reproduce.sh list        the claims, how long each takes, what it needs
#   scripts/reproduce.sh exact       the cheap exact claims, one after another (CI runs these)
#   scripts/reproduce.sh CLAIM       one claim; OPTIONS go to reproduce/CLAIM.py
#
# Each claim prints its measured values next to the published ones and exits 1
# when an exact quantity differs or a timing is outside its stated range (2 on a
# setup error). See docs/reproduce.md.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.elan/bin:$PATH"
claims="copybug smoke lean-regex leanprofiler leanbench batteries lcb-fixes lcb-autoresearch bench-suite"
cheap="copybug smoke leanprofiler leanbench lean-regex"

usage() {
  cat <<'EOF'
usage: scripts/reproduce.sh CLAIM [OPTIONS]

  claim             time (M5 Max, already built; a first run also clones and builds)
  copybug           ~15 s          README example: 2,001 copies (1,999 shared), fib 10,945 calls, explain
  smoke             ~15 s          Tests/Smoke from outside: 1,999 + 999 copies, fib 242,785 calls
  lean-regex        ~2 min         lean-regex 32af6f3: copies, allocations, closure calls, heartbeats
  leanprofiler      ~30 s          LeanProfiler 35e1899: copies per span (exact), span cost growth (timing)
  leanbench         ~40 s          LeanBench case study: copies 0 -> 1,980, allocations 46,214 -> 48,214
                                   (--timing: the detection trials, ~15 min, quiet machine only)
  batteries         ~2 min         Batteries v4.35.0: elab --project time, heartbeats, unfold counts
                                   (--lsp: also lean-source-profiler's whole-project runs, ~3.5 min more)
  lcb-fixes         ~1 min         lean-compiler-backend a25c541 -> 854fcc2: 11,946,202 -> 7,719,273 allocations
  lcb-autoresearch  ~2 min         854fcc2 -> f9ed557 counts (exact); 854fcc2 -> ac8324e plain time -22%, 540 cases
  bench-suite       ~5 min         bench/run.py: exact counts, accuracy table within stated ranges

  list              this table
  exact             copybug, smoke, leanprofiler, leanbench, lean-regex: exact parts only (CI)
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
claim=$1; shift
case "$claim" in
  list|-h|--help) usage ;;
  exact)
    status=0
    for c in $cheap; do
      case "$c" in leanprofiler|lean-regex) set -- --exact-only ;; *) set -- ;; esac
      python3 "$root/reproduce/$c.py" "$@" || status=1
    done
    exit $status ;;
  *)
    for c in $claims; do
      if [ "$c" = "$claim" ]; then exec python3 "$root/reproduce/$claim.py" "$@"; fi
    done
    echo "unknown claim: $claim" >&2; usage >&2; exit 2 ;;
esac
