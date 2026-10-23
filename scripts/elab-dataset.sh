#!/bin/sh
# Profile a whole Lake project into a dataset directory: one file per module with
# every term and tactic and the timeline of its elaboration, an index, the report
# and a Chrome trace (formats: docs/guide/elab-dataset.md).
#
#   sh scripts/elab-dataset.sh PROJECT_DIR OUT_DIR [leanprof elab options...]
#
# e.g.  sh scripts/elab-dataset.sh ~/src/batteries datasets/batteries --compact
#       LEANPROF=/path/to/leanprof sh scripts/elab-dataset.sh . /tmp/ds --jobs 4
#
# The project is built first (`lake build`, which `elab --project` runs). OUT_DIR
# gets index.json, elab.json, modules/MODULE.json and trace.json (open it in
# https://ui.perfetto.dev), plus provenance.json: the project's commit, the Lean
# and leanprof versions, the machine and the command. Nothing is uploaded.
set -eu
if [ $# -lt 2 ]; then sed -n '2,15p' "$0"; exit 2; fi
here="$(cd "$(dirname "$0")" && pwd)"
lp="${LEANPROF:-leanprof}"
case "$lp" in */*) lp="$(cd "$(dirname "$lp")" && pwd)/$(basename "$lp")" ;; esac
project="$1"; out="$2"; shift 2
mkdir -p "$out"
out="$(cd "$out" && pwd)"
rm -rf "$out/modules"
cd "$project"
start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
"$lp" elab --project --out "$out/elab.json" --dataset "$out" --chrome-trace "$out/trace.json" "$@" > "$out/elab.txt"
tail -3 "$out/elab.txt"
commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
python3 - "$out" "$start" "$commit" "$*" <<'PY'
import json, os, platform, subprocess, sys
out, start, commit, opts = sys.argv[1:5]
def cmd(*a):
    try: return subprocess.run(a, capture_output=True, text=True).stdout.strip()
    except OSError: return ""
idx = json.load(open(os.path.join(out, "index.json")))
json.dump({"project": idx.get("project"), "project_commit": commit, "remote": cmd("git", "remote", "get-url", "origin"),
           "lean": cmd("lake", "env", "lean", "--version"), "started": start, "options": opts,
           "machine": {"system": platform.system(), "machine": platform.machine(), "cpus": os.cpu_count()},
           "files": len(idx.get("files", []))}, open(os.path.join(out, "provenance.json"), "w"), indent=1)
PY
python3 "$here/check-elab-dataset.py" "$out"
