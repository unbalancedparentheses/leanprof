#!/usr/bin/env python3
"""Check a leanprof JSON report from a real project (used by CI).

usage: check-report.py REPORT.json [--min-pos N] [--expect NAME=PATH]... [--elab]

- Names of functions (automatic scopes, sampled declarations, copy sites)
  must be demangled: no `l_`/`lp_` symbols, no `_xHH`/`_uHHHH` escapes, no
  `x2d` (an escaped '-').
- At least N entries (default 1) must have a `File.lean:line` position.
- `--expect NAME=PATH`: an entry named NAME must exist with a position in PATH.
- `--expect-untimed NAME`: NAME must be among the functions `run --auto`
  left untimed as too small to time. (Their names are not run through the
  demangling heuristic: this project's «_x41» and «x2d» are untimed, and
  correctly shown as `Odd._x41` and `Odd.x2d`.)
- `--elab`: the report is from `leanprof elab --heartbeats` (names are source
  text, so only positions and the unit are checked).
"""
import json
import re
import sys

args = sys.argv[1:]
if not args:
    sys.exit(__doc__)
path, rest = args[0], args[1:]
min_pos, expects, untimed_expects, elab = 1, [], [], False
while rest:
    a = rest.pop(0)
    if a == "--min-pos":
        min_pos = int(rest.pop(0))
    elif a == "--expect":
        name, _, where = rest.pop(0).partition("=")
        expects.append((name, where))
    elif a == "--expect-untimed":
        untimed_expects.append(rest.pop(0))
    elif a == "--elab":
        elab = True
    else:
        sys.exit(f"unknown option {a}")

report = json.load(open(path))
entries = [(s["name"], s.get("pos", "")) for s in report.get("scopes", []) if elab or s.get("auto")]
entries += [(c["function"], c.get("where", "")) for c in report.get("copies", [])]
problems = []
mangled = re.compile(r"^_?lp?_|_x[0-9a-f]{2}|_u[0-9a-f]{4}|_U[0-9a-f]{8}|x2d")
position = re.compile(r"^[^:]+\.lean:\d+$")
untimed = report.get("untimed", [])
if not elab:
    for name, _ in entries:
        if mangled.search(name):
            problems.append(f"not demangled: {name}")
for name in untimed_expects:
    if name not in untimed:
        problems.append(f"{name} is not among the untimed functions {untimed}")
if elab and report.get("unit") != "heartbeats":
    problems.append(f"unit is {report.get('unit')}, expected heartbeats")
with_pos = [(n, p) for n, p in entries if position.match(p)]
for n, p in entries:
    if p and not position.match(p):
        problems.append(f"bad position for {n}: {p}")
if len(with_pos) < min_pos:
    problems.append(f"{len(with_pos)} entries with positions, expected at least {min_pos}")
for name, where in expects:
    found = [p for n, p in entries if n == name]
    if not found:
        problems.append(f"no entry named {name}")
    elif not any(p.startswith(where + ":") for p in found):
        problems.append(f"{name} is at {found}, expected {where}")
print(f"{path}: {len(entries)} entries, {len(with_pos)} with positions")
for p in problems:
    print("  " + p)
sys.exit(1 if problems else 0)
