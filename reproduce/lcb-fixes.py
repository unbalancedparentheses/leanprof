#!/usr/bin/env python3
"""docs/case-studies/lean-compiler-backend.md; README "lean-compiler-backend":
three fixes found with leanprof cut the allocations needed to compile zlib from
11.95M to 7.72M, and `explain` printed the CFG.build fix (121,054 copies).

Pinned: unbalancedparentheses/lean-compiler-backend at a25c541 (before the
fixes) and 854fcc2 (main with the tokenizer, CFG.build and Parser.peek fixes),
Lean 4.34.1 (the project's toolchain, through elan), the zlib 1.3.1 units
archived in the compiler's repository at 854fcc2. Workload:
`lcb --target aarch64-macos --optimize --allocate deflate inflate trees crc32`.
Published on an Apple M5 Max. All checks are exact counts; the output must be
byte-identical with and without leanprof. (The "160 combinations" identity
check of the case study was not recorded; lcb-autoresearch runs the 540-case
one.)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lcb  # noqa: E402
from lib import Claim, build_leanprof  # noqa: E402

c = Claim("lcb-fixes", "Apple M5 Max (docs/case-studies/lean-compiler-backend.md)",
          "leanprof run --allocs / measure on lcb a25c541 and 854fcc2, zlib")
build_leanprof()
inp = lcb.inputs()


def site(r, fn, kind):
    rows = [x["copies"] for x in r["run"]["copies"]
            if x["function"].split(" (in ")[0].endswith(fn) and x["kind"] == kind]
    return max(rows) if rows else 0


before = lcb.counts(lcb.checkout("a25c541"), inp, "a25c541")
c.exact("a25c541: allocations, whole run", before["allocs"], 11946202)
c.exact("a25c541:   MiB allocated", round(before["alloc_mib"], 1), 266.6)
tok = max(x["allocs"] for x in before["run"]["allocations"] if x["where"] == "LeanCompilerBackend/Parser.lean:20")  # the loop's row
c.exact("a25c541: allocations in Parser.tokenize (Parser.lean:20)", tok, 4066775)
c.exact("a25c541: copies in CFG.build (array, in a for loop)", site(before, "CFG.build", "Array"), 121054)
c.exact("a25c541: copies in Optimize.function", site(before, "Optimize.function", "Array"), 46633)
c.exact("a25c541: output byte-identical with leanprof", before["same_output"], True)
after = lcb.counts(lcb.checkout("854fcc2"), inp, "854fcc2")
c.exact("854fcc2: allocations, whole run", after["allocs"], 7719273)
c.exact("854fcc2:   MiB allocated", round(after["alloc_mib"], 1), 200.1)
c.exact("854fcc2: copies in CFG.build, the same loop",
        sum(x["copies"] for x in after["run"]["copies"] if x["function"].endswith("CFG.build (in List.forIn'.loop)")),
        43899)
c.exact("854fcc2: copies of shared values (judge's copies_total)", after["copies_total"], 86449)
c.exact("854fcc2: output byte-identical with leanprof", after["same_output"], True)
c.note("allocation change", f"{100 * (after['allocs'] / before['allocs'] - 1):+.1f}%", "-35%")
c.finish()
