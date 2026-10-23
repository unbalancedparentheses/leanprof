#!/usr/bin/env python3
"""Check a `leanprof elab` dataset against its documented schemas.

    python3 scripts/check-elab-dataset.py DATASET_DIR [--min-files N] [--timeline]

DATASET_DIR holds index.json, elab.json and modules/*.json (docs/guide/elab-dataset.md).
Each file is validated against docs/schema/*.schema.json (the subset of JSON Schema
those files use; no dependencies), then for consistency: every module file the index
names exists, event parents come before their children and contain them in time,
class indices are in range, and terms and tactics have ranges. --timeline requires
every module to have a timeline (made with the driver, in time). Exit 1 on a problem.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMAS = os.path.join(ROOT, "docs", "schema")
TYPES = {"string": str, "boolean": bool, "array": list, "object": dict, "null": type(None)}


def is_type(v, t):
    if t == "integer":
        return isinstance(v, int) and not isinstance(v, bool)
    if t == "number":
        return isinstance(v, (int, float)) and not isinstance(v, bool)
    return isinstance(v, TYPES[t])


def validate(v, s, path, errs):
    if len(errs) > 20:
        return
    if "const" in s and v != s["const"]:
        errs.append(f"{path}: {v!r} is not {s['const']!r}")
    if "enum" in s and v not in s["enum"]:
        errs.append(f"{path}: {v!r} not one of {s['enum']}")
    if "type" in s:
        ts = s["type"] if isinstance(s["type"], list) else [s["type"]]
        if not any(is_type(v, t) for t in ts):
            errs.append(f"{path}: {type(v).__name__} is not {s['type']}")
            return
    if "minimum" in s and isinstance(v, (int, float)) and v < s["minimum"]:
        errs.append(f"{path}: {v} < {s['minimum']}")
    if "pattern" in s and isinstance(v, str) and not re.search(s["pattern"], v):
        errs.append(f"{path}: {v!r} does not match {s['pattern']}")
    if isinstance(v, dict):
        for k in s.get("required", []):
            if k not in v:
                errs.append(f"{path}: missing {k}")
        for k, sub in s.get("properties", {}).items():
            if k in v:
                validate(v[k], sub, f"{path}.{k}", errs)
    if isinstance(v, list):
        if "minItems" in s and len(v) < s["minItems"]:
            errs.append(f"{path}: fewer than {s['minItems']} items")
        if "maxItems" in s and len(v) > s["maxItems"]:
            errs.append(f"{path}: more than {s['maxItems']} items")
        for i, sub in enumerate(s.get("prefixItems", [])):
            if i < len(v):
                validate(v[i], sub, f"{path}[{i}]", errs)
        if "items" in s:
            # every item of a large array is checked: datasets are what others consume
            for i, x in enumerate(v):
                validate(x, s["items"], f"{path}[{i}]", errs)


def schema(name):
    with open(os.path.join(SCHEMAS, name)) as f:
        return json.load(f)


def check(path, name, errs):
    with open(path) as f:
        d = json.load(f)
    e = []
    validate(d, schema(name), os.path.basename(path), e)
    errs += e
    return d


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    ds = args[0]
    min_files = int(args[args.index("--min-files") + 1]) if "--min-files" in args else 1
    need_timeline = "--timeline" in args
    errs = []
    index = check(os.path.join(ds, "index.json"), "elab-dataset-1.schema.json", errs)
    report = check(os.path.join(ds, index.get("report", "elab.json")), "elab-4.schema.json", errs)
    files = index.get("files", [])
    if len(files) < min_files:
        errs.append(f"index lists {len(files)} files, expected at least {min_files}")
    events = ranges = 0
    for f in files:
        p = os.path.join(ds, f["path"])
        if not f["path"] or not os.path.exists(p):
            errs.append(f"{f['module']}: module file {f['path']!r} missing")
            continue
        m = check(p, "elab-module-1.schema.json", errs)
        ev, cls = m.get("events", []), m.get("classes", [])
        events += len(ev)
        ranges += len(m.get("ranges", []))
        if need_timeline and not ev:
            errs.append(f"{f['module']}: no timeline")
        if len(ev) != f.get("events"):
            errs.append(f"{f['module']}: index says {f.get('events')} events, file has {len(ev)}")
        for i, e in enumerate(ev):
            parent, c, start, dur, _, rng, _ = e
            if not (-1 <= parent < i):
                errs.append(f"{f['module']}: event {i} has parent {parent}")
                break
            if not (0 <= c < len(cls)):
                errs.append(f"{f['module']}: event {i} has class {c}")
                break
            if (rng is not None) != (cls[c] in ("Leanprof.term", "Leanprof.tactic")):
                errs.append(f"{f['module']}: event {i} ({cls[c]}) range {rng!r}")
                break
            if parent >= 0:
                ps, pd = ev[parent][2], ev[parent][3]
                # a child inside its parent, up to clock rounding (1 µs)
                if start + 1000 < ps or start + dur > ps + pd + 1000:
                    errs.append(f"{f['module']}: event {i} [{start}, +{dur}] outside its parent [{ps}, +{pd}]")
                    break
    for e in errs[:30]:
        print("PROBLEM", e)
    print(f"{ds}: {len(files)} modules, {events} timeline events, {ranges} ranges, report has {len(report.get('ranges', []))} ranges; "
          + ("ok" if not errs else f"{len(errs)} problems"))
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
