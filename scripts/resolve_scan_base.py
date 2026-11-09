"""Print the commit a diff scan compares HEAD against, or exit 1.

Shared by the gitleaks-diff and foxguard-diff actions. The result is the merge
base of HEAD and the base commit, so the range `<printed>..HEAD` holds exactly
the commits under review and the base-side tree is one every reviewed commit
descends from.

The base commit, in order:

  1. BASE_REF, when set: a full commit sha, or a branch of the remote as
     `main`, `origin/main` or `refs/remotes/origin/main`. Nothing else: a
     short sha, a tag or a local branch is a name a pull request can create
     or shadow, so a bare `git rev-parse <name>` is never run.
  2. A pull_request (or pull_request_target) event: pull_request.base.sha.
  3. A push event: `before`, when it is a commit here and an ancestor of HEAD
     (the state the branch was pushed from). Otherwise (a new branch's
     all-zero `before`, a force push whose `before` is gone or rewritten) the
     pushed commits are compared with origin/<default_branch>; a push of the
     default branch itself then has an empty range and fails.
  4. Anything else fails: the caller passes base_ref.

Fails closed: an unreadable event, a commit not in the repository, no merge
base, or an empty range (HEAD is the base, or behind it) all exit 1. Nothing
is printed but the merge base on success, and nothing at all on failure.

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
    """The commit a fully qualified ref or full sha names, or None."""
    if not ref or ref.startswith("-") or any(c.isspace() for c in ref):
        return None
    result = git(root, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
    if result.returncode:
        return None
    sha = result.stdout.strip()
    if not SHA.match(sha):
        return None
    # A full sha names itself or nothing: rev-parse would also accept it as
    # an abbreviation of a longer object name.
    if SHA.match(ref) and sha != ref:
        return None
    return sha


def resolve_ref(root, ref):
    """A full sha, or a branch of origin written any of three ways."""
    if SHA.match(ref):
        return commit(root, ref)
    for prefix in ("refs/remotes/origin/", "origin/"):
        if ref.startswith(prefix):
            ref = ref[len(prefix):]
            break
    else:
        if ref.startswith("refs/"):
            return None
    # origin/HEAD is a symref to whatever the remote's default was at clone
    # time, and reads as the local HEAD; neither is a base anyone asked for.
    if not ref or ref == "HEAD" or ref.startswith(".") or ref.endswith(".lock") or ".." in ref or "@{" in ref:
        return None
    return commit(root, "refs/remotes/origin/" + ref)


def is_ancestor(root, older, newer):
    return git(root, "merge-base", "--is-ancestor", older, newer).returncode == 0


def from_event(root):
    path = os.environ.get("GITHUB_EVENT_PATH", "")
    if not path:
        raise ValueError("no event and no base_ref")
    event = json.loads(Path(path).read_text(encoding="utf-8"))
    name = os.environ.get("GITHUB_EVENT_NAME", "")
    pull = event.get("pull_request")
    if pull and name in ("pull_request", "pull_request_target"):
        sha = str(pull["base"]["sha"])
        if not SHA.match(sha):
            raise ValueError("pull request base is not a commit sha")
        return commit(root, sha)
    if name == "push":
        head = commit(root, "HEAD")
        before = str(event.get("before", ""))
        if SHA.match(before) and not ZERO.match(before):
            pushed_from = commit(root, before)
            # Only the state the branch was pushed from counts; a rewritten
            # or unrelated `before` would let the range skip commits.
            if pushed_from and head and is_ancestor(root, pushed_from, head):
                return pushed_from
        default = str((event.get("repository") or {}).get("default_branch", ""))
        if not default:
            raise ValueError("no usable before and no default branch to compare with")
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
    # Re-rendered from its integer value: the one line written is hex of the
    # sha's length and nothing that came from the arguments or the event.
    sys.stdout.write("%0*x\n" % (len(merge_base), int(merge_base, 16)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        # No reason on stderr: the caller discards it, and an event field
        # could otherwise reach a log through the message.
        sys.exit(1)
