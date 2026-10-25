"""lean-compiler-backend checkouts, the zlib inputs and the workload, shared by
lcb-fixes.py and lcb-autoresearch.py."""
import gzip
import hashlib
import os

from lib import LP, WORK, clone, read_json, sh

URL = "https://github.com/unbalancedparentheses/lean-compiler-backend.git"
INPUTS_AT = "854fcc2"  # the 17 zlib units, archived in the compiler's repository
INPUTS_DIR = "docs/benchmarks/arm-scaled-load/private/zlib/ir"
WORKLOAD = ["deflate", "inflate", "trees", "crc32"]  # 562 KB of QBE IL


def checkout(commit):
    src = clone(URL, "main", "lcb-src")
    sh(["git", "fetch", "--quiet", "origin"], cwd=src, check=False)
    return clone(src, commit, f"lcb-{commit}")


def build(repo):
    sh(["lake", "build", "lcb"], cwd=repo)
    return os.path.join(repo, ".lake", "build", "bin", "lcb")


def inputs():
    """All 17 units as .ssa files in WORK/zlib-inputs (decompressed from the archive)."""
    repo = checkout(INPUTS_AT)
    out = os.path.join(WORK, "zlib-inputs")
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(os.path.join(repo, INPUTS_DIR)):
        if f.endswith(".ssa.gz"):
            data = gzip.decompress(open(os.path.join(repo, INPUTS_DIR, f), "rb").read())
            open(os.path.join(out, f[:-3]), "wb").write(data)
    return out


def args(inp, out):
    return ["--target", "aarch64-macos", "--optimize", "--allocate",
            *[os.path.join(inp, u + ".ssa") for u in WORKLOAD], "-o", out]


def counts(repo, inp, tag):
    """Exact counts of the zlib workload: `leanprof run --allocs` (allocations,
    copies by site) and `leanprof measure` (copies_total, what judge compares)."""
    work = os.path.join(WORK, f"lcb-{tag}-out")
    os.makedirs(work, exist_ok=True)
    plain = build(repo)
    ref = os.path.join(work, "plain.s")
    sh([plain, *args(inp, ref)], cwd=repo)
    rj, rs = os.path.join(work, "run.json"), os.path.join(work, "run.s")
    sh([LP, "run", "--allocs", "--json", rj, "lcb", "--", *args(inp, rs)], cwd=repo, env={"LEANPROF_QUIET": "1"})
    mj, ms = os.path.join(work, "measure.json"), os.path.join(work, "measure.s")
    sh([LP, "measure", "--runs", "1", "--warmup", "0", "--out", mj, "lcb", "--", *args(inp, ms)], cwd=repo,
       env={"LEANPROF_QUIET": "1"})
    r, m = read_json(rj), read_json(mj)
    h = [hashlib.sha256(open(p, "rb").read()).hexdigest() for p in (ref, rs, ms)]
    cfg = sum(x["copies"] for x in r["copies"] if x["function"].split(" (in ")[0] == "CFG.build"
              and x["kind"] == "Array")
    return {"allocs": sum(x["allocs"] for x in r["allocations"]),
            "alloc_mib": sum(x.get("bytes", 0) for x in r["allocations"]) / 2**20,
            "copies_total": m["copies_total"], "cfg_build_array_copies": cfg,
            "same_output": h[0] == h[1] == h[2], "run": r, "measure": m}
