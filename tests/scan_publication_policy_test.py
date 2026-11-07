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


if __name__ == "__main__":
    unittest.main()
