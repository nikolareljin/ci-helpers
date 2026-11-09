"""Print the commit foxguard diff compares with, or exit 1.

foxguard diff matches findings by path, so a file the review only renames
reports every old finding in it as new. This writes a commit object whose
tree is the merge base's with the review's renames applied, and prints it;
with no renames it prints the merge base itself. The commit is an unreferenced
object in the caller's repository: no ref, index or work-tree file changes.

Usage: rename_base.py <work-tree> <merge-base> <tmp-dir>
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


def main():
    root, base, tmp = sys.argv[1:4]
    if not SHA.match(base):
        raise ValueError("base is not a commit sha")
    top = git(root, "rev-parse", "--show-toplevel").decode().strip()
    status = git(top, "diff", "-M", "--name-status", "-z", base, "HEAD")
    fields = status.split(b"\0")
    renames = []
    i = 0
    while i < len(fields) and fields[i]:
        kind = fields[i]
        if kind.startswith(b"R") or kind.startswith(b"C"):
            if kind.startswith(b"R"):
                renames.append((fields[i + 1], fields[i + 2]))
            i += 3
        else:
            i += 2
    if not renames:
        sys.stdout.write(base + "\n")
        return 0
    index = {"GIT_INDEX_FILE": os.path.join(tmp, "rename-base.index")}
    git(top, "read-tree", base, env_extra=index)
    # Every removal before any addition: a swap (a->b, b->a) would otherwise
    # remove an entry it had just written.
    removals = b""
    additions = b""
    for old, new in renames:
        entry = git(top, "ls-tree", "-z", base, "--", old.decode("utf-8", "surrogateescape")).rstrip(b"\0")
        meta, _, path = entry.partition(b"\t")
        if path != old:
            raise ValueError("rename source not in the base tree")
        mode, _, sha = meta.split(b" ")
        zero = b"0" * len(sha)
        removals += b"0 " + zero + b"\t" + old + b"\0"
        additions += mode + b" " + sha + b"\t" + new + b"\0"
    git(top, "update-index", "-z", "--index-info", env_extra=index, stdin=removals + additions)
    tree = git(top, "write-tree", env_extra=index).decode().strip()
    ident = {
        "GIT_AUTHOR_NAME": "foxguard-diff", "GIT_AUTHOR_EMAIL": "foxguard-diff@example.invalid",
        "GIT_COMMITTER_NAME": "foxguard-diff", "GIT_COMMITTER_EMAIL": "foxguard-diff@example.invalid",
        "GIT_AUTHOR_DATE": "@0 +0000", "GIT_COMMITTER_DATE": "@0 +0000",
    }
    made = git(top, "commit-tree", tree, "-p", base, "-m", "merge base with renames applied",
               env_extra=ident).decode().strip()
    if not SHA.match(made):
        raise ValueError("commit-tree printed no sha")
    sys.stdout.write(made + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, IndexError, UnicodeError):
        sys.exit(1)
