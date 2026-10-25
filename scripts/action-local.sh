#!/usr/bin/env bash
# Run the GitHub Action's profiling step (action/profile.sh) on this machine,
# as a pull request's workflow would, and print the comment it renders:
#
#   scripts/action-local.sh REPO BASE HEAD ELAB_FILES [EXE [ARGS]]
#
# REPO is a git checkout (it gets a temporary extra worktree, removed at the
# end); BASE and HEAD are commits of it; ELAB_FILES is passed as `elab-files`.
# Nothing is posted: the comment is written to $OUT/leanprof-action/report.md
# (OUT defaults to a new temporary directory). Set LP_EXPLAIN=false to see the
# comment without causes. Needs leanprof built (`lake build leanprof`).
set -u
[ $# -ge 4 ] || { sed -n '2,12p' "$0"; exit 2; }
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$1" && pwd)
export GITHUB_ACTION_PATH=$here GITHUB_WORKSPACE=$repo
export RUNNER_TEMP=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/leanprof-action-local.XXXXXX")}
export GITHUB_OUTPUT=$RUNNER_TEMP/output GITHUB_STEP_SUMMARY=$RUNNER_TEMP/summary.md
export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=local/$(basename "$repo") GITHUB_RUN_ID=0
export LP_BASE=$2 LP_HEAD=$3 LP_ELAB_FILES=$4 LP_EXE=${5:-} LP_ARGS=${6:-}
export LP_ALLOCS=true LP_FAIL_ON=${LP_FAIL_ON:-copies,heartbeats} LP_WORKDIR=. LP_SETUP= LP_TITLE=
export LP_EXPLAIN=${LP_EXPLAIN:-true}
mkdir -p "$RUNNER_TEMP"
: > "$GITHUB_OUTPUT"
cd "$repo" && bash "$here/action/profile.sh" > "$RUNNER_TEMP/profile.log" 2>&1
rc=$?
cat "$RUNNER_TEMP/leanprof-action/report.md" 2>/dev/null || { cat "$RUNNER_TEMP/profile.log"; exit 1; }
echo "(log: $RUNNER_TEMP/profile.log; outputs: $(tr '\n' ' ' < "$GITHUB_OUTPUT"))" >&2
exit $rc
