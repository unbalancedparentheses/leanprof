#!/usr/bin/env python3
"""Capture the real `leanprof run` and `leanprof explain` output on
Examples/CopyBug.lean that the landing page shows.

    lake build leanprof && python3 website/capture.py

Run from the repository root and commit the files it writes in
website/output/. The landing page prints them as they are.
"""

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "website" / "output"
LP = str(ROOT / ".lake" / "build" / "bin" / "leanprof")


def run(*args):
    return subprocess.run([LP, *args], cwd=ROOT, capture_output=True, text=True, check=True)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    r = run("run", "copybug")
    raw = r.stdout + r.stderr
    # the report: from its summary line to the end of the copies table
    m = re.search(r"^leanprof: \d+ scopes.*?(?=^memory:)", raw, re.S | re.M)
    (OUT / "run.txt").write_text("$ leanprof run copybug\n\n" + m.group(0).rstrip() + "\n")
    e = run("explain")
    body = (e.stdout + e.stderr).split("\n", 2)[2]  # without the "why N of N" header
    (OUT / "explain.txt").write_text("$ leanprof explain\n\n" + body.rstrip() + "\n")
    v = subprocess.run(["lean", "--version"], capture_output=True, text=True).stdout
    (OUT / "CAPTURED").write_text(v)


if __name__ == "__main__":
    main()
