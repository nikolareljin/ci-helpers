#!/usr/bin/env python3
"""A scan workflow sends code, credentials and findings to nobody.

    python3 scripts/check_scan_egress.py              # check this repository
    python3 scripts/check_scan_egress.py --root DIR   # check a tree elsewhere

Scan files are .github/workflows/*-scan.yml, codeql-scan.yml, gitleaks-check.yml
and security-weekly.yml, and .github/actions/*-scan/action.yml. Each is read
with PyYAML and fails on:

  uses        a `uses:` outside the allowlist: actions/*, github/*, this
              library (nikolareljin/ci-helpers/..., or the ci-helpers of
              $GITHUB_REPOSITORY_OWNER in a fork), a local path (./...), or one
              of the named toolchain installers below, which must be pinned
              to a 40-hex commit. A third-party scanner action runs with the
              caller's checkout and token; the Trivy actions were hijacked in
              March 2026 to read exactly those.
  docker      a `docker run` in a run block whose image is not pinned by
              `@sha256:`. A tag is re-resolved on every run.
  checkout    an actions/checkout step without `persist-credentials: false`
              (a YAML boolean or the string "false").
              The default writes the job's token into .git/config, where a
              scanner reads it.
  secrets     a job with `secrets: inherit`. A scan job gets no secrets.
  telemetry   a run block in any workflow or action under .github that starts
              Trivy without both --disable-telemetry and --skip-version-check.
              Trivy otherwise reports usage to Aqua on every scan, even with
              --offline-scan.
  permissions a job (or the workflow, when the job sets none) without a
              `permissions:` block, or with `contents` other than `read`
              (absent is none, which is fine); any `write` other than
              `security-events` and `issues`; `security-events: write` in a
              job with no step that uploads SARIF (github/codeql-action/*,
              this library's trivy-scan or codeql-scan.yml).

EXIT_CODES:
  0  nothing found
  1  at least one finding
  2  the tree could not be read
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML is required", file=sys.stderr)
    sys.exit(2)

SCAN_WORKFLOWS = {"codeql-scan.yml", "gitleaks-check.yml", "security-weekly.yml"}

# `uses:` an action here may name without a finding. A local path and this
# library at any owner are fine; so are GitHub's own actions.
ALLOWED_USES = re.compile(r"^(\./|actions/|github/)")
# This library, at its home owner or at the owner of the repository the check
# runs in (a fork). Any other `<owner>/ci-helpers` is someone else's code.
LIBRARY_OWNERS = {"nikolareljin"}
LIBRARY_USES = re.compile(r"^([a-z0-9-]+)/ci-helpers/")

# A command that starts Trivy: the binary by name, or the path the installer
# hands over in TRIVY_BIN / trivy_bin.
# Where a command starts: line start, a separator, `$(`, or a shell keyword.
# Then any `VAR=value` assignments or `env [-opts] VAR=value` in front.
CMD_START = (r"(?:^|[;&|(]\s*|\$\(\s*|(?:\b(?:if|then|else|do|exec|time|sudo|command|while|until)|!)\s+)"
             r"(?:env\s+(?:-\S+\s+)*)?(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*")
TRIVY_CALL = re.compile(CMD_START + r'("?\$\{?(TRIVY_BIN|trivy_bin)\}?"?|(\S*/)?trivy)\s')
TRIVY_QUIET_FLAGS = ("--disable-telemetry", "--skip-version-check")

# Toolchain installers the language scans still use. They install a compiler
# or a package manager, not a scanner, and each must be pinned to a commit.
# Adding one here is a decision, not a convenience.
TOOLCHAIN_EXCEPTIONS = {
    "shivammathur/setup-php",
    "pnpm/action-setup",
    "dtolnay/rust-toolchain",
    "swatinem/rust-cache",
}
COMMIT = re.compile(r"^[0-9a-f]{40}$")

SARIF_UPLOADERS = re.compile(r"(github/codeql-action/|/actions/trivy-scan$|/codeql-scan\.yml$)")
WRITE_OK = {"security-events", "issues"}


def steps_of(job: dict):
    for step in job.get("steps") or []:
        if isinstance(step, dict):
            yield step


def normalise_uses(ref: str) -> tuple[str, str]:
    """`uses:` as (name, pin): lowercased, since GitHub resolves owner and
    repository case-insensitively, with empty and `.` path segments dropped,
    so `Actions/Checkout/.@x` is `actions/checkout`. Every check uses this."""
    name, _, pin = ref.strip().partition("@")
    if name.startswith("./"):
        return name.lower(), pin
    parts = [seg for seg in name.lower().split("/") if seg not in ("", ".")]
    return "/".join(parts), pin


def check_uses(ref: str, where: str, out: list[str]) -> None:
    norm, pin = normalise_uses(ref)
    low = f"{norm}@{pin}" if pin else norm
    if ALLOWED_USES.match(low):
        return
    lib = LIBRARY_USES.match(low)
    if lib and lib.group(1) in LIBRARY_OWNERS:
        return
    base = "/".join(norm.split("/")[:2])
    if base in TOOLCHAIN_EXCEPTIONS:
        if not COMMIT.match(pin):
            out.append(f"{where}: uses: toolchain exception '{base}' is not pinned to a commit ('{ref}')")
        return
    out.append(f"{where}: uses: '{ref}' is not actions/*, github/*, this library or a local path")


def commands(run: str) -> list[str]:
    """The run block as one string per command line: comment lines and
    trailing ` # ...` comments dropped, continuation lines joined."""
    lines = [re.sub(r"\s#.*$", "", ln) for ln in run.splitlines() if not ln.lstrip().startswith("#")]
    joined = re.sub(r"\\\n", " ", "\n".join(lines))
    # Indented commands in if/for/while bodies start a line too.
    return [ln.strip() for ln in joined.splitlines()]


# `docker run` where a command starts: at the start of a line, after a
# separator, inside `$(` or behind a keyword or sudo. `echo "docker run"` is not.
DOCKER_RUN = re.compile(CMD_START + r"docker\s+(container\s+)?run\b")


def check_run(run: str, where: str, out: list[str]) -> None:
    for line in commands(run):
        if DOCKER_RUN.search(line) and "@sha256:" not in line:
            out.append(f"{where}: docker: `docker run` without an @sha256: image")


def check_trivy(run: str, where: str, out: list[str]) -> None:
    for line in commands(run):
        if TRIVY_CALL.search(line.strip() + " "):
            missing = [f for f in TRIVY_QUIET_FLAGS if f not in line.split()]
            if missing:
                out.append(f"{where}: telemetry: Trivy runs without {' '.join(missing)}")


def check_steps(steps, where: str, out: list[str]) -> bool:
    """Check each step; return whether one uploads SARIF."""
    uploads = False
    for i, step in enumerate(steps):
        here = f"{where}.steps[{i}]"
        uses = step.get("uses")
        if isinstance(uses, str):
            check_uses(uses, here, out)
            # GitHub resolves owner and repository case-insensitively, so
            # every match below is on the lowercased name.
            name = normalise_uses(uses)[0]
            if SARIF_UPLOADERS.search(name):
                uploads = True
            if name == "actions/checkout":
                with_ = step.get("with") or {}
                keep = with_.get("persist-credentials") if isinstance(with_, dict) else None
                if keep is not False and str(keep).lower() != "false":
                    out.append(f"{here}: checkout: actions/checkout without persist-credentials: false")
        run = step.get("run")
        if isinstance(run, str):
            check_run(run, here, out)
    return uploads


def check_permissions(perms, where: str, uploads: bool, out: list[str]) -> None:
    if not isinstance(perms, dict):
        out.append(f"{where}: permissions: no `permissions:` block with contents: read")
        return
    # Absent means none, which is tighter than read.
    if perms.get("contents") not in (None, "read"):
        out.append(f"{where}: permissions: contents is '{perms.get('contents')}', not read")
    for scope, level in perms.items():
        if level == "write" and scope not in WRITE_OK:
            out.append(f"{where}: permissions: {scope}: write is not a scan job's to have")
    if perms.get("security-events") == "write" and not uploads:
        out.append(f"{where}: permissions: security-events: write with no SARIF upload step")


def check_workflow(doc: dict, rel: str) -> list[str]:
    out: list[str] = []
    wf_perms = doc.get("permissions")
    for name, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        where = f"{rel}: jobs.{name}"
        if job.get("secrets") == "inherit":
            out.append(f"{where}: secrets: inherit hands every secret to the called workflow")
        uploads = False
        if isinstance(job.get("uses"), str):
            check_uses(job["uses"], where, out)
            uploads = bool(SARIF_UPLOADERS.search(normalise_uses(job["uses"])[0]))
        uploads = check_steps(list(steps_of(job)), where, out) or uploads
        perms = job.get("permissions", wf_perms)
        if "uses" in job and "permissions" not in job and wf_perms is None:
            # A caller job of a reusable workflow inherits the caller's grant;
            # the called workflow declares its own, checked in its own file.
            continue
        check_permissions(perms, where, uploads, out)
    return out


def all_steps(doc):
    """Every step of a workflow's jobs or a composite action's runs."""
    if not isinstance(doc, dict):
        return
    for job in (doc.get("jobs") or {}).values():
        if isinstance(job, dict):
            yield from steps_of(job)
    runs = doc.get("runs")
    if isinstance(runs, dict):
        yield from steps_of(runs)


def check_action(doc: dict, rel: str) -> list[str]:
    out: list[str] = []
    runs = doc.get("runs") or {}
    if runs.get("using") == "docker":
        image = str(runs.get("image", ""))
        if "@sha256:" not in image:
            out.append(f"{rel}: docker: container action image '{image}' is not pinned by digest")
    check_steps(list(s for s in (runs.get("steps") or []) if isinstance(s, dict)), rel, out)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    args = ap.parse_args()
    root = Path(args.root)
    fork_owner = os.environ.get("GITHUB_REPOSITORY_OWNER", "").strip().lower()
    if fork_owner:
        LIBRARY_OWNERS.add(fork_owner)
    workflows = sorted(
        p for p in (root / ".github/workflows").glob("*.yml")
        if p.name.endswith("-scan.yml") or p.name in SCAN_WORKFLOWS
    )
    actions = sorted((root / ".github/actions").glob("*-scan/action.yml"))
    if not workflows and not actions and not any((root / ".github").glob("**/*.yml")):
        print(f"no scan workflow or action under {root}", file=sys.stderr)
        return 2
    findings: list[str] = []
    for path in workflows + actions:
        rel = str(path.relative_to(root))
        try:
            doc = yaml.safe_load(path.read_text())
        except (OSError, yaml.YAMLError) as exc:
            print(f"{rel}: cannot read: {exc}", file=sys.stderr)
            return 2
        if not isinstance(doc, dict):
            continue
        findings += check_action(doc, rel) if path.name == "action.yml" else check_workflow(doc, rel)
    for path in sorted((root / ".github").glob("**/*.yml")):
        rel = str(path.relative_to(root))
        try:
            doc = yaml.safe_load(path.read_text())
        except (OSError, yaml.YAMLError) as exc:
            print(f"{rel}: cannot read: {exc}", file=sys.stderr)
            return 2
        for i, step in enumerate(all_steps(doc)):
            if isinstance(step.get("run"), str):
                check_trivy(step["run"], f"{rel}: step {i}", findings)
    for line in sorted(set(findings)):
        print(line)
    if findings:
        print(f"{len(set(findings))} finding(s): a scan job runs only allowlisted actions, "
              "digest-pinned containers, token-free checkouts, no inherited secrets "
              "and read-only permissions", file=sys.stderr)
        return 1
    print(f"ok: {len(workflows)} scan workflows and {len(actions)} scan actions send nothing out")
    return 0


if __name__ == "__main__":
    sys.exit(main())
