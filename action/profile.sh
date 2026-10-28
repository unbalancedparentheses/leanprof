#!/usr/bin/env bash
# Part of the leanprof GitHub Action (action.yml): profile the base and head
# commits in one extra worktree (so dependency builds are reused between the
# two), compare them and render report.md. Inputs come as LP_* variables.
# Bash 3.2 compatible (macOS runners).

export PATH="$HOME/.elan/bin:$PATH"
lp="$GITHUB_ACTION_PATH/.lake/build/bin/leanprof"
out="${RUNNER_TEMP:-/tmp}/leanprof-action"
work="${RUNNER_TEMP:-/tmp}/leanprof-checkout"
rm -rf "$out"
mkdir -p "$out"

fail() { echo "::error::leanprof action: $*"; exit 1; }

src="$LP_WORKDIR"
case "$src" in /*) ;; *) src="$GITHUB_WORKSPACE/$src" ;; esac
top=$(git -C "$src" rev-parse --show-toplevel 2>/dev/null) ||
  fail "$src is not inside a git checkout: run actions/checkout first"
sub=$(git -C "$src" rev-parse --show-prefix)

[ -n "$LP_EXE" ] || [ -n "$LP_ELAB_FILES" ] || fail "set executable, elab-files or both"
zero=0000000000000000000000000000000000000000
if [ -z "$LP_BASE" ] || [ "$LP_BASE" = "$zero" ]; then
  fail "no base commit to compare with: run on pull_request, or set base-ref"
fi

for sha in "$LP_BASE" "$LP_HEAD"; do
  git -C "$top" cat-file -e "$sha^{commit}" 2>/dev/null ||
    git -C "$top" fetch --quiet --no-tags --depth=1 origin "$sha" ||
    fail "cannot fetch commit $sha"
done

git -C "$top" worktree remove --force "$work" >/dev/null 2>&1
rm -rf "$work"
git -C "$top" worktree add --quiet --detach "$work" "$LP_BASE" || fail "cannot create a worktree at $LP_BASE"

# the executable's arguments, with shell-style quoting
args=()
while IFS= read -r -d '' a; do args+=("$a"); done < <(python3 -c '
import shlex, sys
sys.stdout.write("".join(a + "\0" for a in shlex.split(sys.argv[1])))' "$LP_ARGS")

# profile_side NAME SHA: writes $out/NAME.json and/or $out/NAME-elab.json
profile_side() {
  local side=$1 sha=$2 rc=0
  echo "::group::leanprof: $side ($sha)"
  git -C "$work" checkout --quiet --force --detach "$sha" || return 1
  cd "$work/$sub" || return 1
  if [ -n "$LP_SETUP" ]; then
    bash -c "$LP_SETUP" || { echo "::warning::setup failed on $side"; rc=1; }
  fi
  if [ $rc = 0 ] && [ -n "$LP_EXE" ]; then
    local flags=()
    [ "$LP_ALLOCS" = true ] && flags=(--allocs)
    "$lp" run ${flags[@]+"${flags[@]}"} --json "$out/$side.json" "$LP_EXE" -- ${args[@]+"${args[@]}"}
    local prc=$?
    if [ ! -s "$out/$side.json" ]; then
      echo "::warning::leanprof run failed on $side (exit $prc)"; rc=1
    elif [ $prc != 0 ]; then
      echo "::warning::$LP_EXE exited with $prc on $side"
    fi
    # why each copy happened, from this checkout's emitted C (only read, never run)
    if [ $rc = 0 ] && [ "$LP_EXPLAIN" = true ]; then
      "$lp" explain --report "$out/$side.json" --top 1000 --out "$out/$side-explain.json" > /dev/null ||
        echo "::warning::leanprof explain failed on $side; copies are compared without causes"
    fi
  fi
  if [ $rc = 0 ] && [ -n "$LP_ELAB_FILES" ]; then
    # imports must be built for `lake env lean`
    lake build || echo "::warning::lake build failed on $side; measuring compile cost anyway"
    local files=() f
    for f in $LP_ELAB_FILES; do [ -f "$f" ] && files+=("$f"); done
    if [ ${#files[@]} = 0 ]; then
      echo '{"version":3,"elab":true,"unit":"heartbeats","wall_ns":0,"scopes":[],"copies":[]}' > "$out/$side-elab.json"
    else
      local eflags=()
      [ "$LP_EXPLAIN" = true ] && eflags=(--counts)
      "$lp" elab --heartbeats ${eflags[@]+"${eflags[@]}"} --top 5 --out "$out/$side-elab.json" "${files[@]}" ||
        { echo "::warning::leanprof elab failed on $side"; rc=1; }
    fi
  fi
  cd "$GITHUB_WORKSPACE"
  echo "::endgroup::"
  return $rc
}

base_ok=true head_ok=true
profile_side base "$LP_BASE" || base_ok=false
profile_side head "$LP_HEAD" || head_ok=false
git -C "$top" worktree remove --force "$work" >/dev/null 2>&1

title="$LP_TITLE"
if [ -z "$title" ]; then
  if [ -n "$LP_EXE" ]; then title="leanprof: $LP_EXE${LP_ARGS:+ $LP_ARGS}"; else title="leanprof: compile cost"; fi
fi
report="$out/report.md"
regressed=false
if [ $head_ok != true ]; then
  printf '### %s: ❌ head could not be profiled\n\nSee the workflow log.\n' "$title" > "$report"
  echo "head-failed=true" >> "$GITHUB_OUTPUT"
elif [ $base_ok != true ]; then
  printf '### %s: base could not be profiled\n\nThe base commit did not build or run, so there is nothing to compare with. See the workflow log.\n' "$title" > "$report"
else
  pairs=()
  [ -n "$LP_EXE" ] && pairs+=("$out/base.json" "$out/head.json")
  [ -n "$LP_ELAB_FILES" ] && pairs+=("$out/base-elab.json" "$out/head-elab.json")
  why=()
  [ -s "$out/head-explain.json" ] && why=(--explain "$out/head-explain.json")
  echo "::group::leanprof compare"
  i=0
  while [ $i -lt ${#pairs[@]} ]; do
    "$lp" compare ${why[@]+"${why[@]}"} "${pairs[$i]}" "${pairs[$((i + 1))]}" | tee -a "$out/compare.txt"
    i=$((i + 2))
  done
  echo "::endgroup::"
  budget=()
  if [ -n "${LP_MAX_HB:-}" ]; then
    [ -n "$LP_ELAB_FILES" ] || fail "max-heartbeats needs elab-files"
    budget=(--max-heartbeats "$LP_MAX_HB")
  fi
  "$lp" report-md --fail-on "$LP_FAIL_ON" --title "$title" ${why[@]+"${why[@]}"} ${budget[@]+"${budget[@]}"} "${pairs[@]}" > "$report"
  case $? in
    0) ;;
    1) regressed=true ;;
    *) fail "leanprof report-md failed (is fail-on valid? $LP_FAIL_ON)" ;;
  esac
fi

run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
printf '\n<sub>base %s · head %s · [workflow run](%s) · [leanprof](https://github.com/unbalancedparentheses/leanprof)</sub>\n' \
  "$(echo "$LP_BASE" | cut -c1-7)" "$(echo "$LP_HEAD" | cut -c1-7)" "$run_url" >> "$report"

cat "$report"
{
  cat "$report"
  if [ -s "$out/compare.txt" ]; then
    printf '\n<details><summary>leanprof compare</summary>\n\n```\n'
    cat "$out/compare.txt"
    printf '```\n\n</details>\n'
  fi
} >> "$GITHUB_STEP_SUMMARY"

echo "report=$report" >> "$GITHUB_OUTPUT"
echo "regressed=$regressed" >> "$GITHUB_OUTPUT"
