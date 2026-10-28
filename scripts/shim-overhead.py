#!/usr/bin/env python3
"""What `leanprof build`'s shim adds to each process it records.

    python3 scripts/shim-overhead.py .lake/build/bin/leanprof-build-shim [RUNS]

Runs /usr/bin/true RUNS times (default 300) directly and RUNS times through
the shim (which spawns it, waits, and writes its record), alternating, and
prints the median wall time of each and the difference as JSON. Run it
under the benchmark lock; the load average is recorded with the result.
"""
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time

shim = os.path.abspath(sys.argv[1])
runs = int(sys.argv[2]) if len(sys.argv) > 2 else 300
logdir = tempfile.mkdtemp(prefix="leanprof-shim-")
direct, shimmed = [], []
load0 = os.getloadavg()[0]
for i in range(runs):
    for which in ((0, 1) if i % 2 == 0 else (1, 0)):
        cmd = ["/usr/bin/true"] if which == 0 else [shim, "/usr/bin/true", logdir]
        t = time.perf_counter()
        subprocess.run(cmd, check=True)
        (direct if which == 0 else shimmed).append(time.perf_counter() - t)
records = len(os.listdir(logdir))
d, s = statistics.median(direct), statistics.median(shimmed)
print(json.dumps({"runs": runs, "records_written": records, "direct_median_ms": round(d * 1e3, 3),
                  "shim_median_ms": round(s * 1e3, 3), "added_ms": round((s - d) * 1e3, 3),
                  "load_before": round(load0, 2), "load_after": round(os.getloadavg()[0], 2),
                  "platform": sys.platform}, indent=1))
