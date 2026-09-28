#!/usr/bin/env python3
"""Every reusable workflow is exercised by a self-test leg, or says why not.

Adding a reusable workflow to this repository without either is the failure
this gate exists to stop: `csharp.yml` shipped a lint command built on a tool
delisted four framework versions earlier, `kotlin.yml` shipped Android-only
tasks as its defaults, and `cypress.yml` shipped a command that could not run
on either Yarn line -- each for its whole life, because nothing ran them and
nothing recorded that nothing ran them.

Fails when:

  * a reusable workflow is neither exercised nor listed in
    `tests/workflow-coverage.yaml`
  * a listed workflow has since gained a leg (the list would otherwise say a
    covered workflow is unverified, which is the same lie in the other
    direction)
  * an entry names a workflow that no longer exists
  * a workflow is listed twice, or a group has no reason

Usage: check_workflow_coverage.py [--root <dir>] [--quiet]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

import yaml

SUITES = ("self-test.yml", "self-test-web.yml", "self-test-compiled.yml")
CALL_RE = re.compile(r"uses: \./\.github/workflows/([a-z0-9-]+\.yml)")


def reusable_workflows(workflows_dir: pathlib.Path) -> set[str]:
    """Workflows that can be called by another workflow."""
    found = set()
    for path in sorted(workflows_dir.glob("*.yml")):
        try:
            parsed = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as exc:  # a parse error is the YAML gate's job
            print(f"[WARN] {path.name}: {exc}", file=sys.stderr)
            continue
        # `on:` parses as the boolean True in YAML 1.1, which is why this reads
        # both keys rather than the obvious one.
        triggers = parsed.get(True) or parsed.get("on") or {}
        if isinstance(triggers, dict) and "workflow_call" in triggers:
            found.add(path.name)
    return found


def exercised(workflows_dir: pathlib.Path) -> set[str]:
    """Workflows a self-test leg calls by relative path.

    Read from the parsed jobs, not by grepping the file. Grepping counted the
    example call written inside a step that drives the gate's own refusal, so
    the gate reported a workflow as covered because another step's shell script
    mentioned it.
    """
    called = set()
    for suite in SUITES:
        path = workflows_dir / suite
        if not path.is_file():
            continue
        parsed = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job in (parsed.get("jobs") or {}).values():
            if not isinstance(job, dict):
                continue
            uses = job.get("uses")
            if isinstance(uses, str):
                match = CALL_RE.fullmatch("uses: " + uses.strip())
                if match:
                    called.add(match.group(1))
    return called


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root to check")
    parser.add_argument("--quiet", action="store_true", help="only report problems")
    args = parser.parse_args()

    root = pathlib.Path(args.root)
    workflows_dir = root / ".github" / "workflows"
    coverage_path = root / "tests" / "workflow-coverage.yaml"

    if not workflows_dir.is_dir():
        print(f"[ERROR] no {workflows_dir}", file=sys.stderr)
        return 2
    if not coverage_path.is_file():
        print(f"[ERROR] no {coverage_path}", file=sys.stderr)
        return 2

    coverage = yaml.safe_load(coverage_path.read_text(encoding="utf-8")) or {}
    groups = coverage.get("groups") or {}

    listed: dict[str, str] = {}
    problems: list[str] = []
    for group_name, group in groups.items():
        reason = (group or {}).get("reason", "").strip()
        if not reason:
            problems.append(f"group `{group_name}` has no reason")
        for name in (group or {}).get("workflows") or []:
            if name in listed:
                problems.append(
                    f"{name} is listed twice: `{listed[name]}` and `{group_name}`"
                )
            listed[name] = group_name

    reusable = reusable_workflows(workflows_dir)
    covered = exercised(workflows_dir) & reusable

    for name in sorted(reusable - covered - set(listed)):
        problems.append(
            f"{name} is a reusable workflow that nothing exercises and "
            f"tests/workflow-coverage.yaml does not mention"
        )
    for name in sorted(set(listed) & covered):
        problems.append(
            f"{name} is listed as `{listed[name]}` but a self-test leg calls it; "
            f"remove it from the list"
        )
    for name in sorted(set(listed) - reusable):
        problems.append(
            f"{name} is listed but is not a reusable workflow in this repository"
        )

    if problems:
        print("[ERROR] workflow coverage:", file=sys.stderr)
        for line in problems:
            print(f"      {line}", file=sys.stderr)
        return 1

    if not args.quiet:
        counts = {g: 0 for g in groups}
        for name, group in listed.items():
            counts[group] += 1
        print(
            f"[INFO] {len(reusable)} reusable workflow(s): "
            f"{len(covered)} exercised by a self-test leg, "
            + ", ".join(f"{n} {g}" for g, n in sorted(counts.items()))
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
