"""Print the commit foxguard diff compares with, or exit 1.

foxguard diff matches findings by path, so a file the review only renames
reports every old finding in it as new. This writes a commit object whose
tree is the merge base's with the review's renames applied, and prints it;
with no renames it prints the merge base itself.

A file counts as moved only when its blob and mode at the new path are the
merge base's at an old path that the review deletes or itself fills from
another moved file (a swap, a->b and b->a), both paths under scan_path, and
none when the reviewed config is not empty: an edited move, a copy whose
source stays, or one from a path the scan or the config leaves out would let
a new finding pass as old. Those files are compared as new. The commit and
its tree are written to <tmp-dir>/objects, which reads the caller's objects
as an alternate; foxguard is given it the same way. Nothing in the caller's
repository changes, and a read-only object store works.

Usage: rename_base.py <work-tree> <merge-base> <tmp-dir> <config>

Run foxguard with GIT_ALTERNATE_OBJECT_DIRECTORIES set to <tmp-dir>/objects,
C-quoted ("...") so a ':' in the path does not split it.
"""

import os
import re
import subprocess
import sys

SHA = re.compile(r"^[0-9a-f]{40}$|^[0-9a-f]{64}$")


def git(root, *args, env_extra=None, stdin=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(env_extra or {})
    result = subprocess.run(["git", "-C", root, *args], capture_output=True, env=env, input=stdin)
    if result.returncode:
        raise ValueError("git failed")
    return result.stdout


def quoted(path):
    """One GIT_ALTERNATE_OBJECT_DIRECTORIES entry: git splits the list on
    the path separator unless the entry is C-quoted."""
    return '"' + path.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    root, base, tmp, config = sys.argv[1:5]
    if not SHA.match(base):
        raise ValueError("base is not a commit sha")
    with open(config, "rb") as fh:
        if fh.read().strip():
            sys.stdout.write(base + "\n")
            return 0
    prefix = git(root, "rev-parse", "--show-prefix").strip()
    top = git(root, "rev-parse", "--show-toplevel").decode().strip()
    raw = git(top, "diff", "--no-renames", "--raw", "--abbrev=64", "-z", base, "HEAD").split(b"\0")
    gone = {}    # old path -> (mode, blob) the review deletes or changes
    added = {}   # new path -> (mode, blob) the review adds or changes
    deleted = set()
    i = 0
    while i + 1 < len(raw) and raw[i]:
        old_mode, new_mode, old_sha, new_sha, kind = raw[i].lstrip(b":").split(b" ")
        path = raw[i + 1]
        i += 2
        if not path.startswith(prefix):
            continue
        if kind in (b"D", b"M", b"T"):
            gone[path] = (old_mode, old_sha)
        if kind in (b"A", b"M", b"T"):
            added[path] = (new_mode, new_sha)
        if kind == b"D":
            deleted.add(path)
    by_blob = {}
    for path in sorted(gone):
        by_blob.setdefault(gone[path], []).append(path)
    # Each old path moves at most once; the first new path (sorted) takes it.
    moves = {}
    for path in sorted(added):
        for old in by_blob.get(added[path], []):
            if old != path and old not in moves.values():
                moves[path] = old
                break
    # A source the review keeps with other content is a copy, not a move:
    # drop it until every source is deleted or is itself a moved-to path.
    while True:
        bad = [new for new, old in moves.items() if old not in deleted and old not in moves]
        if not bad:
            break
        for new in bad:
            del moves[new]
    if not moves:
        sys.stdout.write(base + "\n")
        return 0
    objects = os.path.join(tmp, "objects")
    os.makedirs(objects, exist_ok=True)
    store = {
        "GIT_INDEX_FILE": os.path.join(tmp, "rename-base.index"),
        "GIT_OBJECT_DIRECTORY": objects,
    }
    caller = git(top, "rev-parse", "--git-path", "objects").decode().strip()
    store["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = quoted(os.path.join(top, caller))
    git(top, "read-tree", base, env_extra=store)
    # Every removal before any addition: a swap (a->b, b->a) would otherwise
    # remove an entry it had just written.
    removals = b""
    additions = b""
    for new, old in sorted(moves.items()):
        mode, sha = gone[old]
        removals += b"0 " + b"0" * len(sha) + b"\t" + old + b"\0"
        additions += mode + b" " + sha + b"\t" + new + b"\0"
    git(top, "update-index", "-z", "--index-info", env_extra=store, stdin=removals + additions)
    tree = git(top, "write-tree", env_extra=store).decode().strip()
    ident = {
        "GIT_AUTHOR_NAME": "foxguard-diff", "GIT_AUTHOR_EMAIL": "foxguard-diff@example.invalid",
        "GIT_COMMITTER_NAME": "foxguard-diff", "GIT_COMMITTER_EMAIL": "foxguard-diff@example.invalid",
        "GIT_AUTHOR_DATE": "@0 +0000", "GIT_COMMITTER_DATE": "@0 +0000",
    }
    made = git(top, "commit-tree", tree, "-p", base, "-m", "merge base with renames applied",
               env_extra={**store, **ident}).decode().strip()
    if not SHA.match(made):
        raise ValueError("commit-tree printed no sha")
    sys.stdout.write(made + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, IndexError, UnicodeError):
        sys.exit(1)
