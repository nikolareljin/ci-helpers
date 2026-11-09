#!/usr/bin/env python3
"""A scan workflow sends code, credentials and findings to nobody.

    python3 scripts/check_scan_egress.py              # check this repository
    python3 scripts/check_scan_egress.py --root DIR   # check a tree elsewhere

Scan files are .github/workflows/*-scan.yml, codeql-scan.yml, gitleaks-check.yml
and security-weekly.yml, and .github/actions/*-scan/action.yml. Each is read
with PyYAML and fails on:

  uses        a `uses:` that is not canonical (lowercase owner/repo[/path],
              no empty, `.` or `..` segment, pinned to a 40-hex commit; a
              local `./path` with no such segment; or this library at
              `@production`), or one outside the allowlist: actions/*,
              github/*, this library (nikolareljin/ci-helpers, or the
              ci-helpers of $GITHUB_REPOSITORY_OWNER in a fork), a local path,
              or one of the named toolchain installers below. Other spellings
              are refused, not normalised. A third-party scanner action runs
              with the caller's checkout and token; the Trivy actions were
              hijacked in March 2026 to read exactly those.
  docker      a run-block line, comments skipped and continuations joined,
              with a docker, podman or nerdctl token followed by `run` or
              `create`, and no `@sha256:` image. Fails closed: an echo of such
              a line is flagged too.
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
# A `uses:` must be in canonical form or it is refused, never normalised:
# lowercase, no empty, `.` or `..` segment, no trailing `/`, a 40-hex pin.
# GitHub resolves owner and repository case-insensitively and walks odd
# paths, so any other spelling could name an allowed action and dodge a check.
SEG = r"(?!\.\.?(?:/|@|$))[a-z0-9._-]+"
CANONICAL_USES = re.compile(rf"^[a-z0-9-]+/{SEG}(/{SEG})*@[0-9a-f]{{40}}$")
LOCAL_USES = re.compile(r"^\./[A-Za-z0-9._/-]+$")
ALLOWED_OWNERS = {"actions", "github"}
# This library, at its home owner or at the owner of the repository the check
# runs in (a fork), may also ride the `production` ref.
LIBRARY_OWNERS = {"nikolareljin"}
LIBRARY_PRODUCTION = re.compile(rf"^([a-z0-9-]+)/ci-helpers(/{SEG})+@production$")

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

SARIF_UPLOADERS = re.compile(r"(github/codeql-action/|/actions/trivy-scan$|/codeql-scan\.yml$)")
WRITE_OK = {"security-events", "issues"}


def steps_of(job: dict):
    for step in job.get("steps") or []:
        if isinstance(step, dict):
            yield step


def uses_name(ref: str) -> str:
    """The action part of a `uses:` (no pin). Callers match it only after
    check_uses has accepted the ref as canonical."""
    return ref.partition("@")[0]


def check_uses(ref: str, where: str, out: list[str]) -> None:
    if LOCAL_USES.match(ref):
        if any(seg in ("", ".", "..") for seg in ref.split("/")[1:]):
            out.append(f"{where}: uses: local path '{ref}' has an empty, '.' or '..' segment")
        return
    prod = LIBRARY_PRODUCTION.match(ref)
    if prod and prod.group(1) in LIBRARY_OWNERS:
        return
    if not CANONICAL_USES.match(ref):
        out.append(f"{where}: uses: '{ref}' is not canonical (lowercase owner/repo[/path] "
                   "with no empty, '.' or '..' segment, pinned to a 40-hex commit)")
        return
    parts = uses_name(ref).split("/")
    base = "/".join(parts[:2])
    if parts[0] in ALLOWED_OWNERS:
        return
    if parts[1] == "ci-helpers" and parts[0] in LIBRARY_OWNERS:
        return
    if base in TOOLCHAIN_EXCEPTIONS:
        return
    out.append(f"{where}: uses: '{ref}' is not actions/*, github/*, this library or a local path")


def commands(run: str) -> list[str]:
    """The run block as one string per command line: comment lines dropped,
    continuation lines joined, surrounding blanks stripped."""
    lines = [ln for ln in run.splitlines() if not ln.lstrip().startswith("#")]
    joined = re.sub(r"\\\n", " ", "\n".join(lines))
    return [ln.strip() for ln in joined.splitlines()]


# Fail closed: a line with a container engine token followed later by a
# token that starts a container is flagged unless it carries an @sha256:
# image. Prefixes such as sudo -E, env -u X, command -p cannot hide it; an
# echo of such a line is a false positive, accepted.
ENGINES = {"docker", "podman", "nerdctl"}
STARTS = {"run", "create"}


def tokens(line: str) -> list[str]:
    return [t.rsplit("/", 1)[-1] for t in re.split(r"[\s;&|()=`'\"$<>{}]+", line) if t]


def check_run(run: str, where: str, out: list[str]) -> None:
    for line in commands(run):
        toks = tokens(line)
        hits = [i for i, t in enumerate(toks) if t in ENGINES]
        if hits and any(t in STARTS for t in toks[hits[0] + 1:]) and "@sha256:" not in line:
            out.append(f"{where}: docker: container run or create without an @sha256: image")


def check_trivy(run: str, where: str, out: list[str]) -> None:
    for line in commands(run):
        toks = tokens(line)
        if any(t == "trivy" or "TRIVY_BIN" in t or "trivy_bin" in t for t in toks):
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
            name = uses_name(uses)
            if SARIF_UPLOADERS.search(name):
                uploads = True
            if name.lower().split("/")[:2] == ["actions", "checkout"]:
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
            uploads = bool(SARIF_UPLOADERS.search(uses_name(job["uses"])))
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
