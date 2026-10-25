"""Shared helpers for the reproduction scripts (see docs/reproduce.md).

Each script checks one published claim: it pins what it measures (commits,
tags, toolchains), runs it, prints every measured value next to the published
one, and exits 1 when an exact quantity differs or a timing falls outside the
stated range. Python standard library only.
"""
import json
import os
import platform
import shutil
import subprocess
import sys
import time

REPRO = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(REPRO)
LP = os.path.join(ROOT, ".lake", "build", "bin", "leanprof")
LEANPROF_URL = "https://github.com/unbalancedparentheses/leanprof.git"
# clones and builds of other projects; outside the checkout with LEANPROF_REPRO_WORK
WORK = os.path.abspath(os.environ.get("LEANPROF_REPRO_WORK", os.path.join(ROOT, ".lake", "reproduce")))
ELAN_BIN = os.path.join(os.path.expanduser("~"), ".elan", "bin")
if ELAN_BIN not in os.environ.get("PATH", "").split(os.pathsep):
    os.environ["PATH"] = ELAN_BIN + os.pathsep + os.environ.get("PATH", "")


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def sh(args, cwd=ROOT, env=None, check=True, capture=True, stdin=None, timeout=None):
    """Run a command; on failure print its output and exit 2 (a setup error, not a result)."""
    log("$ " + " ".join(str(a) for a in args) + (f"   (in {cwd})" if cwd != ROOT else ""))
    e = dict(os.environ, **(env or {}))
    p = subprocess.run([str(a) for a in args], cwd=cwd, env=e, text=True, stdin=stdin,
                       stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.STDOUT if capture else None, timeout=timeout)
    if check and p.returncode != 0:
        if capture:
            log(p.stdout[-4000:])
        log(f"reproduce: command failed with exit code {p.returncode}")
        sys.exit(2)
    return p


def timed(args, **kw):
    t0 = time.monotonic()
    p = sh(args, **kw)
    return time.monotonic() - t0, p


def load():
    try:
        return " ".join(f"{x:.1f}" for x in os.getloadavg())
    except OSError:
        return "?"


def machine():
    cpu = platform.processor() or platform.machine()
    if sys.platform == "darwin":
        try:
            cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], text=True,
                                 capture_output=True).stdout.strip() or cpu
        except OSError:
            pass
    elif os.path.exists("/proc/cpuinfo"):
        for line in open("/proc/cpuinfo"):
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break
    return f"{cpu}, {os.cpu_count()} CPUs, {platform.system()} {platform.release()}"


def leanprof_commit():
    p = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True, capture_output=True)
    dirty = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                           text=True, capture_output=True).stdout.strip()
    return (p.stdout.strip() or "?") + (" (modified)" if dirty else "")


def build_leanprof(targets=("leanprof",)):
    sh(["lake", "build", *targets])
    return LP


def clone(url, rev, name, depth_tag=False):
    """A clean checkout of `url` at `rev` (a commit or tag) under WORK/name.
    Reused when it is already at that commit with no local changes."""
    dest = os.path.join(WORK, name)
    os.makedirs(WORK, exist_ok=True)
    if not os.path.isdir(os.path.join(dest, ".git")):
        if depth_tag:
            sh(["git", "clone", "--depth", "1", "--branch", rev, url, dest])
        else:
            sh(["git", "clone", url, dest])
    if not depth_tag:
        sh(["git", "fetch", "--quiet", "origin"], cwd=dest, check=False)
        sh(["git", "checkout", "--quiet", "--detach", rev], cwd=dest)
    sh(["git", "reset", "--quiet", "--hard"], cwd=dest)
    return dest


def lean_prefix(toolchain):
    return sh(["lean", f"+{toolchain}", "--print-prefix"]).stdout.strip().splitlines()[-1]


class Claim:
    """Collects checks for one claim and prints the verdict.

    exact(): must be equal (copies, allocations, calls, heartbeats, counts).
    within(): a measurement that must fall in [lo, hi] (timings: machines differ).
    note(): printed for information, never fails.
    """

    def __init__(self, name, published_on, cmd):
        self.name, self.rows, self.failed = name, [], []
        self.t0 = time.monotonic()
        self.load0 = load()
        print(f"== reproduce {name}")
        print(f"   published on: {published_on}")
        print(f"   this machine: {machine()}; load at start {self.load0}")
        print(f"   leanprof {leanprof_commit()}; command: {cmd}")
        sys.stdout.flush()

    def exact(self, what, got, want):
        ok = got == want
        self.rows.append(("exact", what, fmt(got), fmt(want), "ok" if ok else "DIFFERS"))
        if not ok:
            self.failed.append(what)
        return ok

    def within(self, what, got, lo, hi, published, unit=""):
        ok = got is not None and lo <= got <= hi
        self.rows.append(("range", what, fmt(got, unit), f"{fmt(published, unit)} (accept {fmt(lo, unit)}–{fmt(hi, unit)})",
                          "ok" if ok else "OUTSIDE"))
        if not ok:
            self.failed.append(what)
        return ok

    def note(self, what, got, published=""):
        self.rows.append(("info", what, fmt(got), fmt(published), ""))

    def finish(self):
        w = [max(len(r[i]) for r in self.rows + [("", "check", "measured", "published", "")]) for i in range(5)]
        print()
        print(f"   {'':5}  {'check':<{w[1]}}  {'measured':>{w[2]}}  {'published':<{w[3]}}  result")
        for kind, what, got, want, res in self.rows:
            print(f"   {kind:5}  {what:<{w[1]}}  {got:>{w[2]}}  {want:<{w[3]}}  {res}")
        mins = (time.monotonic() - self.t0) / 60
        print(f"\n   load at end {load()}; took {mins:.1f} min")
        if self.failed:
            print(f"FAIL {self.name}: {len(self.failed)} of {len(self.rows)} checks: " + "; ".join(self.failed))
            sys.exit(1)
        print(f"PASS {self.name}: {sum(r[0] != 'info' for r in self.rows)} checks")
        sys.exit(0)


def fmt(x, unit=""):
    if x is None:
        return "–"
    if isinstance(x, bool):
        return str(x).lower()
    if isinstance(x, int):
        return f"{x:,}{unit}"
    if isinstance(x, float):
        s = f"{x:,.3f}".rstrip("0").rstrip(".") if abs(x) < 10 else f"{x:,.1f}"
        return s + unit
    if isinstance(x, (list, tuple, dict)):
        return json.dumps(x, ensure_ascii=False)
    return str(x)


def read_json(path):
    with open(path) as f:
        return json.load(f)


def which(cmd):
    return shutil.which(cmd)
