#!/usr/bin/env python3
"""Reject workflow settings that publish scanner diagnostics."""

from pathlib import Path
import re
import subprocess
import sys

import yaml


def violations(doc):
    problems = []
    trigger = doc.get("on", doc.get(True, {}))
    declared = trigger.get("workflow_call", {}).get("inputs", {}) if isinstance(trigger, dict) else {}
    for job in (doc.get("jobs") or {}).values():
        if not isinstance(job, dict):
            continue
        steps = job.get("steps", [])
        scanner_job = bool(re.search(r"gitleaks|foxguard", str(job.get("uses", "")), re.I))
        for step in steps + [job]:
            uses = str(step.get("uses", ""))
            options = step.get("with") or {}
            if re.search(r"gitleaks|foxguard", uses, re.I):
                scanner_job = True
                for key in ("upload_artifact", "upload_sarif", "upload-sarif"):
                    value = options.get(key, False)
                    forwarded = (
                        key == "upload_artifact"
                        and value == "${{ inputs.upload_artifact }}"
                        and uses == "./.ci-helpers-actions/.github/actions/gitleaks-scan"
                        and declared.get(key, {}).get("default") is False
                    )
                    if str(value).lower() not in ("false", "") and not forwarded:
                        problems.append("scanner upload enabled")
                if "gitleaks" in uses.lower() and str(options.get("fail_on_findings", True)).lower() == "false":
                    problems.append("credential enforcement disabled")
        if scanner_job:
            for step in steps:
                if re.search(r"upload-artifact|upload-sarif", str(step.get("uses", ""))):
                    problems.append("scanner job publishes diagnostics")
        permissions = job.get("permissions", doc.get("permissions", {}))
        writer = permissions == "write-all" or isinstance(permissions, dict) and permissions.get("contents") == "write"
        writer = writer or bool(re.search(r"git (?:[^\n]* )?push|create_production\.sh|publish_homebrew\.sh", yaml.safe_dump(job)))
        if writer and steps and not any("publication-guard" in str(s.get("uses", "")) for s in steps):
            problems.append("outbound writer lacks guard")
        if writer and steps:
            for step in steps:
                if "publication-guard" in str(step.get("uses", "")):
                    break
                if re.search(r"git (?:[^\n]* )?push|gh (?:pr|issue|release|gist) (?:create|edit|comment|upload)|action-gh-release|upload-release-asset", yaml.safe_dump(step)):
                    problems.append("writer publishes before its guard")
    return problems


def main():
    root = Path(__file__).resolve().parents[1]
    try:
        for path in (root / ".github/workflows").glob("*.yml"):
            if violations(yaml.safe_load(path.read_text())):
                subprocess.run(["bash", str(root / "vendor/script-helpers/scripts/security_notice.sh"), "Security"], check=False)
                return 1
    except (OSError, ValueError, yaml.YAMLError):
        subprocess.run(["bash", str(root / "vendor/script-helpers/scripts/security_notice.sh"), "Security"], check=False)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
