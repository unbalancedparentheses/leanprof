#!/usr/bin/env python3
"""Compile real Lean fixtures, compare static warnings with instrumented copies."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("static_copies", ROOT / "scripts/static-copies/analyze.py")
analysis = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analysis)


def run(args, cwd=ROOT):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{args}: {(result.stderr + result.stdout)[-4000:]}")
    return result.stdout


def export(project, module):
    return json.loads(run(["lake", "env", "lean", "--run",
                           str(ROOT / "scripts/static-copies/Export.lean"), module], project))


class StaticCopyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = ROOT / "Tests/StaticCopies"
        run(["lake", "build", "checkCopies"], cls.project)
        cls.ir = export(cls.project, "Cases")
        cls.result = analysis.analyze(cls.ir)
        cls.warned = {f["source"]["declaration"].split(".")[-1] for f in cls.result["findings"]}
        cls.counts = {}
        for size in (2, 20, 128):
            output = run([str(cls.project / ".lake/build/bin/checkCopies"), str(size)], cls.project)
            cls.counts[size] = {line.split("\t")[0]: int(line.split("\t")[1]) for line in output.splitlines()}
        run(["lake", "build", "explainpatterns"])
        cls.patterns = analysis.analyze(export(ROOT, "Examples.ExplainPatterns"))
        output = run([str(ROOT / ".lake/build/bin/explainpatterns"), "400"])
        cls.pattern_counts = {name: int(count) for name, count in re.findall(r"^(\w+): (\d+) copies", output, re.M)}

    def test_retained_array_is_detected_and_copies(self):
        self.assertIn("retained", self.warned)
        self.assertTrue(all(c["retained"] == 1 for c in self.counts.values()))

    def test_stored_array_is_detected_and_copies(self):
        self.assertIn("stored", self.warned)
        self.assertTrue(all(c["stored"] == 1 for c in self.counts.values()))
        finding = next(f for f in self.result["findings"] if f["source"]["declaration"].endswith(".stored"))
        self.assertTrue(finding["evidence"]["holders"])

    def test_nested_array_is_detected_and_copies(self):
        self.assertIn("nested", self.warned)
        self.assertTrue(all(c["nested"] == 1 for c in self.counts.values()))

    def test_exclusive_moved_released_and_fixed_do_not_warn_or_copy(self):
        for name in ("exclusive", "moved", "released", "nestedFixed"):
            with self.subTest(name=name):
                self.assertNotIn(name, self.warned)
                self.assertTrue(all(c[name] == 0 for c in self.counts.values()))

    def test_conditional_warning_carries_path_and_does_not_predict_every_run(self):
        finding = next(f for f in self.result["findings"] if f["source"]["declaration"].endswith(".conditional"))
        self.assertTrue(finding["conditions"])
        self.assertTrue(all(c["conditional.true"] == 1 and c["conditional.false"] == 0
                            for c in self.counts.values()))

    def test_known_empty_copy_is_suppressed(self):
        self.assertNotIn("emptyRetained", self.warned)
        self.assertTrue(all(c["emptyRetained"] == 1 for c in self.counts.values()))
        self.assertTrue(any(c["suppressedEmptySites"] for c in self.result["coverage"]))

    def test_interprocedural_copy_is_an_explicit_known_miss(self):
        self.assertNotIn("interprocedural", self.warned)
        self.assertTrue(all(c["interprocedural"] == 1 for c in self.counts.values()))
        self.assertTrue(any("interprocedural" in s for s in self.result["limitations"]))

    def test_fixture_prediction_set_is_exact(self):
        self.assertEqual(self.warned, {"retained", "stored", "nested", "conditional"})

    def test_source_location_is_honestly_declaration_level(self):
        for finding in self.result["findings"]:
            self.assertEqual(finding["source"]["precision"], "declaration")
            self.assertGreater(finding["source"]["line"], 0)
            self.assertIn("Array.push", finding["irExpression"])

    def test_existing_copy_patterns_have_no_warnings_on_fixed_versions(self):
        predicted = {f["source"]["declaration"] for f in self.patterns["findings"]}
        self.assertEqual(predicted, {"keepHistory", "nestedBuckets"})
        self.assertEqual(self.pattern_counts["keepHistory"], 399)
        self.assertEqual(self.pattern_counts["nestedBuckets"], 390)
        negative = {name for name, count in self.pattern_counts.items() if count == 0}
        self.assertEqual(len(negative), 10)
        self.assertFalse(predicted & negative)
        positive = {name for name, count in self.pattern_counts.items() if count > 0}
        # Deliberately record misses instead of claiming all sharing is covered.
        self.assertEqual(len(positive - predicted), 6)

    def test_budget_exhaustion_is_reported(self):
        limited = analysis.analyze(self.ir, max_states=1)
        self.assertTrue(any("state_budget" in c["limits"] for c in limited["coverage"]))
        self.assertEqual(limited["status"], "partial")

    def test_unknown_schema_and_empty_evidence(self):
        with self.assertRaises(ValueError):
            analysis.analyze({"schema": 999})
        empty = dict(self.ir, modules=[])
        self.assertEqual(analysis.analyze(empty)["status"], "no-ir-bodies")

    def test_missing_module_returns_error_not_empty_success(self):
        result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/static-copies/analyze.py"),
                                 "--project", str(self.project), "--module", "MissingStaticCopyModule"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["status"], "error")


if __name__ == "__main__":
    unittest.main(verbosity=2)
