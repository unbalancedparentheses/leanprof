#!/bin/sh
# End-to-end test of `leanprof fix` on Tests/Fix (see Tests/Fix/Fix.lean),
# copied to a fresh git repository:
#
#   a tree with uncommitted changes      -> refused, nothing touched
#   --dry-run                            -> the diff, nothing touched
#   buckets (nested-array-element)       -> KEEP, committed on a new branch;
#                                           git hooks do not run, the commit is
#                                           exactly the edit
#   smooth (loop-over-updated-array)     -> refused: the body writes an element
#                                           not visited yet, nothing touched
#   buckets, a test the edit fails       -> DISCARD, no branch
#   buckets, a test rewrites the file    -> DISCARD: not what was measured
#   TERM while the candidate is checked  -> exit 143, worktree removed
#
# The checks run in a git worktree (.lake/leanprof/fix/worktree). After each,
# the checkout must be on main with a clean tree and no worktree. Exits 1 on any
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
  [ "$(git worktree list | wc -l)" -eq 1 ] || fail "$1: a git worktree was left: $(git worktree list)"
}
# the measurements are small: 3 runs, 10 pairs
opts="--runs 3 --pairs 10"
# result.json follows schemas/fix.schema.json, with status $1 (and outcome $2)
result() {
  python3 "$root/scripts/contract-check.py" --validate fix .lake/leanprof/fix/result.json > contract.txt ||
    { cat contract.txt; fail "$3: result.json does not follow schemas/fix.schema.json"; }
  got=$(python3 -c "import json; d=json.load(open('.lake/leanprof/fix/result.json')); print(d['status'], d.get('outcome', '-'))")
  [ "$got" = "$1 $2" ] || fail "$3: result.json says $got, expected $1 $2"
}

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
result dry_run - "dry run"

echo
echo "== buckets: KEEP (with git hooks that must not run)"
# a pre-commit hook that changes what is committed, and hooks that leave a mark
hooks=$(git rev-parse --git-path hooks)
mkdir -p "$hooks"
printf '#!/bin/sh\necho "-- added by a hook" >> Fix.lean\ngit add Fix.lean\ntouch "%s/hook-ran"\n' "$work" > "$hooks/pre-commit"
printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$work" > "$hooks/post-checkout"
cp "$hooks/post-checkout" "$hooks/post-commit"
chmod +x "$hooks/pre-commit" "$hooks/post-checkout" "$hooks/post-commit"
if "$lp" fix $opts --exe buckets > keep.txt 2>&1; then :; else fail "buckets: exit code $?"; fi
rm -f "$hooks/pre-commit" "$hooks/post-checkout" "$hooks/post-commit"
[ ! -e "$work/hook-ran" ] || fail "buckets: a git hook ran"
cat keep.txt
grep -q "^KEEP: committed" keep.txt || fail "buckets: not kept"
result kept improved "buckets"
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
[ "$(git diff main "$branch" | grep -c '^[-+] ')" = 2 ] || fail "buckets: the commit has more than the edit"
git show "$branch:Fix.lean" | grep -q "added by a hook" && fail "buckets: a hook changed the commit"

echo
echo "== smooth: refused (the loop rewrite could change what it computes)"
if "$lp" fix $opts --exe buckets -- --smooth > refused-loop.txt 2>&1; then fail "smooth: not refused"; fi
sed -n '/^leanprof fix: [0-9]* finding/,$p' refused-loop.txt
grep -q "which fix cannot show" refused-loop.txt || fail "smooth: no reason given for refusing the loop rewrite"
grep -q "none of these findings has a mechanical fix" refused-loop.txt || fail "smooth: not refused before any change"
result no_mechanical_fix - "smooth"
clean "smooth"
[ -z "$(git branch --list 'leanprof-fix/smooth*')" ] || fail "smooth: a branch was created"
git diff --quiet HEAD -- Fix.lean || fail "smooth: Fix.lean changed"

echo
echo "== buckets with a test the edit fails: DISCARD"
git branch -q -D "$branch"
if "$lp" fix $opts --exe buckets --test 'grep -q "bs.set!" Fix.lean' > discard.txt 2>&1; then fail "discard: kept"; fi
cat discard.txt
grep -q "^DISCARD" discard.txt || fail "discard: no DISCARD"
grep -q "the tests fail" discard.txt || fail "discard: the reason is not the tests"
result discarded correctness_failure "discard"
clean "discard"
[ -z "$(git branch --list 'leanprof-fix/*')" ] || fail "discard: the branch was not deleted"
git diff --quiet HEAD -- Fix.lean || fail "discard: Fix.lean changed"

echo
echo "== buckets with a test that rewrites the file: DISCARD (what was measured is not the edit)"
if "$lp" fix $opts --exe buckets --test 'echo "-- by the test" >> Fix.lean' > rewritten.txt 2>&1; then
  fail "rewritten: kept"
fi
sed -n '/^leanprof fix: alternative/,$p' rewritten.txt
grep -q "changed while it was checked" rewritten.txt || fail "rewritten: the reason is not the changed file"
result discarded measurement_failed "rewritten"
clean "rewritten"
[ -z "$(git branch --list 'leanprof-fix/*')" ] || fail "rewritten: a branch was created"

echo
echo "== TERM while the candidate is checked: the worktree goes, the checkout is untouched"
log=.lake/leanprof/fix/log.txt
rm -f "$log"
"$lp" fix $opts --exe buckets > term.txt 2>&1 &
pid=$!
i=0
# the second build in the log is the candidate's
while [ $i -lt 1500 ]; do
  n=$(grep -c '^== lake build' "$log" 2>/dev/null || true)
  [ "${n:-0}" -ge 2 ] && break
  sleep 0.2; i=$((i + 1))
done
grep -q "bs := bs.modify" .lake/leanprof/fix/worktree/Fix.lean 2>/dev/null || fail "term: the candidate was not in the worktree"
grep -q "bs := bs.modify" Fix.lean && fail "term: the candidate is in the checkout"
kill -TERM $pid
code=0; wait $pid || code=$?
cat term.txt
[ $code = 143 ] || fail "term: exit code $code, not 143 (128 + TERM)"
clean "term"
[ -z "$(git branch --list 'leanprof-fix/*')" ] || fail "term: a branch was left"
[ ! -e .lake/leanprof/fix/worktree ] || fail "term: the worktree directory was left"

[ $failed = 0 ] && echo "fix-check: all passed"
exit $failed
