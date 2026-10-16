#!/usr/bin/env python3
"""Add, remove or report the script-helpers PreToolUse hook in a Claude Code settings.json.

USAGE:
  merge_settings.py install   <settings.json> <command> [timeout] [block]
  merge_settings.py uninstall <settings.json>
  merge_settings.py status    <settings.json>

Every other key and every other hook is kept. Any hook entry whose command
ends in pretooluse_private_names.sh (an older install, another path) is
replaced, so a re-run never adds a second one. The file's BOM and line endings
are kept. Before a change, the old file is copied byte for byte to
<settings.json>.bak-<UTC timestamp>.

EXIT CODES:
  0  done (install/uninstall), or the entry is present (status)
  1  status: no entry
  3  the file is not valid JSON or not an object; nothing was written
  4  usage error, or the file could not be written

Run by scripts/setup-hooks.sh. Works with Python 3.5 or newer, as python3 or
python, on Linux, macOS and Windows.
"""
import datetime
import json
import os
import shutil
import sys
import tempfile

HOOK_SCRIPT = "pretooluse_private_names.sh"
STATUS_MESSAGE = "script-helpers security gate"


def is_ours(hook):
    cmd = hook.get("command") if isinstance(hook, dict) else None
    if not isinstance(cmd, str):
        return False
    return cmd.strip().rstrip("'\"").rstrip().endswith(HOOK_SCRIPT)


def load(path):
    """(data, raw bytes or None, bom, newline). Exit 3 on invalid content."""
    if not os.path.exists(path):
        return {}, None, False, "\n"
    with open(path, "rb") as fh:
        raw = fh.read()
    bom = raw.startswith(b"\xef\xbb\xbf")
    newline = "\r\n" if b"\r\n" in raw else "\n"
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        fail(path, "is not UTF-8")
    if not text.strip():
        return {}, raw, bom, newline
    try:
        data = json.loads(text)
    except ValueError as exc:
        fail(path, "is not valid JSON ({})".format(exc))
    if not isinstance(data, dict):
        fail(path, "does not hold a JSON object")
    return data, raw, bom, newline


def fail(path, why):
    sys.stderr.write("[merge_settings] {} {}; left unchanged. Fix it, then run this again.\n".format(path, why))
    sys.exit(3)


def strip_ours(data):
    """Remove our entries from hooks.PreToolUse. True when something was removed."""
    hooks = data.get("hooks")
    if not isinstance(hooks, dict) or not isinstance(hooks.get("PreToolUse"), list):
        return False
    removed = False
    groups = []
    for group in hooks["PreToolUse"]:
        if isinstance(group, dict) and isinstance(group.get("hooks"), list):
            kept = [h for h in group["hooks"] if not is_ours(h)]
            if len(kept) != len(group["hooks"]):
                removed = True
                if not kept:
                    continue
                group = dict(group)
                group["hooks"] = kept
        groups.append(group)
    if removed:
        if groups:
            hooks["PreToolUse"] = groups
        else:
            del hooks["PreToolUse"]
            if not hooks:
                del data["hooks"]
    return removed


def ours(data):
    hooks = data.get("hooks")
    if not isinstance(hooks, dict) or not isinstance(hooks.get("PreToolUse"), list):
        return []
    found = []
    for group in hooks["PreToolUse"]:
        if isinstance(group, dict) and isinstance(group.get("hooks"), list):
            found.extend(h for h in group["hooks"] if is_ours(h))
    return found


def backup_name(path):
    """A backup path that does not exist yet: two runs in one second keep both."""
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    name = "{}.bak-{}".format(path, stamp)
    n = 1
    while os.path.lexists(name):
        name = "{}.bak-{}.{}".format(path, stamp, n)
        n += 1
    return name


def save(path, data, raw, bom, newline):
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if newline != "\n":
        text = text.replace("\n", newline)
    body = (b"\xef\xbb\xbf" if bom else b"") + text.encode("utf-8")
    if raw == body:
        return False
    # Write through a symlink (a dotfiles checkout), never replace it with a file.
    target = os.path.realpath(path)
    folder = os.path.dirname(target)
    tmp = None
    try:
        if not os.path.isdir(folder):
            os.makedirs(folder)
        if raw is not None:
            # Created with the original's mode (settings may hold tokens), and
            # O_EXCL: never through a file or link that is already there.
            bfd = os.open(backup_name(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                          os.stat(target).st_mode & 0o777)
            with os.fdopen(bfd, "wb") as dst, open(target, "rb") as src:
                shutil.copyfileobj(src, dst)
        fd, tmp = tempfile.mkstemp(prefix=".settings.", dir=folder)
        with os.fdopen(fd, "wb") as fh:
            fh.write(body)
        if raw is not None:
            shutil.copymode(target, tmp)
        os.replace(tmp, target)
        tmp = None
    except OSError as exc:
        sys.stderr.write("[merge_settings] could not write {}: {}\n".format(path, exc))
        sys.exit(4)
    finally:
        if tmp is not None and os.path.exists(tmp):
            os.remove(tmp)
    return True


def main(argv):
    if len(argv) < 3 or argv[1] not in ("install", "uninstall", "status"):
        sys.stderr.write(__doc__)
        return 4
    action, path = argv[1], argv[2]
    data, raw, bom, newline = load(path)
    if action == "status":
        found = ours(data)
        for h in found:
            print(h.get("command"))
            print("onFailure={}".format(h.get("onFailure", "")))
        return 0 if found else 1
    if action == "install":
        if len(argv) < 4 or not argv[3].strip():
            sys.stderr.write("[merge_settings] install needs the hook command\n")
            return 4
        timeout = int(argv[4]) if len(argv) > 4 else 60
        want = {"type": "command", "command": argv[3], "timeout": timeout,
                "shell": "bash", "statusMessage": STATUS_MESSAGE}
        if len(argv) > 5 and argv[5] == "block":
            # Claude Code 2.1.295+: a timeout or crash blocks instead of failing open.
            want["onFailure"] = "block"
        if ours(data) == [want] and {"matcher": "Bash", "hooks": [want]} in data["hooks"]["PreToolUse"]:
            print("unchanged {}".format(path))
            return 0
    removed = strip_ours(data)
    if action == "uninstall" and not removed:
        # Nothing of ours: the file is left byte for byte (no reformat, no new file).
        print("unchanged {}".format(path))
        return 0
    if action == "install":
        hooks = data.get("hooks")
        if not isinstance(hooks, dict):
            if hooks is not None:
                fail(path, "has a \"hooks\" value that is not an object")
            hooks = data["hooks"] = {}
        pre = hooks.get("PreToolUse")
        if not isinstance(pre, list):
            if pre is not None:
                fail(path, "has a \"hooks.PreToolUse\" value that is not a list")
            pre = hooks["PreToolUse"] = []
        pre.append({"matcher": "Bash", "hooks": [want]})
    changed = save(path, data, raw, bom, newline)
    print("{} {}".format("updated" if changed else "unchanged", path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
