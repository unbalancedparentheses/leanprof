#!/bin/sh
# End-to-end test of `leanprof experiment` on Tests/Experiment (see
# Tests/Experiment/Exp/Buckets.lean), copied to a fresh git repository:
#
#   library experiment (no --exe): compile heartbeats
#     a slower proof                        -> DISCARD (heartbeats up)
#     a cheaper proof                       -> KEEP (heartbeats down), a git note
#     a proof replaced by sorry             -> DISCARD (guard: sorry)
#   run-time experiment (--exe bench, --inputs, --heldout, --check-output)
#     the working tree: Array.modify (no    -> KEEP, committed on main with the
#       copies), plus a change that only       evidence in the message
#       the held-out input reaches
#     one value moves, on one input only    -> DISCARD (outputs differ on that case)
#     sorry in a theorem                    -> DISCARD (guard: sorry)
#     a weaker theorem statement            -> INCONCLUSIVE (guard: signature changed)
#     a loosened test                       -> DISCARD (guard: protected file)
#     a cheaper proof only                  -> no timing: the generated C is the
#                                              base's, the measure is heartbeats
#     nothing changed                       -> DISCARD
#     finish                                -> the held-out input differs (exit 1)
#   fix --elab on Tests/FixElab (compile time, through an experiment)
#     --dry-run                             -> Lean's simp only lists, nothing changed
#     the costliest simp calls              -> KEEP: simp only, on a new branch, with
#                                              the evidence in the commit message
#
# After each step the checkout must be clean (the checks run in git worktrees
# under .lake/leanprof/experiments). Exits 1 on any unexpected result. CI runs
# it; run it from the repository root.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
(cd "$root" && lake build leanprof >/dev/null)
lp="$root/.lake/build/bin/leanprof"

work=$(mktemp -d "${TMPDIR:-/tmp}/leanprof-experiment.XXXXXX")
cp -R "$root/Tests/Experiment/." "$work/"
rm -rf "$work/.lake" "$work/result.txt"
out=$(mktemp -d "${TMPDIR:-/tmp}/leanprof-experiment-out.XXXXXX")
cd "$work"
echo "fixture in $work"
export GIT_AUTHOR_NAME=leanprof-test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=leanprof-test GIT_COMMITTER_EMAIL=test@example.invalid
git init -q -b main
printf '.lake\n' > .gitignore
git add -A
git commit -q -m "fixture"

failed=0
fail() { echo "experiment-check: $1"; failed=1; }
clean() {
  [ -z "$(git status --porcelain)" ] || fail "$1: the checkout is not clean: $(git status --porcelain)"
}
# a candidate: branch $1 from $2 with perl's in-place substitution $4 in file $3
candidate() {
  git checkout -q -b "$1" "$2"
  perl -0pi -e "$4" "$3"
  git diff --quiet && fail "candidate $1: the substitution changed nothing"
  git commit -q -am "$1"
  git checkout -q main
}
# `try`, expecting exit code $1; its output and evidence go to $out
expect() {
  want=$1; shift
  code=0
  "$lp" experiment try "$@" > "$out/try.txt" 2>&1 || code=$?
  cat "$out/try.txt"
  [ "$code" = "$want" ] || fail "try $*: exit code $code, expected $want"
  path=$(sed -n 's/^  evidence: \([^ ]*\) .*/\1/p' "$out/try.txt")
  if [ -n "$path" ] && [ -f "$path" ]; then
    cp "$path" "$out/evidence.json"
    python3 "$root/scripts/contract-check.py" --validate experiment-try "$out/evidence.json" > "$out/contract.txt" ||
      { cat "$out/contract.txt"; fail "try $*: the evidence does not follow schemas/experiment-try.schema.json"; }
  else echo '{}' > "$out/evidence.json"; fi
  clean "try $*"
}
field() { python3 -c "import json,sys; d=json.load(open(sys.argv[2])); print(eval(sys.argv[1]))" "$1" "$out/evidence.json"; }

modify='s/bs := bs.set! i \(bs\[i\]!.push v\)/bs := bs.modify i (·.push v)/'
slow_proof='s/  unfold bucketOf\n  omega/  unfold bucketOf\n  have _h : v * 7 % 16 < 16 + v := by omega\n  omega/'
fast_proof='s/:= by\n  intro v hv\n  unfold bucketOf\n  omega/:=\n  fun v _ => Nat.mod_lt _ (by decide)/'
candidate lib-slow main Exp/Spec.lean "$slow_proof"
candidate lib-fast main Exp/Spec.lean "$fast_proof"
candidate lib-sorry main Exp/Spec.lean 's/Nat.mod_lt _ h/sorry/'
clean "the library candidates"

echo
echo "== library experiment: compile heartbeats"
"$lp" experiment start --id lib --no-test || fail "library start"
expect 1 lib-slow
grep -q "compile heartbeats" "$out/try.txt" || fail "lib-slow: not judged by heartbeats"
[ "$(field 'd["outcome"]')" = regression ] || fail "lib-slow: outcome $(field 'd["outcome"]'), not regression"
expect 0 lib-fast
grep -q "compile heartbeats: .* -> " "$out/try.txt" || fail "lib-fast: no heartbeat reason"
git notes --ref=leanprof-experiments show lib-fast | grep -q "KEEP" || fail "lib-fast: no note with the evidence"
expect 1 lib-sorry
[ "$(field 'd["guard"]["status"]')" = FAIL ] || fail "lib-sorry: the guard did not fail"
grep -q "sorry_dependency" "$out/try.txt" || fail "lib-sorry: no sorry finding"
[ "$(field 'd["outcome"]')" = correctness_failure ] || fail "lib-sorry: outcome is not correctness_failure"
"$lp" experiment finish --id lib || fail "library finish"

echo
echo "== run-time experiment"
"$lp" experiment start --exe bench --inputs inputs --heldout heldout --check-output result.txt \
  --runs 2 --pairs 10 -- 60000 > "$out/start.txt" 2>&1 || { cat "$out/start.txt"; fail "start"; }
cat "$out/start.txt"
grep -q 'tests      pass (`lake test`)' "$out/start.txt" || fail "start: the Lake test driver was not found"
grep -q "cases      3 " "$out/start.txt" || fail "start: not 3 cases"
clean "start"

echo
echo "-- the working tree: Array.modify, and a value that moves only beyond the inputs"
perl -0pi -e "$modify" Exp/Buckets.lean
perl -0pi -e 's/let i := bucketOf v k/let i := if v == 200000 then 1 else bucketOf v k/' Exp/Buckets.lean
"$lp" experiment try --working-tree --message "Array.modify in buckets" > "$out/try.txt" 2>&1 || fail "working tree: not KEEP (exit $?)"
grep -q "measured on case 0 only" "$out/try.txt" || fail "working tree: the verdict does not say which case was timed"
cat "$out/try.txt"
clean "working tree"
git log -1 --format=%B > "$out/message.txt"
grep -q "^Array.modify in buckets$" "$out/message.txt" || fail "working tree: commit subject"
grep -q "leanprof experiment .*KEEP" "$out/message.txt" || fail "working tree: no evidence in the message"
grep -q "outputs    identical on 3 case" "$out/message.txt" || fail "working tree: no outputs in the message"
grep -q "copies: 59,986 -> [0-9]$" "$out/message.txt" || fail "working tree: the copies did not go (almost) to 0"

candidate behaviour main Exp/Buckets.lean 's/else bucketOf v k/else if v == 65000 then 0 else bucketOf v k/'
candidate sorry main Exp/Spec.lean 's/Nat.mod_lt _ h/sorry/'
candidate weaker main Exp/Spec.lean 's/bucketOf v k < k :=\n  Nat.mod_lt _ h/bucketOf v k ≤ k :=\n  Nat.le_of_lt (Nat.mod_lt _ h)/'
candidate tests main tests/Check.lean 's/bs.all \(·.size == 10\)/true/'
candidate proof main Exp/Spec.lean "$fast_proof"
clean "the run-time candidates"

echo
echo "-- behaviour: one value moves, on the large input only"
expect 1 behaviour
grep -q "DIFFER on 1 of 3 cases" "$out/try.txt" || fail "behaviour: not caught on exactly one case"
grep -q "inputs/large.txt" "$out/try.txt" || fail "behaviour: the case is not named"
[ "$(field 'd.get("exact")')" = None ] || fail "behaviour: measured after the outputs differed"
[ "$(field 'd["outcome"]')" = correctness_failure ] || fail "behaviour: outcome is not correctness_failure"

echo
echo "-- sorry"
expect 1 sorry
grep -q "sorry_dependency bucketOf_lt" "$out/try.txt" || fail "sorry: no sorry finding"

echo
echo "-- a weaker statement"
expect 3 weaker
grep -q "signature_changed bucketOf_lt" "$out/try.txt" || fail "weaker: no signature finding"
[ "$(field 'd["outcome"]')" = insufficient_evidence ] || fail "weaker: outcome is not insufficient_evidence"

echo
echo "-- a loosened test"
expect 1 tests
grep -q "protected_file_changed tests/Check.lean" "$out/try.txt" || fail "tests: no protected-file finding"

echo
echo "-- a cheaper proof only: nothing to time"
expect 0 proof
grep -q "compiled   identical" "$out/try.txt" || fail "proof: the generated C was not found identical"
grep -q "heartbeats" "$out/try.txt" || fail "proof: not measured by heartbeats"
if grep -q "^  time" "$out/try.txt" || grep -q "^  exact" "$out/try.txt"; then fail "proof: measured although the code is the same"; fi

echo
echo "-- nothing changed"
expect 1 proof
grep -q "changes nothing" "$out/try.txt" || fail "no change: reason"
[ "$(field 'd["outcome"]')" = no_improvement ] || fail "no change: outcome is not no_improvement"

echo
echo "== finish: the held-out input"
code=0
"$lp" experiment finish > "$out/finish.txt" 2>&1 || code=$?
cat "$out/finish.txt"
[ "$code" = 1 ] || fail "finish: exit code $code, expected 1 (the held-out input differs)"
grep -q "held out: DIFFER on 1 of 1" "$out/finish.txt" || fail "finish: no held-out difference"
[ ! -e .lake/leanprof/experiments/current ] || fail "finish: the experiment is still current"
[ "$(git worktree list | wc -l)" -eq 1 ] || fail "finish: worktrees left: $(git worktree list)"
clean "finish"

echo
echo "== fix --elab: simp only, checked by an experiment"
fe=$(mktemp -d "${TMPDIR:-/tmp}/leanprof-fixelab.XXXXXX")
cp -R "$root/Tests/FixElab/." "$fe/"
rm -rf "$fe/.lake"
cd "$fe"
git init -q -b main
printf '.lake\n' > .gitignore
git add -A
git commit -q -m "fixture"
lake build >/dev/null 2>&1 || fail "fix --elab: the fixture does not build"
code=0
"$lp" fix --elab --dry-run FixElab.lean > "$out/fixelab.txt" 2>&1 || code=$?
cat "$out/fixelab.txt"
[ "$code" = 0 ] || fail "fix --elab --dry-run: exit code $code"
grep -q "+  simpa only using Nat.max_eq_right h" "$out/fixelab.txt" || fail "fix --elab --dry-run: no simpa only edit"
clean "fix --elab --dry-run"
code=0
"$lp" fix --elab --no-test FixElab.lean > "$out/fixelab.txt" 2>&1 || code=$?
cat "$out/fixelab.txt"
[ "$code" = 0 ] || fail "fix --elab: exit code $code, expected 0 (KEEP)"
grep -q "guard      PASS" "$(ls .lake/leanprof/fix/message.txt)" || fail "fix --elab: no guard evidence in the message"
git show leanprof-fix/elab-FixElab > "$out/fixelab-commit.txt" 2>&1 || fail "fix --elab: no branch"
grep -q "^+  simpa only using Nat.max_eq_right h" "$out/fixelab-commit.txt" || fail "fix --elab: the commit lacks the simpa only edit"
grep -q "KEEP against" "$out/fixelab-commit.txt" || fail "fix --elab: no evidence in the commit message"
[ "$(git rev-parse HEAD)" = "$(git rev-parse main)" ] || fail "fix --elab: the checkout moved"
[ "$(git worktree list | wc -l)" -eq 1 ] || fail "fix --elab: worktrees left: $(git worktree list)"
clean "fix --elab"

[ $failed = 0 ] && echo "experiment-check: all passed"
exit $failed
