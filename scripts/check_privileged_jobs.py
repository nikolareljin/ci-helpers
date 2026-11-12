#!/usr/bin/env python3
"""No job both runs caller-controlled code and holds a write token or a secret.

    python3 scripts/check_privileged_jobs.py              # this repository
    python3 scripts/check_privileged_jobs.py --root DIR   # a tree elsewhere
    python3 scripts/check_privileged_jobs.py --list       # print every finding, pending ones too

Every workflow under .github/workflows is read with PyYAML. A job is

  privileged  when its permissions (the job's, else the workflow's) grant
              write on contents, packages, id-token, pages, deployments,
              attestations or actions, or `write-all`, or are not set (a
              called workflow then gets whatever the caller grants); when it names any
              `secrets.<name>` other than GITHUB_TOKEN; or when it sets
              `environment:` (environment secrets reach every step);
  caller      when a step runs code the caller controls: a run: that
              splices `${{ inputs.<name> }}` where the name ends in
              `command`, `cmd`, `script`, `script_path`, `args` or `hook`
              (plurals too), or uses any input as a command word; a uses:
              handed such an input; in a reusable workflow, a script from
              the checked-out tree run by path or interpreter; or calls a build,
              package or install tool (make, npm, cargo, go build, flutter,
              docker build, dpkg-buildpackage, ...) or a library script that
              builds the caller's tree; or a uses: that builds the caller's
              tree (docker/build-push-action, tauri-apps/tauri-action,
              a local `./` action outside `.ci-helpers-*`).

A job that is both fails. So does a step named `Stage ...` that copies
files for an artifact without refusing symlinks (`! -L`), checking each
file resolves under its tree (`realpath -e`), copying with `cp -P` and
checking the staged tree holds only regular files. The split is: build in a read-only job, upload
the outputs with a sha256 manifest, and publish or sign in a job that runs
only library code on the downloaded files.

PENDING lists the jobs not yet split, each with the reason. An entry that
no longer fails is itself a finding, so the list only shrinks.

Exit 0 with nothing found, 1 with a finding, 2 on a usage or parse error.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("::error::PyYAML is required (pip install pyyaml)")
    sys.exit(2)

WRITE_SCOPES = {"contents", "packages", "id-token", "pages", "deployments",
                "attestations", "actions"}
SECRET = re.compile(r"secrets\.([A-Za-z_][A-Za-z0-9_]*)")
INPUT_CODE = re.compile(r"\$\{\{\s*inputs\.([A-Za-z0-9_-]*(?:command|commands|cmd|cmds|script|scripts|"
                        r"script_path|args|hook|hooks))\s*\}\}")
# Any input spliced as the command word of a line runs, whatever its name.
INPUT_AS_COMMAND = re.compile(r"(?:^|[;&|(`]|\$\(|\bthen\b|\bdo\b|\beval\s+)\s*[\"']?\$\{\{\s*inputs\.([A-Za-z0-9_-]+)\s*\}\}", re.M)
# A file from the caller's tree run by path or by an interpreter.
REL_SCRIPT = re.compile(r"(?:^|[;&|(`]|\$\(|\bthen\b|\bdo\b)\s*(?:(?:bash|sh|zsh|python3?|ruby|perl|pwsh)\s+)?"
                        r"[\"']?(?:\./(?!\.ci-helpers-)|(?:bash|sh|zsh|python3?|ruby|perl|pwsh)\s+[\"']?(?![-$/.~]))"
                        r"[A-Za-z0-9_./-]*\.(?:sh|py|rb|pl|ps1)\b", re.M)
# Tools that execute the caller's tree: build files, package scripts,
# lifecycle hooks, Dockerfiles, test suites. Matched as a command word.
TOOLS = (r"make|cmake|ninja|npm|npx|pnpm|yarn|bun|node|deno|cargo|rustc|go|flutter|dart|"
         r"dotnet|msbuild|gradle|\./gradlew|gradlew|mvn|\./mvnw|ant|sbt|pip|pip3|pipx|poetry|"
         r"uv|tox|nox|pytest|composer|php|phpunit|bundle|rake|gem|fastlane|pod|xcodebuild|"
         r"dpkg-buildpackage|debuild|pbuilder|sbuild|rpmbuild|mock|lazbuild|fpc|wrangler|"
         r"tauri|godot|swift|zig|meson|scons|bazel|ctest|hugo|jekyll|mkdocs|sphinx-build|"
         r"electron-builder|appimagetool|snapcraft|unity-editor")
TOOL_RUN = re.compile(r"(?:^|[;&|(`]|\$\(|\bthen\b|\bdo\b|\belse\b)\s*(?:sudo\s+(?:-E\s+)?)?(?:" + TOOLS
                      + r")(?=\s|$)", re.M)
DOCKER_BUILD = re.compile(r"(?:^|[;&|(\s])docker\s+(?:buildx\s+)?(?:build|bake)\b", re.M)
# Library scripts that run the caller's build, image or test suite.
LIB_BUILDERS = re.compile(r"scripts/(?:docker_build|rust_release_build|unity_test|unity_container|"
                          r"ppa_upload)\.sh")
# Installing a named tool from its registry runs no caller code, on a line
# that does nothing else.
TOOL_INSTALL = re.compile(r"^\s*(?:sudo\s+)?(?:dotnet\s+tool\s+(?:install|update)|"
                          r"npm\s+(?:install|i)\s+(?:-g|--global)\b|cargo\s+install\s+(?!.*--path)|"
                          r"go\s+install\s+\S+@)")
CALLER_USES = re.compile(r"^(?:docker/build-push-action|docker/bake-action|tauri-apps/tauri-action|"
                         r"github/codeql-action/autobuild|game-ci/)")
LOCAL_ACTION = re.compile(r"^\./(?!\.ci-helpers-[a-z]+/)")
# Command inputs that run on the deploy target over ssh, not on the runner.
REMOTE_INPUTS = {"post_deploy_command"}

# Jobs not yet split. "file:job" -> why it still holds both.
PENDING: dict[str, str] = {
    "auto-tag.yml:production": "runs the caller's scripts/create_production.sh with the push token (opt-in); split next",
    "cloudflare-deploy.yml:deploy": "wrangler resolves and deploys from the caller's tree; split next",
    "docker-multiarch.yml:build-push": "builds and pushes in one buildx call; next: build to an OCI layout artifact, push in a separate job",
    "flutter-release.yml:flutter_release": "signs and uploads to the stores from the build job; split next",
    "update-production.yml:move": "runs the caller's scripts/create_production.sh with the push token; split next",
    "java-scan.yml:scan": "nvd_api_key feeds the caller's dependency_check_command; split next",
    "self-test.yml:docker-refuses-what-it-must": "snyk_token reaches the job that builds the test images; split next",
    "tauri-release.yml:build-macos": "signs inside tauri build; next: sign the downloaded bundle in its own macOS job",
    "tauri-release.yml:build-windows": "signs the updater bundle inside tauri build; split next",
    "unity.yml:test": "the licence is activated for the caller's test run and returned after it; see docs/SECURITY.md",
}


def permissions(job: dict, wf: dict) -> list[str]:
    perm = job["permissions"] if "permissions" in job else wf.get("permissions")
    if perm == "write-all":
        return ["write-all"]
    if isinstance(perm, dict):
        return sorted(k for k, v in perm.items() if v == "write" and k in WRITE_SCOPES)
    return []


def privileged(job: dict, wf: dict) -> list[str]:
    why = [f"{p}: write" for p in permissions(job, wf)]
    if "permissions" not in job and "permissions" not in wf:
        why.append("the caller's permissions (no permissions: block)")
    names = sorted(set(SECRET.findall(yaml.safe_dump(job, sort_keys=False))) - {"GITHUB_TOKEN"})
    why += [f"secrets.{n}" for n in names]
    if job.get("environment"):
        why.append("environment:")
    return why


def caller_steps(job: dict, reusable: bool = True) -> list[str]:
    """reusable: the workflow is called by another repository, so a script
    in the checked-out tree is the caller's, not this repository's."""
    hits = []
    for i, step in enumerate(job.get("steps") or []):
        if not isinstance(step, dict):
            continue
        name = step.get("name") or step.get("uses") or f"step {i + 1}"
        uses = str(step.get("uses") or "")
        run = str(step.get("run") or "")
        with_text = " ".join(str(v) for v in (step.get("with") or {}).values())
        fwd = INPUT_CODE.search(with_text) if uses else None
        if uses and (CALLER_USES.match(uses) or LOCAL_ACTION.match(uses)):
            hits.append(f"{name} (uses {uses.split('@')[0]})")
        elif fwd and fwd.group(1) not in REMOTE_INPUTS:
            # A library action handed a command input runs it.
            hits.append(f"{name} (uses {uses.split('@')[0]} with inputs.{fwd.group(1)})")
        elif run:
            # A command input reaches the script through env: as often as inline.
            env_text = " ".join(str(v) for v in (step.get("env") or {}).values())
            m = next((m for m in [*INPUT_CODE.finditer(run), *INPUT_CODE.finditer(env_text),
                                  *INPUT_AS_COMMAND.finditer(run)]
                      if m.group(1) not in REMOTE_INPUTS), None)
            if m:
                hits.append(f"{name} (inputs.{m.group(1)})")
            elif LIB_BUILDERS.search(run):
                hits.append(f"{name} ({LIB_BUILDERS.search(run).group(0)})")
            elif reusable and REL_SCRIPT.search(run):
                hits.append(f"{name} ({REL_SCRIPT.search(run).group(0).strip()})")
            elif DOCKER_BUILD.search(run):
                hits.append(f"{name} (docker build)")
            else:
                for line in run.replace("\\\n", " ").splitlines():
                    plain_install = TOOL_INSTALL.search(line) and not re.search(r"[;&|`]|\$\(", line)
                    t = None if plain_install else TOOL_RUN.search(line)
                    if t:
                        hits.append(f"{name} ({t.group(0).strip(' ;&|(`$').split()[-1]})")
                        break
    return hits


STAGE_NEEDS = (re.compile(r'! -L "\$'), re.compile(r"realpath -e"), re.compile(r"cp -P"),
               re.compile(r"find \"\$out\" -mindepth 1 ! -type f"))


def staging_gaps(job: dict) -> list[str]:
    """A step named `Stage ...` that copies files for an artifact refuses
    symlinks, keeps each file under its tree, copies with `cp -P` and
    checks the staged tree holds only regular files."""
    gaps = []
    for step in job.get("steps") or []:
        if not isinstance(step, dict) or not str(step.get("name") or "").startswith("Stage "):
            continue
        run = str(step.get("run") or "")
        if not re.search(r"(?:^|[\s;&|(])cp\s", run):
            continue
        missing = [p.pattern for p in STAGE_NEEDS if not p.search(run)]
        if missing:
            gaps.append(f"{step['name']} copies without the symlink refusal (missing {', '.join(missing)})")
    return gaps


def scan(root: Path) -> dict[str, str]:
    found: dict[str, str] = {}
    wdir = root / ".github" / "workflows"
    for path in sorted([*wdir.glob("*.yml"), *wdir.glob("*.yaml")]):
        try:
            wf = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as exc:
            print(f"::error file={path}::not YAML: {exc}")
            sys.exit(2)
        for jname, job in (wf.get("jobs") or {}).items():
            if not isinstance(job, dict) or "steps" not in job:
                continue
            gaps = staging_gaps(job)
            if gaps:
                found[f"{path.name}:{jname}:stage"] = "; ".join(gaps)
            why = privileged(job, wf)
            if not why:
                continue
            triggers = wf.get("on", wf.get(True)) or {}
            reusable = "workflow_call" in (triggers if isinstance(triggers, (dict, list)) else [triggers])
            steps = caller_steps(job, reusable)
            if steps:
                found[f"{path.name}:{jname}"] = (f"holds {', '.join(why)} and runs caller code: "
                                                 f"{'; '.join(steps)}")
    return found


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--no-pending", action="store_true", help="ignore PENDING")
    args = ap.parse_args()
    root = Path(args.root)
    if not (root / ".github" / "workflows").is_dir():
        print(f"::error::no .github/workflows under {root}")
        return 2
    found = scan(root)
    pending = {} if args.no_pending else PENDING
    bad = 0
    for key, msg in found.items():
        if key in pending:
            if args.list:
                print(f"pending {key}: {msg}")
            continue
        fix = ("Refuse symlinks and special files when staging an artifact." if key.endswith(":stage")
               else "Move the write permission and secrets to a job that runs only library code.")
        print(f"::error::{key} {msg}. {fix}")
        bad = 1
    for key in pending:
        if key not in found:
            print(f"::error::{key} is in PENDING but no longer fails; remove it.")
            bad = 1
    if not bad:
        print(f"ok: no job runs caller code with a write token or a secret ({len(found)} pending)")
    return bad


if __name__ == "__main__":
    sys.exit(main())
