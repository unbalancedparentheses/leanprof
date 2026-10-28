# The flags of `leanprof explain --static --all` over Lean's own C, one per line.
#   python3 flags-tsv.py static-4.35.0.json.gz released.json > flags-4.35.0.tsv
# `released.json` comes from released.py, run on the build host.
import gzip, json, sys

AREAS = [
    ("Lean/Elab/", "Lean.Elab"), ("Lean/Meta/", "Lean.Meta"), ("Lean/Compiler/", "compiler"),
    ("lake/", "Lake"), ("Init/", "Init"), ("Std/", "Std"), ("Lean/Server/", "server"),
    ("Lean/Data/Lsp/", "server"), ("Lean/Parser", "parser"), ("Lean/PrettyPrinter", "pretty printer"),
]

def area(path):
    for prefix, name in AREAS:
        if path.startswith(prefix):
            return name
    return "Lean (other)" if path.startswith("Lean/") else "tools"

j = json.load(gzip.open(sys.argv[1]))
released = json.load(open(sys.argv[2]))
cols = ["area", "where", "declaration", "function", "kind", "operation", "value", "cause", "loop",
        "shown", "confidence", "local_check", "why"]
print("\t".join(cols))
for f in j["flags"]:
    key = f'{f["file"]}:{f["line"]}|{f["symbol"]}|{f["value"]}|{f["cause"]}'
    row = [area(f["file"]), f["where"], f["declaration"], f["function"], f["kind"], f["operation"],
           f["value"], f["cause"], "loop" if f["loop"] else "", "" if f["kind"] == "String" and not f["loop"] else "shown",
           f["confidence"].split(":")[0], released.get(key, ""), f["why"]]
    print("\t".join(str(x).replace("\t", " ").replace("\n", " ") for x in row))
