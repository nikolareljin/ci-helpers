#!/usr/bin/env python3
"""A job that holds a secret, a write token or a release to ship restores no
cache and saves none, and no job saves a cache after the caller's code ran.

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

  secrets      anything in the job (a step's `run:`, `env:`, `with:` or
               `if:`, the job's `env:` or `if:`, a reusable call's `secrets:`
               mapping) reads the secrets context in any form: `secrets.X`,
               `secrets . X`, `SECRETS.X`, `secrets['X']`, `secrets[inputs.n]`,
               `toJSON(secrets)`, `contains(secrets, ...)`, `format(...,
               secrets.X)`; or the job has `secrets: inherit`. The one read
               that is not a secret of the repository is exactly
               `secrets.GITHUB_TOKEN`;
  environment  it names a deployment `environment:`, which holds secrets
               the gate cannot see;
  write        its permissions (the job's; else the workflow's, when the
               job does not narrow them) grant any scope `write`, `id-token`
               included, or are `write-all`;
  needs        a trusted job of the same workflow needs it, directly or
               through other jobs: its artifacts and outputs feed the
               publishing job;
  called       a job trusted that way calls its workflow with
               `uses: ./.github/workflows/<file>`: what the called
               workflow builds is what the caller publishes. A caller
               trusted by its own write permissions passes them to each
               called job that sets no `permissions:`, in a workflow that
               sets none, as that job runs with the caller's token; a
               caller trusted by its secrets alone passes nothing on, as
               a called job reads a secret only by naming it;
  named        a token of its workflow file name (between `-`, `_` and `.`)
               is release, deploy, publish, sign or submit: a
               `deploy_command` the caller supplies ships with credentials
               the gate cannot see.

Every other job is PLAIN. A composite action runs inside whatever job
calls it, so its steps are held to the trusted rules.

In a trusted job, and in a composite action:

  restore      `actions/cache` and `actions/cache/restore` fail, whatever the
               path. A cache entry is a tar archive, and restore unpacks it
               where its members point, not only under the declared path:
               an entry can overwrite the library checkout or the
               workspace before any digest check runs. A trusted job
               downloads and checks what it needs on every run;
  save         `actions/cache` and `actions/cache/save` fail: a trusted job
               writes no cache;
  setup        every `actions/setup-*` step must carry its action's off
               value for each cache input, from SETUP_OFF below: setup-go
               and setup-dotnet `cache: false`, setup-python and setup-java
               `cache: ""`, setup-node `cache: ""` and
               `package-manager-cache: false`. A missing key fails: setup-go
               caches by default, and setup-node 5 caches the package
               manager's store whenever package.json names one. An
               expression fails too, as nothing here can read it, and so
               does a setup action the table does not know;
  buildkit     a step, or the job's or workflow's `env:`, whose text holds
               `type=gha` (any case), or a `with:` of `cache-from` or
               `cache-to`, fails: a layer cache restored from the Actions
               cache is a layer in the pushed image;
  expression   a `uses:` written as an expression fails, as nothing here
               can tell what it names. A third-party action (setup-uv,
               setup-ruby, rust-cache) is refused in every job by
               scripts/check_scan_egress.py, outside its short kept list.

In every job, trusted or plain, and in a composite action:

  post-job     `actions/cache` fails. Its save runs when the job ends, after
               the caller's code ran under the cached path. Restore with
               `actions/cache/restore` and save with `actions/cache/save`.
  placement    `actions/cache/save` at step k must have `actions/cache/restore`
               with the same `path` and `key` at step k-2 and a `run:` step at
               k-1 (the dependency fetch); no run step before the save may
               name `inputs.<name>command` (any case, `-` or `_`, dotted or
               indexed), the caller's own code, in its `run:` or its
               `env:`, and when the job's or workflow's `env:` names one,
               no run step may come before the save.

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

# The value that turns each cache input of a setup action off, per action.
# A boolean input refuses "" and a package-manager input refuses "false",
# so the off value is the action's, not one word for all. A trusted job
# must write it: a missing key is the action's default, and setup-go's is
# on. Adding an action here is a pull request that reads its action.yml.
SETUP_OFF = {
    "actions/setup-go": {"cache": (False, "false")},
    "actions/setup-dotnet": {"cache": (False, "false")},
    "actions/setup-python": {"cache": ("",)},
    "actions/setup-java": {"cache": ("",)},
    "actions/setup-node": {"cache": ("",), "package-manager-cache": (False, "false")},
}

# Every way an expression reaches the secrets context, wherever the
# expression sits (env, with, run, if with or without braces, a reusable
# call's secrets:): `secrets.X`, `secrets . X`, `SECRETS.X` (contexts and
# properties are case-insensitive), `secrets['X']`, `secrets[inputs.n]`,
# and `secrets` whole as an argument (`toJSON(secrets)`, `contains(secrets,
# ...)`). The one read that is not a secret of the repository is exactly
# `secrets.GITHUB_TOKEN`, with nothing dereferenced after it.
SECRET_REF = re.compile(
    r"\bsecrets\s*(?:\.\s*(?P<name>[A-Za-z_][A-Za-z0-9_-]*)(?P<more>\s*[.\[])?|(?P<index>\[[^\]]*\]?))"
    r"|(?<=[(,])\s*\bsecrets\b\s*(?=[),])",
    re.IGNORECASE)
# The caller's own code: inputs.<name>command, any case,
# `-` or `_` in the name, dotted or indexed.
CALLER = re.compile(r"\binputs\s*(?:\.\s*[A-Za-z0-9_-]*|\[\s*['\"][A-Za-z0-9_-]*)command\b",
                    re.IGNORECASE)
GHA = re.compile(r"type\s*=\s*gha\b", re.IGNORECASE)



def steps_of(body: dict) -> list[dict]:
    return [s for s in (body.get("steps") or []) if isinstance(s, dict)]


def action_of(step: dict) -> str:
    """owner/repo[/path] of a step's uses:, lowercased, no pin; '' for a run step."""
    uses = step.get("uses")
    return uses.strip().partition("@")[0].lower().rstrip("/") if isinstance(uses, str) else ""


def with_text(step: dict, key: str) -> str:
    with_ = step.get("with")
    value = with_.get(key) if isinstance(with_, dict) else None
    return " ".join(str(value).split()) if value is not None else ""


def yaml_text(value) -> str:
    """A with: value as it is written in a workflow."""
    if value is False:
        return "false"
    if value is True:
        return "true"
    if value == "":
        return '""'
    return repr(value)


def label(step: dict, i: int) -> str:
    name = step.get("name") or step.get("id") or action_of(step) or "run"
    return f"steps[{i}] '{name}'"


EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)


def expressions(job: dict) -> list[str]:
    """Every expression of a job: each `${{ ... }}` anywhere in it, and each
    `if:` of the job or a step, which is an expression with or without the
    braces. Prose in a run block is not one."""
    text = yaml.safe_dump(job, width=10**9)
    found = EXPRESSION.findall(text)
    for holder in [job, *steps_of(job)]:
        cond = holder.get("if")
        if isinstance(cond, str):
            found.append(cond)
    return found


def secret_reads(exprs: list[str]) -> list[str]:
    """Each read of the secrets context in the expressions, as written,
    except an exact secrets.GITHUB_TOKEN."""
    reads = []
    for expr in exprs:
        for m in SECRET_REF.finditer(expr):
            name = m.group("name")
            if name and name.lower() == "github_token" and not m.group("more"):
                continue
            reads.append(" ".join(m.group(0).split()))
    return sorted(set(reads))


def is_trusted(job: dict, wf_perms) -> list[str]:
    """Why a job is trusted: a list of reasons, empty for a plain job."""
    why = []
    # The job's own `secrets:` key (a reusable call) is read apart: `inherit`
    # is every secret, and a mapping's values are expressions like the rest.
    rest = {k: v for k, v in job.items() if k != "secrets"}
    hits = secret_reads(expressions(rest))
    if hits:
        why.append("reads " + ", ".join(hits))
    passed = job.get("secrets")
    if passed == "inherit":
        why.append("secrets: inherit")
    elif isinstance(passed, dict) and passed:
        why.append("passes " + ", ".join(sorted(str(k) for k in passed)) + " to the workflow it calls")
    env = job.get("environment")
    if env:
        name = (env.get("name") if isinstance(env, dict) else env) or "(unnamed)"
        why.append(f"uses environment {name}: a deployment environment holds secrets")
    perms = job.get("permissions", wf_perms)
    if perms == "write-all":
        why.append("permissions: write-all")
    elif write_scopes(perms):
        why.append("holds " + ", ".join(f"{k}: write" for k in write_scopes(perms)))
    return why


def write_scopes(perms) -> list[str]:
    if perms == "write-all":
        return ["write-all"]
    if isinstance(perms, dict):
        return sorted(str(k) for k, v in perms.items() if v == "write")
    return []


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


# A token of the file name, between `-`, `_` or `.`: deploy.yml, go-deploy.yml,
# rust-release-tarballs.yml, winget-submit.yml; not a word that holds one.
PUBLISHING_TOKENS = {"release", "deploy", "publish", "sign", "submit"}


def named_for_shipping(rel: str) -> bool:
    return bool(PUBLISHING_TOKENS & set(re.split(r"[-_.]", Path(rel).name)))


def trusted_jobs(doc: dict, rel: str = "") -> dict[str, str]:
    """Job name -> reason, closed over `needs`: a job a trusted job needs
    builds what that job publishes."""
    jobs = {n: j for n, j in (doc.get("jobs") or {}).items() if isinstance(j, dict)}
    out: dict[str, str] = {}
    named = named_for_shipping(rel) if rel else False
    for name, job in jobs.items():
        why = is_trusted(job, doc.get("permissions"))
        if named:
            why.append(f"is a job of {Path(rel).name}, a workflow named for what it ships")
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
    out = {rel: trusted_jobs(doc, rel) for rel, doc in docs.items()}
    changed = True
    while changed:
        changed = False
        for rel, doc in docs.items():
            jobs = {n: j for n, j in (doc.get("jobs") or {}).items() if isinstance(j, dict)}
            for name, why in list(out[rel].items()):
                uses = jobs[name].get("uses")
                called = LOCAL_WORKFLOW.match(uses) if isinstance(uses, str) else None
                if not called or called.group(1) not in docs:
                    continue
                target = called.group(1)
                whole = why.startswith(("is needed by", "is called by"))
                # A called job that sets no permissions, in a workflow that
                # sets none, runs with the caller's token: write passes on.
                writes = not whole and bool(write_scopes(jobs[name].get("permissions", doc.get("permissions"))))
                narrowed = "permissions" in docs[target]
                for job, body in (docs[target].get("jobs") or {}).items():
                    if not whole and not (writes and not narrowed and isinstance(body, dict)
                                          and "permissions" not in body):
                        continue
                    if isinstance(body, dict) and job not in out[target]:
                        out[target][job] = f"is called by trusted job {rel}: jobs.{name}"
                        changed = True
            if close_needs(jobs, out[rel]):
                changed = True
    return out


def check_trusted_steps(steps: list[dict], where: str, why: str, out: list[str],
                        env_text: str = "") -> None:
    if GHA.search(env_text):
        out.append(f"{where}: env: names type=gha, a BuildKit cache from the Actions cache in a "
                   f"job that {why}; a restored layer is a layer of the pushed image")
    for i, step in enumerate(steps):
        here = f"{where}.{label(step, i)}"
        act = action_of(step)
        path = with_text(step, "path")
        if "${{" in act:
            out.append(f"{here}: uses: is an expression in a job that {why}; nothing here can "
                       "tell whether it names a cache action, so a trusted job names its actions")
        elif act == "actions/cache":
            out.append(f"{here}: restores and saves '{path}' in a job that {why}; "
                       "a job that holds a secret or a write token builds clean")
        elif act == "actions/cache/save":
            out.append(f"{here}: saves '{path}' from a job that {why}; a trusted job writes no cache")
        elif act == "actions/cache/restore":
            out.append(f"{here}: restores '{path}' into a job that {why}; a cache entry is a tar "
                       "archive unpacked wherever its members point, so a trusted job restores "
                       "none and downloads what it needs")
        elif act.startswith("actions/setup-"):
            off = SETUP_OFF.get(act)
            with_ = step.get("with") if isinstance(step.get("with"), dict) else {}
            if off is None:
                out.append(f"{here}: {act} is not in SETUP_OFF, so nothing here knows how its "
                           f"cache is turned off; a job that {why} runs only a setup action "
                           "whose off value is listed there")
            else:
                for key, values in off.items():
                    if key not in with_:
                        out.append(f"{here}: {act} without {key}: in a job that {why}; the "
                                   f"action's default may restore a dependency cache there, "
                                   f"so write {key}: {yaml_text(values[0])}")
                    elif with_[key] not in values:
                        out.append(f"{here}: {act} with {key}: {yaml_text(with_[key])} restores a dependency "
                                   f"cache into a job that {why}; write {key}: {yaml_text(values[0])}")
        text = yaml.safe_dump(step, width=10**9)
        with_ = step.get("with") if isinstance(step.get("with"), dict) else {}
        if GHA.search(text) or "cache-from" in with_ or "cache-to" in with_:
            out.append(f"{here}: a BuildKit cache from the Actions cache in a job that {why}; "
                       "a restored layer is a layer of the pushed image")


def check_all_steps(steps: list[dict], where: str, out: list[str], env_text: str = "") -> None:
    # A caller step runs inputs.<name>command, in its run: or through env:.
    # When the job's or workflow's env: carries one, every run step can.
    env_caller = bool(CALLER.search(env_text))
    first_caller = next((j for j, s in enumerate(steps)
                         if "uses" not in s and (env_caller or CALLER.search(yaml.safe_dump(s, width=10**9)))), None)
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
                what = ("the job's env carries the caller's inputs.<name>command" if env_caller
                        else "which runs the caller's inputs.<name>command")
                out.append(f"{here}: actions/cache/save after {label(steps[first_caller], first_caller)}, "
                           f"{what}; save before any caller step")


def check_workflow(doc: dict, rel: str, trusted: dict[str, str]) -> tuple[list[str], int, int]:
    out: list[str] = []
    plain = 0
    for name, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        where = f"{rel}: jobs.{name}"
        steps = steps_of(job)
        env_text = yaml.safe_dump([doc.get("env"), job.get("env")], width=10**9)
        if name in trusted:
            check_trusted_steps(steps, where, trusted[name], out, env_text)
        else:
            plain += 1
        check_all_steps(steps, where, out, env_text)
    return out, len(trusted), plain


def check_action(doc: dict, rel: str) -> list[str]:
    out: list[str] = []
    runs = doc.get("runs")
    if not isinstance(runs, dict):
        return out
    steps = steps_of(runs)
    where = f"{rel}: runs"
    check_trusted_steps(steps, where, "may run inside a job that holds a secret (a composite action)", out)
    check_all_steps(steps, where, out)
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
        print(f"{len(set(findings))} finding(s): a job that holds a secret, a write token or a "
              "release to ship restores no cache and saves none; no job saves a cache after the "
              "caller's code ran", file=sys.stderr)
        return 1
    print(f"ok: {trusted} trusted jobs restore no cache and save none; "
          f"{plain} plain jobs and {len(actions)} actions save only right after a dependency fetch")
    return 0


if __name__ == "__main__":
    sys.exit(main())
