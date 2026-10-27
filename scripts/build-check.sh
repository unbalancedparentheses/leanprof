#!/bin/sh
# End-to-end test of `leanprof build` on Tests/Build (Demo.Heavy is the slow
# module; Demo.Leaf imports it but uses only Demo.Base), copied to a fresh git
# repository:
#
#   build --clean --validate 2 --imports 1 --html
#     every process is recorded: modules, C compiles and the link
#     the critical path runs through Demo.Heavy and Demo.Leaf, ends with the link
#     each touched module rebuilds exactly the predicted modules
#     Leaf's `import Demo.Heavy` narrowed to `import Demo.Base` builds
#   the checkout is unchanged and the worktree removed
#   a plain `lake build` afterwards rebuilds nothing
#   build again: nothing to rebuild, no process recorded
#   build --from FILE shows the saved report
#
# Timing numbers are not checked (they depend on the machine). Exits 1 on any
# unexpected result. Run it from the repository root. With a toolchain
# (`sh scripts/build-check.sh leanprover/lean4:v4.27.0`), the fixture builds
# with that Lean; leanprof itself is built with lean-toolchain's.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
(cd "$root" && lake build leanprof >/dev/null)
lp="$root/.lake/build/bin/leanprof"

work=$(mktemp -d "${TMPDIR:-/tmp}/leanprof-build.XXXXXX")
cp -R "$root/Tests/Build/." "$work/"
rm -rf "$work/.lake"
if [ $# -gt 0 ]; then echo "$1" > "$work/lean-toolchain"; fi
cd "$work"
echo "fixture in $work"
export GIT_AUTHOR_NAME=leanprof-test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=leanprof-test GIT_COMMITTER_EMAIL=test@example.invalid
git init -q -b main
printf '.lake\n' > .gitignore
git add -A
git commit -qm fixture

fail() { echo "FAIL: $*"; exit 1; }

"$lp" build --clean --quiet --validate 2 --imports 1 --html out.html --json out.json > report.txt ||
  { cat report.txt; fail "leanprof build exited with $?"; }
cat report.txt
python3 - out.json <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
def check(name, ok, detail=""):
    if not ok:
        print(f"FAIL: {name} {detail}")
        sys.exit(1)
    print(f"ok   {name}")
jobs = r["jobs"]
kinds = {j["kind"] for j in jobs}
check("report kind and version", r["leanprof"] == "build" and r["version"] == 1)
check("modules, C compiles and the link recorded", {"lean", "cc", "link"} <= kinds, kinds)
lean = {j["name"] for j in jobs if j["kind"] == "lean"}
want = {"Demo.Base", "Demo.Heavy", "Demo.Mid", "Demo.Leaf", "Demo.Top", "Demo", "Main"}
check("every module elaborated once", want <= lean and len([j for j in jobs if j["kind"] == "lean"]) == len(lean), lean)
check("every job has a peak memory", all(j["max_rss_bytes"] > 0 for j in jobs))
check("jobs end after they start", all(j["end_s"] >= j["start_s"] for j in jobs))
by = {j["id"]: j for j in jobs}
heavy = next(j for j in jobs if j["kind"] == "lean" and j["name"] == "Demo.Heavy")
base = next(j for j in jobs if j["kind"] == "lean" and j["name"] == "Demo.Base")
check("Heavy depends on Base", base["id"] in heavy["deps"], heavy["deps"])
steps = [by[s["job"]] for s in r["critical_path"]["steps"]]
names = [(s["kind"], s["name"]) for s in steps]
check("critical path through Heavy", ("lean", "Demo.Heavy") in names, names)
check("critical path ends with the link", steps[-1]["kind"] == "link", names)
check("critical jobs marked", all(s["critical"] for s in steps))
check("slack zero on the critical path", all(s["slack_s"] < 0.05 for s in steps if s["kind"] == "lean"), [s["slack_s"] for s in steps])
mods = {m["name"]: m for m in r["modules"]}
check("modules built", all(mods[m]["state"] == "built" for m in want), {m: mods[m]["state"] for m in want if m in mods})
check("Heavy's rebuild includes its importers", mods["Demo.Heavy"]["rebuild"]["jobs"] > mods["Demo.Top"]["rebuild"]["jobs"])
check("parallelism profile", r["parallelism"]["peak"] >= 1 and len(r["parallelism"]["profile"]) > 2)
check("no-op build timed", r["model"]["noop_measured"] and r["model"]["noop_jobs"] == 0, r["model"])
v = r["validation"]["samples"]
check("two modules validated", len(v) == 2, v)
check("validated rebuilds as predicted", all(s.get("same_modules") for s in v), v)
check("validation builds passed", all(s["exit_codes"] == [0, 0] for s in v), [s.get("error") for s in v])
check("validated builds measured",all(len(s["measured_s"]) == 2 and min(s["measured_s"]) > 0 for s in v), v)
tried = r["imports"]["tried"]
check("one import tried", len(tried) == 1, tried)
t = tried[0]
check("Leaf's import of Heavy narrowed to Base", t["module"] == "Demo.Leaf" and t["import"] == "Demo.Heavy"
      and t["verdict"] == "builds" and t["replaced_by"] == ["Demo.Base"], t)
check("its rebuild measured before and after", t["before_modules"] > t["after_modules"], t)
EOF
grep -q "Build timeline" out.html || fail "no HTML timeline"
rm out.html out.json report.txt
test -z "$(git status --porcelain)" || { git status --porcelain; fail "the checkout changed"; }
test "$(git worktree list | wc -l)" -eq 1 || { git worktree list; fail "a worktree was left behind"; }
lake build > plain.txt 2>&1 || { cat plain.txt; fail "plain lake build failed"; }
if grep -q "Built" plain.txt; then cat plain.txt; fail "a plain lake build after leanprof build rebuilt something"; fi
echo "ok   a plain lake build afterwards rebuilds nothing"
"$lp" build --quiet --json again.json > again.txt || { cat again.txt; fail "second build failed"; }
grep -q "No process ran" again.txt || { cat again.txt; fail "the second build recorded a process"; }
echo "ok   nothing to rebuild the second time"
"$lp" build --from again.json > from.txt
grep -q "No process ran" from.txt || { cat from.txt; fail "--from"; }
echo "ok   --from shows a saved report"
echo "build-check: all passed"
