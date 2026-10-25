#!/usr/bin/env python3
"""Tests/Smoke, a project with no dependency on leanprof, profiled from outside.

Published (scripts/smoke-baseline.json, the facts `scripts/smoke.py --check`
holds every release to): with n = 2000, `leanprof run` counts 1,999 copies
of a shared Array in buildWithHistory (Main.lean:10) and 999 of a shared
String in strings (Main.lean:19); `run --auto` counts fib's calls exactly,
242,785 (fib 25), and main, buildWithHistory, strings once each.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import LP, ROOT, WORK, Claim, build_leanprof, read_json, sh  # noqa: E402

c = Claim("smoke", "any machine (deterministic; scripts/smoke-baseline.json)",
          "leanprof run [--auto] smoke -- 2000, on a copy of Tests/Smoke")
build_leanprof()
work = os.path.join(WORK, "smoke")
shutil.rmtree(work, ignore_errors=True)
os.makedirs(work)
for f in ("lakefile.toml", "lake-manifest.json", "lean-toolchain", "Main.lean"):
    shutil.copy(os.path.join(ROOT, "Tests", "Smoke", f), work)
c.note("toolchain", open(os.path.join(work, "lean-toolchain")).read().strip())
sh(["lake", "build", "smoke"], cwd=work)
env = {"LEANPROF_QUIET": "1"}
sh([LP, "run", "--json", "run.json", "smoke", "--", "2000"], cwd=work, env=env)
r = read_json(os.path.join(work, "run.json"))
copies = {(x["function"].split(" (in ")[0], x["where"], x["kind"]): x["shared"] for x in r["copies"] if x["shared"]}
c.exact("shared copies, buildWithHistory Main.lean:10 Array",
        copies.get(("buildWithHistory", "Main.lean:10", "Array")), 1999)
c.exact("shared copies, strings Main.lean:19 String", copies.get(("strings", "Main.lean:19", "String")), 999)
c.exact("no other shared copies", sorted(k[0] for k in copies), ["buildWithHistory", "strings"])
c.exact("self check", r["self_check"]["ok"], True)
sh([LP, "run", "--auto", "--json", "auto.json", "smoke", "--", "2000"], cwd=work, env=env)
a = {s["name"]: s for s in read_json(os.path.join(work, "auto.json"))["scopes"]}
for name, pos, calls in [("fib", "Main.lean:5", 242785), ("main", "Main.lean:29", 1),
                         ("buildWithHistory", "Main.lean:10", 1), ("strings", "Main.lean:19", 1)]:
    c.exact(f"--auto calls of {name} ({pos})", (a[name]["pos"], a[name]["calls"]) if name in a else None,
            (pos, calls))
c.finish()
