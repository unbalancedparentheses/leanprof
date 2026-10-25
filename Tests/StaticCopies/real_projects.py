#!/usr/bin/env python3
"""Reproduce CFG before/after and inspect the installed Lake's saved IR.
Requires a local lean-compiler-backend Git repository with the pinned revisions.
All builds happen in a new output directory, never in the input repository.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
BEFORE = "a623accdc611b2659941b220af54fd42d4b87d75"
AFTER = "8a0d286fba88298d6f8074e598781478bf6c5cc9"


def run(args, cwd, log=None):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=180)
    if log:
        log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"{args}: {(result.stderr + result.stdout)[-3000:]}")
    return result.stdout


MAIN = '''import Leanprof
import LeanCompilerBackend.CFG
open LeanCompilerBackend

def inputFunction (n : Nat) : Function := Id.run do
  let mut blocks := #[]
  for i in [:n] do
    let term := if i + 1 < n then
      Terminator.branch (.constant 1) (toString (i + 1)) (toString (n - 1))
      else Terminator.ret none
    blocks := blocks.push { label := toString i, phis := #[], instructions := #[], terminator := term }
  return { name := "staticCopyFixture", exported := false, resultWidth := none,
           parameters := #[], blocks }

def main (args : List String) : IO Unit := do
  let n := (args.head? >>= String.toNat?).getD 40
  let input := inputFunction n
  let before ← Leanprof.copies
  let graph ← IO.lazyPure fun _ => CFG.build input
  let count := (← Leanprof.copies) - before
  match graph with
  | .error e => throw <| IO.userError e
  | .ok g =>
    IO.println s!"copies={count}"
    IO.println s!"successors={g.successors.toList.map Array.toList}"
    IO.println s!"predecessors={g.predecessors.toList.map Array.toList}"
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lcb-repo", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="new directory to create")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    support = out / "leanprof"
    support.mkdir()
    for name in ("Leanprof", "c", "LeanprofHtml"):
        shutil.copytree(ROOT / name, support / name)
    for name in ("Leanprof.lean", "lakefile.lean", "lake-manifest.json", "lean-toolchain", "README.md", "LICENSE"):
        shutil.copy(ROOT / name, support / name)
    summary = dict(scope="real CFG sources on a synthetic branching CFG; not a full compiler benchmark",
                   revisions={}, results={})
    outputs = {}
    for label, revision in (("before", BEFORE), ("after", AFTER)):
        project = out / label
        (project / "LeanCompilerBackend").mkdir(parents=True)
        source_hashes = {}
        for file in ("IR.lean", "CFG.lean"):
            source = run(["git", "show", f"{revision}:LeanCompilerBackend/{file}"], args.lcb_repo)
            (project / "LeanCompilerBackend" / file).write_text(source)
            source_hashes[file] = hashlib.sha256(source.encode()).hexdigest()
        toolchain = run(["git", "show", f"{revision}:lean-toolchain"], args.lcb_repo)
        (project / "lean-toolchain").write_text(toolchain)
        lakefile = (ROOT / "Tests/StaticCopies/lakefile.lean").read_text()
        lakefile = lakefile.replace('"../.."', '"../leanprof"').replace("lean_lib Cases", "lean_lib LeanCompilerBackend")
        (project / "lakefile.lean").write_text(lakefile)
        (project / "Main.lean").write_text(MAIN)
        run(["lake", "build", "checkCopies"], project, out / f"{label}-build.log")
        raw = run([sys.executable, "-B", str(ROOT / "scripts/static-copies/analyze.py"),
                   "--project", str(project), "--module", "LeanCompilerBackend.CFG",
                   "--save-ir", str(out / f"{label}-ir.json")], ROOT)
        (out / f"{label}-analysis.json").write_text(raw)
        analysis = json.loads(raw)
        findings = [f for f in analysis["findings"] if f.get("source") and
                    f["source"]["declaration"] == "LeanCompilerBackend.CFG.build"]
        measurements = []
        for size in (10, 40, 100):
            measured = run([str(project / ".lake/build/bin/checkCopies"), str(size)], project,
                           out / f"{label}-{size}-runtime.log")
            lines = measured.splitlines()
            copies = int(lines[0].split("=")[1])
            checksum = hashlib.sha256("\n".join(lines[1:]).encode()).hexdigest()
            outputs[label, size] = checksum
            measurements.append(dict(blocks=size, copies=copies, graphHash=checksum))
        summary["revisions"][label] = dict(revision=revision, sourceHashes=source_hashes, toolchain=toolchain.strip())
        summary["results"][label] = dict(buildFindings=len(findings), findings=findings,
                                          measurements=measurements,
                                          otherFindings=len(analysis["findings"]) - len(findings))
    summary["graphsIdentical"] = all(outputs["before", size] == outputs["after", size] for size in (10, 40, 100))
    # Installed Lake IR is read without rebuilding or running Lake's build workload.
    lake = run([sys.executable, "-B", str(ROOT / "scripts/static-copies/analyze.py"),
                "--project", str(ROOT), "--module", "Lake.Build.Module",
                "--save-ir", str(out / "lake-ir.json")], ROOT)
    (out / "lake-analysis.json").write_text(lake)
    analysis = json.loads(lake)
    summary["lake"] = dict(leanVersion=analysis["leanVersion"], leanGithash=analysis["leanGithash"],
                           functions=len(analysis["coverage"]),
                           arrayPushSites=sum(c["arrayPushSites"] for c in analysis["coverage"]),
                           emptySitesSuppressed=sum(c["suppressedEmptySites"] for c in analysis["coverage"]),
                           findings=analysis["findings"],
                           knownMiss="Multi-threaded job queue: no interprocedural/multi-threaded ownership model")
    (out / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, indent=2, sort_keys=True))
    if not summary["graphsIdentical"] or not summary["results"]["before"]["buildFindings"]:
        return 1
    if summary["results"]["after"]["buildFindings"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
