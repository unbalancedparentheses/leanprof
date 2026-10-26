#!/usr/bin/env python3
"""Real Lean fixtures plus fail-closed evidence and project-boundary tests."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("proof_audit", ROOT / "scripts/proof-audit/audit.py")
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


TACTIC = "\ntheorem small_range : ∀ v, v < 24 → obligation v := by\n  intro v hv\n  unfold obligation\n  omega\n"


def command(args, cwd):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{args} in {cwd}:\n{result.stdout}\n{result.stderr}")
    return result.stdout


class ProofAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="leanprof-proof-audit-tests-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name).resolve()
        cls.projects = {}
        cls.snapshots = {}
        base = (ROOT / "Tests/ProofAudit/Base.lean").read_text()
        variants = {
            "base": base,
            "good": (ROOT / "Tests/ProofAudit/Good.lean").read_text(),
            "weakened": (ROOT / "Tests/ProofAudit/Weakened.lean").read_text(),
            "sorry": base.replace("exact Nat.add_zero n", "sorry"),
            "axiom": base.replace("theorem preserved", "axiom shortcut : ∀ n : Nat, obligation n\n\ntheorem preserved").replace("exact Nat.add_zero n", "exact shortcut n"),
            "unused_axiom": base + "\naxiom unusedEscape : False\n",
            "removed": "def obligation (n : Nat) : Prop := n + 0 = n\ndef compute (n : Nat) : Nat := n\n",
            "statement": base.replace("theorem preserved (n : Nat) : obligation n := by\n  unfold obligation\n  exact Nat.add_zero n", "theorem preserved (_ : Nat) : True := by trivial"),
            "extern": base.replace("def compute", '@[extern "fake_native_compute"]\ndef compute'),
            "implemented_by": base.replace("def compute", "def alternate (n : Nat) : Nat := n\n@[implemented_by alternate]\ndef compute"),
            "native": base + "\ntheorem nativeEscape : (1 : Nat) = 1 := by native_decide\n",
            "comment": base + '\n-- sorry axiom @[extern] @[implemented_by]\ndef note : String := "sorry axiom"\n',
            # a tactic proof that abstracts a `_proof_1` lemma, rewritten as a term without it
            "tactic": base + TACTIC,
            "tactic_term": base + TACTIC.replace(":= by\n  intro v hv\n  unfold obligation\n  omega",
                                                 ":=\n  fun v _ => Nat.add_zero v"),
        }
        for label, source in variants.items():
            p = cls.directory / label
            p.mkdir()
            (p / "lean-toolchain").write_text(os.environ.get("LEANPROF_AUDIT_TEST_TOOLCHAIN", (ROOT / "lean-toolchain").read_text()))
            (p / "lakefile.toml").write_text('name = "audit_fixture"\nversion = "0.1.0"\n[[lean_lib]]\nname = "Sample"\n')
            (p / ".gitignore").write_text(".lake/\n")
            (p / "Sample.lean").write_text(source)
            command(["git", "init", "-q"], p)
            command(["lake", "build", "Sample"], p)
            command(["git", "add", "."], p)
            command(["git", "-c", "user.name=Audit Test", "-c", "user.email=audit@example.invalid",
                     "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"], p)
            cls.projects[label] = p
            cls.snapshots[label], _ = audit.capture(p, ["Sample"], 60)

    def assertVerdict(self, label, status, code=None):
        result = audit.compare(self.snapshots["base"], self.snapshots[label])
        self.assertEqual(result["status"], status, json.dumps(result, indent=2))
        if code:
            self.assertIn(code, {f["code"] for f in result["findings"]})
        return result

    def test_proof_rewrite_and_binder_rename_pass(self):
        self.assertVerdict("good", "PASS")

    def test_unchanged_pass(self):
        self.assertVerdict("base", "PASS")

    def test_indirect_statement_weakening_is_not_pass(self):
        self.assertVerdict("weakened", "INCONCLUSIVE", "statement_dependency_changed")

    def test_direct_statement_change_is_not_pass(self):
        self.assertVerdict("statement", "INCONCLUSIVE", "signature_changed")

    def test_sorry_fails(self):
        self.assertVerdict("sorry", "FAIL", "sorry_dependency")

    def test_new_axiom_dependency_fails(self):
        self.assertVerdict("axiom", "FAIL", "added_axiom_dependency")

    def test_unused_axiom_fails(self):
        self.assertVerdict("unused_axiom", "FAIL", "added_axiom")

    def test_removed_theorem_fails(self):
        self.assertVerdict("removed", "FAIL", "removed_declaration")

    def test_extern_fails(self):
        self.assertVerdict("extern", "FAIL", "runtime_escape_changed")

    def test_implemented_by_fails(self):
        self.assertVerdict("implemented_by", "FAIL", "runtime_escape_changed")

    def test_native_decide_trust_increase_fails(self):
        self.assertVerdict("native", "FAIL", "added_axiom_dependency")

    def test_generated_lemma_gone_with_its_proof_passes(self):
        names = set(self.snapshots["tactic"]["roots"]) - set(self.snapshots["tactic_term"]["roots"])
        self.assertTrue(any(audit.generated(n) for n in names), names)
        result = audit.compare(self.snapshots["tactic"], self.snapshots["tactic_term"])
        self.assertEqual(result["status"], "PASS", json.dumps(result, indent=2))
        # the theorem the proof belonged to is still an obligation
        removed = audit.compare(self.snapshots["tactic"], self.snapshots["base"])
        self.assertIn(("FAIL", "removed_declaration", "small_range"),
                      {(f["status"], f["code"], f["subject"]) for f in removed["findings"]})

    def test_generated_names(self):
        for name in ("small_range._proof_1_1", "f._unsafe_rec", "f.eq_1", "f.eq_def", "f.match_2",
                     "_private.A.0.f._proof_3", "f._auxLemma.4"):
            self.assertTrue(audit.generated(name), name)
        for name in ("eq_1", "preserved", "f.proof", "f.match", "_private.A.0.g", "fast._impl"):
            self.assertFalse(audit.generated(name), name)

    def test_comments_and_strings_do_not_trigger(self):
        self.assertVerdict("comment", "PASS")

    def test_empty_truncated_and_incompatible_evidence(self):
        for key, value in (("roots", []), ("declarations", []), ("schema", 99)):
            bad = copy.deepcopy(self.snapshots["base"])
            bad[key] = value
            self.assertEqual(audit.compare(self.snapshots["base"], bad)["status"], "INCONCLUSIVE")
        bad = copy.deepcopy(self.snapshots["base"])
        bad["leanVersion"] = "different"
        self.assertEqual(audit.compare(self.snapshots["base"], bad)["status"], "INCONCLUSIVE")

    def test_project_audit_records_provenance(self):
        result = audit.audit(self.projects["base"], self.projects["good"], ["Sample"],
                             audit.DEFAULT_PROTECTED, 60)
        self.assertEqual(result["status"], "PASS", result)
        self.assertEqual(result["changedFiles"], ["Sample.lean"])
        self.assertEqual(len(result["candidate"]["sourceHash"]), 64)

    def test_protected_file_add_change_delete(self):
        candidate = self.projects["good"]
        base = self.projects["base"]
        for project in (base, candidate):
            (project / "Tests").mkdir(exist_ok=True)
        bp, cp = base / "Tests/expected.txt", candidate / "Tests/expected.txt"
        self.addCleanup(lambda: bp.unlink(missing_ok=True))
        self.addCleanup(lambda: cp.unlink(missing_ok=True))
        for old, new in ((None, "new"), ("old", "new"), ("old", None)):
            for path, content in ((bp, old), (cp, new)):
                if content is None:
                    path.unlink(missing_ok=True)
                else:
                    path.write_text(content)
            result = audit.audit(base, candidate, ["Sample"], audit.DEFAULT_PROTECTED, 60)
            self.assertEqual(result["status"], "FAIL", result)
            self.assertIn("protected_file_changed", {f["code"] for f in result["findings"]})

    def test_uncovered_source_change(self):
        path = self.projects["good"] / "Other.lean"
        path.write_text("theorem unseen : True := by trivial\n")
        self.addCleanup(lambda: path.unlink(missing_ok=True))
        result = audit.audit(self.projects["base"], self.projects["good"], ["Sample"], (), 60)
        self.assertEqual(result["status"], "INCONCLUSIVE")
        self.assertIn("uncovered_source_change", {f["code"] for f in result["findings"]})

    def test_files_only_without_modules(self):
        # no module selected: a protected change fails, a Lean change is not covered
        base, candidate = self.projects["base"], self.projects["good"]
        result = audit.audit(base, candidate, [], audit.DEFAULT_PROTECTED, 60)
        self.assertEqual(result["status"], "INCONCLUSIVE", result)
        self.assertIn("uncovered_source_change", {f["code"] for f in result["findings"]})
        (candidate / "tests").mkdir(exist_ok=True)
        expected = candidate / "tests/expected.txt"
        expected.write_text("weakened")
        self.addCleanup(lambda: expected.unlink(missing_ok=True))
        result = audit.audit(base, candidate, [], audit.DEFAULT_PROTECTED, 60)
        self.assertEqual(result["status"], "FAIL", result)

    def test_package_in_a_subdirectory(self):
        # the Lake package below the checkout root (`--subdir`), as in lean-regex's regex/
        pairs = {}
        for label in ("base", "sorry"):
            top = self.directory / f"nested-{label}"
            package = top / "pkg"
            package.mkdir(parents=True)
            for name in ("lean-toolchain", "lakefile.toml", "Sample.lean"):
                (package / name).write_text((self.projects[label] / name).read_text())
            (top / ".gitignore").write_text(".lake/\n")
            command(["git", "init", "-q"], top)
            command(["lake", "build", "Sample"], package)
            command(["git", "add", "."], top)
            command(["git", "-c", "user.name=Audit Test", "-c", "user.email=audit@example.invalid",
                     "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"], top)
            pairs[label] = top
        result = audit.audit(pairs["base"], pairs["sorry"], ["Sample"], audit.DEFAULT_PROTECTED, 60, "pkg")
        self.assertEqual(result["status"], "FAIL", result)
        self.assertIn("sorry_dependency", {f["code"] for f in result["findings"]})
        self.assertEqual(result["changedFiles"], ["pkg/Sample.lean"])
        with self.assertRaisesRegex(ValueError, "package root"):
            audit.audit(pairs["base"], pairs["sorry"], ["Sample"], audit.DEFAULT_PROTECTED, 60)

    def test_source_change_during_capture(self):
        actual = audit.inventory
        calls = 0

        def unstable(*args):
            nonlocal calls
            calls += 1
            files = actual(*args)
            if calls == 2:
                files["Sample.lean"] = "changed while building"
            return files

        with patch.object(audit, "inventory", side_effect=unstable):
            with self.assertRaisesRegex(ValueError, "changed while"):
                audit.capture(self.projects["base"], ["Sample"], 60)

    def test_timeout_stops_compiler_children(self):
        marker = self.directory / "timeout-child-finished"
        child = "import time; from pathlib import Path; time.sleep(0.4); Path(%r).touch()" % str(marker)
        parent = "import subprocess,sys,time; subprocess.Popen([sys.executable, '-c', %r]); time.sleep(5)" % child
        with self.assertRaises(subprocess.TimeoutExpired):
            audit.run(["python3", "-c", parent], self.directory, 0.15)
        time.sleep(0.5)
        self.assertFalse(marker.exists())

    def test_cli_success_and_failure_exit_codes(self):
        for label, code, status in (("good", 0, "PASS"), ("sorry", 1, "FAIL")):
            result = subprocess.run(["python3", str(ROOT / "scripts/proof-audit/audit.py"),
                                     "--base", str(self.projects["base"]),
                                     "--candidate", str(self.projects[label]),
                                     "--module", "Sample"], capture_output=True, text=True)
            self.assertEqual(result.returncode, code, result.stderr + result.stdout)
            self.assertEqual(json.loads(result.stdout)["status"], status)

    def test_cli_collection_failure_is_inconclusive(self):
        result = subprocess.run(["python3", str(ROOT / "scripts/proof-audit/audit.py"),
                                 "--base", str(self.projects["base"]),
                                 "--candidate", str(self.projects["good"]),
                                 "--module", "Missing"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["status"], "INCONCLUSIVE")


if __name__ == "__main__":
    unittest.main(verbosity=2)
