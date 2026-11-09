"""A scanner may fail without sending its diagnostics to the runner log."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUN = ROOT / ".github/actions/gitleaks-scan/run.sh"


class NoPublicationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.workspace = self.base / "workspace"
        self.workspace.mkdir()
        self.runner = self.base / "runner"
        self.runner.mkdir()
        self.stub = self.base / "scanner"
        self.stub.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
pathlib.Path(os.environ['CALLED']).touch()
print(os.environ['CANARY'])
print(os.environ['CANARY'], file=sys.stderr)
if os.environ.get('FAIL_RUNTIME'): sys.exit(2)
if '--report-path' in args: sys.exit(9)
if os.environ.get('EMPTY_SCAN'): print('scanned ~0 bytes')
if json.loads(os.environ['REPORT']): sys.exit(3)
""")
        self.stub.chmod(0o700)
        metadata_checker = self.base / "metadata-checker"
        metadata_checker.write_bytes(b"#!/bin/sh\nexit 0\n")
        metadata_checker.chmod(0o700)
        self.canary = "PRIVATE" + "-SCANNER-DIAGNOSTICS"
        self.env = {
            **{k: v for k, v in os.environ.items() if not k.startswith("GIT_")}, "CI": "true", "GL_BIN": str(self.stub),
            "RUNNER_TEMP": str(self.runner), "GITHUB_WORKSPACE": str(self.workspace),
            "GITLEAKS_BIN": str(metadata_checker),
            "SCAN_PATH": str(self.workspace), "CANARY": self.canary,
            "CALLED": str(self.base / "called"), "REPORT": "[]",
            "GITHUB_HEAD_REF": "fixture-branch", "GITHUB_EVENT_PATH": "",
        }

    def run_scan(self, expected, expected_branch="fixture-branch", **changes):
        original_files = sorted(self.workspace.iterdir())
        proc = subprocess.run(["bash", str(RUN)], cwd=self.workspace, env={**self.env, **changes}, capture_output=True, text=True)
        self.assertEqual(proc.returncode, expected, proc.stderr)
        self.assertNotIn(self.canary, proc.stdout + proc.stderr)
        self.assertNotIn(str(self.base), proc.stdout + proc.stderr)
        self.assertEqual(list(self.runner.iterdir()), [])
        self.assertEqual(sorted(self.workspace.iterdir()), original_files)
        if expected:
            self.assertIn("Gitleaks check failed.\nBranch: " + expected_branch + "\n", proc.stderr)
            self.assertIn("https://nikolareljin.github.io/leak-lock/", proc.stderr)
            self.assertIn("run Scan Repository", proc.stderr)
            self.assertIn("rerun the repository tests", proc.stderr)
        else:
            self.assertEqual(proc.stdout + proc.stderr, "")
        return proc

    def test_clean_is_silent(self):
        self.run_scan(0)

    def test_external_directory_does_not_require_the_callers_pr_base(self):
        event = self.base / "event.json"
        event.write_text(json.dumps({"pull_request": {"base": {"sha": "1" * 40}}}))
        self.run_scan(0, GITHUB_EVENT_PATH=str(event))

    def test_findings_only_emit_generic_message(self):
        self.run_scan(1, REPORT=json.dumps([{"rule": "synthetic"}]))

    def test_unsafe_branch_text_is_not_echoed(self):
        name = "jane.roe" + "@mailbox.org"
        proc = self.run_scan(1, expected_branch="your working branch", GITHUB_HEAD_REF=name, REPORT="[1]")
        self.assertNotIn(name, proc.stdout + proc.stderr)

    def test_scanner_error_is_not_echoed(self):
        self.run_scan(1, FAIL_RUNTIME="1")

    def test_empty_scan_is_refused_without_echoing_diagnostics(self):
        self.run_scan(1, EMPTY_SCAN="1")

    def test_artifact_opt_in_is_refused_before_scan(self):
        self.run_scan(1, UPLOAD_ARTIFACT="true")
        self.assertFalse((self.base / "called").exists())

    def test_advisory_credentials_are_refused(self):
        self.run_scan(1, FAIL_ON_FINDINGS="false")
        self.assertFalse((self.base / "called").exists())

    def test_runner_temp_inside_workspace_is_refused(self):
        self.run_scan(1, RUNNER_TEMP=str(self.workspace))
        self.assertFalse((self.base / "called").exists())

    def configure(self, text):
        subprocess.run(["git", "init", "-q", str(self.workspace)], env=self.env, check=True)
        (self.workspace / ".gitleaks.toml").write_text(text)
        subprocess.run(["git", "-C", str(self.workspace), "add", "."], env=self.env, check=True)
        subprocess.run(["git", "-C", str(self.workspace), "-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-qm", "fixture"], env=self.env, check=True)

    def test_reviewed_rule_path_is_accepted(self):
        self.configure('[extend]\nuseDefault = true\n[[rules]]\nid = "fixture"\nregex = "fixture"\npath = "fixture"\n')
        self.run_scan(0)

    def test_external_scan_uses_explicit_reviewed_caller_configuration(self):
        self.configure('[extend]\nuseDefault = true\n')
        external = self.base / "external"
        external.mkdir()
        (external / "README.txt").write_text("Ready for inspection.")
        self.run_scan(0, SCAN_PATH=str(external), CONFIG_PATH=".gitleaks.toml")

    def test_quoted_external_extension_path_refused(self):
        self.configure('["extend"]\n"path" = "unreviewed.toml"\n')
        self.run_scan(1)
        self.assertFalse((self.base / "called").exists())

    def test_inline_external_extension_path_refused(self):
        self.configure('extend = {path = "unreviewed.toml"}\n')
        self.run_scan(1)
        self.assertFalse((self.base / "called").exists())


if __name__ == "__main__":
    unittest.main()
