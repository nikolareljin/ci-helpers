"""Print the commit a diff scan compares HEAD against, or exit 1.

Shared by the gitleaks-diff and foxguard-diff actions. The result is the merge
base of HEAD and the base commit, so the range `<printed>..HEAD` holds exactly
the commits under review and the base-side tree is one every reviewed commit
descends from.

The base commit, in order:

  1. BASE_REF, when set: a commit, a local ref, or a branch under
     refs/remotes/origin/. Must not start with "-".
  2. A pull_request (or pull_request_target) event: pull_request.base.sha.
  3. A push event: `before`. An all-zero `before` is a new branch; it is
     compared against origin/<default_branch>, unless the pushed ref is the
     default branch itself, which has no base and fails.
  4. Anything else fails: the caller passes base_ref.

Fails closed: an unreadable event, a commit not in the repository, no merge
base, or an empty range (HEAD is the base, or behind it) all exit 1. Nothing
is printed but the merge base on success; diagnostics are for the caller's
private log only.

Usage: resolve_scan_base.py <work-tree>
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys

ZERO = re.compile(r"^0{40}$|^0{64}$")
SHA = re.compile(r"^[0-9a-f]{40}$|^[0-9a-f]{64}$")


def git(root, *args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, env=env)


def commit(root, ref):
    """The commit a ref names, or None."""
    if not ref or ref.startswith("-") or any(c.isspace() for c in ref):
        return None
    result = git(root, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
    if result.returncode:
        return None
    sha = result.stdout.strip()
    return sha if SHA.match(sha) else None


def resolve_ref(root, ref):
    return commit(root, ref) or commit(root, "refs/remotes/origin/" + ref)


def from_event(root):
    path = os.environ.get("GITHUB_EVENT_PATH", "")
    if not path:
        raise ValueError("no event and no base_ref")
    event = json.loads(Path(path).read_text(encoding="utf-8"))
    name = os.environ.get("GITHUB_EVENT_NAME", "")
    pull = event.get("pull_request")
    if pull and name in ("pull_request", "pull_request_target", ""):
        sha = str(pull["base"]["sha"])
        if not SHA.match(sha):
            raise ValueError("pull request base is not a commit sha")
        return commit(root, sha)
    if name == "push":
        before = str(event.get("before", ""))
        # All zeros is a sha by shape and no commit at all: test it first.
        if not ZERO.match(before):
            if not SHA.match(before):
                raise ValueError("push event carries no usable before sha")
            return commit(root, before)
        default = str((event.get("repository") or {}).get("default_branch", ""))
        if not default:
            raise ValueError("new branch and no default branch to compare with")
        if str(event.get("ref", "")) == "refs/heads/" + default:
            raise ValueError("first push of the default branch has no base")
        return commit(root, "refs/remotes/origin/" + default)
    raise ValueError("event %r carries no base; pass base_ref" % name)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    if git(root, "rev-parse", "--is-inside-work-tree").stdout.strip() != "true":
        raise ValueError("not a git work tree")
    head = commit(root, "HEAD")
    if not head:
        raise ValueError("no HEAD commit")
    base_ref = os.environ.get("BASE_REF", "").strip()
    base = resolve_ref(root, base_ref) if base_ref else from_event(root)
    if not base:
        raise ValueError("base commit is not in the repository")
    merge_base = git(root, "merge-base", base, head)
    if merge_base.returncode:
        raise ValueError("no merge base")
    merge_base = merge_base.stdout.strip()
    if not SHA.match(merge_base):
        raise ValueError("merge base is not a commit sha")
    count = git(root, "rev-list", "--count", merge_base + ".." + head)
    if count.returncode or not count.stdout.strip().isdigit() or int(count.stdout) == 0:
        raise ValueError("nothing to review: HEAD is the base or behind it")
    print(merge_base)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print("base: %s" % exc, file=sys.stderr)
        sys.exit(1)
