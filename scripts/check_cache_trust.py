#!/usr/bin/env python3
"""A job that holds a secret or a write token restores no cache it has not
verified, and no job saves a cache after the caller's code ran.

    python3 scripts/check_cache_trust.py              # check this repository
    python3 scripts/check_cache_trust.py --root DIR   # check a tree elsewhere

A cache entry is written by whichever run owned the key first: a default
branch build whose dependency scripts were compromised, or the post-job
save of `actions/cache`, which stores whatever the job left under the path
after every step ran, the caller's build and test scripts included. A job
that restores such an entry into `target/`, `vendor/bundle`, `node_modules`,
a package store or a BuildKit layer cache and then signs, pushes or
uploads what it built has put that content into a release without reading
it. The signing job is the one place a build must be clean.

Every workflow and composite action under .github (.yml or .yaml) is read
with PyYAML. A job is TRUSTED when any of these holds:

  secrets      a step, `env:`, `with:` or `if:` of the job names `secrets.X`
               for an X other than GITHUB_TOKEN, or the job has
               `secrets: inherit`;
  write        its permissions (the job's, else the workflow's) grant any
               scope `write`, or are `write-all`;
  needs        a trusted job of the same workflow needs it, directly or
               through other jobs: its artifacts and outputs feed the
               publishing job;
  called       a job trusted that way calls its workflow with
               `uses: ./.github/workflows/<file>`: what the called
               workflow builds is what the caller publishes. A caller
               trusted only by its own secrets or permissions passes
               nothing on; the called workflow declares what its jobs hold
               and is read on its own.

Every other job is PLAIN. A composite action runs inside whatever job
calls it, so its steps are held to the trusted rules.

In a trusted job, and in a composite action:

  restore      `actions/cache` and `actions/cache/restore` fail, unless the
               restore's `path` is an entry of VERIFIED_ARCHIVES and the
               step right after it runs the script named there, which
               checks the archive's digest on every run before unpacking
               it, so a tampered entry is refused, never used;
  save         `actions/cache` and `actions/cache/save` fail: a trusted job
               writes no cache;
  setup        `actions/setup-*` with `cache:` other than `false`, `"false"`
               or empty fails; an expression that may be empty at run time
               fails too, as nothing here can read it;
  buildkit     a step whose text holds `type=gha`, or a `with:` of
               `cache-from` or `cache-to`, fails: a layer cache restored
               from the Actions cache is a layer in the pushed image.

In every job, trusted or plain, and in a composite action:

  post-job     `actions/cache` fails. Its save runs when the job ends, after
               the caller's code ran under the cached path. Restore with
               `actions/cache/restore` and save with `actions/cache/save`.
  placement    `actions/cache/save` at step k must have `actions/cache/restore`
               with the same `path` and `key` at step k-2 and a `run:` step at
               k-1 (the dependency fetch); no step before the save may run
               `inputs.<name>command`, the caller's own code.

EXIT_CODES:
  0  nothing found
  1  at least one finding
  2  the tree could not be read
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML is required", file=sys.stderr)
    sys.exit(2)

# The archive caches a trusted job may restore: the step after the restore
# runs this script, which checks the archive's sha256 against a pin held in
# this repository before it unpacks anything, every run. The entry is the
# downloaded archive only, never the unpacked tool. Adding one is a pull
# request that names the script and its test.
VERIFIED_ARCHIVES = {
    # tests/setup_godot_test.sh
    "${{ runner.temp }}/ci-helpers-godot-archive": "setup_godot.sh",
    # tests/setup_flutter_test.sh
    "${{ steps.flutter_resolve.outputs.cache_path }}": "setup_flutter.sh",
}

SECRET = re.compile(r"\bsecrets\.(?!GITHUB_TOKEN\b)[A-Za-z_][A-Za-z0-9_]*")
CALLER = re.compile(r"\$\{\{\s*inputs\.[a-z_]*command\s*\}\}")
CACHE_OFF = (None, False, "", "false")


def steps_of(body: dict) -> list[dict]:
    return [s for s in (body.get("steps") or []) if isinstance(s, dict)]


def action_of(step: dict) -> str:
    """owner/repo[/path] of a step's uses:, lowercased, no pin; '' for a run step."""
    uses = step.get("uses")
    return uses.partition("@")[0].lower() if isinstance(uses, str) else ""


def with_text(step: dict, key: str) -> str:
    with_ = step.get("with")
    value = with_.get(key) if isinstance(with_, dict) else None
    return " ".join(str(value).split()) if value is not None else ""


def label(step: dict, i: int) -> str:
    name = step.get("name") or step.get("id") or action_of(step) or "run"
    return f"steps[{i}] '{name}'"


def is_trusted(job: dict, wf_perms) -> list[str]:
    """Why a job is trusted: a list of reasons, empty for a plain job."""
    why = []
    text = yaml.safe_dump(job, width=10**9)
    hits = sorted(set(SECRET.findall(text)))
    if hits:
        why.append("reads " + ", ".join(hits))
    if job.get("secrets") == "inherit":
        why.append("secrets: inherit")
    perms = job.get("permissions", wf_perms)
    if perms == "write-all":
        why.append("permissions: write-all")
    elif isinstance(perms, dict):
        writes = sorted(k for k, v in perms.items() if v == "write")
        if writes:
            why.append("holds " + ", ".join(f"{k}: write" for k in writes))
    return why


def close_needs(jobs: dict[str, dict], out: dict[str, str]) -> bool:
    """Mark what a trusted job needs as trusted; True when anything changed."""
    changed = False
    for name in list(out):
        needs = jobs[name].get("needs") or []
        for dep in [needs] if isinstance(needs, str) else needs:
            if dep in jobs and dep not in out:
                out[dep] = f"is needed by trusted job {name}"
                changed = True
    return changed


def trusted_jobs(doc: dict) -> dict[str, str]:
    """Job name -> reason, closed over `needs`: a job a trusted job needs
    builds what that job publishes."""
    jobs = {n: j for n, j in (doc.get("jobs") or {}).items() if isinstance(j, dict)}
    out: dict[str, str] = {}
    for name, job in jobs.items():
        why = is_trusted(job, doc.get("permissions"))
        if why:
            out[name] = "; ".join(why)
    while close_needs(jobs, out):
        pass
    return out


LOCAL_WORKFLOW = re.compile(r"^\./(\.github/workflows/[^@]+)$")


def trusted_everywhere(docs: dict[str, dict]) -> dict[str, dict[str, str]]:
    """rel -> job -> reason, closed over local reusable-workflow calls. A
    job trusted because a publishing job needs it (directly, or through
    another call) trusts every job of the workflow it calls: the caller
    publishes what that workflow built. A caller trusted only by its own
    secrets or permissions does not: the called workflow declares the
    secrets and permissions its jobs hold, and is read on its own."""
    out = {rel: trusted_jobs(doc) for rel, doc in docs.items()}
    changed = True
    while changed:
        changed = False
        for rel, doc in docs.items():
            jobs = {n: j for n, j in (doc.get("jobs") or {}).items() if isinstance(j, dict)}
            for name, why in list(out[rel].items()):
                if not why.startswith(("is needed by", "is called by")):
                    continue
                uses = jobs[name].get("uses")
                called = LOCAL_WORKFLOW.match(uses) if isinstance(uses, str) else None
                if not called or called.group(1) not in docs:
                    continue
                target = called.group(1)
                for job in (docs[target].get("jobs") or {}):
                    if job not in out[target]:
                        out[target][job] = f"is called by trusted job {rel}: jobs.{name}"
                        changed = True
            if close_needs(jobs, out[rel]):
                changed = True
    return out


def check_trusted_steps(steps: list[dict], where: str, why: str, out: list[str]) -> None:
    for i, step in enumerate(steps):
        here = f"{where}.{label(step, i)}"
        act = action_of(step)
        path = with_text(step, "path")
        if act == "actions/cache":
            out.append(f"{here}: restores and saves '{path}' in a job that {why}; "
                       "a job that holds a secret or a write token builds clean")
        elif act == "actions/cache/save":
            out.append(f"{here}: saves '{path}' from a job that {why}; a trusted job writes no cache")
        elif act == "actions/cache/restore":
            script = VERIFIED_ARCHIVES.get(path)
            nxt = steps[i + 1] if i + 1 < len(steps) else {}
            run = nxt.get("run") if isinstance(nxt.get("run"), str) else ""
            if script is None:
                out.append(f"{here}: restores '{path}' into a job that {why}; only an archive "
                           "listed in VERIFIED_ARCHIVES, checked against its pinned digest by the "
                           "next step, may be restored there")
            elif "uses" in nxt or f"scripts/{script}" not in run:
                out.append(f"{here}: restores '{path}' but the next step does not run "
                           f"scripts/{script}, which checks the archive before it is unpacked")
        elif act.startswith("actions/setup-"):
            cache = (step.get("with") or {}).get("cache") if isinstance(step.get("with"), dict) else None
            if cache not in CACHE_OFF:
                out.append(f"{here}: {act} with cache: {cache!r} restores a dependency cache into "
                           f"a job that {why}; set cache: false there")
        text = yaml.safe_dump(step, width=10**9)
        with_ = step.get("with") if isinstance(step.get("with"), dict) else {}
        if "type=gha" in text or "cache-from" in with_ or "cache-to" in with_:
            out.append(f"{here}: a BuildKit cache from the Actions cache in a job that {why}; "
                       "a restored layer is a layer of the pushed image")


def check_all_steps(steps: list[dict], where: str, out: list[str]) -> None:
    first_caller = next((j for j, s in enumerate(steps)
                         if isinstance(s.get("run"), str) and CALLER.search(s["run"])), None)
    for i, step in enumerate(steps):
        here = f"{where}.{label(step, i)}"
        act = action_of(step)
        if act == "actions/cache":
            out.append(f"{here}: actions/cache saves '{with_text(step, 'path')}' when the job ends, "
                       "after the caller's code ran under it; restore with actions/cache/restore "
                       "and save with actions/cache/save right after the dependency fetch")
        elif act == "actions/cache/save":
            restore = steps[i - 2] if i >= 2 else {}
            fetch = steps[i - 1] if i >= 1 else {}
            same = (action_of(restore) == "actions/cache/restore"
                    and with_text(restore, "path") == with_text(step, "path")
                    and with_text(restore, "key") == with_text(step, "key"))
            if not same:
                out.append(f"{here}: actions/cache/save without actions/cache/restore of the same "
                           "path and key two steps before it")
            if "uses" in fetch or not isinstance(fetch.get("run"), str):
                out.append(f"{here}: the step before actions/cache/save is not a run step; "
                           "the save follows the dependency fetch directly")
            if first_caller is not None and first_caller < i:
                out.append(f"{here}: actions/cache/save after {label(steps[first_caller], first_caller)}, "
                           "which runs the caller's inputs.<name>command; save before any caller step")


def check_workflow(doc: dict, rel: str, trusted: dict[str, str]) -> tuple[list[str], int, int]:
    out: list[str] = []
    plain = 0
    for name, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        where = f"{rel}: jobs.{name}"
        steps = steps_of(job)
        if name in trusted:
            check_trusted_steps(steps, where, trusted[name], out)
        else:
            plain += 1
        check_all_steps(steps, where, out)
    return out, len(trusted), plain


def check_action(doc: dict, rel: str) -> list[str]:
    out: list[str] = []
    runs = doc.get("runs")
    if not isinstance(runs, dict):
        return out
    steps = steps_of(runs)
    check_trusted_steps(steps, rel, "may run inside a job that holds a secret (a composite action)", out)
    check_all_steps(steps, rel, out)
    return out


def yaml_files(base: Path, pattern: str) -> list[Path]:
    return sorted(p for ext in (".yml", ".yaml") for p in base.glob(pattern + ext))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    args = ap.parse_args()
    root = Path(args.root)
    workflows = yaml_files(root / ".github/workflows", "*")
    actions = yaml_files(root / ".github/actions", "*/action")
    if not workflows and not actions:
        print(f"no workflow or action under {root}/.github", file=sys.stderr)
        return 2
    findings: list[str] = []
    trusted = plain = 0
    docs: dict[str, dict] = {}
    for path in workflows + actions:
        rel = str(path.relative_to(root))
        try:
            doc = yaml.safe_load(path.read_text())
        except (OSError, yaml.YAMLError) as exc:
            print(f"{rel}: cannot read: {exc}", file=sys.stderr)
            return 2
        if isinstance(doc, dict):
            docs[rel] = doc
    workflow_docs = {rel: doc for rel, doc in docs.items() if not rel.endswith(("/action.yml", "/action.yaml"))}
    trust = trusted_everywhere(workflow_docs)
    for rel, doc in docs.items():
        if rel in workflow_docs:
            found, t, p = check_workflow(doc, rel, trust[rel])
            findings += found
            trusted += t
            plain += p
        else:
            findings += check_action(doc, rel)
    for line in sorted(set(findings)):
        print(line)
    if findings:
        print(f"{len(set(findings))} finding(s): a job that holds a secret or a write token restores "
              "only a digest-checked archive and saves nothing; no job saves a cache after the "
              "caller's code ran", file=sys.stderr)
        return 1
    print(f"ok: {trusted} trusted jobs restore only digest-checked archives and save no cache; "
          f"{plain} plain jobs and {len(actions)} actions save only right after a dependency fetch")
    return 0


if __name__ == "__main__":
    sys.exit(main())
