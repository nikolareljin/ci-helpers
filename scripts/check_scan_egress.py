#!/usr/bin/env python3
"""No workflow runs a third-party action, and a scan workflow sends code,
credentials and findings to nobody.

    python3 scripts/check_scan_egress.py              # check this repository
    python3 scripts/check_scan_egress.py --root DIR   # check a tree elsewhere

Every workflow and action under .github (.yml or .yaml) is read with PyYAML. Each `uses:`
must be canonical (lowercase owner/repo[/path], no empty, `.` or `..`
segment, pinned to a 40-hex commit; a local `./path` with no such segment;
or this library at `@production`) and one of: this library
(nikolareljin/ci-helpers, or the ci-helpers of $GITHUB_REPOSITORY_OWNER in
a fork), a local path, an entry of ALLOWED_ACTIONS below (the one list of
actions this repository runs, each with its reason, some bound to named
files and jobs), or an entry of KEPT_THIRD_PARTY (temporary, each to be
replaced by a first-party step). Other spellings are refused, not
normalised. A third-party action runs inside the caller's job with the
checkout, the token and whatever secrets it is given; the Trivy actions
were hijacked in March 2026 to read exactly those. Any other action fails
here, however it is pinned; allowing one is a pull request that adds it to
ALLOWED_ACTIONS with its reason.

Scan files are .github/workflows/*-scan.yml, codeql-scan.yml, gitleaks-check.yml
and security-weekly.yml, and .github/actions/*-scan/action.yml. They allow
only the named toolchain installers, not the kept list, and also fail on:

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
import fnmatch
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

# A `uses:` must be in canonical form or it is refused, never normalised:
# lowercase, no empty, `.` or `..` segment, no trailing `/`, a 40-hex pin.
# GitHub resolves owner and repository case-insensitively and walks odd
# paths, so any other spelling could name an allowed action and dodge a check.
SEG = r"(?!\.\.?(?:/|@|$))[a-z0-9._-]+"
CANONICAL_USES = re.compile(rf"^[a-z0-9-]+/{SEG}(/{SEG})*@[0-9a-f]{{40}}$")
LOCAL_USES = re.compile(r"^\./[A-Za-z0-9._/-]+$")

# The one list of actions a workflow or action here may run, besides this
# library and a local path. Each entry: an owner/repo pattern (fnmatch, on
# the canonical lowercase name), the reason, and where it may appear: None
# for anywhere, else a set of (workflow file, job) pairs. An action outside
# this list and KEPT_THIRD_PARTY is refused, however it is pinned. Adding an
# entry is a pull request that states the reason here.
ALLOWED_ACTIONS = (
    ("actions/*", "GitHub's own actions (checkout, cache, setup-*, upload-artifact)", None),
    ("github/*", "GitHub's own actions (CodeQL)", None),
    # Microsoft, a verified organisation; SHA-pinned; receives the Azure
    # tenant, client id, client secret and the installers. Signing jobs
    # only: a job that downloads the built installers and runs no build or
    # app code.
    ("azure/artifact-signing-action", "Microsoft, Azure Artifact Signing; signing jobs only",
     frozenset({(".github/workflows/tauri-release.yml", "sign-windows")})),
)
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
}

# Temporary: third-party actions the other workflows still run, each to be
# replaced (E223) by a first-party step in a pull request of its own that
# deletes the line. The comment says what the action receives in the job,
# so a reader knows what is at stake until then. Nothing is added here
# without a replacement task; an empty set is the goal.
KEPT_THIRD_PARTY = {
    # To be replaced (E223). Installs PHP and Composer; runs with the
    # checkout (composer.json) and the job token for API rate limits;
    # downloads tools from its own CDN.
    "shivammathur/setup-php",
    # To be replaced (E223). Runs Unity tests in a container with the
    # checkout mounted and the licence secrets passed in.
    "game-ci/unity-test-runner",
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


def allowed_entry(base: str):
    """The ALLOWED_ACTIONS entry whose pattern matches owner/repo, or None."""
    for pattern, reason, scope in ALLOWED_ACTIONS:
        if fnmatch.fnmatchcase(base, pattern):
            return pattern, reason, scope
    return None


def check_uses(ref: str, where: str, out: list[str], kept: frozenset = frozenset(),
               at: tuple[str, str] | None = None) -> None:
    """One `uses:` reference. `kept` is the temporary allowlist for the
    file: empty for a scan file, KEPT_THIRD_PARTY for every other workflow.
    `at` is (workflow file, job) of a step, for a file-scoped
    ALLOWED_ACTIONS entry; None (a composite action, a reusable-workflow
    call, or unknown) matches no scope."""
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
    if parts[1] == "ci-helpers" and parts[0] in LIBRARY_OWNERS:
        return
    entry = allowed_entry(base)
    if entry:
        _, reason, scope = entry
        # A scoped entry is the action itself, as a step: no subpath, and
        # never a reusable workflow from the same repository.
        if scope is None or (at in scope and uses_name(ref) == base):
            return
        places = ", ".join(f"{f} job {j}" for f, j in sorted(scope))
        out.append(f"{where}: uses: '{ref}' is allowed only in {places} ({reason})")
        return
    if base in TOOLCHAIN_EXCEPTIONS:
        return
    if base in kept:
        return
    out.append(f"{where}: uses: '{ref}' is not in ALLOWED_ACTIONS, this library or a local path"
               + ("" if kept else " (a scan workflow allows only the toolchain installers)")
               + "; replace it with a first-party step, or add it to ALLOWED_ACTIONS with its reason")


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


def yaml_files(base: Path, pattern: str) -> list[Path]:
    """`pattern` with either extension: GitHub runs .yaml workflows and
    action.yaml actions as it runs .yml ones."""
    return [p for ext in (".yml", ".yaml") for p in base.glob(pattern + ext)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    args = ap.parse_args()
    root = Path(args.root)
    fork_owner = os.environ.get("GITHUB_REPOSITORY_OWNER", "").strip().lower()
    if fork_owner:
        LIBRARY_OWNERS.add(fork_owner)
    workflows = sorted(
        p for p in yaml_files(root / ".github/workflows", "*")
        if p.stem.endswith("-scan") or p.with_suffix(".yml").name in SCAN_WORKFLOWS
    )
    actions = sorted(yaml_files(root / ".github/actions", "*-scan/action"))
    if not workflows and not actions and not yaml_files(root / ".github", "**/*"):
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
        findings += check_action(doc, rel) if path.stem == "action" else check_workflow(doc, rel)
    scan_files = {str(p.relative_to(root)) for p in workflows + actions}
    kept = frozenset(KEPT_THIRD_PARTY)
    for path in sorted(yaml_files(root / ".github", "**/*")):
        rel = str(path.relative_to(root))
        try:
            doc = yaml.safe_load(path.read_text())
        except (OSError, yaml.YAMLError) as exc:
            print(f"{rel}: cannot read: {exc}", file=sys.stderr)
            return 2
        if not isinstance(doc, dict):
            continue
        # Every workflow and action: no third-party `uses:` beyond the kept
        # list. Scan files were held to the narrower rule above.
        if rel not in scan_files:
            for name, job in (doc.get("jobs") or {}).items():
                if not isinstance(job, dict):
                    continue
                if isinstance(job.get("uses"), str):
                    # A reusable-workflow call is not a step: no scope.
                    check_uses(job["uses"], f"{rel}: jobs.{name}", findings, kept)
                for i, step in enumerate(steps_of(job)):
                    if isinstance(step.get("uses"), str):
                        check_uses(step["uses"], f"{rel}: jobs.{name}.steps[{i}]", findings, kept, (rel, name))
            runs = doc.get("runs")
            if isinstance(runs, dict):
                for i, step in enumerate(steps_of(runs)):
                    if isinstance(step.get("uses"), str):
                        check_uses(step["uses"], f"{rel}: step {i}", findings, kept)
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
    print(f"ok: {len(workflows)} scan workflows and {len(actions)} scan actions send nothing out; "
          f"no workflow runs an action outside ALLOWED_ACTIONS and the {len(KEPT_THIRD_PARTY)} "
          "kept third-party actions, each temporary, to be replaced (E223)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
