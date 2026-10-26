#!/usr/bin/env python3
"""The project view compares each term or tactic with the same one in the base.

    NODE_PATH=DIR/node_modules python3 scripts/check-html-ranges.py [LEANPROF]

Two compile-time reports with the same content: a project whose module has two
declarations, each with an identical `simp` costing 10,000 heartbeats (and
the first with a second one). Ranges with the same text were matched by text
alone, and each was compared with the sum of all of them in the file (20,000
or 30,000 against 10,000: "faster"). Compared with itself, every row of the
module's and each declaration's terms and tactics must be "same"
(scripts/check-html-view.js --same-ranges).
"""
import json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LP = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(ROOT, ".lake", "build", "bin", "leanprof")
F = "Demo/Simp.lean"


def scope(name, line, total):
    return {"key": f"{F} {name}", "name": f"theorem {name} : True := by simp", "pos": f"{F}:{line}",
            "total_ns": total, "elab_ns": total, "kernel_ns": 0, "compile_ns": 0, "lint_ns": 0}


def rng(l1, c1, l2, c2, amount):
    return {"amount": amount, "count": 1, "kind": "tactic", "pos": f"{F}:{l1}", "range": f"{F}:{l1}:{c1}-{l2}:{c2}",
            "syntax": "Lean.Parser.Tactic.simp", "text": "simp"}


report = {"version": 3, "elab": True, "project": True, "unit": "heartbeats", "exact_ranges": True,
          "threshold": 1000, "wall_ns": 1000000,
          "files": [{"file": F, "module": "Demo.Simp", "key": "module Demo.Simp", "total_ns": 40000,
                     "elab_ns": 40000, "kernel_ns": 0, "compile_ns": 0, "lint_ns": 0, "errors": 0, "first_error": ""},
                    {"file": "Demo.lean", "module": "Demo", "key": "module Demo", "total_ns": 5000,
                     "elab_ns": 5000, "kernel_ns": 0, "compile_ns": 0, "lint_ns": 0, "errors": 0, "first_error": ""}],
          "scopes": [scope("a", 1, 20000), scope("b", 10, 20000)],
          "ranges": [rng(2, 2, 2, 6, 10000), rng(3, 2, 3, 6, 10000), rng(11, 2, 11, 6, 10000)],
          "repeated": [], "constants": []}
with tempfile.TemporaryDirectory() as d:
    for side in ("base", "head"):
        with open(os.path.join(d, side + ".json"), "w") as f:
            json.dump(report, f)
    page = os.path.join(d, "page.html")
    subprocess.run([LP, "html", "-o", page, os.path.join(d, "head.json"), os.path.join(d, "base.json")],
                   check=True, stdout=subprocess.DEVNULL)
    rc = subprocess.run(["node", os.path.join(ROOT, "scripts", "check-html-view.js"), page, "--compare",
                         "--same-ranges", "--module", F]).returncode
sys.exit(rc)
