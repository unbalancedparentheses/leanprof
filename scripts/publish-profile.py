#!/usr/bin/env python3
"""Turn a project's compile-time report into a published profile.

    publish-profile.py [--leanprof BIN] [--ranges N] [--keep N] [--decls N] [--title T] PROJECT_DIR ELAB_JSON OUT_DIR

Writes OUT_DIR/index.html (`leanprof html`, run in PROJECT_DIR so the page
keeps the source lines around what it reports) and OUT_DIR/elab.json.gz (the
report). Both drop each definition's `path` (where its file is on the machine
that made the report; the editor uses it, the page does not), so nothing of
that machine is published. The page keeps the N costliest term and tactic
ranges (default 6000) and, with --keep N, the N costliest repeated operations
and definitions and the operations inside the N costliest declarations
(`leanprof html --keep`, default 3000) and, with --decls N, only the N costliest
declarations (default all); elab.json.gz keeps the whole report.
"""
import argparse
import gzip
import json
import os
import shutil
import subprocess
import sys


def drop(j, key):
    if isinstance(j, dict):
        return {k: drop(v, key) for k, v in j.items() if k != key}
    if isinstance(j, list):
        return [drop(x, key) for x in j]
    return j


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--leanprof", default=shutil.which("leanprof") or "leanprof")
    ap.add_argument("--ranges", type=int, default=6000)
    ap.add_argument("--keep", type=int, default=3000)
    ap.add_argument("--decls", type=int, default=0)
    ap.add_argument("--title")
    ap.add_argument("project")
    ap.add_argument("report")
    ap.add_argument("out")
    o = ap.parse_args()
    d = drop(json.load(open(o.report)), "path")
    os.makedirs(o.out, exist_ok=True)
    # the page reads the report from the project's usual place, so it names it as `elab` writes it
    rep = os.path.join(o.project, ".lake", "leanprof", "elab.json")
    os.makedirs(os.path.dirname(rep), exist_ok=True)
    with open(rep, "w") as f:
        json.dump(d, f, ensure_ascii=False, separators=(",", ":"))
    page = os.path.abspath(os.path.join(o.out, "index.html"))
    cmd = [o.leanprof, "html", "-o", page, "--ranges", str(o.ranges), "--keep", str(o.keep), "--decls", str(o.decls)] + (["--title", o.title] if o.title else [])
    subprocess.run(cmd, cwd=o.project, check=True)
    with gzip.open(os.path.join(o.out, "elab.json.gz"), "wt", encoding="utf-8", compresslevel=9) as f:
        json.dump(d, f, ensure_ascii=False, separators=(",", ":"))
    for name in ("index.html", "elab.json.gz"):
        p = os.path.join(o.out, name)
        text = open(p, "rb").read()
        if name.endswith(".gz"):
            text = gzip.decompress(text)
        for bad in (os.path.expanduser("~").encode(), b"/private/tmp/"):
            if bad in text:
                sys.exit(f"{p} still contains {bad.decode()}")
        print(f"{p}: {os.path.getsize(p) // 1024} KiB")


if __name__ == "__main__":
    main()
