#!/usr/bin/env python3
"""README "What it shows": `leanprof run copybug` and `leanprof explain` on Examples/CopyBug.lean.

Published (README, Apple M5 Max): 2001 copies of an Array (15.3 MiB) in
buildWithHistory at Examples/CopyBug.lean:17, 99% of the scope's time;
buildWithHistory called once, fib 10,945 times; explain blames line 21
(`history := history.push acc`) and line 22. Of the 2001 copies, 1999 are of
a shared value (n - 1 for n = 2000), the other 2 of persistent values.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import LP, ROOT, WORK, Claim, build_leanprof, read_json, sh, timing  # noqa: E402

c = Claim("copybug", "Apple M5 Max (README)", "leanprof run copybug; leanprof explain")
build_leanprof(("leanprof", "copybug"))
os.makedirs(WORK, exist_ok=True)
out = os.path.join(WORK, "copybug.json")
with timing():  # the copies are exact; their share of the scope's time is not
    sh([LP, "run", "--json", out, "copybug"], env={"LEANPROF_QUIET": "1"})
d = read_json(out)
cp = [x for x in d["copies"] if x["scope"] == "buildWithHistory" and x["kind"] == "Array"]
s = {x["name"]: x for x in d["scopes"]}
c.exact("copies in buildWithHistory (all)", sum(x["copies"] for x in cp), 2001)
c.exact("  of them of a shared value (n - 1)", sum(x["shared"] for x in cp), 1999)
c.exact("bytes copied", round(sum(x["bytes"] for x in cp) / 2**20, 1), 15.3)
c.exact("where", sorted({x["where"] for x in cp}), ["Examples/CopyBug.lean:17"])
c.exact("buildWithHistory calls", s["buildWithHistory"]["calls"], 1)
c.exact("fib calls", s["fib"]["calls"], 10945)
pct_scope = 100 * sum(x["copy_ns"] for x in cp) / s["buildWithHistory"]["total_ns"]
c.within("copy time as % of the scope (timing)", pct_scope, 90.0, 100.5, 99.1, "%")
ex = " ".join(sh([LP, "explain"]).stdout.split())  # unwrap lines
c.exact("explain: stored in `history` at line 21",
        "`acc` is stored in `history` at line 21" in ex, True)
c.exact("explain: updated afterwards at line 22", "is updated afterwards at line 22" in ex, True)
c.exact("explain: prints the fix `history := history.push acc.size`",
        "history := history.push acc.size" in ex, True)
c.finish()
