#!/bin/sh
# End-to-end test of `leanprof fix` on Tests/Fix (see Tests/Fix/Fix.lean),
# copied to a fresh git repository:
#
#   a tree with uncommitted changes      -> refused, nothing touched
#   --dry-run                            -> the diff, nothing touched
#   buckets (nested-array-element)       -> KEEP, committed on a new branch
#   smooth (loop-over-updated-array)     -> DISCARD: output changed, branch deleted
#
# After each, the checkout must be on main with a clean tree. Exits 1 on any
# unexpected result. CI runs it; run it from the repository root.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
(cd "$root" && lake build leanprof >/dev/null)
lp="$root/.lake/build/bin/leanprof"

work=$(mktemp -d "${TMPDIR:-/tmp}/leanprof-fix.XXXXXX")
cp -R "$root/Tests/Fix/." "$work/"
rm -rf "$work/.lake"
cd "$work"
echo "fixture in $work"
export GIT_AUTHOR_NAME=leanprof-test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=leanprof-test GIT_COMMITTER_EMAIL=test@example.invalid
git init -q -b main
printf '.lake\n' > .gitignore
git add -A
git commit -q -m "fixture"
lake build >/dev/null

failed=0
fail() { echo "fix-check: $1"; failed=1; }
clean() {
  [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "$1: not back on main"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "$1: the tree is not clean"
}
# the measurements are small: 3 runs, 10 pairs
opts="--runs 3 --pairs 10"

echo
echo "== a tree with uncommitted changes is refused"
echo "-- edit" >> Fix.lean
if "$lp" fix $opts --exe buckets >refused.txt 2>&1; then fail "a dirty tree was not refused"; fi
cat refused.txt
grep -q "uncommitted changes" refused.txt || fail "no reason given for refusing"
[ "$(tail -n 1 Fix.lean)" = "-- edit" ] || fail "the uncommitted change was touched"
git checkout -q -- Fix.lean

echo
echo "== --dry-run prints the diff"
"$lp" fix --dry-run --exe buckets > dry.txt
sed -n '/^leanprof fix: finding/,$p' dry.txt
grep -q '^+    bs := bs.modify i (·.push v)$' dry.txt || fail "dry run: no Array.modify edit"
grep -q '^-    bs := bs.set! i (bs\[i\]!.push v)$' dry.txt || fail "dry run: the old line is not shown"
clean "dry run"
[ -z "$(git branch --list 'leanprof-fix/*')" ] || fail "dry run created a branch"

echo
echo "== buckets: KEEP"
if "$lp" fix $opts --exe buckets > keep.txt 2>&1; then :; else fail "buckets: exit code $?"; fi
cat keep.txt
grep -q "^KEEP: committed" keep.txt || fail "buckets: not kept"
clean "buckets"
branch=leanprof-fix/buckets-nested-array-element
git rev-parse -q --verify "refs/heads/$branch" >/dev/null || fail "buckets: no branch $branch"
git log -1 --format=%B "$branch" > message.txt
echo "-- commit message:"
cat message.txt
grep -q "^buckets: Array.modify (leanprof fix)" message.txt || fail "buckets: commit subject"
grep -q "copies buckets .* -> 0$" message.txt || fail "buckets: no copy counts in the message"
grep -q "tests: \`lake test\`, passed before and after" message.txt || fail "buckets: tests not in the message"
grep -q "output: identical before and after" message.txt || fail "buckets: output not in the message"
grep -q "paired time: median change" message.txt || fail "buckets: no paired interval in the message"
[ "$(git diff --name-only main "$branch")" = Fix.lean ] || fail "buckets: the commit changes more than Fix.lean"
git diff main "$branch" | grep -q '^+    bs := bs.modify i (·.push v)$' || fail "buckets: the commit is not the edit"

echo
echo "== smooth: DISCARD (the output changes)"
if "$lp" fix $opts --exe buckets -- --smooth > discard.txt 2>&1; then fail "smooth: kept"; fi
cat discard.txt
grep -q "^DISCARD" discard.txt || fail "smooth: no DISCARD"
grep -q "the output changed" discard.txt || fail "smooth: the reason is not the output"
grep -q "tests pass" discard.txt || fail "smooth: the tests were expected to pass"
clean "smooth"
[ -z "$(git branch --list 'leanprof-fix/smooth*')" ] || fail "smooth: the branch was not deleted"
git diff --quiet HEAD -- Fix.lean || fail "smooth: Fix.lean changed"

[ $failed = 0 ] && echo "fix-check: all passed"
exit $failed
