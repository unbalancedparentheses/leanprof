#!/usr/bin/env python3
"""The verdict calibration of bench/verdicts/run.py, unchanged, on a shared
Linux host. This file only wraps it:

* results go to bench/linux/verdicts/results/ and RESULTS.md here;
* before each trial (inside the protocol's lock) it waits until the
  1-minute load is under 2, stricter than the protocol's quiet condition
  (under 0.4 of the CPU count, 12.8 on 32 CPUs), because other people's
  work shares the host;
* each trial also records the load when it ended (`load_end`), and the
  summary adds a section with the rates over the trials whose load stayed
  under 4.

    python3 bench/linux/verdicts/run.py trials --condition quiet
    python3 bench/linux/verdicts/run.py summary
"""
import importlib.util, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "..", "verdicts", "run.py"))
spec = importlib.util.spec_from_file_location("verdicts", SRC)
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)

v.RES = os.path.join(HERE, "results")
LIMIT, ROSE = 2.0, 4.0
_trial = v.trial


def trial(*a, **k):
    waited = time.monotonic()
    while v.load() >= LIMIT:
        time.sleep(10)
    rec = _trial(*a, **k)
    rec["load_wait_s"] = round(time.monotonic() - waited, 1)
    rec["load_end"] = v.load()
    return rec


v.trial = trial
_summary = v.cmd_summary


def summary(a):
    v.HERE = HERE  # RESULTS.md here
    _summary(a)
    path = os.path.join(HERE, "RESULTS.md")
    text = open(path).read().replace("[`run.py`](run.py)", "[`run.py`](../../verdicts/run.py)")
    out = [text.rstrip("\n"), "", "## Trials whose load stayed under 4", "",
           "Each trial waited until the 1-minute load was under 2 (other people's work shares the host); "
           "these are the rates over the trials whose load was still under 4 when they ended.", ""]
    for f in sorted(os.listdir(v.RES)):
        if not f.endswith(".jsonl") or f.startswith("reps-"):
            continue
        rows = [json.loads(l) for l in open(os.path.join(v.RES, f))]
        keep = [r for r in rows if r.get("load_end", 0) < ROSE]
        out += [f"`{f}`: {len(keep)} of {len(rows)} trials.", "",
                "| | `measure-pair --scope` | `--repeat 5` | LeanBench at 5% |", "|---|---|---|---|"]
        for name, var, verdicts in [("identical code: false positives", "base", ("slower", "faster")),
                                    ("identical code: inconclusive", "base", ("inconclusive",)),
                                    ("+1%: caught as slower", "pct1", ("slower",)),
                                    ("+2%: caught as slower", "pct2", ("slower",)),
                                    ("+5%: caught as slower", "pct5", ("slower",))]:
            cells = []
            for cfg in v.CONFIGS:
                sel = [r[cfg] for r in keep if r["variant"] == var and cfg in r]
                cells.append(v.rate(sum(1 for x in sel if x["verdict"] in verdicts), len(sel)))
            out.append(f"| {name} | " + " | ".join(cells) + " |")
        out.append("")
    open(path, "w").write("\n".join(out) + "\n")


v.cmd_summary = summary

if __name__ == "__main__":
    v.main()
