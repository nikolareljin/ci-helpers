"""Drive release-tag-gate's decision step against a table of branch names.

Three of that step's four paths *skip* the tag check, and nothing tested which
one a given branch takes -- a gate that skips is not a gate that passes
(ADR-0034). This reads the step out of the workflow and runs it, so the table
cannot drift from the shipped logic the way a re-implementation would.

The last case is the one the step's own comment is about: a ref a fork author
controls reaches the script through the environment, never spliced into it. If
that ever changes, `release/$(touch /tmp/pwned)` writes the file and this
fails.
"""
import os, subprocess, sys, tempfile, yaml

WORKFLOW = ".github/workflows/release-tag-gate.yml"
STEP = "Decide whether to check release tag"

CASES = [
    # release_branch, base_branch, default_branch, expected run_check, why
    ("release/1.2.3", "main", "main", "true", "a release branch onto the default branch"),
    ("release/v1.2.3", "main", "main", "true", "the v prefix is accepted"),
    ("release/1.2.3-rc1", "main", "main", "true", "an rc without a dot"),
    ("release/1.2.3-rc.1", "main", "main", "true", "an rc with a dot"),
    ("release/1.2.3", "develop", "main", "false", "not onto the default branch"),
    ("release/1.2.3", "", "main", "false", "no base branch at all"),
    ("feature/whatever", "main", "main", "false", "not a release branch"),
    ("release/1.2.3.4", "main", "main", "false", "four components is not semver"),
    ("release/1.2", "main", "main", "false", "two components is not semver"),
    ("release/$(touch /tmp/pwned)", "main", "main", "false", "a ref that is also a shell command"),
]

def step_script():
    doc = yaml.safe_load(open(WORKFLOW))
    for job in doc["jobs"].values():
        for step in job.get("steps", []):
            if step.get("name") == STEP:
                return step["run"]
    raise SystemExit(f"step {STEP!r} not found in {WORKFLOW}")

def main():
    script = step_script()
    failures = 0
    for release, base, default, expected, why in CASES:
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "output")
            open(out, "w").close()
            path = os.path.join(tmp, "step.sh")
            open(path, "w").write(script)
            env = {
                **os.environ,
                "RELEASE_BRANCH": release,
                "BASE_BRANCH": base,
                "DEFAULT_BRANCH": default,
                "GITHUB_OUTPUT": out,
            }
            proc = subprocess.run(
                ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", path],
                capture_output=True, text=True, env=env,
            )
            written = open(out).read()
            got = "true" if "run_check=true" in written else "false" if "run_check=false" in written else "?"
            ok = proc.returncode == 0 and got == expected
            if not ok:
                failures += 1
                print(f"::error::{why}: {release!r} -> run_check={got} (expected {expected}), exit {proc.returncode}")
                print(proc.stdout + proc.stderr)
            else:
                print(f"  ok  {why}: {release!r} -> {got}")

    if os.path.exists("/tmp/pwned"):
        failures += 1
        print("::error::a branch name was executed as a shell command; it must reach the script through the environment only")

    print(f"{len(CASES)} case(s), {failures} failure(s)")
    return 1 if failures else 0

if __name__ == "__main__":
    sys.exit(main())
