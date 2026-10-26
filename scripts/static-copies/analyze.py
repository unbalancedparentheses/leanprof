#!/usr/bin/env python3
"""Prototype: identify locally retained Array.push receivers in saved Lean IR."""
import argparse
import copy
import hashlib
import json
import math
import os
import signal
from pathlib import Path
import subprocess
import sys

# Argument positions include erased type/proof arguments, as stored in Lean.IR.
GETTERS = {"Array.getInternal": (1, 2, False),
           "Array.get!Internal": (2, 3, False),
           "Array.getInternalBorrowed": (1, 2, True),
           "Array.get!InternalBorrowed": (2, 3, True),
           "Array.uget": (1, 2, False), "Array.ugetBorrowed": (1, 2, True)}
SETTERS = {"Array.set", "Array.set!", "Array.uset"}


class State:
    def __init__(self):
        self.aliases = {}
        self.refs = {}
        self.increments = {}
        self.held = {}  # owner -> [(value, slot, IR site, explanation)]
        self.shared_tests = {}
        self.case_values = {}
        self.sizes = {}

    def key(self, var):
        return self.aliases.get(var, var)

    def count(self, var):
        return self.refs.get(self.key(var), 1)

    def fresh(self, var):
        self.aliases.pop(var, None)
        self.refs[var] = 1

    def release_members(self, owner):
        for value, _, _, _ in self.held.pop(owner, []):
            self.refs[value] = max(0, self.refs.get(value, 1) - 1)

    def consume(self, var, amount=1):
        if var is None:
            return
        value = self.key(var)
        self.refs[value] = max(0, self.refs.get(value, 1) - amount)
        # Conservatively forget ownership retained by a consumed container. A
        # callee may keep it, but that requires an interprocedural summary.
        self.release_members(value)

    def hold(self, owner, value, slot, site, reason):
        if value is not None:
            self.held.setdefault(self.key(owner), []).append(
                (self.key(value), slot, site, reason))

    def project(self, result, owner, slot, site, borrowed=True):
        parent = self.key(owner)
        existing = next((e for e in self.held.get(parent, []) if e[1] == slot), None)
        if existing:
            value = existing[0]
            self.aliases[result] = value
            if not borrowed:
                self.refs[value] = self.refs.get(value, 1) + 1
        else:
            self.fresh(result)
            self.refs[result] = 1 if borrowed else 2
            self.hold(owner, result, slot, site, "read from a live container")

    def remove_slot(self, owner, slot):
        key = self.key(owner)
        kept = []
        for entry in self.held.pop(key, []):
            value, old_slot, _, _ = entry
            # Different index variables may denote the same slot. Drop those
            # uncertain relationships rather than treating them as disjoint.
            if old_slot == slot or old_slot[0] == "index":
                self.refs[value] = max(0, self.refs.get(value, 1) - 1)
            else:
                kept.append(entry)
        self.held[key] = kept


def analyze_function(function, module, max_states):
    nodes = function["nodes"]
    joins = {n["join"]: n for n in nodes if n["kind"] == "join"}
    state = State()
    for p in function["params"]:
        state.fresh(p["id"])
    work = [(function["entry"], state, (), frozenset())]
    findings, operations, limits, empty = {}, set(), set(), set()
    processed = 0
    while work:
        node_id, state, conditions, visited = work.pop()
        if node_id in visited:
            limits.add("join_cycle")
            continue
        if processed >= max_states:
            limits.add("state_budget")
            break
        processed += 1
        visited = visited | {node_id}
        node = nodes[node_id]
        kind = node["kind"]
        if kind == "case":
            tested_value = state.key(node["var"])
            test = state.shared_tests.get(tested_value)
            for alt in node["alternatives"]:
                known = state.case_values.get(tested_value)
                if known is not None and alt["label"] != known:
                    continue
                branch = copy.deepcopy(state)
                branch.case_values[tested_value] = alt["label"]
                if test is not None:
                    key = branch.key(test)
                    if alt["label"] == "Bool.false":
                        branch.refs[key] = 1
                    elif alt["label"] == "Bool.true":
                        branch.refs[key] = max(branch.refs.get(key, 1), 2)
                path = conditions + ((node_id, alt["label"]),)
                work.append((alt["entry"], branch, path, visited))
            continue
        if kind == "jump":
            target = joins.get(node["join"])
            if target is None or len(target["params"]) != len(node["args"]):
                limits.add("unresolved_join")
                continue
            # Parallel substitution: a join parameter may also be an argument.
            bindings = [(p["id"], state.key(a)) for p, a in zip(target["params"], node["args"])]
            for param, value in bindings:
                state.aliases[param] = value
            work.append((target["entry"], state, conditions, visited))
            continue
        if kind in ("return", "unreachable"):
            continue
        if kind == "inc" and node.get("persistent"):
            limits.add("persistent_reference")
        elif kind == "inc":
            key = state.key(node["var"])
            state.refs[key] = state.count(node["var"]) + node["count"]
            if node["count"]:
                state.increments[key] = node_id
        elif kind in ("dec", "delete"):
            state.consume(node["var"], node.get("count", state.count(node["var"])))
        elif kind == "store":
            slot = ("field", node["index"])
            state.remove_slot(node["holder"], slot)
            state.hold(node["holder"], node["value"], slot, node_id, "stored in a constructor")
        elif kind == "let":
            expression = node["expression"]
            ek, result = expression["kind"], node["result"]
            state.fresh(result)
            if ek == "projection":
                state.project(result, expression["receiver"], ("field", expression["index"]), node_id)
            elif ek == "isShared":
                state.shared_tests[state.key(result)] = expression["receiver"]
            elif ek in ("constructor", "closure", "reuse"):
                if ek == "reuse":
                    state.consume(expression["receiver"])
                for index, arg in enumerate(expression["args"]):
                    state.hold(result, arg, ("field", index), node_id, "stored in a constructor/closure")
            elif ek == "reset":
                state.consume(expression["receiver"])
            elif ek == "call":
                callee, args = expression["callee"], expression["args"]
                if callee == "Array.push" and len(args) == 3 and args[1] is not None:
                    receiver, item = args[1:]
                    operations.add(node_id)
                    value = state.key(receiver)
                    known_size = state.sizes.get(value)
                    if state.count(receiver) >= 2 and known_size == 0:
                        empty.add(node_id)
                    if state.count(receiver) >= 2 and known_size != 0:
                        holders = [dict(variable=owner, site=site, reason=reason)
                                   for owner, entries in state.held.items()
                                   for held, _, site, reason in entries if held == value]
                        evidence = dict(trackedReferences=state.count(receiver),
                                        incrementSite=state.increments.get(value), holders=holders)
                        findings.setdefault(node_id, dict(
                            module=module, function=function["name"], source=function.get("source"),
                            irSite=node_id, operation="Array.push", receiver=receiver,
                            classification="likely-copy", evidence=evidence, irExpression=expression["text"],
                            conditions=[dict(site=i, branch=b) for i, b in conditions],
                            explanation="The receiver still has another reference at this update; "
                                        "Array.push is expected to copy when this path executes.",
                            suggestion="Avoid retaining the old array across this push. For nested arrays, "
                                       "try Array.modify; for history, consider storing prefix lengths "
                                       "only when that preserves the intended snapshots."))
                    # Move the container's known members to its result. Copies
                    # may duplicate members; ignoring that only loses evidence.
                    members = state.held.pop(value, [])
                    state.consume(receiver)
                    state.held[result] = members
                    if known_size is not None:
                        state.sizes[result] = known_size + 1
                    state.hold(result, item, ("append", node_id), node_id, "stored by Array.push")
                elif callee == "Array.mkEmpty":
                    state.sizes[result] = 0
                elif callee in GETTERS:
                    owner_pos, index_pos, borrowed = GETTERS[callee]
                    if len(args) <= index_pos or args[owner_pos] is None:
                        limits.add("unexpected_array_signature")
                    else:
                        state.project(result, args[owner_pos], ("index", state.key(args[index_pos])),
                                      node_id, borrowed=borrowed)
                elif callee in SETTERS and len(args) >= 4:
                    owner, index, item = args[1:4]
                    state.remove_slot(owner, ("index", state.key(index)))
                    members = state.held.pop(state.key(owner), [])
                    state.consume(owner)
                    state.held[result] = members
                    state.hold(result, item, ("index", state.key(index)), node_id, "stored by Array.set")
                else:
                    borrowed = expression.get("borrowed")
                    if borrowed is None or len(borrowed) != len(args):
                        limits.add("unknown_call_ownership")
                        borrowed = [False] * len(args)
                    for arg, borrow in zip(args, borrowed):
                        if not borrow:
                            state.consume(arg)
            elif ek == "apply":
                limits.add("indirect_call")
                for arg in [expression["receiver"], *expression["args"]]:
                    state.consume(arg)
        if "next" in node:
            work.append((node["next"], state, conditions, visited))
    return list(findings.values()), len(operations), sorted(limits), processed, len(empty)


def analyze(snapshot, max_states=10000):
    if snapshot.get("schema") != 1 or snapshot.get("representation") != "Lean.IR.post-RC":
        raise ValueError("unsupported compiler IR export schema")
    findings, coverage, module_coverage = [], [], []
    for module in snapshot["modules"]:
        module_coverage.append(dict(module=module["module"],
                                    irBodies=sum(not d["external"] for d in module["declarations"])))
        for function in module["declarations"]:
            if function["external"]:
                continue
            found, operations, limits, states, empty = analyze_function(function, module["module"], max_states)
            findings.extend(found)
            coverage.append(dict(module=module["module"], function=function["name"],
                                 arrayPushSites=operations, states=states, limits=limits, suppressedEmptySites=empty))
    incomplete = (any(set(c["limits"]) & {"state_budget", "join_cycle", "unresolved_join"} for c in coverage)
                  or any(not m["irBodies"] for m in module_coverage))
    status = "no-ir-bodies" if not coverage else "partial" if incomplete else "analyzed"
    return dict(schema=1, status=status,
                leanVersion=snapshot["leanVersion"], leanGithash=snapshot["leanGithash"],
                pattern="locally-retained-array-push", findings=findings, coverage=coverage, moduleCoverage=module_coverage,
                limitations=["No warning is not proof of no copies.",
                             "No interprocedural alias or multi-threaded ownership analysis.",
                             "Array getters require an in-bounds access for container-retention evidence.",
                             "Locations identify the declaration and IR site, not an exact Lean expression.",
                             "Warnings describe possible compiler paths, not workload frequency or cost.",
                             "Known-empty receiver copies are suppressed; they can still allocate memory.",
                             "Source/IR freshness is not checked; rebuild selected modules before scanning."])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, help="built Lean project; builds are never started automatically")
    parser.add_argument("--module", action="append", default=[], help="module whose saved IR to inspect")
    parser.add_argument("--ir", type=Path, help="previous Export.lean JSON instead of a live project")
    parser.add_argument("--save-ir", type=Path, help="save the collected compiler evidence")
    parser.add_argument("--max-states", type=int, default=10000, help="per-function path exploration budget")
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    try:
        if not math.isfinite(args.timeout) or args.timeout <= 0:
            raise ValueError("--timeout must be positive and finite")
        if args.max_states < 1:
            raise ValueError("--max-states must be positive")
        if args.ir:
            if args.project or args.module:
                raise ValueError("--ir cannot be combined with --project/--module")
            raw = args.ir.read_text()
        else:
            if not args.project or not args.module:
                raise ValueError("supply --project and --module, or --ir")
            driver = Path(__file__).with_name("Export.lean").resolve()
            with subprocess.Popen(["lake", "env", "lean", "--run", str(driver), *args.module],
                                  cwd=args.project, text=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, start_new_session=True) as proc:
                try:
                    raw, stderr = proc.communicate(timeout=args.timeout)
                except (subprocess.TimeoutExpired, KeyboardInterrupt):
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.communicate()
                    raise
                if proc.returncode:
                    raise ValueError((stderr + raw)[-4000:])
        snapshot = json.loads(raw)
        result = analyze(snapshot, args.max_states)
        result["irSha256"] = hashlib.sha256(raw.encode()).hexdigest()
        if args.save_ir:
            args.save_ir.write_text(raw)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["status"] == "analyzed" else 2
    except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.TimeoutExpired) as exc:
        print(json.dumps(dict(schema=1, status="error", error=str(exc))))
        return 2


if __name__ == "__main__":
    sys.exit(main())
