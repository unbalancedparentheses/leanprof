#!/bin/sh
# Test of action/comment.sh (the GitHub Action's comment step) with a fake
# `gh` that serves two pages of comments and records what the step sends.
# The comment tag is data: a tag with `"` or jq syntax must find its own
# comment and only it. CI runs it; run it from the repository root.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/leanprof-comment.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
# `gh api --paginate URL --jq PROGRAM` runs PROGRAM on each page with jq;
# `gh api -X METHOD URL ...` is recorded
cat > "$work/bin/gh" <<'EOF'
#!/bin/sh
shift  # api
if [ "$1" = --paginate ]; then
  [ "$3" = --jq ] || exit 2
  for page in "$FAKE_PAGES"/*.json; do jq -r "$4" "$page"; done
  exit 0
fi
echo "$*" >> "$FAKE_LOG"
echo "https://example.invalid/comment"
EOF
chmod +x "$work/bin/gh"

failed=0
# $1: comment-tag, $2: the call expected in the log
run() {
  rm -rf "$work/pages" "$work/log"
  mkdir -p "$work/pages"
  printf '[{"id": 11, "body": "someone else\\n<!-- leanprof-action:default -->"},
    {"id": 12, "body": "<!-- leanprof-action:other -->\\nold report"}]' > "$work/pages/1.json"
  printf '[{"id": 13, "body": "<!-- leanprof-action:a\\"b -->\\nold report"}, {"id": 14, "body": null}]' \
    > "$work/pages/2.json"
  echo "report" > "$work/report.md"
  PATH="$work/bin:$PATH" FAKE_PAGES="$work/pages" FAKE_LOG="$work/log" RUNNER_TEMP="$work" \
    GITHUB_REPOSITORY=o/r LP_COMMENT=true LP_PR=5 LP_HEAD_REPO=o/r LP_TAG="$1" LP_REPORT="$work/report.md" \
    bash "$root/action/comment.sh" > "$work/out" 2>&1 || true
  got=$(cat "$work/log" 2>/dev/null || true)
  case "$got" in
    "$2"*) echo "ok   tag '$1': $got" ;;
    *) echo "FAIL tag '$1': expected '$2', got '$got'"; cat "$work/out"; failed=1 ;;
  esac
  python3 -c 'import json,sys; b=json.load(open(sys.argv[1]))["body"]; sys.exit(0 if b.startswith(sys.argv[2] + "\n") else 1)' \
    "$work/leanprof-action/comment.json" "<!-- leanprof-action:$1 -->" || { echo "FAIL tag '$1': payload"; failed=1; }
}
mkdir -p "$work/leanprof-action"
run other "-X PATCH repos/o/r/issues/comments/12"
run 'a"b' "-X PATCH repos/o/r/issues/comments/13"
# jq syntax in the tag must not change what matches
run 'x") or (true) or ("' "-X POST repos/o/r/issues/5/comments"
run new "-X POST repos/o/r/issues/5/comments"
# a marker later in a body is not this action's comment
run default "-X POST repos/o/r/issues/5/comments"
[ $failed = 0 ] && echo "comment-check: all passed"
exit $failed
