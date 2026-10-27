#!/usr/bin/env python3
"""docs/guide/static-copies.md: `leanprof explain --static` on real code.

lean-compiler-backend, a Lean package of about 30 modules, at a25c541 (before
the fixes of its case study): the static scan of the whole package, nothing
run, then the zlib workload of `lcb-fixes` under `leanprof run --auto`, which
says which flagged functions ran and which copied. Also `CFG.build` at the
commits before and after its fix (a623acc, 8a0d286): flagged before, not
after.

Pinned: unbalancedparentheses/lean-compiler-backend at those commits, Lean
4.34.1 (the project's toolchain, through elan), the zlib 1.3.1 units archived
in the compiler's repository at 854fcc2. All checks are exact counts.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lcb  # noqa: E402
from lib import LP, WORK, Claim, build_leanprof, read_json, sh  # noqa: E402

c = Claim("static-copies", "Apple M5 Max (docs/guide/static-copies.md)",
          "leanprof explain --static on lean-compiler-backend; run --auto on zlib")
build_leanprof()
inp = lcb.inputs()


def scan(repo, out, report=None):
    """The static flags of the whole package (all of them, --all), checked
    against `report` when given."""
    sh(["lake", "build"], cwd=repo)
    args = [LP, "explain", "--static", "--no-build", "--all", "--json", "--out", out]
    args += ["--report", report] if report else ["--no-report"]
    return json.loads(sh(args, cwd=repo).stdout)


def in_decl(flags, decl):
    return [f for f in flags if f["declaration"].endswith(decl)]


# CFG.build before and after its fix
# (after the fix, one copy remains in CFG.build: a flag of another cause)
for rev, want in (("a623acc", True), ("8a0d286", False)):
    repo = lcb.checkout(rev)
    r = scan(repo, os.path.join(WORK, f"static-{rev}.json"))
    cfg = in_decl(r["flags"], "CFG.build")
    c.exact(f"{rev}: CFG.build flagged for its nested arrays",
            any(f["cause"] == "nested-array-element" for f in cfg), want)
    c.note(f"{rev}: CFG.build flags (cause)", [f["cause"] for f in cfg])

# the whole package, then the workload
rev = "a25c541"
repo = lcb.checkout(rev)
static = scan(repo, os.path.join(WORK, f"static-{rev}.json"))
work = os.path.join(WORK, f"lcb-{rev}-static")
os.makedirs(work, exist_ok=True)
report = os.path.join(work, "auto.json")
sh([LP, "run", "--auto", "--json", report, "lcb", "--", *lcb.args(inp, os.path.join(work, "out.s"))],
   cwd=repo, env={"LEANPROF_QUIET": "1"})
checked = scan(repo, os.path.join(WORK, f"static-{rev}-checked.json"), report)
flags = checked["flags"]
status = {}
for f in flags:
    status[f["runtime"]["status"]] = status.get(f["runtime"]["status"], 0) + 1
ran = [f for f in flags if f["runtime"]["status"] in ("confirmed", "constants", "ran-no-copies")]
c.note(f"{rev}: compiled functions scanned", static["functions"])
c.note(f"{rev}: updates that can copy", static["updates"])
c.exact(f"{rev}: flags (with strings outside loops)", len(flags), 63)
c.note(f"{rev}: flags by run-time status", status)
c.exact(f"{rev}: flagged functions that ran", len(ran), 36)
c.exact(f"{rev}: ... and copied shared values", status.get("confirmed", 0), 20)
# the copy sites of the run in the package's own code: flagged or not
r = read_json(report)
own = [x for x in r["copies"] if x["shared"] + x["multi_threaded"] > 0 and
       x["where"].startswith("LeanCompilerBackend/")]
flagged_fns = {f["function"] for f in flags} | {f["via"].split(", ")[0][len("caller "):] for f in flags
                                                   if f["via"].startswith("caller ")}
missed = [x for x in own if x["function"] not in flagged_fns]
c.exact(f"{rev}: functions that copied shared values in the run", len(own), 26)
c.exact(f"{rev}: ... of them flagged", len(own) - len(missed), 17)
c.note(f"{rev}: copies in the run, flagged / all",
       f'{sum(x["shared"] + x["multi_threaded"] for x in own if x not in missed)} / '
       f'{sum(x["shared"] + x["multi_threaded"] for x in own)}')
for x in missed:
    c.note("  not flagged", f'{x["function"]} ({x["where"]}): {x["shared"] + x["multi_threaded"]} copies')
for f in flags:
    if f["runtime"]["status"] == "ran-no-copies":
        c.note("  ran, no copies", f'{f["where"]} {f["declaration"]} {f["operation"]} ({f["cause"]})')
c.finish()
