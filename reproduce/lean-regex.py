#!/usr/bin/env python3
"""docs/case-studies/lean-regex.md: leanprof on lean-regex's own benchmark.

Pinned: pandaman64/lean-regex at 32af6f3 (its toolchain, Lean 4.34.0-rc1),
the input every Init/Data/*/*.lean of Lean 4.35.0 concatenated (4.58 MB),
`Bench -e '[a-zA-Z_]+_(lt|le)\\b' -n 3 corpus.txt`. The same commit CI's
lean-regex job uses. Published on an Apple M5 Max.
"""
import argparse
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import LEANPROF_URL, LP, Claim, build_leanprof, clone, lean_prefix, read_json, sh, timed  # noqa: E402

COMMIT = "32af6f3"
PUBLISHED_LEANPROF = "8caf3fd"  # the leanprof that measured the case study's heartbeats
PATTERN = r"[a-zA-Z_]+_(lt|le)\b"
ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument("--no-elab", action="store_true", help="skip the compile-time (heartbeats) part")
ap.add_argument("--exact-only", action="store_true", help="no timing and no heartbeats part (CI)")
a = ap.parse_args()

c = Claim("lean-regex", "Apple M5 Max (docs/case-studies/lean-regex.md)",
          f"leanprof run/--allocs/--counters/--frees/elab on lean-regex {COMMIT} Bench -n 3")
build_leanprof()
repo = clone("https://github.com/pandaman64/lean-regex.git", COMMIT, "lean-regex")
rx = os.path.join(repo, "regex")
c.note("lean-regex toolchain", open(os.path.join(rx, "lean-toolchain")).read().strip())
sh(["lake", "build", "Bench"], cwd=rx)
src = os.path.join(lean_prefix("leanprover/lean4:v4.35.0"), "src", "lean", "Init", "Data")
corpus = os.path.join(rx, "corpus.txt")
with open(corpus, "wb") as out:
    for f in sorted(glob.glob(os.path.join(src, "*", "*.lean"))):
        out.write(open(f, "rb").read())
c.exact("corpus size (MB, Lean 4.35.0 Init/Data/*/*.lean)", round(os.path.getsize(corpus) / 1e6, 2), 4.58)
args = ["Bench", "--", "-e", PATTERN, "-n", "3", corpus]
plain = os.path.join(rx, ".lake", "build", "bin", "Bench")
times = []
for _ in range(1 if a.exact_only else 3):
    secs, p = timed([plain, "-e", PATTERN, "-n", "3", corpus], cwd=rx)
    times.append(secs)
c.note("Bench output", p.stdout.strip().splitlines()[-1] if p.stdout.strip() else "")
c.exact("matches (per search)", "4878" in p.stdout.replace(",", ""), True)
if not a.exact_only:
    c.within("uninstrumented, three searches, best of 3 (timing)", min(times), 1.4, 3.0, 2.0, " s")

env = {"LEANPROF_QUIET": "1"}
sh([LP, "run", "--json", "run.json", *args], cwd=rx, env=env)
r = read_json(os.path.join(rx, "run.json"))
cp = {}
for x in r["copies"]:
    cp[x["function"].split(" (in ")[0]] = cp.get(x["function"].split(" (in ")[0], 0) + x["copies"]
c.exact("copies, Regex.BufferStrategy", cp.get("Regex.BufferStrategy"), 13376304)
c.exact("copies, Regex.Data.SparseSet.insert", cp.get("Regex.Data.SparseSet.insert"), 43911)

sh([LP, "run", "--allocs", "--counters", "--frees", "--json", "all.json", *args], cwd=rx, env=env)
d = read_json(os.path.join(rx, "all.json"))
al = {}
for x in d["allocations"]:
    al[x["function"]] = al.get(x["function"], 0) + x["allocs"]
c.exact("allocations, total", sum(x["allocs"] for x in d["allocations"]), 204911040)
c.exact("allocations, Regex.VM.εClosure", al.get("Regex.VM.εClosure"), 117325311)
c.exact("allocations, Regex.VM.stepChar", al.get("Regex.VM.stepChar"), 74087541)
c.exact("allocations, Regex.VM.captureNext.go", al.get("Regex.VM.captureNext.go"), 13347033)
apps = sum(x["applications"] for x in d["closures"])
site = sum(x["applications"] for x in d["closures"]
           if x["function"] == "Regex.VM.εClosure" and x["target"] == "Regex.BufferStrategy")
c.exact("closure applications, total", apps, 13702767)
c.exact("  from εClosure to BufferStrategy", site, 13702767)
c.exact("objects freed (millions)", round(d["frees"]["objects"] / 1e6, 1), 131.8)
ru = [x for x in d["reuse"] if x["function"] == "Regex.VM.εClosure"]
checks = sum(x["checks"] for x in ru)
fails = sum(x["failures"] for x in ru)
c.exact("reuse checks in εClosure (millions)", round(checks / 1e6, 1), 158.6)
c.exact("  failed (%)", round(100 * fails / checks, 1) if checks else None, 9.4)

sh([LP, "run", "--auto", "--json", "auto.json", *args], cwd=rx, env=env)
au = {s["name"]: s for s in read_json(os.path.join(rx, "auto.json"))["scopes"]}
c.exact("--auto calls of Regex.BufferStrategy (millions)",
        round(au["Regex.BufferStrategy"]["calls"] / 1e6, 1) if "Regex.BufferStrategy" in au else None, 13.7)
c.exact("--auto calls of Regex.VM.eachStepChar.go",
        au["Regex.VM.eachStepChar.go"]["calls"] if "Regex.VM.eachStepChar.go" in au else None, 13376301)

if not (a.no_elab or a.exact_only):
    # The case study's heartbeats were measured with leanprof 8caf3fd, the
    # commit that published them. Heartbeats are exact for one leanprof and
    # one Lean, but what leanprof traces counts in them, and later leanprof
    # versions report fewer for the same file (shown below as info, not
    # checked). The four files of the published 108.5M total are not named in
    # the case study, so only the figures that name their place are checked.
    files = ["Regex/VM/Basic.lean", "Regex/Syntax/Parser/Basic.lean",
             "Regex/NFA/Compile/ProofData/Basic.lean"]
    old = clone(LEANPROF_URL, PUBLISHED_LEANPROF, "leanprof-" + PUBLISHED_LEANPROF)
    sh(["lake", "build", "leanprof"], cwd=old)

    def elab(lp):
        sh([lp, "elab", "--heartbeats", *files], cwd=rx)
        e = read_json(os.path.join(rx, ".lake", "leanprof", "elab.json"))
        sc = {s["pos"]: s["total_ns"] for s in e["scopes"]}
        # later versions print names in full (Regex.NFA.Compile.ProofData.nfa')
        rep = {(r["class"], r["op"].replace("Regex.NFA.Compile.ProofData.", "")): (r["count"], r["total"])
               for r in e["repeated"]}
        return sc, rep

    def mhb(x):
        return round(x / 1e6, 1) if x is not None else None

    for who, lp in ((f"leanprof {PUBLISHED_LEANPROF}", os.path.join(old, ".lake", "build", "bin", "leanprof")),
                    ("this leanprof", LP)):
        sc, rep = elab(lp)
        chk = c.exact if lp != LP else c.note
        chk(f"{who}: eachStepChar (VM/Basic.lean:105), M heartbeats", mhb(sc.get("Regex/VM/Basic.lean:105")), 13.5)
        dq = rep.get(("Meta.isDefEq", "i < nfa'.size =?= i < nfa'.size"), (None, None))
        chk(f"{who}: isDefEq `i < nfa'.size =?= i < nfa'.size`, times", dq[0], 76)
        chk(f"{who}:   its M heartbeats", mhb(dq[1]), 25.7)
        chk(f"{who}: whnf of nfa', times", rep.get(("Meta.whnf", "Non-easy whnf: nfa'"), (None,))[0], 5766)
        chk(f"{who}: whnf of inst.toProofData, times",
            rep.get(("Meta.whnf", "Non-easy whnf: inst.toProofData"), (None,))[0], 13560)
        chk(f"{who}: decreasing_tactic, M heartbeats",
            mhb(rep.get(("Elab.step", "decreasing_tactic"), (0, None))[1]), 25.2)
c.finish()
