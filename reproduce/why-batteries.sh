#!/usr/bin/env bash
# The worked example of docs/guide/ci-and-regressions.md ("Worked example:
# Batteries"): the Action's comment on a known compile-time regression.
#
# Batteries #1880 ("perf: make a List.filter grind annotation less
# aggressive", commit 45337c63) replaced `@[grind =>]` on
# `List.getElem_filter_eq_getElem_getElem_findIdxs` by a narrower
# `grind_pattern`. Here it is undone on Batteries 66e46918 (its last commit on
# Lean v4.35.0, the Lean leanprof is built with, so the elab driver and
# definition locations work): base = 66e46918, head = a local commit with the
# old annotation back. Nothing is pushed anywhere.
#
#   reproduce/why-batteries.sh [WORKDIR]     (default: a new temporary directory)
#
# Took 34 s on an 18-core M5 Max (Batteries built once, then the one changed file and what imports it).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=${1:-$(mktemp -d "${TMPDIR:-/tmp}/leanprof-why-batteries.XXXXXX")}
mkdir -p "$work"
b=$work/batteries
[ -d "$b/.git" ] || git clone -q https://github.com/leanprover-community/batteries "$b"
git -C "$b" checkout -q -B why-1880-undone 66e469188fe07963e5cf666c7d4433f45b8131c5
f=$b/Batteries/Data/List/Lemmas.lean
python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
a = "theorem getElem_filter_eq_getElem_getElem_findIdxs\n"
b = "grind_pattern getElem_filter_eq_getElem_getElem_findIdxs => (xs.filter p)[i]'h, (xs.findIdxs p)[i]\n\n"
assert s.count(a) == 1 and s.count(b) == 1, "Batteries 66e46918 is not as expected"
open(p, "w").write(s.replace(a, "@[grind =>]\n" + a).replace(b, ""))
PY
git -C "$b" -c user.name=leanprof-example -c user.email=example@invalid commit -qam \
  "Undo #1880: the aggressive @[grind =>] annotation again (leanprof worked example)"
OUT=$work/action "$here/scripts/action-local.sh" "$b" 66e469188fe07963e5cf666c7d4433f45b8131c5 \
  "$(git -C "$b" rev-parse HEAD)" Batteries/Data/List/Lemmas.lean || true
