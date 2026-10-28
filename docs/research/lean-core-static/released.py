# A check of the flags of `explain --static` against one pattern it misses, run in
# the Lean checkout that was scanned:
#   python3 released.py static-4.35.0.json released.json
#
# The pattern: the IR stores the value in a structure it rebuilds (`{ s with x }`,
# with `lean_ctor_set`), takes a reference for it, and then, on the path to the
# update, releases that structure (`lean_dec_ref`) without using it. When the
# structure is unique that release frees it and drops the value's count back to
# one, so the update is in place and the flag is a false positive.
#
# For each flag the window is the C function's code before the update: from the
# second reference (a flag with the reference at the update) or up to 150 lines
# before the call (a flag known from a caller). Verdicts:
#   holder-released  a structure holding an argument of the update or call is
#                    built and released in the window: likely false positive
#   kept             no such release found in the window
#   unchecked        the evidence does not name lines this check can read
import json, re, sys

j = json.load(open(sys.argv[1]))
files = {}

def lines_of(path):
    if path not in files:
        files[path] = open(path).read().split("\n")
    return files[path]

def verdict(cfile, start, end):
    """Is a structure holding an argument of line `end` released in [start, end)?"""
    ls = lines_of(cfile)
    if end > len(ls) or start < 1:
        return "unchecked"
    target = ls[end - 1]
    args = set(re.findall(r"\b(v_\w+)", target.split("=", 1)[-1]))
    window = ls[start - 1:end - 1]
    # stop at the start of the C function
    for i in range(len(window) - 1, -1, -1):
        if window[i].startswith(("LEAN_EXPORT", "static ", "lean_object* l_")) and "{" in window[i]:
            window = window[i:]
            break
    holders = set()
    released = False
    for l in window:
        m = re.search(r"lean_ctor_set\((v_\w+), \d+, (v_\w+)\)", l)
        if m and m.group(2) in args:
            holders.add(m.group(1))
        m = re.match(r"\s*(v_\w+) = (v_\w+);", l)
        if m and m.group(2) in holders:
            holders.add(m.group(1))
        m = re.search(r"lean_dec\w*\((v_\w+)[,)]", l)
        if m and m.group(1) in holders:
            released = True
    return "holder-released" if released else "kept"

out = {}
for f in j["flags"]:
    key = f'{f["file"]}:{f["line"]}|{f["symbol"]}|{f["value"]}|{f["cause"]}'
    m = re.match(r"(\S+):(\d+) `.*?`(?:, second reference at (\S+):(\d+))?", f["evidence"])
    c = re.match(r"caller .*?, (\S+):(\d+) `", f["via"] or "")
    try:
        if c:
            line = int(c.group(2))
            out[key] = verdict(c.group(1), max(1, line - 150), line)
        elif m and m.group(3) and m.group(3) == m.group(1) and int(m.group(4)) <= int(m.group(2)):
            out[key] = verdict(m.group(1), int(m.group(4)), int(m.group(2)))
        elif m:
            line = int(m.group(2))
            out[key] = verdict(m.group(1), max(1, line - 150), line)
        else:
            out[key] = "unchecked"
    except OSError:
        out[key] = "unchecked"
json.dump(out, open(sys.argv[2], "w"), indent=0)
import collections
print(collections.Counter(out.values()))
