"""scripts/junit_summary.py: counts, failures, nested suites, no files, a
DOCTYPE refused, output appended to GITHUB_STEP_SUMMARY, never a non-zero exit.
Then the pnpm workflows: no dorny/test-reporter step, no `checks: write`, and
the report job runs this script from a checkout at job.workflow_sha."""

import contextlib
import glob
import importlib.util
import io
import os
import pathlib
import sys
import tempfile
import types
import unittest
from unittest import mock

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/junit_summary.py"
spec = importlib.util.spec_from_file_location("junit_summary", SCRIPT)
junit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(junit)

PASS_FAIL = """<?xml version="1.0"?>
<testsuites>
  <testsuite name="a" tests="4" failures="1" errors="1" skipped="1" time="1.5">
    <testcase classname="pkg.A" name="passes" time="0.5"/>
    <testcase classname="pkg.A" name="fails" time="0.5">
      <failure message="expected 1 | got 2">stack</failure>
    </testcase>
    <testcase classname="pkg.A" name="errors" time="0.25">
      <error>Boom &lt;b&gt;
second line</error>
    </testcase>
    <testcase classname="pkg.A" name="skipped" time="0.25"><skipped/></testcase>
  </testsuite>
</testsuites>
"""
NESTED = """<testsuites><testsuite name="outer"><testsuite name="inner">
<testcase name="deep"/></testsuite></testsuite></testsuites>"""
DOCTYPE = """<?xml version="1.0"?>
<!DOCTYPE x [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]>
<testsuite><testcase name="&b;"/></testsuite>"""


class JunitSummaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def write(self, rel, text):
        path = self.dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def run_script(self, *args, env=None):
        """main() in-process with the given argv and environment; returns an
        object with returncode, stdout and stderr like subprocess would."""
        argv = ["junit_summary.py", "--glob", str(self.dir / "**/*.xml"), *args]
        full_env = {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}
        full_env.update(env or {})
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", argv), mock.patch.dict(os.environ, full_env, clear=True), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                rc = junit.main()
            except SystemExit as exc:  # argparse
                rc = exc.code
        return types.SimpleNamespace(returncode=rc, stdout=out.getvalue(), stderr=err.getvalue())

    def test_counts_and_failures(self):
        self.write("results/a.xml", PASS_FAIL)
        res = self.run_script("--title", "Tests-web")
        self.assertEqual(res.returncode, 0, res.stderr)
        out = res.stdout
        self.assertIn("## Tests-web", out)
        self.assertIn("| 4 | 1 | 1 | 1 | 1 | 1.5s |", out)
        self.assertIn("| failure | pkg.A / fails | expected 1 \\| got 2 | a.xml |", out)
        self.assertIn("| error | pkg.A / errors | Boom &lt;b&gt; | a.xml |", out, "first line of the body, escaped")
        self.assertNotIn("passes |", out, "passing tests are counted, not listed")
        self.assertIn("1 file(s) read.", out)

    def test_nested_suites_and_several_files(self):
        self.write("x/a.xml", PASS_FAIL)
        self.write("y/z/b.xml", NESTED)
        res = self.run_script()
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("| 5 | 2 | 1 | 1 | 1 |", res.stdout)
        self.assertIn("2 file(s) read.", res.stdout)

    def test_no_files(self):
        res = self.run_script()
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("No JUnit XML found.", res.stdout)

    def test_doctype_refused_and_malformed_reported(self):
        self.write("a.xml", DOCTYPE)
        self.write("b.xml", "<testsuite><testcase name='ok'/>")
        self.write("c.xml", NESTED)
        res = self.run_script()
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertNotIn("aaaa", res.stdout)
        self.assertIn("a.xml: DOCTYPE refused", res.stdout)
        self.assertIn("b.xml:", res.stdout)
        self.assertIn("| 1 | 1 | 0 | 0 | 0 |", res.stdout, "the readable file is still counted")

    def test_appends_to_step_summary(self):
        self.write("a.xml", NESTED)
        target = self.dir / "summary.md"
        target.write_text("before\n")
        res = self.run_script("--title", "T", env={"GITHUB_STEP_SUMMARY": str(target)})
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(res.stdout, "")
        text = target.read_text()
        self.assertTrue(text.startswith("before\n## T\n"), text)

    def test_oversized_file_skipped(self):
        self.write("a.xml", NESTED)
        res = self.run_script("--max-bytes", "10")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("a.xml: over 10 bytes", res.stdout)


class ReportJobTests(unittest.TestCase):
    """The three pnpm workflows publish their summary from this script."""

    WORKFLOWS = ("pnpm.yml", "pnpm-cypress.yml", "pnpm-playwright.yml")

    def test_no_test_reporter_anywhere(self):
        for path in glob.glob(str(ROOT / ".github/**/*.yml"), recursive=True):
            self.assertNotIn("dorny/test-reporter", pathlib.Path(path).read_text(), path)

    def test_report_job_shape(self):
        for name in self.WORKFLOWS:
            doc = yaml.safe_load((ROOT / ".github/workflows" / name).read_text())
            job = doc["jobs"]["report"]
            self.assertEqual(job.get("permissions"), {"contents": "read"}, f"{name}: report job permissions")
            steps = job["steps"]
            runs = [s for s in steps if "scripts/junit_summary.py" in str(s.get("run", ""))]
            self.assertEqual(len(runs), 1, f"{name}: one summary step")
            step = runs[0]
            self.assertNotIn("${{", str(step["run"]), f"{name}: inputs go through env")
            env = step.get("env") or {}
            self.assertIn("TITLE", env, name)
            self.assertIn("RESULTS_GLOB", env, name)
            checkout_dir = str(step["run"]).split("scripts/junit_summary.py")[0].split()[-1].rstrip("/")
            co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")
                  and (s.get("with") or {}).get("path") == checkout_dir]
            self.assertEqual(len(co), 1, f"{name}: one checkout at {checkout_dir}")
            with_ = co[0]["with"]
            self.assertEqual(with_.get("ref"), "${{ job.workflow_sha }}", name)
            self.assertEqual(with_.get("repository"), "${{ job.workflow_repository }}", name)
            self.assertEqual(str(with_.get("persist-credentials")).lower(), "false", name)
            self.assertIn("scripts", str(with_.get("sparse-checkout", "")).split(), name)
            verify = [s for s in steps if "rev-parse HEAD" in str(s.get("run", ""))]
            self.assertEqual(len(verify), 1, f"{name}: the checkout's commit is verified")
            inputs = (doc.get(True) or doc.get("on"))["workflow_call"]["inputs"]
            self.assertIn("upload_test_results", inputs, name)
            self.assertIn("artifact_suffix", inputs, name)


if __name__ == "__main__":
    unittest.main()
