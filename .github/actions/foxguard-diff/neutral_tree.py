"""Copy every changed file to neutral paths in a new repository, or exit 1.

foxguard skips some paths even when they are named on the command line
(vendor/, build/, node_modules/, dist/, names such as a.min.js), on the base
side too, so a new finding there passes and an old one in an edited vendored
file is reported as new. This writes, under <tmp-dir>/neutral, a repository
with two commits: the base copy of each changed regular file, read from
<rename-base> (the merge base with the review's renames applied), and its
head copy. File i lands at f<i>/file.<ext>, or f<i>/<name> when the name has
no extension (Dockerfile), so no path or name of the review decides what
foxguard reads. Links and submodules are not copied. Only git moves bytes;
nothing in the caller's repository changes.

Usage: neutral_tree.py <work-tree> <merge-base> <rename-base> <tmp-dir> <config-or-empty>
       < reviewed-config-text

Prints the base commit of the new repository on the first line. With a
<config> (the path of the reviewed config, only its directory is used), the
config text is read from stdin and printed after that line for use at the
root of <tmp-dir>/neutral: each scan.ignore_rules entry whose path names a
changed file is rewritten to that file's neutral path (foxguard matches the
exact path only), the others are dropped. Run foxguard diff on the base
commit from <tmp-dir>/neutral, with "." as the path.
"""

import os
import posixpath
import re
import subprocess
import sys

SHA = re.compile(r"^[0-9a-f]{40}$|^[0-9a-f]{64}$")
REGULAR = (b"100644", b"100755")
IDENT = {
    "GIT_AUTHOR_NAME": "foxguard-diff", "GIT_AUTHOR_EMAIL": "foxguard-diff@example.invalid",
    "GIT_COMMITTER_NAME": "foxguard-diff", "GIT_COMMITTER_EMAIL": "foxguard-diff@example.invalid",
    "GIT_AUTHOR_DATE": "@0 +0000", "GIT_COMMITTER_DATE": "@0 +0000",
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
}


def git(root, *args, env_extra=None, stdin=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(env_extra or {})
    result = subprocess.run(["git", "-C", root, *args], capture_output=True, env=env, input=stdin)
    if result.returncode:
        raise ValueError("git failed")
    return result.stdout


def quoted(path):
    return '"' + path.replace("\\", "\\\\").replace('"', '\\"') + '"'


def neutral_name(index, path):
    name = path.rsplit(b"/", 1)[-1].lstrip(b".")
    stem, dot, ext = name.rpartition(b".")
    if dot and stem and ext:
        name = b"file." + ext
    elif not name:
        name = b"file"
    return b"f%d/" % index + name


def tree(root, commit, env_extra):
    """Every blob of commit: exact path bytes -> (mode, sha). No pathspec is
    passed, so a file named ":(exclude)a.py", "*.py" or "[x].py" is a path."""
    out = git(root, "ls-tree", "-r", "-z", "--full-tree", commit, env_extra=env_extra)
    entries = {}
    for item in out.split(b"\0"):
        if item:
            meta, _, path = item.partition(b"\t")
            mode, kind, sha = meta.split(b" ")
            entries[path] = (mode, kind, sha)
    return entries


def regular(entries, path):
    found = entries.get(path)
    return (found[0], found[2]) if found and found[1] == b"blob" and found[0] in REGULAR else None


def neutral_config(text, folder, names):
    """The reviewed config with its ignore paths moved to the neutral names."""
    import yaml
    doc = yaml.safe_load(text)
    if not isinstance(doc, dict):
        raise ValueError("config is not a mapping")
    scan = doc.get("scan")
    if isinstance(scan, dict) and "ignore_rules" in scan:
        rules = scan["ignore_rules"]
        if not isinstance(rules, list):
            raise ValueError("scan.ignore_rules is not a list")
        moved = []
        for rule in rules:
            if not (isinstance(rule, dict) and isinstance(rule.get("path"), str)):
                raise ValueError("ignore rule without a path")
            target = posixpath.normpath(posixpath.join(folder, rule["path"]))
            if target in names:
                moved.append({**rule, "path": names[target]})
        scan["ignore_rules"] = moved
    return yaml.safe_dump(doc, sort_keys=False)


def main():
    root, base, renamed, tmp = sys.argv[1:5]
    config = sys.argv[5] if len(sys.argv) > 5 else ""
    if not (SHA.match(base) and SHA.match(renamed)):
        raise ValueError("not a commit sha")
    top = git(root, "rev-parse", "--show-toplevel").decode().strip()
    prefix = git(root, "rev-parse", "--show-prefix").strip()
    caller = {"GIT_ALTERNATE_OBJECT_DIRECTORIES": quoted(os.path.join(tmp, "objects"))}
    changed = git(root, "diff", "--name-only", "-z", "--relative", "--diff-filter=ACMRT",
                  base, "HEAD", "--", ".").split(b"\0")
    neutral = os.path.join(tmp, "neutral")
    git(tmp, "init", "-q", neutral, env_extra=IDENT)
    store = {**IDENT, "GIT_INDEX_FILE": os.path.join(tmp, "neutral.index")}
    copied = {}
    names = {}
    head_tree = tree(top, "HEAD", None)
    old_tree = tree(top, renamed, caller)
    base_info = b""
    head_info = b""
    for index, path in enumerate(p for p in changed if p):
        full = prefix + path
        if full not in head_tree:
            raise ValueError("a changed file is not in the head tree")
        head = regular(head_tree, full)
        if head is None:
            continue
        name = neutral_name(index, path)
        names[full.decode()] = name.decode()
        for mode, sha in filter(None, (head, regular(old_tree, full))):
            if sha not in copied:
                blob = git(top, "cat-file", "blob", sha.decode(), env_extra=caller)
                copied[sha] = git(neutral, "hash-object", "-w", "--stdin", env_extra=store, stdin=blob).strip()
        old = regular(old_tree, full)
        if old is not None:
            base_info += old[0] + b" " + copied[old[1]] + b"\t" + name + b"\0"
        head_info += head[0] + b" " + copied[head[1]] + b"\t" + name + b"\0"
    git(neutral, "read-tree", "--empty", env_extra=store)
    git(neutral, "update-index", "-z", "--index-info", env_extra=store, stdin=base_info)
    base_tree = git(neutral, "write-tree", env_extra=store).decode().strip()
    base_commit = git(neutral, "commit-tree", base_tree, "-m", "base", env_extra=store).decode().strip()
    git(neutral, "update-index", "-z", "--index-info", env_extra=store, stdin=head_info)
    head_sha = git(neutral, "write-tree", env_extra=store).decode().strip()
    head_commit = git(neutral, "commit-tree", head_sha, "-p", base_commit, "-m", "head",
                      env_extra=store).decode().strip()
    if not (SHA.match(base_commit) and SHA.match(head_commit)):
        raise ValueError("commit-tree printed no sha")
    git(neutral, "update-ref", "HEAD", head_commit, env_extra=IDENT)
    git(neutral, "reset", "-q", "--hard", "HEAD", env_extra=IDENT)
    out = base_commit + "\n"
    if config:
        folder = os.path.relpath(os.path.dirname(os.path.realpath(config)), os.path.realpath(top))
        if folder == ".." or folder.startswith("../") or os.path.isabs(folder):
            raise ValueError("config outside the repository")
        out += neutral_config(sys.stdin.read(), folder.replace(os.sep, "/"), names)
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, IndexError, UnicodeError):
        sys.exit(1)
