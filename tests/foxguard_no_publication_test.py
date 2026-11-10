"""The Foxguard action may fail without sending its diagnostics to the runner log."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUN = ROOT / ".github/actions/foxguard-scan/run.sh"


class NoPublicationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.workspace = self.base / "workspace"
        self.workspace.mkdir()
        (self.workspace / "app.py").write_text("print('ready')\n")
        self.runner = self.base / "runner"
        self.runner.mkdir()
        # A stand-in for the foxguard binary: records its arguments and the
        # config it was handed, prints a canary on both streams and writes the
        # report the environment describes.
        self.stub = self.base / "scanner"
        self.stub.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
record = {"args": args}
if '--config' in args:
    cfg = pathlib.Path(args[args.index('--config') + 1])
    record["config"] = cfg.read_text()
    record["config_dir"] = str(cfg.resolve().parent)
pathlib.Path(os.environ['CALLED']).write_text(json.dumps(record))
print(os.environ['CANARY'])
print(os.environ['CANARY'], file=sys.stderr)
if os.environ.get('FAIL_RUNTIME'): sys.exit(2)
out = pathlib.Path(args[args.index('--output') + 1])
if os.environ.get('MALFORMED'):
    out.write_text('{not json')
    sys.exit(0)
total = int(os.environ['FINDINGS'])
out.write_text(json.dumps({
    "scanner": {"name": "foxguard", "version": "0.0.0"},
    "finding_counts": {"total": total},
    "findings": [{"rule_id": "stub/rule", "file": "app.py"}] * total,
    "target": {"files_scanned": int(os.environ['FILES'])},
}))
sys.exit(1 if total else 0)
""")
        self.stub.chmod(0o700)
        # security_notice vets the branch text with the credential scanner
        # before printing it; the runner has none, so one that passes stands in.
        metadata_checker = self.base / "metadata-checker"
        metadata_checker.write_bytes(b"#!/bin/sh\nexit 0\n")
        metadata_checker.chmod(0o700)
        self.canary = "PRIVATE" + "-SCANNER-DIAGNOSTICS"
        self.env = {
            **{k: v for k, v in os.environ.items() if not k.startswith("GIT_")}, "CI": "true", "FG_BIN": str(self.stub),
            "RUNNER_TEMP": str(self.runner), "GITHUB_WORKSPACE": str(self.workspace),
            "GITLEAKS_BIN": str(metadata_checker),
            "SCAN_PATH": str(self.workspace), "CANARY": self.canary,
            "CALLED": str(self.base / "called"), "FINDINGS": "0", "FILES": "1",
            "GITHUB_HEAD_REF": "fixture-branch", "GITHUB_EVENT_PATH": "",
        }

    def called(self):
        path = self.base / "called"
        if not path.exists():
            return None
        return json.loads(path.read_text())

    def run_scan(self, expected, expected_branch="fixture-branch", **changes):
        original_files = sorted(self.workspace.iterdir())
        proc = subprocess.run(["bash", str(RUN)], cwd=self.workspace, env={**self.env, **changes}, capture_output=True, text=True)
        self.assertEqual(proc.returncode, expected, proc.stderr)
        self.assertNotIn(self.canary, proc.stdout + proc.stderr)
        self.assertNotIn(str(self.base), proc.stdout + proc.stderr)
        self.assertNotIn("stub/rule", proc.stdout + proc.stderr)
        self.assertNotIn("app.py", proc.stdout + proc.stderr)
        self.assertEqual(list(self.runner.iterdir()), [])
        self.assertEqual(sorted(self.workspace.iterdir()), original_files)
        if expected:
            self.assertIn("Foxguard check failed.\nBranch: " + expected_branch + "\n", proc.stderr)
            self.assertIn("https://nikolareljin.github.io/leak-lock/", proc.stderr)
            self.assertIn("run Scan Repository", proc.stderr)
            self.assertIn("rerun the repository tests", proc.stderr)
            self.assertEqual(proc.stdout, "")
        else:
            self.assertEqual(proc.stdout + proc.stderr, "")
        return proc

    def test_clean_is_silent(self):
        self.run_scan(0)
        self.assertEqual(self.called()["config"], "")

    def test_scanner_is_driven_quietly_at_the_requested_severity(self):
        self.run_scan(0, SEVERITY="HIGH")
        args = self.called()["args"]
        self.assertIn("-q", args)
        self.assertEqual(args[args.index("-s") + 1], "high")
        self.assertEqual(args[args.index("-f") + 1], "json")
        self.assertEqual(args[-2:], ["--", str(self.workspace)])

    def test_scan_path_that_reads_as_an_option_is_refused(self):
        (self.workspace / "-s").mkdir()
        self.run_scan(1, SCAN_PATH="-s")
        self.assertIsNone(self.called())

    def test_own_checkout_inside_the_scan_path_is_refused(self):
        # foxguard-scan.yml checks this library out beside the caller's tree,
        # never under it. Scanning the parent of this checkout stands in for a
        # layout that would read the library's scripts as the caller's.
        self.run_scan(1, SCAN_PATH=str(ROOT.parent))
        self.assertIsNone(self.called())
        # The action run from its own repository:
        # the checkout is the scan root, not under it.
        self.run_scan(0, SCAN_PATH=str(ROOT))
        self.assertIsNotNone(self.called())

    def test_unknown_severity_is_refused_before_scan(self):
        self.run_scan(1, SEVERITY="loud")
        self.assertIsNone(self.called())

    def test_findings_only_emit_generic_message(self):
        self.run_scan(1, FINDINGS="3")

    def test_unsafe_branch_text_is_not_echoed(self):
        name = "jane.roe" + "@mailbox.org"
        proc = self.run_scan(1, expected_branch="your working branch", GITHUB_HEAD_REF=name, FINDINGS="1")
        self.assertNotIn(name, proc.stdout + proc.stderr)

    def test_scanner_error_is_not_echoed(self):
        self.run_scan(1, FAIL_RUNTIME="1")

    def test_malformed_report_is_refused_without_echoing_it(self):
        self.run_scan(1, MALFORMED="1")

    def test_empty_scan_is_refused(self):
        self.run_scan(1, FILES="0")

    def test_missing_scan_path_is_refused_before_scan(self):
        self.run_scan(1, SCAN_PATH=str(self.base / "absent"))
        self.assertIsNone(self.called())

    def test_advisory_findings_are_refused(self):
        self.run_scan(1, FAIL_ON_FINDINGS="false")
        self.assertIsNone(self.called())

    def test_runner_temp_inside_workspace_is_refused(self):
        self.run_scan(1, RUNNER_TEMP=str(self.workspace))
        self.assertIsNone(self.called())

    def configure(self, text, name=".foxguard.yml", commit=True):
        if not (self.workspace / ".git").exists():
            subprocess.run(["git", "init", "-q", str(self.workspace)], env=self.env, check=True)
            subprocess.run(["git", "-C", str(self.workspace), "add", "app.py"], env=self.env, check=True)
            self.commit("fixture")
        (self.workspace / name).write_text(text)
        if commit:
            subprocess.run(["git", "-C", str(self.workspace), "add", name], env=self.env, check=True)
            self.commit("config")

    def commit(self, message):
        subprocess.run(["git", "-C", str(self.workspace), "-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-qm", message], env=self.env, check=True)

    def test_reviewed_config_is_passed(self):
        self.configure("scan:\n  disable_rules: [fixture/rule]\n")
        self.run_scan(0)
        self.assertEqual(self.called()["config"], "scan:\n  disable_rules: [fixture/rule]\n")

    def test_reviewed_config_sits_where_the_caller_keeps_it(self):
        # foxguard resolves scan.ignore_rules[].path and secrets.exclude_paths
        # against the config's directory and refuses paths outside the scanned
        # tree, so the vetted copy must sit beside the caller's config.
        self.configure("scan:\n  ignore_rules: [{path: app.py, rules: [x]}]\n")
        self.run_scan(0)
        self.assertEqual(self.called()["config_dir"], str(self.workspace.resolve()))
        (self.workspace / "ci").mkdir()
        self.configure("# nested\n", name="ci/foxguard.yml")
        self.run_scan(0, CONFIG_PATH="ci/foxguard.yml")
        self.assertEqual(self.called()["config_dir"], str((self.workspace / "ci").resolve()))

    def test_config_directory_linked_outside_the_tree_is_refused(self):
        # The reviewed config is at ci/ in the base; the tree under review
        # swaps ci/ for a link out of the workspace. Nothing is written there.
        (self.workspace / "ci").mkdir()
        self.configure("# reviewed\n", name="ci/foxguard.yml")
        subprocess.run(["rm", "-rf", str(self.workspace / "ci")], check=True)
        outside = self.base / "outside"
        outside.mkdir()
        (self.workspace / "ci").symlink_to(outside)
        self.run_scan(1, CONFIG_PATH="ci/foxguard.yml")
        self.assertIsNone(self.called())
        self.assertEqual(list(outside.iterdir()), [])

    def test_config_directory_linked_inside_the_tree_is_refused(self):
        # A link from ci/ to the root would anchor the base's ignore_rules
        # paths at the root, silencing findings the base never ignored there.
        (self.workspace / "ci").mkdir()
        self.configure("# reviewed\n", name="ci/foxguard.yml")
        subprocess.run(["rm", "-rf", str(self.workspace / "ci")], check=True)
        (self.workspace / "ci").symlink_to(".")
        self.run_scan(1, CONFIG_PATH="ci/foxguard.yml")
        self.assertIsNone(self.called())

    def test_reviewed_config_is_placed_without_o_nofollow(self):
        # Windows Python has no os.O_NOFOLLOW; the action supports Windows.
        self.configure("# reviewed\n")
        target = self.base / "target"
        target.mkdir()
        prepare = RUN.parent / "prepare_config.py"
        shim = self.base / "no_nofollow.py"
        shim.write_text("import os, runpy, sys\ndel os.O_NOFOLLOW\nsys.argv = sys.argv[1:]\n"
                        "runpy.run_path(sys.argv[0], run_name='__main__')\n")
        proc = subprocess.run(["python3", "-I", str(shim), str(prepare), str(target)],
                              cwd=self.workspace, env={**self.env, "SCAN_PATH": str(self.workspace)},
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        placed = Path((target / "config.path").read_text())
        self.assertEqual(placed.read_text(), "# reviewed\n")
        placed.unlink()

    def test_uncommitted_config_in_the_tree_is_not_used(self):
        self.configure("scan:\n  disable_rules: [fixture/rule]\n", commit=False)
        self.run_scan(0)
        self.assertEqual(self.called()["config"], "")

    def test_pr_scan_reads_config_from_the_base_commit(self):
        self.configure("# base\n")
        base = subprocess.run(["git", "-C", str(self.workspace), "rev-parse", "HEAD"], env=self.env, capture_output=True, text=True, check=True).stdout.strip()
        self.configure("# head\n")
        event = self.base / "event.json"
        event.write_text(json.dumps({"pull_request": {"base": {"sha": base}}}))
        self.run_scan(0, GITHUB_EVENT_PATH=str(event))
        self.assertEqual(self.called()["config"], "# base\n")

    def test_baseline_in_reviewed_config_is_refused(self):
        for text in (
            "scan:\n  baseline: .foxguard/baseline.json\n",
            "scan: {disable_rules: [], baseline: .foxguard/baseline.json}\n",
            'scan: {"baseline": "b.json"}\n',
            "scan:\n  nested:\n    deeper:\n      baseline: b.json\n",
            'scan:\n  "base\\x6cine": b.json\n',
            "defaults: &d\n  baseline: b.json\nscan:\n  <<: *d\n",
            "defaults: &d {baseline: b.json}\nscan: *d\n",
            "rules:\n  - baseline: b.json\n",
            "---\nscan: {}\n---\nscan: {baseline: b.json}\n",
        ):
            self.configure(text)
            self.run_scan(1)
            self.assertIsNone(self.called())

    def test_unparsable_reviewed_config_is_refused(self):
        self.configure("scan: [unclosed\n")
        self.run_scan(1)
        self.assertIsNone(self.called())

    def test_baseline_as_a_value_is_not_a_key(self):
        self.configure("scan:\n  disable_rules: [baseline]\n  note: 'baseline: kept locally'\n")
        self.run_scan(0)
        self.assertIn("disable_rules", self.called()["config"])

    def test_named_config_missing_at_base_is_refused(self):
        self.configure("# base\n")
        self.run_scan(1, CONFIG_PATH="ci/foxguard.yml")
        self.assertIsNone(self.called())

    def test_config_path_outside_the_repository_is_refused(self):
        self.configure("# base\n")
        for path in ("../other.yml", "/etc/foxguard.yml"):
            self.run_scan(1, CONFIG_PATH=path)
            self.assertIsNone(self.called())

    def test_external_directory_does_not_require_the_callers_pr_base(self):
        event = self.base / "event.json"
        event.write_text(json.dumps({"pull_request": {"base": {"sha": "1" * 40}}}))
        self.run_scan(0, GITHUB_EVENT_PATH=str(event))

    def test_external_scan_uses_explicit_reviewed_caller_configuration(self):
        self.configure("# reviewed\n")
        external = self.base / "external"
        external.mkdir()
        (external / "lib.py").write_text("print('ready')\n")
        self.run_scan(0, SCAN_PATH=str(external), CONFIG_PATH=".foxguard.yml")
        self.assertEqual(self.called()["config"], "# reviewed\n")


if __name__ == "__main__":
    unittest.main()
