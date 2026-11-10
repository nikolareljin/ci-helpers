"""The diff actions review only what a branch adds, and fail closed.

resolve_scan_base.py is run against real git repositories built here; the two
run.sh scripts are run with a stand-in scanner that records its arguments, so
no scanner is downloaded and no real-looking secret is written anywhere.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESOLVE = ROOT / "scripts/resolve_scan_base.py"
GITLEAKS_RUN = ROOT / ".github/actions/gitleaks-diff/run.sh"
FOXGUARD_RUN = ROOT / ".github/actions/foxguard-diff/run.sh"
RENAME_BASE = ROOT / ".github/actions/foxguard-diff/rename_base.py"
NEUTRAL_TREE = ROOT / ".github/actions/foxguard-diff/neutral_tree.py"
ZERO = "0" * 40


def git(root, *args, **kw):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update({"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"})
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=True, env=env, **kw).stdout.strip()


def commit(root, message, **files):
    for name, text in files.items():
        path = Path(root) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if text is None:
            git(root, "rm", "-q", "--", name)
        else:
            path.write_text(text)
            git(root, "add", "--", name)
    git(root, "commit", "-q", "--allow-empty", "-m", message)
    return git(root, "rev-parse", "HEAD")


class Fixture:
    """An upstream with `main` and a feature branch, and a clone of the branch."""

    def __init__(self, base):
        self.src = Path(base) / "src"
        self.src.mkdir()
        git(self.src, "init", "-q", "-b", "main")
        self.base = commit(self.src, "base", **{"README.md": "# fixture\n", "old.py": "x = 1\n"})
        self.main2 = commit(self.src, "main moves", **{"later.txt": "on main after the branch\n"})
        git(self.src, "checkout", "-q", "-b", "feature", self.base)
        self.feature = commit(self.src, "feature", **{"new.py": "y = 2\n"})
        git(self.src, "checkout", "-q", "main")
        self.clone = Path(base) / "clone"
        subprocess.run(["git", "clone", "-q", "--branch", "feature", str(self.src), str(self.clone)],
                       check=True, capture_output=True)


class RenameBaseTests(unittest.TestCase):
    """Only a pure rename inside scan_path, under an empty config, moves a base path."""

    BODY = "".join("line %d\n" % i for i in range(40)) + "danger()\n"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        self.base = commit(self.repo, "base", **{"old.py": self.BODY, "sub/keep.py": "x = 1\n"})
        self.config = Path(self.tmp.name) / "config.yml"
        self.config.write_text("")

    def run_it(self, scan_path="."):
        out = subprocess.run(["python3", "-I", str(RENAME_BASE), str(self.repo / scan_path), self.base,
                              self.tmp.name, "1" if self.config.read_text().strip() else "0"],
                             capture_output=True, text=True)
        self.assertEqual(out.returncode, 0)
        return out.stdout.strip()

    def made_git(self, *args):
        """git in the repository, reading the objects rename_base.py wrote."""
        env = {**os.environ, "GIT_ALTERNATE_OBJECT_DIRECTORIES": '"%s"' % os.path.join(self.tmp.name, "objects")}
        return subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, text=True,
                              check=True, env=env).stdout.strip()

    def test_paths_with_a_colon_or_a_space_work(self):
        # GIT_ALTERNATE_OBJECT_DIRECTORIES splits on ':' unless an entry is quoted.
        odd = Path(self.tmp.name) / "a:b c"
        odd.mkdir()
        self.repo.rename(odd / "repo")
        self.repo = odd / "repo"
        commit(self.repo, "rename", **{"old.py": None, "new.py": self.BODY})
        made = self.run_it()
        self.assertEqual(self.made_git("ls-tree", "--name-only", made), "new.py\nsub")

    def test_pure_rename_moves_the_base_path(self):
        commit(self.repo, "rename", **{"old.py": None, "new.py": self.BODY})
        made = self.run_it()
        self.assertNotEqual(made, self.base)
        self.assertEqual(self.made_git("ls-tree", "--name-only", made), "new.py\nsub")

    def test_edited_rename_is_a_new_file(self):
        # 40 of 41 lines kept: git calls it a rename, but the added line is new.
        commit(self.repo, "rename", **{"old.py": None, "new.py": self.BODY + "danger(2)\n"})
        self.assertEqual(self.run_it(), self.base)

    def test_rename_from_outside_scan_path_is_a_new_file(self):
        commit(self.repo, "rename", **{"old.py": None, "sub/new.py": self.BODY})
        self.assertEqual(self.run_it("sub"), self.base)

    def test_rename_under_a_config_is_a_new_file(self):
        # The config may exclude the source and not the destination.
        self.config.write_text("scan:\n  exclude_paths:\n    - old.py\n")
        commit(self.repo, "rename", **{"old.py": None, "new.py": self.BODY})
        self.assertEqual(self.run_it(), self.base)

    def test_swap_keeps_both_files_old(self):
        commit(self.repo, "swap", **{"old.py": "x = 1\n", "sub/keep.py": self.BODY})
        made = self.run_it()
        self.assertEqual(self.made_git("rev-parse", made + ":old.py"), git(self.repo, "rev-parse", "HEAD:old.py"))
        self.assertEqual(self.made_git("rev-parse", made + ":sub/keep.py"),
                         git(self.repo, "rev-parse", "HEAD:sub/keep.py"))

    def test_copy_over_an_edited_file_is_new(self):
        # old.py keeps its path with new text; its old text at a second path
        # is not a move, since the source is still there.
        commit(self.repo, "copy", **{"old.py": "x = 2\n", "copy.py": self.BODY})
        self.assertEqual(self.run_it(), self.base)

    def test_nothing_is_written_to_the_repository(self):
        commit(self.repo, "rename", **{"old.py": None, "new.py": self.BODY})
        objects = self.repo / ".git" / "objects"
        before = sorted(str(p) for p in objects.rglob("*"))
        for path in [objects, *objects.rglob("*")]:
            path.chmod(path.stat().st_mode & ~0o222)
        try:
            out = subprocess.run(["python3", "-I", str(RENAME_BASE), str(self.repo), self.base,
                                  self.tmp.name, "1" if self.config.read_text().strip() else "0"],
                             capture_output=True, text=True)
        finally:
            for path in [objects, *objects.rglob("*")]:
                path.chmod(path.stat().st_mode | 0o200)
        self.assertEqual(out.returncode, 0)
        self.assertEqual(sorted(str(p) for p in objects.rglob("*")), before)
        made = out.stdout.strip()
        self.assertEqual(self.made_git("ls-tree", "--name-only", made), "new.py\nsub")


class ResolveBaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fx = Fixture(self.tmp.name)

    def resolve(self, root=None, event=None, event_name="", base_ref=""):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "GITHUB_", "BASE_REF"))}
        env["BASE_REF"] = base_ref
        env["GITHUB_EVENT_NAME"] = event_name
        if event is not None:
            path = Path(self.tmp.name) / "event.json"
            path.write_text(json.dumps(event))
            env["GITHUB_EVENT_PATH"] = str(path)
        return subprocess.run(["python3", "-I", str(RESOLVE), str(root or self.fx.clone)],
                              capture_output=True, text=True, env=env)

    def assert_base(self, proc, sha):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, sha + "\n")

    def assert_refused(self, proc):
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertEqual(proc.stdout, "")

    def test_base_ref_commit_branch_and_origin_fallback(self):
        # A sha, a branch only the remote has (the clone fetched one branch,
        # so `main` is origin/main), and an explicit origin/ name.
        self.assert_base(self.resolve(base_ref=self.fx.base), self.fx.base)
        self.assert_base(self.resolve(base_ref="main"), self.fx.base)
        self.assert_base(self.resolve(base_ref="origin/main"), self.fx.base)
        # The merge base, not the branch tip: main moved after the branch.
        self.assertNotEqual(self.fx.main2, self.fx.base)

    def test_base_ref_that_is_not_a_commit_is_refused(self):
        for ref in ("nosuch", "--all", "main HEAD", "a" * 40, "HEAD", "origin/HEAD", "refs/remotes/origin/HEAD",
                    self.fx.base[:12], "refs/heads/main", "refs/tags/main", "@{-1}", "main@{1}"):
            with self.subTest(ref=ref):
                self.assert_refused(self.resolve(base_ref=ref))

    def test_base_ref_names_the_remote_branch_whatever_else_has_the_name(self):
        # A tag and a local branch called `main`, both at the branch tip: a
        # bare rev-parse would pick one of them; origin/main is what is read.
        git(self.fx.clone, "tag", "main", self.fx.feature)
        git(self.fx.clone, "branch", "main", self.fx.feature)
        for ref in ("main", "origin/main", "refs/remotes/origin/main"):
            with self.subTest(ref=ref):
                self.assert_base(self.resolve(base_ref=ref), self.fx.base)
        # A full sha is itself; a shorter unique prefix is not accepted.
        self.assert_base(self.resolve(base_ref=self.fx.base), self.fx.base)
        self.assert_refused(self.resolve(base_ref=self.fx.base[:20]))

    def test_pull_request_event_uses_the_base_sha(self):
        event = {"pull_request": {"base": {"sha": self.fx.base, "ref": "main"}}}
        self.assert_base(self.resolve(event=event, event_name="pull_request"), self.fx.base)

    def test_pull_request_target_is_refused(self):
        # pull_request_target checks out the base branch, not the pull
        # request: its range would scan the base's commits and pass.
        event = {"pull_request": {"base": {"sha": self.fx.base, "ref": "main"}}}
        self.assert_refused(self.resolve(event=event, event_name="pull_request_target"))

    def test_pull_request_base_missing_or_malformed_is_refused(self):
        self.assert_refused(self.resolve(event={"pull_request": {"base": {"sha": "f" * 40}}}, event_name="pull_request"))
        self.assert_refused(self.resolve(event={"pull_request": {"base": {"sha": "main"}}}, event_name="pull_request"))
        self.assert_refused(self.resolve(event={"pull_request": {}}, event_name="pull_request"))

    def test_push_event_uses_before(self):
        event = {"before": self.fx.base, "ref": "refs/heads/feature", "repository": {"default_branch": "main"}}
        self.assert_base(self.resolve(event=event, event_name="push"), self.fx.base)

    def test_push_of_a_new_branch_compares_with_the_default_branch(self):
        event = {"before": ZERO, "ref": "refs/heads/feature", "repository": {"default_branch": "main"}}
        self.assert_base(self.resolve(event=event, event_name="push"), self.fx.base)

    def test_push_of_a_new_default_branch_is_refused(self):
        # A checkout of main itself: its merge base with origin/main is HEAD.
        on_main = Path(self.tmp.name) / "on-main"
        subprocess.run(["git", "clone", "-q", "--branch", "main", str(self.fx.src), str(on_main)], check=True, capture_output=True)
        event = {"before": ZERO, "ref": "refs/heads/main", "repository": {"default_branch": "main"}}
        self.assert_refused(self.resolve(root=on_main, event=event, event_name="push"))
        # No default branch to fall back on.
        self.assert_refused(self.resolve(event={"before": ZERO, "ref": "refs/heads/x", "repository": {}}, event_name="push"))
        self.assert_refused(self.resolve(event={"before": ZERO, "ref": "refs/heads/x"}, event_name="push"))

    def test_push_before_that_is_not_an_ancestor_falls_back_to_the_default_branch(self):
        # A force push: `before` is gone, or rewritten. The branch is then
        # compared with the default branch, never with a guess at history.
        gone = {"before": "e" * 40, "ref": "refs/heads/feature", "repository": {"default_branch": "main"}}
        self.assert_base(self.resolve(event=gone, event_name="push"), self.fx.base)
        # A commit that exists but is not behind HEAD: main's own tip.
        rewritten = {"before": self.fx.main2, "ref": "refs/heads/feature", "repository": {"default_branch": "main"}}
        self.assert_base(self.resolve(event=rewritten, event_name="push"), self.fx.base)
        # A force push that rewrote only the last commit: `before` is the old
        # tip, present and not behind HEAD. Its merge base with HEAD would be
        # the commit before it, and the range would skip everything older;
        # the default branch is the base instead.
        old_tip = commit(self.fx.clone, "old tip", **{"old.py": "x = 2\n"})
        git(self.fx.clone, "reset", "-q", "--hard", self.fx.feature)
        rewritten_tip = commit(self.fx.clone, "new tip", **{"old.py": "x = 3\n"})
        self.assertNotEqual(old_tip, rewritten_tip)
        event = {"before": old_tip, "ref": "refs/heads/feature", "repository": {"default_branch": "main"}}
        self.assert_base(self.resolve(event=event, event_name="push"), self.fx.base)
        # Not a sha at all.
        self.assert_base(self.resolve(event={"before": "main", "ref": "refs/heads/feature", "repository": {"default_branch": "main"}}, event_name="push"), self.fx.base)
        # And without a default branch, nothing.
        self.assert_refused(self.resolve(event={"before": "e" * 40, "ref": "refs/heads/feature"}, event_name="push"))

    def test_push_before_that_is_an_ancestor_is_the_base(self):
        # Two pushes of the branch: the second reviews only what it added.
        second = commit(self.fx.clone, "second push", **{"more.py": "z = 3\n"})
        event = {"before": self.fx.feature, "ref": "refs/heads/feature", "repository": {"default_branch": "main"}}
        self.assert_base(self.resolve(event=event, event_name="push"), self.fx.feature)
        self.assertNotEqual(second, self.fx.feature)

    def test_other_events_and_no_event_are_refused(self):
        self.assert_refused(self.resolve())
        self.assert_refused(self.resolve(event={}, event_name="workflow_dispatch"))
        self.assert_refused(self.resolve(event={"before": self.fx.base}, event_name="schedule"))
        # A pull_request payload under another event name, or none, is not trusted.
        self.assert_refused(self.resolve(event={"pull_request": {"base": {"sha": self.fx.base}}}, event_name="push"))
        self.assert_refused(self.resolve(event={"pull_request": {"base": {"sha": self.fx.base}}}, event_name=""))

    def test_empty_range_is_refused(self):
        # HEAD is the base, or behind it: nothing to review is not a pass.
        self.assert_refused(self.resolve(base_ref="HEAD"))
        self.assert_refused(self.resolve(base_ref="feature"))
        self.assert_refused(self.resolve(root=self.fx.src, base_ref=self.fx.main2))

    def test_unrelated_history_and_no_work_tree_are_refused(self):
        other = Path(self.tmp.name) / "other"
        other.mkdir()
        git(other, "init", "-q", "-b", "main")
        lone = commit(other, "lone", **{"a.txt": "a\n"})
        git(self.fx.clone, "fetch", "-q", str(other), "main")
        self.assert_refused(self.resolve(base_ref=lone))
        plain = Path(self.tmp.name) / "plain"
        plain.mkdir()
        self.assert_refused(self.resolve(root=plain, base_ref="main"))

    def test_base_ref_wins_over_the_event(self):
        event = {"pull_request": {"base": {"sha": self.fx.main2}}}
        self.assert_base(self.resolve(event=event, event_name="pull_request", base_ref=self.fx.base), self.fx.base)


class DiffRunTests(unittest.TestCase):
    """Both run.sh scripts, with a stand-in scanner."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.fx = Fixture(base)
        self.runner = base / "runner"
        self.runner.mkdir()
        self.workspace = base / "workspace"
        self.workspace.mkdir()
        self.canary = "PRIVATE" + "-SCANNER-DIAGNOSTICS"
        self.called = base / "called"
        # Records its arguments and any config handed to it, prints a canary
        # on both streams, and behaves as the environment says.
        self.stub = base / "scanner"
        self.stub.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
record = {"args": args, "cwd": os.getcwd()}
if args and args[-1] == ".":
    # The neutral copies: path -> text, the .git directory and the config left out.
    record["tree"] = {str(p.relative_to(".")): p.read_text() for p in pathlib.Path(".").rglob("*")
                      if p.is_file() and ".git" not in p.parts and not p.name.startswith(".foxguard")}
    import subprocess
    show = lambda *a: subprocess.run(["git", *a], capture_output=True, text=True, check=True).stdout
    record["base_tree"] = {n: show("show", args[1] + ":" + n)
                           for n in show("ls-tree", "-r", "--name-only", args[1]).split()}
for flag in ("--config", "-c"):
    if flag in args:
        record["config"] = pathlib.Path(args[args.index(flag) + 1]).read_text()
if "--gitleaks-ignore-path" in args:
    record["ignore"] = pathlib.Path(args[args.index("--gitleaks-ignore-path") + 1]).read_text()
pathlib.Path(os.environ["CALLED"]).write_text(json.dumps(record))
with open(os.environ["CALLED"] + ".all", "a") as fh:
    fh.write(json.dumps(record) + "\\n")
print(os.environ["CANARY"])
print(os.environ["CANARY"], file=sys.stderr)
rc = int(os.environ.get("STUB_RC", "0"))
if "--output" in args:
    out = pathlib.Path(args[args.index("--output") + 1])
    if os.environ.get("MALFORMED"):
        out.write_text("{not json")
    else:
        total = int(os.environ.get("FINDINGS", "0"))
        if os.environ.get("FINDINGS_IN") and os.environ["FINDINGS_IN"] in args[-1]:
            total = 1
        if os.environ.get("FINDINGS_TEXT") and any(os.environ["FINDINGS_TEXT"] in t
                                                   for t in record.get("tree", {}).values()):
            total = 1
        out.write_text(json.dumps({
            "scanner": {"name": "foxguard", "version": "0.0.0"},
            "finding_counts": {"total": total},
            "findings": [{"rule_id": "stub/rule", "file": "new.py"}] * total,
            "target": {"files_scanned": int(os.environ.get("FILES", "1")),
                       "diff_base": os.environ.get("DIFF_BASE", args[1])},
        }))
        if total and rc == 0:
            rc = 1
if os.environ.get("STUB_SAY"):
    print(os.environ["STUB_SAY"])
sys.exit(rc)
""")
        self.stub.chmod(0o700)
        # security_notice vets the branch text with the credential scanner
        # before printing it; the runner has none, so one that passes stands in.
        checker = base / "metadata-checker"
        checker.write_bytes(b"#!/bin/sh\nexit 0\n")
        checker.chmod(0o700)
        self.env = {
            **{k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "GITHUB_"))},
            "CI": "true", "RUNNER_TEMP": str(self.runner), "GITHUB_WORKSPACE": str(self.workspace),
            "GITLEAKS_BIN": str(checker), "GL_BIN": str(self.stub), "FG_BIN": str(self.stub),
            "CANARY": self.canary, "CALLED": str(self.called),
            "SCAN_PATH": str(self.fx.clone), "BASE_REF": "origin/main",
            "GITHUB_HEAD_REF": "fixture-branch", "GITHUB_EVENT_PATH": "", "GITHUB_EVENT_NAME": "",
        }

    def run_script(self, script, expected, dirty=False, **changes):
        for stale in (self.called, Path(str(self.called) + ".all")):
            if stale.exists():
                stale.unlink()
        env = {**self.env, **changes}
        proc = subprocess.run(["bash", str(script)], cwd=self.workspace, env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, expected, proc.stdout + proc.stderr)
        self.assertNotIn(self.canary, proc.stdout + proc.stderr)
        self.assertEqual(proc.stdout, "")
        if expected == 0:
            self.assertEqual(proc.stderr, "")
        else:
            lines = proc.stderr.splitlines()
            self.assertEqual(len(lines), 4, proc.stderr)
            self.assertIn(lines[0], ("Gitleaks check failed.", "Foxguard check failed."))
            self.assertEqual(lines[1], "Branch: fixture-branch")
            self.assertIn("https://nikolareljin.github.io/leak-lock/", lines[2])
        # Nothing of the scan survives in RUNNER_TEMP or the work tree.
        self.assertEqual(sorted(self.runner.iterdir()), [])
        if not dirty:
            self.assertEqual(git(self.fx.clone, "status", "--porcelain"), "")
        return proc

    def record(self):
        return json.loads(self.called.read_text()) if self.called.exists() else None

    # gitleaks-diff

    def test_gitleaks_scans_the_reviewed_range_only(self):
        self.run_script(GITLEAKS_RUN, 0)
        args = self.record()["args"]
        self.assertEqual(args[0], "git")
        self.assertIn("--log-opts=%s..HEAD" % self.fx.base, args)
        self.assertEqual(args[-2:], ["--", str(self.fx.clone)])
        for flag in ("--redact", "--no-banner", "--no-color", "--ignore-gitleaks-allow", "--exit-code", "3"):
            self.assertIn(flag, args)
        self.assertNotIn("detect", args)
        self.assertNotIn("--no-git", args)

    def test_gitleaks_findings_and_errors_fail_without_diagnostics(self):
        self.run_script(GITLEAKS_RUN, 1, STUB_RC="3")
        self.run_script(GITLEAKS_RUN, 1, STUB_RC="2")
        self.run_script(GITLEAKS_RUN, 1, STUB_SAY="ERR git error encountered")

    def test_gitleaks_config_comes_from_the_base_not_the_branch(self):
        # The branch adds an allow-everything config; the scan must not read
        # it. (An ignore list the branch adds is refused outright: see the
        # next test.)
        commit(self.fx.clone, "silence", **{".gitleaks.toml": '[allowlist]\npaths = [".*"]\n'})
        self.run_script(GITLEAKS_RUN, 0)
        rec = self.record()
        self.assertEqual(rec["config"], "[extend]\nuseDefault = true\n")
        self.assertEqual(rec["ignore"], "")
        # Named explicitly, a config the base does not hold is refused.
        self.run_script(GITLEAKS_RUN, 1, CONFIG_PATH=".gitleaks.toml")
        self.assertIsNone(self.record())

    def test_gitleaks_ignore_file_in_the_tree_must_match_the_base(self):
        # gitleaks reads <source>/.gitleaksignore on its own, so the one the
        # branch adds is not just left unread: the scan is refused.
        commit(self.fx.clone, "ignore list", **{".gitleaksignore": "fingerprint-of-the-new-secret\n"})
        self.run_script(GITLEAKS_RUN, 1)
        self.assertIsNone(self.record())
        # A file identical to the base's is what the base approved.
        git(self.fx.src, "checkout", "-q", "main")
        commit(self.fx.src, "approved ignore list", **{".gitleaksignore": "fingerprint-of-an-old-finding\n"})
        git(self.fx.clone, "reset", "-q", "--hard", self.fx.feature)
        git(self.fx.clone, "fetch", "-q", "origin")
        git(self.fx.clone, "rebase", "-q", "origin/main")
        self.run_script(GITLEAKS_RUN, 0)
        self.assertEqual(self.record()["ignore"], "fingerprint-of-an-old-finding\n")
        # One more line than the base has, and a link in place of the file.
        commit(self.fx.clone, "one more", **{".gitleaksignore": "fingerprint-of-an-old-finding\nfingerprint-of-the-new-secret\n"})
        self.run_script(GITLEAKS_RUN, 1)
        self.assertIsNone(self.record())
        git(self.fx.clone, "reset", "-q", "--hard", "HEAD~1")
        (self.fx.clone / ".gitleaksignore").unlink()
        (self.fx.clone / ".gitleaksignore").symlink_to("README.md")
        self.run_script(GITLEAKS_RUN, 1, dirty=True)
        self.assertIsNone(self.record())
        (self.fx.clone / ".gitleaksignore").unlink()
        git(self.fx.clone, "checkout", "-q", "--", ".gitleaksignore")

    def test_gitleaks_config_on_the_base_is_used(self):
        git(self.fx.src, "checkout", "-q", "main")
        commit(self.fx.src, "reviewed config", **{".gitleaks.toml": '[extend]\nuseDefault = true\n[allowlist]\npaths = ["docs/.*"]\n'})
        reviewed = git(self.fx.src, "rev-parse", "HEAD")
        git(self.fx.clone, "fetch", "-q", "origin")
        # The branch is rebased on the new base so the merge base carries it.
        git(self.fx.clone, "rebase", "-q", "origin/main")
        self.run_script(GITLEAKS_RUN, 0)
        rec = self.record()
        self.assertIn('paths = ["docs/.*"]', rec["config"])
        self.assertIn("--log-opts=%s..HEAD" % reviewed, rec["args"])

    def test_gitleaks_refuses_a_scan_path_that_reads_as_an_option(self):
        commit(self.fx.clone, "dash", **{"-s/x.txt": "z\n"})
        proc = subprocess.run(["bash", str(GITLEAKS_RUN)], cwd=self.fx.clone,
                              env={**self.env, "SCAN_PATH": "-s"}, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 1)
        self.assertIsNone(self.record())

    def test_gitleaks_refuses_without_a_base(self):
        self.run_script(GITLEAKS_RUN, 1, BASE_REF="nosuch")
        self.assertIsNone(self.record())
        self.run_script(GITLEAKS_RUN, 1, BASE_REF="")
        self.assertIsNone(self.record())
        self.run_script(GITLEAKS_RUN, 1, BASE_REF="feature")
        self.assertIsNone(self.record())

    def test_gitleaks_refuses_a_disabled_or_missing_scanner(self):
        self.run_script(GITLEAKS_RUN, 1, FAIL_ON_FINDINGS="false")
        self.assertIsNone(self.record())
        self.run_script(GITLEAKS_RUN, 1, GL_BIN=str(self.workspace / "absent"))
        self.run_script(GITLEAKS_RUN, 1, SCAN_PATH=str(self.workspace / "absent"))
        plain = Path(self.tmp.name) / "plain"
        plain.mkdir()
        self.run_script(GITLEAKS_RUN, 1, SCAN_PATH=str(plain))
        self.assertIsNone(self.record())

    # foxguard-diff

    def test_foxguard_diffs_against_the_merge_base(self):
        self.run_script(FOXGUARD_RUN, 0)
        calls = [json.loads(line) for line in Path(str(self.called) + ".all").read_text().splitlines()]
        self.assertEqual([c["args"][-1] for c in calls], [str(self.fx.clone), "."])
        args = calls[0]["args"]
        self.assertEqual(args[:2], ["diff", self.fx.base])
        self.assertEqual(args[-2:], ["--", str(self.fx.clone)])
        self.assertIn("--config", args)
        self.assertIn("json", args)
        self.assertEqual(args[args.index("-s") + 1], "medium")
        self.assertEqual(self.record()["config"], "")

    def test_foxguard_severity_is_passed_and_validated(self):
        self.run_script(FOXGUARD_RUN, 0, SEVERITY="HIGH")
        self.assertEqual(self.record()["args"][self.record()["args"].index("-s") + 1], "high")
        self.run_script(FOXGUARD_RUN, 1, SEVERITY="loud")
        self.assertIsNone(self.record())

    def test_foxguard_new_findings_and_errors_fail_without_diagnostics(self):
        self.run_script(FOXGUARD_RUN, 1, FINDINGS="1")
        self.run_script(FOXGUARD_RUN, 1, STUB_RC="2")
        self.run_script(FOXGUARD_RUN, 1, MALFORMED="1")
        # A report of nothing read, or of another base than the one asked for.
        self.run_script(FOXGUARD_RUN, 1, FILES="0")
        self.run_script(FOXGUARD_RUN, 1, DIFF_BASE="main")

    def test_foxguard_config_comes_from_the_base_not_the_branch(self):
        commit(self.fx.clone, "silence", **{".foxguard.yml": "scan:\n  ignore_rules:\n    - id: py/no-command-injection\n"})
        self.run_script(FOXGUARD_RUN, 0)
        self.assertEqual(self.record()["config"], "")
        self.run_script(FOXGUARD_RUN, 1, CONFIG_PATH=".foxguard.yml")
        self.assertIsNone(self.record())

    def test_foxguard_config_on_the_base_is_used_and_removed_after(self):
        git(self.fx.src, "checkout", "-q", "main")
        commit(self.fx.src, "reviewed config", **{".foxguard.yml": "scan:\n  exclude_paths:\n    - docs\n"})
        git(self.fx.clone, "fetch", "-q", "origin")
        git(self.fx.clone, "rebase", "-q", "origin/main")
        self.run_script(FOXGUARD_RUN, 0)
        rec = json.loads(Path(str(self.called) + ".all").read_text().splitlines()[0])
        self.assertIn("exclude_paths", rec["config"])
        # Placed beside the caller's config, under a temporary name, and gone.
        config_arg = rec["args"][rec["args"].index("--config") + 1]
        self.assertEqual(str(Path(config_arg).parent), str(self.fx.clone))
        self.assertFalse(Path(config_arg).exists())
        # A baseline entry at the base would let old findings hide new ones.
        commit(self.fx.src, "baseline", **{".foxguard.yml": "scan:\n  baseline: findings.json\n"})
        git(self.fx.clone, "fetch", "-q", "origin")
        git(self.fx.clone, "rebase", "-q", "origin/main")
        self.run_script(FOXGUARD_RUN, 1)
        self.assertIsNone(self.record())

    def test_foxguard_refuses_a_changed_file_the_tree_ignores(self):
        # foxguard skips what .gitignore or .ignore names, and both come from
        # the tree under review.
        for name in (".gitignore", ".ignore"):
            with self.subTest(name=name):
                (self.fx.clone / name).write_text("evil.py\n")
                (self.fx.clone / "evil.py").write_text("z = 3\n")
                git(self.fx.clone, "add", "-f", name, "evil.py")
                git(self.fx.clone, "commit", "-q", "-m", "hide")
                self.run_script(FOXGUARD_RUN, 1)
                self.assertIsNone(self.record())
                git(self.fx.clone, "reset", "-q", "--hard", "HEAD~1")
        # git reads no .gitignore that is a link; foxguard follows it.
        for name in (".gitignore", ".ignore"):
            with self.subTest(link=name):
                (self.fx.clone / "list").write_text("evil.py\n")
                (self.fx.clone / name).symlink_to("list")
                (self.fx.clone / "evil.py").write_text("z = 3\n")
                git(self.fx.clone, "add", "-f", "list", name, "evil.py")
                git(self.fx.clone, "commit", "-q", "-m", "hide")
                self.run_script(FOXGUARD_RUN, 1)
                self.assertIsNone(self.record())
                git(self.fx.clone, "reset", "-q", "--hard", "HEAD~1")
        # An ignore file the review adds or edits that hides no changed file
        # passes, above scan_path too; one that hides a changed file fails.
        sub = self.fx.clone / "sub"
        commit(self.fx.clone, "ignore build output", **{".gitignore": "out/\n", "sub/x.py": "x = 1\n"})
        self.run_script(FOXGUARD_RUN, 0, SCAN_PATH=str(sub))
        self.run_script(FOXGUARD_RUN, 0)
        commit(self.fx.clone, "hide it", **{"sub/.ignore": "y.py\n"})
        (sub / "y.py").write_text("z = 3\n")
        git(self.fx.clone, "add", "-f", "sub/y.py")
        git(self.fx.clone, "commit", "-q", "-m", "hidden file")
        self.run_script(FOXGUARD_RUN, 1, SCAN_PATH=str(sub))
        self.assertIsNone(self.record())

    def neutral_call(self):
        calls = [json.loads(line) for line in Path(str(self.called) + ".all").read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1]["args"][-2:], ["--", "."])
        self.assertEqual(Path(calls[1]["cwd"]).name, "neutral")
        return calls[1]

    def test_foxguard_scans_every_changed_file_at_a_neutral_path(self):
        # foxguard skips hidden entries, vendor/ and build/, names such as
        # a.min.js, and what the ignore files name, some even when named; the
        # neutral copy at f<i>/file.<ext> or f<i>/<name> is read whatever the
        # review calls the file.
        cases = {".h/x.py": ["x.py", "file.py"], "a/.b/c/x.py": ["x.py", "file.py"],
                 ".x.py": ["x.py", "file.py"], "-s/x.py": ["x.py", "file.py"],
                 "vendor/x.py": ["x.py", "file.py"], "a/build/y.py": ["y.py", "file.py"],
                 "node_modules/z.js": ["z.js", "file.js"], "a.min.js": ["a.min.js", "file.js"],
                 "sub/Dockerfile": ["Dockerfile"], "vendor/Dockerfile.dev": ["Dockerfile.dev", "file.dev"],
                 "conf/nginx.conf": ["nginx.conf", "file.conf"], ".bashrc": ["bashrc"],
                 ":(glob)*.py": [":(glob)*.py", "file.py"], ":(exclude)a.py": [":(exclude)a.py", "file.py"],
                 ":!b.py": [":!b.py", "file.py"], "*.py": ["*.py", "file.py"], "[x].py": ["[x].py", "file.py"]}
        for path, neutral in cases.items():
            with self.subTest(path=path):
                commit(self.fx.clone, "changed", **{path: "marker = 3\n"})
                self.addCleanup(git, self.fx.clone, "reset", "-q", "--hard", self.fx.feature)
                self.run_script(FOXGUARD_RUN, 1, FINDINGS_TEXT="marker")
                self.run_script(FOXGUARD_RUN, 0)
                # The branch's own new.py is there too.
                tree = self.neutral_call()["tree"]
                self.assertEqual(sorted(p.split("/", 1)[1] for p, t in tree.items() if t.startswith("marker")),
                                 sorted(neutral))
                self.assertEqual(sorted(p.split("/", 1)[1] for p, t in tree.items() if t == "y = 2\n"),
                                 ["file.py", "new.py"])
                git(self.fx.clone, "reset", "-q", "--hard", self.fx.feature)

    def test_foxguard_neutral_base_holds_the_old_copies(self):
        # The base commit of the neutral repository holds each changed file as
        # the merge base had it, at the renamed path for an identical move.
        commit(self.fx.clone, "move and edit", **{"old.py": None, "vendor/old.py": "x = 1\n",
                                                  "README.md": "# fixture\nmore\n"})
        self.run_script(FOXGUARD_RUN, 0)
        call = self.neutral_call()
        neutral = Path(call["cwd"])
        # new.py (f1) and the changed README (f0) and the moved old.py (f2).
        self.assertEqual(call["tree"], {"f0/README.md": "# fixture\nmore\n", "g0/file.md": "# fixture\nmore\n",
                                        "f1/new.py": "y = 2\n", "g1/file.py": "y = 2\n",
                                        "f2/old.py": "x = 1\n", "g2/file.py": "x = 1\n"})
        self.assertEqual(call["base_tree"], {"f0/README.md": "# fixture\n", "g0/file.md": "# fixture\n",
                                             "f2/old.py": "x = 1\n", "g2/file.py": "x = 1\n"})
        # The neutral repository is gone with the rest of the scan.
        self.assertFalse(neutral.exists())

    def test_foxguard_neutral_config_moves_ignore_paths_to_the_copies(self):
        # foxguard matches an ignore path exactly; one naming a changed file is
        # rewritten to its copy, the others are dropped.
        git(self.fx.src, "checkout", "-q", "main")
        commit(self.fx.src, "reviewed config", **{"cfg/.foxguard.yml": (
            "scan:\n  ignore_rules:\n    - path: ../new.py\n      rules: [py/no-command-injection]\n"
            "    - path: ../old.py\n      rules: [py/no-command-injection]\n")})
        git(self.fx.clone, "fetch", "-q", "origin")
        git(self.fx.clone, "rebase", "-q", "origin/main")
        self.run_script(FOXGUARD_RUN, 0, CONFIG_PATH="cfg/.foxguard.yml")
        config = self.neutral_call()["config"]
        self.assertIn("path: f0/new.py", config)
        self.assertIn("path: g0/file.py", config)
        self.assertNotIn("old.py", config)
        self.assertIn("py/no-command-injection", config)

    def test_foxguard_neutral_config_drops_secret_exclusions(self):
        # secrets.exclude_paths and exclude_path_files would silence the copies
        # by path or glob: dropped. foxguard 0.14.1 reads secrets.ignore_rules
        # as strings only and diff runs no secret rules: dropped too.
        git(self.fx.src, "checkout", "-q", "main")
        commit(self.fx.src, "reviewed config", **{"cfg/.foxguard.yml": (
            "secrets:\n  exclude_paths: ['../new.py', '**/*.py', 'f0']\n"
            "  exclude_path_files: [../paths.txt]\n"
            "  ignore_rules:\n    - path: ../new.py\n      rules: [s/x]\n"
            "    - path: ../old.py\n      rules: [s/x]\n")})
        git(self.fx.clone, "fetch", "-q", "origin")
        git(self.fx.clone, "rebase", "-q", "origin/main")
        self.run_script(FOXGUARD_RUN, 0, CONFIG_PATH="cfg/.foxguard.yml")
        config = self.neutral_call()["config"]
        self.assertNotIn("exclude_path", config)
        self.assertNotIn("*.py", config)
        self.assertNotIn("ignore_rules", config)
        self.assertNotIn("path:", config)

    def test_foxguard_refuses_a_changed_file_over_the_size_limit_before_the_scan(self):
        # Refused whatever foxguard logs; a binary type no rule reads passes.
        big = "#" * 1048576 + "\n"
        commit(self.fx.clone, "big", **{"vendor/big.py": big})
        self.run_script(FOXGUARD_RUN, 1)
        self.assertEqual(len(Path(str(self.called) + ".all").read_text().splitlines()), 1)
        git(self.fx.clone, "reset", "-q", "--hard", self.fx.feature)
        commit(self.fx.clone, "limit", **{"edge.py": big[:-2] + "\n"})
        self.run_script(FOXGUARD_RUN, 0)
        commit(self.fx.clone, "image", **{"logo.PNG": big})
        self.run_script(FOXGUARD_RUN, 0)

    def test_foxguard_refuses_a_changed_file_it_skips_for_size(self):
        self.run_script(FOXGUARD_RUN, 1, STUB_SAY="warning: skipping ./f0/file.py (1048577 bytes exceeds --max-file-size)")
        self.run_script(FOXGUARD_RUN, 1, STUB_SAY="Skipped 1 file: 1 too large.")
        # One line over about 2000 characters makes foxguard skip a file as
        # minified, whatever its size or name.
        self.run_script(FOXGUARD_RUN, 1, STUB_SAY="Skipped 2 files: 1 unsupported extension, 1 minified.")
        self.run_script(FOXGUARD_RUN, 0, STUB_SAY="Skipped 2 files: 2 unsupported extensions.")

    def test_foxguard_refuses_a_scan_path_that_reads_as_an_option(self):
        dash = self.fx.clone / "-s"
        commit(self.fx.clone, "dash", **{"-s/x.py": "z = 3\n"})
        proc = subprocess.run(["bash", str(FOXGUARD_RUN)], cwd=self.fx.clone,
                              env={**self.env, "SCAN_PATH": "-s"}, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 1)
        self.assertIsNone(self.record())
        self.assertTrue(dash.is_dir())

    def test_foxguard_refuses_without_a_base(self):
        self.run_script(FOXGUARD_RUN, 1, BASE_REF="nosuch")
        self.assertIsNone(self.record())
        self.run_script(FOXGUARD_RUN, 1, BASE_REF="")
        self.assertIsNone(self.record())

    def test_foxguard_refuses_a_disabled_or_missing_scanner(self):
        self.run_script(FOXGUARD_RUN, 1, FAIL_ON_FINDINGS="false")
        self.assertIsNone(self.record())
        self.run_script(FOXGUARD_RUN, 1, FG_BIN=str(self.workspace / "absent"))
        self.run_script(FOXGUARD_RUN, 1, SCAN_PATH=str(self.workspace / "absent"))


class NeutralTreeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fx = Fixture(self.tmp.name)
        self.out = Path(self.tmp.name) / "out"
        self.out.mkdir()

    def run_main(self, patch_head):
        import importlib.util
        import io
        import sys
        from unittest import mock
        spec = importlib.util.spec_from_file_location("neutral_tree", NEUTRAL_TREE)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        real = mod.tree
        if patch_head:
            # A changed path that the head listing lacks, which a diff from the
            # same repository cannot produce: the guard must still fail.
            mod.tree = lambda root, commit, env: (
                {k: v for k, v in real(root, commit, env).items() if k != b"new.py"}
                if commit == "HEAD" else real(root, commit, env))
        argv = ["neutral_tree.py", str(self.fx.clone), self.fx.base, self.fx.base, str(self.out), ""]
        with mock.patch.object(sys, "argv", argv), mock.patch.object(sys, "stdout", io.StringIO()):
            return mod.main()

    def test_changed_path_missing_from_the_head_tree_fails(self):
        with self.assertRaises(ValueError):
            self.run_main(True)

    def test_changed_path_in_the_head_tree_passes(self):
        self.assertEqual(self.run_main(False), 0)


if __name__ == "__main__":
    unittest.main()
