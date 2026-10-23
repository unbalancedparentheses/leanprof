#!/bin/sh
# The autoresearch loop of research/program.md with scripted experiments
# instead of an AI agent, to show the harness works end to end:
#
#   1-fix-copies.patch    removes the hidden copies, same output  -> KEEP
#   2-wrong-output.patch  a "simplification" that changes output  -> DISCARD
#
# It copies research/demo/project (a Lake project that does not depend on
# leanprof) to a temporary git repository, measures a baseline, then for each
# experiment: apply the change, build, measure, judge, and commit or reset.
# Exits 1 if a verdict is not the expected one.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
(cd "$root" && lake build leanprof >/dev/null)
lp="$root/.lake/build/bin/leanprof"

work=$(mktemp -d "${TMPDIR:-/tmp}/leanprof-research.XXXXXX")
cp -R "$here/project/." "$work/"
cd "$work"
echo "demo project in $work"
git init -q
git checkout -q -b research
commit() { git -c user.name=leanprof-demo -c user.email=demo@example.invalid commit -q "$@"; }
git add -A
commit -m "baseline"

# the fixed experiment: same command, runs and files every time
measure() {
  "$lp" measure --runs 5 --heartbeats-files Main.lean --out "$1" demo -- 3000 >"$1.log" 2>&1 ||
    { cat "$1.log"; exit 1; }
  sed -n '/^leanprof measure:/,/^written/p' "$1.log" | sed '$d'
}
# one numeric field of a summary, e.g. `field median base.json`
field() { sed -n "s/.*\"$1\": \([0-9.e+-]*\).*/\1/p" "$2" | head -n 1; }
# a row of research/results.tsv (untracked): the commit (none for a discarded
# experiment), verdict, median time, copies, compile heartbeats, description
log() {
  c=$(git rev-parse --short HEAD)
  [ "$1" = DISCARD ] && c=-
  printf '%s\t%s\t%.3f\t%s\t%.1f\t%s\n' "$c" "$1" \
    "$(awk "BEGIN { print $(field median "$2") / 1e6 }")" "$(field copies_total "$2")" \
    "$(awk "BEGIN { print $(field heartbeats_total "$2") / 1000 }")" "$3" >> research/results.tsv
}

mkdir -p .lake/research research
base=.lake/research/base.json
new=.lake/research/new.json
echo
echo "== baseline"
lake build demo >/dev/null
measure "$base"
printf 'commit\tverdict\tmedian_ms\tcopies\tcompile_khb\tdescription\n' > research/results.tsv
log baseline "$base" "baseline"

failed=0
experiment() {
  patch=$1 expected=$2 description=$3
  echo
  echo "== experiment: $description ($patch)"
  git apply "$here/experiments/$patch"
  lake build demo >/dev/null           # an agent would also run the tests here
  measure "$new"
  echo
  if "$lp" judge "$base" "$new" >.lake/research/judge.txt; then
    cat .lake/research/judge.txt
    commit -am "$description"
    cp "$new" "$base"
    log KEEP "$new" "$description"
    verdict=KEEP
  else
    cat .lake/research/judge.txt
    log DISCARD "$new" "$description"
    git reset -q --hard
    verdict=DISCARD
  fi
  if [ "$verdict" != "$expected" ]; then
    echo "demo: expected $expected, got $verdict"
    failed=1
  fi
}

experiment 1-fix-copies.patch KEEP "keep a running sum instead of every prefix"
experiment 2-wrong-output.patch DISCARD "add each element before counting its prefix"

echo
echo "== research/results.tsv"
cat research/results.tsv
echo
git log --oneline
exit $failed
