#!/usr/bin/env python3
"""Before/after table from interleaved suite runs (bench/run.py JSON):
    python3 bench/linux/probe/compare.py results/suite-before-p*.json -- results/suite-after-p*.json
Each cell: the median over the runs of each side's suite medians, and the
range over the suite runs in brackets."""
import json, statistics, sys

i = sys.argv.index("--")
sides = {"before": sys.argv[1:i], "after": sys.argv[i + 1:]}
data = {k: [json.load(open(f)) for f in fs] for k, fs in sides.items()}
CONFIGS = ["profile", "run", "auto", "retime"]
FIELDS = [("share_mae_pp", "share error, pp", "{:.1f}"), ("total_ratio", "reported/plain", "{:.2f}"),
          ("ns_per_scope", "cost per scope, ns", "{:.1f}"), ("slowdown", "slowdown", "{:.2f}x")]


def cell(side, w, c, f, fmt):
    vals = [d["results"][w]["configs"].get(c, {}).get(f) for d in data[side]]
    vals = [v for v in vals if v is not None]
    if not vals:
        return "-"
    return fmt.format(statistics.median(vals)) + " (" + fmt.format(min(vals)) + "-" + fmt.format(max(vals)) + ")"


workloads = list(data["before"][0]["results"])
for f, name, fmt in FIELDS:
    print(f"\n### {name}\n")
    print("| workload | " + " | ".join(f"`{c}` before | `{c}` after" for c in CONFIGS) + " |")
    print("|---|" + "---|" * (2 * len(CONFIGS)))
    for w in workloads:
        print(f"| `{w}` | " + " | ".join(f"{cell('before', w, c, f, fmt)} | {cell('after', w, c, f, fmt)}"
                                       for c in CONFIGS) + " |")
