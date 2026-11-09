"""Reject unsafe scanner publication settings before workflows run."""

import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("policy", Path(__file__).resolve().parents[1] / "scripts/check_scan_publication.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class PolicyTests(unittest.TestCase):
    def check(self, steps):
        return policy.violations({"jobs": {"scan": {"steps": steps}}})

    def test_scanner_upload_opt_in_refused(self):
        for tool, option in (("gitleaks", "upload_artifact"), ("foxguard", "upload-sarif")):
            self.assertTrue(self.check([{"uses": "fixture/" + tool, "with": {option: True}}]))

    def test_external_uploader_after_scan_refused(self):
        self.assertTrue(self.check([{"uses": "fixture/gitleaks"}, {"uses": "actions/upload-artifact"}]))

    def test_silent_enforced_scan_allowed(self):
        self.assertFalse(self.check([{"uses": "fixture/gitleaks", "with": {"upload_artifact": False}}]))

    def test_writer_without_guard_refused(self):
        self.assertTrue(policy.violations({"jobs": {"write": {"permissions": {"contents": "write"}, "steps": [{"run": "git push origin HEAD"}]}}}))

    def test_guard_after_transport_refused(self):
        self.assertTrue(policy.violations({"jobs": {"write": {"permissions": {"contents": "write"}, "steps": [
            {"run": "git push origin HEAD"}, {"uses": "./publication-guard"},
        ]}}}))

    def test_artifact_action_without_payload_check_refused(self):
        self.assertTrue(self.check([{"uses": "actions/upload-artifact@fixture", "with": {"path": "dist/*"}}]))

    def test_always_cannot_bypass_a_failed_payload_check(self):
        guard = {"id": "checked", "uses": "./trusted/.github/actions/publication-check", "with": {"mode": "artifact"}}
        upload = {"uses": "actions/upload-artifact@fixture", "with": {"path": "${{ steps.checked.outputs.paths }}"}}
        for condition in ("always()", "${{ steps.checked.outcome == 'success' || always() }}", "${{ !(steps.checked.outcome == 'success') }}"):
            upload["if"] = condition
            self.assertTrue(self.check([guard, upload]))
        upload["if"] = "${{ always() && steps.checked.outcome == 'success' }}"
        self.assertFalse(self.check([guard, upload]))

    def test_original_payload_path_cannot_bypass_snapshot(self):
        self.assertTrue(self.check([
            {"id": "checked", "uses": "./trusted/.github/actions/publication-check", "with": {"mode": "artifact"}},
            {"uses": "actions/upload-artifact@fixture", "if": "${{ always() && steps.checked.outcome == 'success' }}", "with": {"path": "dist/*"}},
        ]))


if __name__ == "__main__":
    unittest.main()
