#!/usr/bin/env python3
"""docs/case-studies/batteries.md and compile-time-vs-lean-source-profiler.md;
README "Compile-time speed in the recorded comparison" and "What it found"
(Batteries: an iterator definition unfolded 24,369 times).

Pinned: leanprover-community/batteries at tag v4.35.0 (Lean 4.35.0), 195
modules; lean-source-profiler CLI 0.3.0 for --lsp. Published on an Apple M5
Max (18 cores), shared, load average 20-30 for the comparison.

Exact figures (heartbeats, unfold and repeat counts) are checked with the
leanprof that published them, a69f32a, which ran `lean --json`: heartbeats
are exact for one leanprof and one Lean, but what leanprof traces counts in
them, and since 55897d7 `elab` runs its own driver, whose wrappers allocate
too. This leanprof's figures are printed next to them as information.

Timings (this leanprof; the README's 17 s is from 55897d7, the comparison's
second round): accepted within half to twice the published time.
"""
import argparse
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import LEANPROF_URL, LP, WORK, Claim, build_leanprof, clone, read_json, sh, timed, which  # noqa: E402

TAG = "v4.35.0"
PUBLISHED_LEANPROF = "a69f32a"  # docs/case-studies/batteries.md
LSP_VERSION = "0.3.0"
ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--lsp", action="store_true", help="also lean-source-profiler's whole-project runs (needs npm)")
ap.add_argument("--no-exact", action="store_true", help="skip the exact figures (a second leanprof build)")
a = ap.parse_args()

c = Claim("batteries", "Apple M5 Max, 18 cores, shared (docs/case-studies/batteries.md)",
          f"leanprof elab --project [--heartbeats] on Batteries {TAG}")
build_leanprof()
bat = clone("https://github.com/leanprover-community/batteries", TAG, "batteries", depth_tag=True)
shutil.rmtree(os.path.join(bat, ".lake"), ignore_errors=True)
secs, _ = timed(["lake", "build"], cwd=bat)
c.within("lake build from clean (timing)", secs, 6.6, 26.6, 13.3, " s")
REPORT = os.path.join(bat, ".lake", "leanprof", "elab.json")
SLOWEST = [("Batteries/Data/List/Lemmas.lean", 98.3), ("Batteries/Data/BinaryHeap/WF.lean", 94.6),
           ("Batteries/Recycling/RBTree/Lemmas.lean", 83.2), ("Batteries/Recycling/RBTree/WF.lean", 83.0),
           ("Batteries/Data/String/Lemmas.lean", 79.6)]


def profile(lp, label):
    """One timed whole-project profile and two with --heartbeats; the reports are kept in WORK."""
    out = {}
    secs, _ = timed([lp, "elab", "--project", "--no-build"], cwd=bat)
    out["time_s"] = secs
    out["time"] = os.path.join(WORK, f"batteries-{label}-time.json")
    shutil.copy(REPORT, out["time"])
    out["hb"], out["hb_s"] = [], []
    for i in (1, 2):
        secs, _ = timed([lp, "elab", "--project", "--no-build", "--heartbeats"], cwd=bat)
        dest = os.path.join(WORK, f"batteries-{label}-heartbeats-{i}.json")
        shutil.copy(REPORT, dest)
        out["hb"].append(dest)
        out["hb_s"].append(secs)
    return out


def files(path):
    return {x["file"]: x["total_ns"] for x in read_json(path)["files"]}


def decls(path):
    return {s["key"]: s["total_ns"] for s in read_json(path)["scopes"]}


def check(p, chk, who, lp):
    """The case study's figures, from one profile; chk is c.exact or c.note."""
    t = read_json(p["time"])
    f1, f2 = files(p["hb"][0]), files(p["hb"][1])
    tot1, tot2 = sum(f1.values()), sum(f2.values())
    chk(f"{who}: modules profiled", len(f1), 195)
    chk(f"{who}: heartbeats, whole library (millions)", round(tot1 / 1e6), 1504)
    # Heartbeats of a whole project elaborated in parallel are not quite the
    # same from run to run; the case study says within 2 in a million.
    d1, d2 = decls(p["hb"][0]), decls(p["hb"][1])
    c.note(f"{who}: two --heartbeats runs differ by (heartbeats)", abs(tot1 - tot2), 3394)
    if chk == c.exact:
        c.within(f"{who}:   per million (variation)", 1e6 * abs(tot1 - tot2) / tot1, 0, 3.0, 2.3)
    c.note(f"{who}:   largest difference of one declaration", max(abs(d1[k] - d2.get(k, 0)) for k in d1), 290)
    for name, mhb in SLOWEST:
        chk(f"{who}: {name.replace('Batteries/', '')} (M heartbeats)", round(f1.get(name, 0) / 1e6, 1), mhb)
    rep = {}
    for r in read_json(p["hb"][0])["repeated"]:
        rep.setdefault(r["op"], (r["count"], round(r["total"] / 1e6, 1)))
    for op, n, mhb in (("decreasing_tactic", 193, 216.5), ("get_elem_tactic", 187, 145.2), ("grind", 99, 26.4)):
        chk(f"{who}: {op}: times, M heartbeats", rep.get(op), (n, mhb))
    # The definitions behind the work come from the timed profile, which
    # keeps only operations over its time threshold (1 ms): their counts
    # depend on timing, so they are checked within a range, not exactly
    # (--threshold 0 records all: 24,493 unfolds from 71 declarations).
    con = {(x["name"], x["kind"]): x for x in t["constants"]}
    rng = c.within if chk == c.exact else None
    for name, n, sites in (("Std.Iterator.IsPlausibleStep", 24369, 69), ("Std.IterM.IsPlausibleStep", 24371, None),
                           ("Std.Iter.IsPlausibleStep", 12180, None)):
        x = con.get((name, "unfold"), {})
        if rng:
            rng(f"{who}: unfolds of {name} (over the threshold)", x.get("count"), round(n * 0.99), round(n * 1.01), n)
            if sites:
                rng(f"{who}:   from declarations", x.get("sites"), sites - 5, sites + 5, sites)
        else:
            c.note(f"{who}: unfolds of {name}, from declarations", (x.get("count"), x.get("sites")), n)
    inst = "String.Slice.RevPosIterator.instIteratorSubtypePosNeEndPosOfPure"
    x = next((v for (nm, _k), v in con.items() if nm == inst), {})
    c.note(f"{who}: tries of {inst.split('.')[-1]}, from declarations (timing-dependent)",
           (x.get("count"), x.get("sites")), (66, 21))
    cmp = sh([lp, "compare", p["hb"][0], p["hb"][1]], check=False)
    chk(f"{who}: compare of the two --heartbeats reports finds no regression", cmp.returncode, 0)


cur = profile(LP, "current")
c.within("elab --project, whole library (timing)", cur["time_s"], 8.4, 34.0, 16.8, " s")
c.note("elab --project --heartbeats (timing, two runs)", [round(s, 1) for s in cur["hb_s"]], "19.7 s")
c.note("term and tactic ranges in the report", len(read_json(cur["time"]).get("ranges", [])), 10594)
if not a.no_exact:
    old = clone(LEANPROF_URL, PUBLISHED_LEANPROF, "leanprof-" + PUBLISHED_LEANPROF)
    sh(["lake", "build", "leanprof"], cwd=old)
    old_lp = os.path.join(old, ".lake", "build", "bin", "leanprof")
    pub = profile(old_lp, PUBLISHED_LEANPROF)
    c.note(f"leanprof {PUBLISHED_LEANPROF}: elab --project (timing)", round(pub["time_s"], 1), "17.0 s")
    check(pub, c.exact, f"leanprof {PUBLISHED_LEANPROF}", old_lp)
check(cur, c.note, "this leanprof", LP)

if a.lsp:
    npm = which("npm")
    if not npm:
        print("reproduce: --lsp needs npm (Node 20)", file=sys.stderr)
        sys.exit(2)
    import hashlib
    import urllib.request
    prefix = os.path.join(WORK, f"lean-source-profiler-{LSP_VERSION}")
    os.makedirs(prefix, exist_ok=True)
    base = f"https://github.com/Vilin97/lean-source-profiler/releases/download/v{LSP_VERSION}/"
    tgz = os.path.join(prefix, "lean-source-profiler-cli.tgz")
    urllib.request.urlretrieve(base + "lean-source-profiler-cli.tgz", tgz)
    sums = urllib.request.urlopen(base + "SHA256SUMS").read().decode()
    want = next(line.split()[0] for line in sums.splitlines() if line.endswith("lean-source-profiler-cli.tgz"))
    if hashlib.sha256(open(tgz, "rb").read()).hexdigest() != want:
        print("reproduce: lean-source-profiler-cli.tgz does not match the release's SHA256SUMS", file=sys.stderr)
        sys.exit(2)
    sh([npm, "install", "--prefix", prefix, tgz])
    lsp = os.path.join(prefix, "node_modules", ".bin", "lean-profile")
    c.note("lean-source-profiler CLI, release checked against its SHA256SUMS", LSP_VERSION)
    for mode, pubs in (("compact", 102.9), ("detailed", 152.3)):
        dest = os.path.join(WORK, f"lsp-{mode}")  # must be a new directory
        shutil.rmtree(dest, ignore_errors=True)
        # it exits non-zero when some files fail (8 of 271 in the case study), so only the time is used
        secs, p = timed([lsp, "profile", "--project", ".", "--mode", mode, "--output", dest], cwd=bat, check=False)
        if not os.path.isdir(dest):
            print(p.stdout[-3000:], file=sys.stderr)
            print("reproduce: lean-source-profiler wrote no session", file=sys.stderr)
            sys.exit(2)
        c.note(f"  lean-source-profiler's last line ({mode})", (p.stdout.strip().splitlines() or [""])[-1][:100])
        c.within(f"lean-source-profiler {LSP_VERSION} --mode {mode}, whole project (timing)",
                 secs, pubs / 2, pubs * 2, pubs, " s")
        c.within(f"  its time over leanprof's elab --project", secs / cur["time_s"], 3.0, 1e9,
                 pubs / 16.8, "x")
c.finish()
