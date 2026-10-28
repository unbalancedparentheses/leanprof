#!/usr/bin/env python3
"""Conservative, scoped proof-preservation evidence for two Lean project checkouts."""
import argparse
import fnmatch
import hashlib
import json
import os
import signal
from pathlib import Path
import re
import subprocess
import sys

SCHEMA = 1
DEFAULT_PROTECTED = ("Tests/**", "tests/**", "test/**", "**/Tests/**", "**/tests/**",
                     "**/expected/**", "expected/**")
SIGNATURE = ("kind", "type", "levels", "extra", "isUnsafe", "isPartial")
SEMANTICS = SIGNATURE + ("value", "implementedBy", "extern")


# Name components of declarations Lean generates for another declaration: the
# lemmas a tactic abstracts from a proof, equation and unfolding lemmas, matchers,
# the compiled code of well-founded recursion. A proof rewrite removes or changes
# them; they state nothing the project wrote. (A component in first position,
# a theorem the user named `eq_1`, is not generated.)
GENERATED = re.compile(r"(_proof|proof|_simp|eq|match)_\d+(_\d+)*|_auxLemma|eq_def|_unfold|_sunfold"
                       r"|induct|splitter|_unsafe_rec|_unary|_binary|_mutual|fun_cases")


def generated(name):
    return any(GENERATED.fullmatch(part) for part in name.split(".")[1:])


def finding(status, code, subject, detail):
    return dict(status=status, code=code, subject=subject, detail=detail)


def report(findings, **evidence):
    status = ("FAIL" if any(f["status"] == "FAIL" for f in findings) else
              "INCONCLUSIVE" if findings else "PASS")
    return dict(schema=SCHEMA, status=status, scope="selected-module-proof-preservation",
                findings=findings, **evidence)


def validate(snapshot):
    """Missing or malformed evidence must not look like an empty successful audit."""
    if snapshot.get("schema") != SCHEMA or not isinstance(snapshot.get("leanVersion"), str) or not isinstance(snapshot.get("leanGithash"), str):
        raise ValueError("unsupported snapshot schema or missing Lean version")
    for key in ("modules", "roots"):
        values = snapshot.get(key)
        if not isinstance(values, list) or not values or not all(isinstance(v, str) for v in values):
            raise ValueError(f"missing/empty {key}")
        if len(values) != len(set(values)):
            raise ValueError(f"duplicate {key}")
    escapes = snapshot.get("runtimeEscapes")
    if not isinstance(escapes, dict):
        raise ValueError("missing runtime attribute inventory")
    for name, attrs in escapes.items():
        if not isinstance(name, str) or not isinstance(attrs, dict):
            raise ValueError("invalid runtime attribute inventory")
        for key in ("implementedBy", "extern"):
            if key not in attrs or (attrs[key] is not None and not isinstance(attrs[key], str)):
                raise ValueError("invalid runtime attribute")
        for key in ("isUnsafe", "isPartial"):
            if not isinstance(attrs.get(key), bool):
                raise ValueError("invalid runtime safety flag")
    records = snapshot.get("declarations")
    if not isinstance(records, list):
        raise ValueError("missing declarations")
    declarations = {}
    for d in records:
        for key in ("name", "kind", "type", "levels", "extra"):
            if not isinstance(d.get(key), str):
                raise ValueError(f"invalid declaration {key}")
        for key in ("isUnsafe", "isPartial"):
            if not isinstance(d.get(key), bool):
                raise ValueError(f"invalid declaration {key}")
        for key in ("value", "implementedBy", "extern"):
            if key not in d or (d[key] is not None and not isinstance(d[key], str)):
                raise ValueError(f"invalid declaration {key}")
        for key in ("dependencies", "axioms"):
            if not isinstance(d.get(key), list) or not all(isinstance(n, str) for n in d[key]):
                raise ValueError(f"invalid declaration {key}")
        if d["name"] in declarations:
            raise ValueError(f"duplicate declaration {d['name']}")
        declarations[d["name"]] = d
    required = set(snapshot["roots"])
    for d in records:
        required.update(d["dependencies"])
        required.update(d["axioms"])
    if required - declarations.keys():
        raise ValueError("incomplete declaration dependency graph")
    return declarations


def compare(base, candidate):
    try:
        old, new = validate(base), validate(candidate)
    except (ValueError, TypeError, AttributeError) as e:
        return report([finding("INCONCLUSIVE", "invalid_evidence", "snapshot", str(e))])
    if any(base[k] != candidate[k] for k in ("leanVersion", "leanGithash", "modules")):
        return report([finding("INCONCLUSIVE", "incompatible_snapshots", "snapshot",
                               "Lean version and selected modules must match")])
    findings = []
    roots = set(base["roots"])
    candidate_roots = set(candidate["roots"])
    for name in sorted(roots - candidate_roots):
        if generated(name):
            continue  # e.g. a tactic's `_proof_1`, gone with the proof that made it
        findings.append(finding("FAIL", "removed_declaration", name,
                                "A baseline declaration is absent from the candidate modules"))
    for name in sorted(roots & candidate_roots):
        a, b = old[name], new[name]
        if generated(name):
            pass  # its axioms are still checked below; what it states is not an obligation
        elif a["kind"] != b["kind"]:
            findings.append(finding("FAIL", "declaration_kind_changed", name,
                                    f"{a['kind']} became {b['kind']}"))
        elif any(a[k] != b[k] for k in SIGNATURE):
            findings.append(finding("INCONCLUSIVE", "signature_changed", name,
                                    "Structural signature differs; semantic equivalence is not established"))
        added = sorted(set(b["axioms"]) - set(a["axioms"]))
        if added:
            findings.append(finding("FAIL", "added_axiom_dependency", name, ", ".join(added)))
    for name in sorted(candidate_roots):
        b = new[name]
        if "sorryAx" in b["axioms"]:
            findings.append(finding("FAIL", "sorry_dependency", name, "Candidate depends on sorryAx"))
        if name not in roots and b["kind"] == "axiom":
            findings.append(finding("FAIL", "added_axiom", name, "New axiom in selected modules"))
        # A new proof is not allowed to introduce arbitrary external axioms either.
        if name not in roots:
            allowed = set().union(*(set(old[n]["axioms"]) for n in roots))
            added = sorted(set(b["axioms"]) - allowed)
            if added:
                findings.append(finding("FAIL", "added_axiom_dependency", name, ", ".join(added)))
    # Check overrides across the collected closure, including imported dependencies.
    for name, b in sorted(candidate["runtimeEscapes"].items()):
        a = base["runtimeEscapes"].get(name, {})
        for attr in ("implementedBy", "extern", "isUnsafe", "isPartial"):
            # the compiled code of well-founded recursion (`f._unsafe_rec`) is partial by design
            if attr in ("isUnsafe", "isPartial") and generated(name):
                continue
            if b[attr] and b[attr] != a.get(attr):
                findings.append(finding("FAIL", "runtime_escape_changed", name,
                                        f"New or changed {attr}"))
    # An identical theorem type can name a definition that changed underneath it.
    # Check the full interpretation graph of every preserved theorem statement,
    # plus the types of its axioms. Theorem proof bodies are irrelevant here.
    pending = []
    for name in roots & candidate_roots:
        if old[name]["kind"] == "theorem" and not generated(name):
            pending.extend(old[name]["dependencies"])
        # an axiom the candidate no longer depends on cannot weaken it
        pending.extend(set(old[name]["axioms"]) & set(new[name]["axioms"]))
    seen = set()
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        a, b = old[name], new.get(name)
        if b is None or any(a[k] != b[k] for k in SEMANTICS):
            findings.append(finding("INCONCLUSIVE", "statement_dependency_changed", name,
                                    "A statement/axiom dependency changed; preservation is not established"))
        pending.extend(a["dependencies"])
    if not any(old[n]["kind"] == "theorem" for n in roots):
        findings.append(finding("INCONCLUSIVE", "no_theorems", "modules",
                                "Selected baseline modules contain no theorem declarations"))
    return report(findings, modules=base["modules"],
                  checkedDeclarations=len(roots), checkedStatementDependencies=len(seen),
                  checkedTheorems=sum(old[n]["kind"] == "theorem" for n in roots))


def run(cmd, cwd, timeout):
    with subprocess.Popen(cmd, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            # Lake may have compiler children; stop the whole isolated process group.
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
        if process.returncode:
            raise ValueError(f"{cmd[0]} exited {process.returncode}: {(stderr + stdout)[-4000:]}")
        return stdout


def inventory(project, timeout):
    root = Path(run(["git", "rev-parse", "--show-toplevel"], project, timeout).strip()).resolve()
    if root != project:
        raise ValueError("Each project must be the root of its own Git checkout")
    names = run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                project, timeout).split("\0")
    files = {}
    for name in sorted(set(names) - {""}):
        path = project / name
        if path.is_symlink():
            # A link is recorded by its target, never followed: a changed target changes the
            # inventory. A Lean source behind a link could change without its link changing.
            if name.endswith(".lean"):
                raise ValueError(f"Symlink Lean source is unsupported: {name}")
            files[name] = "symlink:" + hashlib.sha256(os.readlink(path).encode()).hexdigest()
            continue
        if path.is_file():
            files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        elif path.exists():
            raise ValueError(f"Submodule/directory source is unsupported: {name}")
        # Deleted tracked paths are absent, so deletions change the inventory.
    return files


def source_path(module, subdir=""):
    """A module's source file, relative to the checkout root (`subdir`: the Lake package's directory)."""
    path = module.replace(".", "/") + ".lean"
    return f"{subdir}/{path}" if subdir else path


def capture(project, modules, timeout, subdir=""):
    before = inventory(project, timeout)
    for module in modules:
        if source_path(module, subdir) not in before:
            raise ValueError(f"Module {module} needs an inventoried source file at the package root; "
                             "custom srcDir and ignored module sources are unsupported")
    revision = run(["git", "rev-parse", "HEAD"], project, timeout).strip()
    package = project / subdir if subdir else project
    driver = Path(__file__).with_name("Snapshot.lean").resolve()
    if modules:
        run(["lake", "build", *modules], package, timeout)
        output = run(["lake", "env", "lean", "--run", str(driver), *modules], package, timeout)
        snapshot = json.loads(output)
    else:
        # No module selected: only the file checks (protected and uncovered files) run.
        output, snapshot = "", {}
    after = inventory(project, timeout)
    if before != after or revision != run(["git", "rev-parse", "HEAD"], project, timeout).strip():
        raise ValueError("Source or revision changed while building/collecting evidence; retry on a stable checkout")
    provenance = dict(project=str(project), revision=revision, files=after,
                      leanVersion=snapshot.get("leanVersion"), leanGithash=snapshot.get("leanGithash"),
                      collectorHash=hashlib.sha256(driver.read_bytes()).hexdigest(),
                      sourceHash=hashlib.sha256(json.dumps(after, sort_keys=True).encode()).hexdigest(),
                      snapshotHash=hashlib.sha256(output.encode()).hexdigest())
    return snapshot, provenance


def audit(base_path, candidate_path, modules, protected, timeout, subdir=""):
    if base_path == candidate_path:
        raise ValueError("Use separate baseline and candidate checkouts")
    base, bp = capture(base_path, modules, timeout, subdir)
    candidate, cp = capture(candidate_path, modules, timeout, subdir)
    result = compare(base, candidate) if modules else report([], modules=[])
    findings = result["findings"]
    files = bp["files"].keys() | cp["files"].keys()
    changed = sorted(p for p in files if bp["files"].get(p) != cp["files"].get(p))
    covered = {source_path(m, subdir) for m in modules}
    for path in changed:
        if any(fnmatch.fnmatchcase(path, pattern) for pattern in protected):
            findings.append(finding("FAIL", "protected_file_changed", path,
                                    "Protected file added, removed or modified"))
        elif path not in covered:
            findings.append(finding("INCONCLUSIVE", "uncovered_source_change", path,
                                    "Change is outside the explicitly selected root-layout modules"))
    # Recheck BOTH checkouts after both captures, not only each capture in isolation.
    for project, provenance in ((base_path, bp), (candidate_path, cp)):
        if (inventory(project, timeout) != provenance["files"] or
                run(["git", "rev-parse", "HEAD"], project, timeout).strip() != provenance["revision"]):
            findings.append(finding("INCONCLUSIVE", "stale_evidence", str(project),
                                    "Source changed after evidence collection"))
    evidence = {k: v for k, v in result.items() if k not in ("status", "findings", "schema", "scope")}
    return report(findings, **evidence, base=bp, candidate=cp, changedFiles=changed,
                  protectedPatterns=list(protected), subdir=subdir)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--module", action="append", dest="modules", default=[],
                        help="changed module to audit (repeat); none: only the file checks run")
    parser.add_argument("--subdir", default="",
                        help="the Lake package's directory inside both checkouts (default: their root)")
    parser.add_argument("--protect", action="append", default=[], help="additional protected path glob")
    parser.add_argument("--timeout", type=float, default=300, help="seconds per subprocess")
    args = parser.parse_args()
    try:
        if args.timeout <= 0 or any(not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*(\.[A-Za-z_][A-Za-z_0-9]*)*", m)
                                    for m in args.modules):
            raise ValueError("Positive timeout and ordinary dotted module names required")
        subdir = args.subdir.strip("/")
        if subdir and (Path(subdir).is_absolute() or ".." in Path(subdir).parts):
            raise ValueError("--subdir must be a relative path inside the checkouts")
        result = audit(args.base.resolve(), args.candidate.resolve(), sorted(set(args.modules)),
                       DEFAULT_PROTECTED + tuple(args.protect), args.timeout, subdir)
    except (OSError, ValueError, subprocess.TimeoutExpired) as e:
        result = report([finding("INCONCLUSIVE", "collection_failed", "audit", str(e))])
    print(json.dumps(result, indent=2, sort_keys=True))
    return {"PASS": 0, "FAIL": 1, "INCONCLUSIVE": 2}[result["status"]]


if __name__ == "__main__":
    sys.exit(main())
