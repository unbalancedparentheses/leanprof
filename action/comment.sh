#!/usr/bin/env bash
# Part of the leanprof GitHub Action (action.yml): post the report as a pull
# request comment, or update the one posted before (found by its marker).
# Never fails the job: without permission (pull requests from forks get a
# read-only token) the report stays in the job summary.

[ "$LP_COMMENT" = true ] || exit 0
if [ -z "$LP_PR" ]; then
  echo "not a pull request: the report is in the job summary"
  exit 0
fi
if [ -n "$LP_HEAD_REPO" ] && [ "$LP_HEAD_REPO" != "$GITHUB_REPOSITORY" ]; then
  echo "::notice::leanprof: pull request from a fork, whose token cannot comment; the report is in the job summary"
  exit 0
fi

marker="<!-- leanprof-action:$LP_TAG -->"
payload="${RUNNER_TEMP:-/tmp}/leanprof-action/comment.json"
python3 - "$marker" "$LP_REPORT" "$payload" <<'PY'
import json, sys
marker, report, payload = sys.argv[1:]
json.dump({"body": marker + "\n" + open(report, encoding="utf-8").read()}, open(payload, "w"))
PY

repo="repos/$GITHUB_REPOSITORY"
id=$(gh api --paginate "$repo/issues/$LP_PR/comments" \
  --jq ".[] | select(.body | startswith(\"$marker\")) | .id" 2>/dev/null | head -n 1)
if [ -n "$id" ]; then
  gh api -X PATCH "$repo/issues/comments/$id" --input "$payload" --jq .html_url && exit 0
else
  gh api -X POST "$repo/issues/$LP_PR/comments" --input "$payload" --jq .html_url && exit 0
fi
echo "::warning::leanprof: could not comment on the pull request (the workflow needs 'permissions: pull-requests: write'); the report is in the job summary"
exit 0
