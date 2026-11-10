#!/usr/bin/env python3
"""Refuse a PHP job that defaults to ubuntu-latest.

scripts/setup_php.sh installs PHP from apt, and the ondrej/php PPA has no
suite for ubuntu-latest (26.04) yet. Every job that runs setup_php.sh, and
every job that hands php_version and its runner to a reusable workflow,
must default to ubuntu-24.04 when php_version is set. A caller can still
pass another runner. Switch back when the PPA ships a resolute suite.

Usage: check_php_runner.py [workflow_dir]   (default .github/workflows)
Exit 0 when every PHP job defaults to ubuntu-24.04, 1 otherwise.
"""
import sys
from pathlib import Path

import yaml

PHP_RUNNER = "ubuntu-24.04"
# The shared workflows resolve the runner from php_version.
SHARED_EXPR = "inputs.php_version != '' && inputs.runner == 'ubuntu-latest' && 'ubuntu-24.04' || inputs.runner"
# Workflows whose job maps ubuntu-latest to ubuntu-24.04 itself; a wrapper may
# pass them its ubuntu-latest default (the engine-inputs gate wants it equal).
MAPPING = ("ci.yml", "pr-gate.yml", "release-build.yml", "deploy.yml")


def inputs_of(doc):
    on = doc.get("on", doc.get(True)) or {}
    if not isinstance(on, dict):
        return {}
    call = on.get("workflow_call") or {}
    return (call.get("inputs") or {}) if isinstance(call, dict) else {}


def runs_setup_php(job):
    for step in job.get("steps") or []:
        if isinstance(step, dict) and "setup_php.sh" in str(step.get("run", "")):
            return True
    return False


def passes_php(job):
    w = job.get("with") or {}
    return "uses" in job and any(k in w for k in ("php_version", "php_versions"))


def check(path):
    errors = []
    doc = yaml.safe_load(path.read_text())
    if not isinstance(doc, dict):
        return errors
    runner_default = (inputs_of(doc).get("runner") or {}).get("default")
    for name, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        where = f"{path}: job {name}"
        if runs_setup_php(job):
            ro = str(job.get("runs-on", ""))
            compact = " ".join(ro.replace("${{", "").replace("}}", "").split())
            if ro.strip() == "${{ inputs.runner }}":
                if runner_default != PHP_RUNNER:
                    errors.append(f"{where} runs setup_php.sh on inputs.runner, whose default is {runner_default!r}, not {PHP_RUNNER}")
            elif "inputs." in ro:
                if compact != SHARED_EXPR:
                    errors.append(f"{where} runs setup_php.sh on '{ro}'; with php_version set it must default to {PHP_RUNNER}: ${{{{ {SHARED_EXPR} }}}}")
            elif ro != PHP_RUNNER:
                errors.append(f"{where} runs setup_php.sh on {ro!r}, not {PHP_RUNNER}")
        elif passes_php(job):
            w = job.get("with") or {}
            r = str(w.get("runner", ""))
            if str(job.get("uses", "")).rsplit("/", 1)[-1] in MAPPING:
                continue
            if r.strip() == "${{ inputs.runner }}":
                if runner_default not in (PHP_RUNNER, ""):
                    errors.append(f"{where} passes php_version with inputs.runner, whose default is {runner_default!r}, not {PHP_RUNNER}")
            elif r == "ubuntu-latest":
                errors.append(f"{where} passes php_version with runner ubuntu-latest")
    return errors


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".github/workflows")
    errors = []
    for p in sorted(list(root.glob("*.yml")) + list(root.glob("*.yaml"))):
        errors += check(p)
    for e in errors:
        print(f"::error::{e}")
    if errors:
        print("A PHP job must default to ubuntu-24.04 until the ondrej/php PPA ships a suite for ubuntu-latest (26.04).")
        return 1
    print("ok: every PHP job defaults to ubuntu-24.04")
    return 0


if __name__ == "__main__":
    sys.exit(main())
