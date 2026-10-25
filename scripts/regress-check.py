#!/usr/bin/env python3
"""Check that `compare` and `report-md` say why something got worse.

Tests/Regress holds two versions (base/ and head/) of a small Lake project
with known regressions: a lemma that joins the simp set, a definition whose
unfolding gets more expensive, and an array kept alive across a push (a copy
per push). This script profiles both versions with the real pipeline
(`leanprof elab --heartbeats --counts`, `leanprof run --allocs`, `leanprof
explain`) in one temporary directory, as the GitHub Action does, and checks
that the known causes are named.

    python3 scripts/regress-check.py           # check (live pipeline, then golden output)
    python3 scripts/regress-check.py --save    # regenerate Tests/Regress/fixtures and expected/

The golden part renders `report-md` and `compare` from the reports saved in
Tests/Regress/fixtures and compares them with Tests/Regress/expected byte for
byte, so a change to the comment shows up in review. Run from anywhere, with
Lean on PATH and leanprof built (`lake build leanprof`).
"""
import json, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(ROOT, "Tests", "Regress")
LP = os.path.join(ROOT, ".lake", "build", "bin", "leanprof")
ENV = dict(os.environ, LEANPROF_QUIET="1")
TITLE = "leanprof: regress fixture"


def sh(*args, cwd, ok=(0,)):
    p = subprocess.run(list(args), cwd=cwd, env=ENV, capture_output=True, text=True)
    if p.returncode not in ok:
        sys.exit(f"failed ({p.returncode}): {' '.join(args)}\n{p.stdout[-3000:]}\n{p.stderr[-3000:]}")
    return p


def scrub(x):
    """Drop what depends on the machine (absolute paths, timings of leanprof itself)."""
    if isinstance(x, dict):
        return {k: scrub(v) for k, v in x.items() if k not in ("path", "timing")}
    if isinstance(x, list):
        return [scrub(v) for v in x]
    return x


def profile(out):
    """Profile base/ then head/ in one directory; reports go to `out`."""
    work = tempfile.mkdtemp(prefix="leanprof-regress-")
    try:
        for f in ("lakefile.toml", "lean-toolchain"):
            shutil.copy(os.path.join(FIX, f), work)
        for side in ("base", "head"):
            for f in ("Main.lean", "Regress.lean"):
                shutil.copy(os.path.join(FIX, side, f), os.path.join(work, f))
            sh(LP, "elab", "--heartbeats", "--counts", "--out", os.path.join(out, f"{side}-elab.json"),
               "Regress.lean", cwd=work)
            sh(LP, "run", "--allocs", "--json", os.path.join(out, f"{side}.json"), "regress", "--", "300", cwd=work)
            sh(LP, "explain", "--report", os.path.join(out, f"{side}.json"), "--top", "50",
               "--out", os.path.join(out, f"{side}-explain.json"), cwd=work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    for f in os.listdir(out):
        if f.endswith(".json"):
            p = os.path.join(out, f)
            with open(p) as h:
                d = scrub(json.load(h))
            with open(p, "w") as h:
                json.dump(d, h, indent=1, sort_keys=True)
                h.write("\n")


def render(d):
    """report-md and compare of the reports in `d`: (report.md, compare-elab.txt, compare-run.txt)."""
    j = lambda f: os.path.join(d, f)
    md = sh(LP, "report-md", "--fail-on", "copies,heartbeats", "--title", TITLE, "--explain", j("head-explain.json"),
            j("base.json"), j("head.json"), j("base-elab.json"), j("head-elab.json"), cwd=d, ok=(1,)).stdout
    ce = sh(LP, "compare", j("base-elab.json"), j("head-elab.json"), cwd=d, ok=(1,)).stdout
    cr = sh(LP, "compare", "--explain", j("head-explain.json"), j("base.json"), j("head.json"), cwd=d, ok=(1,)).stdout
    return md, ce, cr


def facts(md, ce, cr):
    """What must hold whatever the exact numbers: the known causes are named."""
    problems = []
    def need(text, pattern, what):
        if not re.search(pattern, text, re.M):
            problems.append(f"{what}: no match for {pattern!r}")
    # the simp set grew: `step_eq` rewrote 41 times in head, never in base
    need(ce, r"^  Regress\.lean simp_case \(Regress\.lean:\d+\): .* -> ", "simp_case regressed and is explained")
    need(ce, r"^    simp lemma used \(count\) step_eq \(Regress\.lean:9\): 0 -> 41  \(\+41\)$", "simp_case: step_eq counted")
    need(ce, r"^    simp lemma rewrote with step_eq \(Regress\.lean:9\): 0× -> 41×", "simp_case: step_eq traced")
    # the definition got more expensive to unfold: `decide` reduces `tri` in head
    need(ce, r"^    whnf reduces tri \(Regress\.lean:11\): 0\.00 kHB, 0× -> [1-9][0-9.]* kHB, \d+×  \(\+", "unfold_case: tri credited")
    need(ce, r"^    unfolded \(count\) tri \(Regress\.lean:11\): 1 -> \d\d+  \(\+", "unfold_case: tri counted")
    if re.search(r"REGRESSION  Regress\.lean unchanged", ce):
        problems.append("`unchanged` reported as a regression")
    # the comment: one collapsed block per regressed declaration, the top cause in its summary
    need(md, r"^<details><summary>why <code>Regress\.lean unfold_case</code> got more expensive: \+[0-9.]+ kHB; most changed: whnf reduces <code>tri</code> \+", "comment: unfold_case")
    need(md, r"^<details><summary>why <code>Regress\.lean simp_case</code> got more expensive: .*step_eq", "comment: simp_case")
    # the copy: explain's cause, for the site that copies more
    need(cr, r"^  REGRESSION  collect .*\[Array\] in .*: 0 -> 299$", "run: collect copies 299 times")
    need(cr, r"^    why: [a-z-]+: ", "run: explain's cause named")
    need(md, r"^- `collect[^`]*\[Array\][^`]*`: \+299 copies\. ", "comment: the copy site")
    need(md, r"^- `collect[^`]*`: \+[0-9,]+( \([^)]*\))? allocations\. Cause not attributed: explain explains copies, not allocations\. The same function copies more too", "comment: the allocation site")
    need(cr, r"^  more  collect .*: \d+ -> \d+\n    why: cause not attributed: explain explains copies, not allocations", "run: allocation site")
    if len(md) > 60000:
        problems.append(f"comment is {len(md)} characters")
    return problems


def main():
    save = "--save" in sys.argv[1:]
    live = tempfile.mkdtemp(prefix="leanprof-regress-out-")
    try:
        profile(live)
        md, ce, cr = render(live)
        problems = facts(md, ce, cr)
        for p in problems:
            print("FAIL", p)
        if problems:
            print(md, ce, cr, sep="\n----\n")
            sys.exit(1)
        print("ok   live pipeline: the known causes are named")
        fixtures = os.path.join(FIX, "fixtures")
        expected = os.path.join(FIX, "expected")
        if save:
            os.makedirs(fixtures, exist_ok=True)
            os.makedirs(expected, exist_ok=True)
            for f in os.listdir(live):
                shutil.copy(os.path.join(live, f), fixtures)
        # golden: the committed reports rendered as committed
        md, ce, _ = render(fixtures)
        outs = {"report.md": md, "compare-elab.txt": ce}
        bad = 0
        for name, text in outs.items():
            p = os.path.join(expected, name)
            if save:
                with open(p, "w") as h:
                    h.write(text)
                print(f"wrote {os.path.relpath(p, ROOT)}")
                continue
            with open(p) as h:
                want = h.read()
            if text != want:
                bad += 1
                print(f"FAIL golden {name} differs from {os.path.relpath(p, ROOT)}:")
                import difflib
                sys.stdout.writelines(difflib.unified_diff(want.splitlines(True), text.splitlines(True), "expected", "now"))
            else:
                print(f"ok   golden {name}")
        sys.exit(1 if bad else 0)
    finally:
        shutil.rmtree(live, ignore_errors=True)


if __name__ == "__main__":
    main()
