#!/usr/bin/env python3
"""Reject workflow settings that publish scanner diagnostics."""

from pathlib import Path
import re
import subprocess
import sys

import yaml

RELEASE_SCRIPT = re.compile(r"scripts/github_release\.sh")


def mandatory_outcome(condition, key):
    match = re.fullmatch(
        r"\$\{\{\s*(.+?)\s+&&\s+steps\." + re.escape(key)
        + r"\.outcome\s*==\s*'success'\s*\}\}", condition,
    )
    if not match:
        return False
    prefix = match.group(1).strip()
    if prefix == "always()":
        return True
    if not prefix.startswith("(") or not prefix.endswith(")"):
        return False
    depth, quote = 0, ""
    for index, char in enumerate(prefix):
        if quote:
            if char == quote:
                quote = ""
            continue
        if char in "\"'":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if depth == 0 and index != len(prefix) - 1:
            return False
    return depth == 0 and not quote


def violations(doc):
    problems = []
    trigger = doc.get("on", doc.get(True, {}))
    declared = trigger.get("workflow_call", {}).get("inputs", {}) if isinstance(trigger, dict) else {}
    for job in (doc.get("jobs") or {}).values():
        if not isinstance(job, dict):
            continue
        steps = job.get("steps", [])
        checked = {}
        for step in steps:
            uses = str(step.get("uses", ""))
            options = step.get("with") or {}
            if uses.endswith("/.github/actions/publication-check"):
                checked[step.get("id")] = options
            # A release step is scripts/github_release.sh with its inputs in
            # env (the release action it replaced took them in `with`; a step
            # that still uses the action is checked the same way).
            script = RELEASE_SCRIPT.search(str(step.get("run", ""))) is not None
            if script or re.search(r"(?:actions/upload-artifact|softprops/action-gh-release)@", uses):
                release = script or "action-gh-release" in uses
                if script:
                    options = step.get("env") or {}
                    files_key, body_key, notes_keys = "FILES", "BODY_PATH", ("BODY", "GENERATE_RELEASE_NOTES")
                else:
                    files_key, body_key, notes_keys = ("files" if release else "path"), "body_path", ("body", "generate_release_notes")
                condition = str(step.get("if", ""))
                matches = re.findall(r"steps\.([A-Za-z_][\w-]*)\.outcome\s*==\s*'success'", condition)
                guards = [key for key in matches if key in checked]
                if len(guards) != 1 or not mandatory_outcome(condition, guards[0]):
                    problems.append("file upload lacks mandatory payload check")
                    continue
                key = guards[0]
                if checked[key].get("mode") != ("release" if release else "artifact"):
                    problems.append("file upload uses wrong payload check")
                if (not release or files_key in options) and options.get(files_key) != "${{ steps." + key + ".outputs.paths }}":
                    problems.append("file upload bypasses checked snapshot")
                if body_key in options and options[body_key] != "${{ steps." + key + ".outputs.body_path }}":
                    problems.append("release notes bypass checked snapshot")
                if any(options.get(k) for k in notes_keys):
                    problems.append("release generates unchecked notes")
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
                if str(options.get("fail_on_findings", True)).lower() == "false":
                    problems.append("scanner enforcement disabled")
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
                if re.search(r"git (?:[^\n]* )?push|gh (?:pr|issue|release|gist) (?:create|edit|comment|upload)|action-gh-release|upload-release-asset|github_release\.sh", yaml.safe_dump(step)):
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
