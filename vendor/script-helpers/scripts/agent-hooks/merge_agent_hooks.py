#!/usr/bin/env python3
"""Add, remove or report the script-helpers pre-command hook in another AI agent's hook file.

USAGE:
  merge_agent_hooks.py install   <agent> <file> <command>
  merge_agent_hooks.py uninstall <agent> <file>
  merge_agent_hooks.py status    <agent> <file>

<agent> is codex, gemini, copilot or cursor. The shape written:
  codex    hooks.PreToolUse[]: {matcher: Bash, hooks: [{type, command, timeout}]}
  gemini   hooks.BeforeTool[]: {matcher: run_shell_command, hooks: [{name, type, command, timeout ms}]}
  copilot  version 1, hooks.preToolUse[]: {type, matcher: bash|powershell, bash, timeoutSec}
  cursor   version 1, hooks.beforeShellExecution[]: {command, timeout, failClosed}

Every other key and hook is kept. An entry whose command runs agent_hook.sh is
ours and is replaced, so a re-run never adds a second one. Loading, the
backup (<file>.bak-<UTC timestamp>) and the write are merge_settings.py's.

EXIT CODES:
  0  done (install/uninstall), or the entry is present (status)
  1  status: no entry
  3  the file is not valid JSON, or a hooks value has the wrong type; nothing written
  4  usage error, or the file could not be written
"""
import os
import sys

sys.dont_write_bytecode = True  # no __pycache__ in an installed copy
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "claude-hooks"))
from merge_settings import fail, load, save  # noqa: E402

ADAPTER = "agent_hook.sh"
NAME = "script-helpers-security-gate"
TIMEOUT = 60
AGENTS = {
    # agent: (event key, grouped under a matcher?, matcher)
    "codex": ("PreToolUse", True, "Bash"),
    "gemini": ("BeforeTool", True, "run_shell_command"),
    "copilot": ("preToolUse", False, None),
    "cursor": ("beforeShellExecution", False, None),
}


def entry(agent, command):
    if agent == "codex":
        return {"type": "command", "command": command, "timeout": TIMEOUT}
    if agent == "gemini":
        return {"name": NAME, "type": "command", "command": command, "timeout": TIMEOUT * 1000}
    if agent == "copilot":
        # Copilot runs "powershell" on Windows and "bash" elsewhere; without the
        # first, the hook would not run on Windows at all.
        return {"type": "command", "matcher": "bash|powershell", "bash": command,
                "powershell": "& " + command, "timeoutSec": TIMEOUT}
    # A crash or timeout must block: Cursor lets a command run on those otherwise.
    return {"command": command, "timeout": TIMEOUT, "failClosed": True}


def is_ours(hook):
    if not isinstance(hook, dict):
        return False
    return any(isinstance(hook.get(k), str) and ADAPTER in hook[k] for k in ("command", "bash", "powershell"))


def event_list(data, agent, path, create):
    event = AGENTS[agent][0]
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        if hooks is not None:
            fail(path, "has a \"hooks\" value that is not an object")
        if not create:
            return None
        hooks = data["hooks"] = {}
    lst = hooks.get(event)
    if not isinstance(lst, list):
        if lst is not None:
            fail(path, "has a \"hooks.{}\" value that is not a list".format(event))
        if not create:
            return None
        lst = hooks[event] = []
    return lst


def ours(data, agent, path):
    lst = event_list(data, agent, path, False) or []
    if AGENTS[agent][1]:
        return [h for g in lst if isinstance(g, dict) and isinstance(g.get("hooks"), list)
                for h in g["hooks"] if is_ours(h)]
    return [h for h in lst if is_ours(h)]


def strip_ours(data, agent, path):
    event, grouped, _ = AGENTS[agent]
    lst = event_list(data, agent, path, False)
    if lst is None:
        return False
    kept, removed = [], False
    for item in lst:
        if grouped and isinstance(item, dict) and isinstance(item.get("hooks"), list):
            inner = [h for h in item["hooks"] if not is_ours(h)]
            if len(inner) != len(item["hooks"]):
                removed = True
                if not inner:
                    continue
                item = dict(item)
                item["hooks"] = inner
        elif not grouped and is_ours(item):
            removed = True
            continue
        kept.append(item)
    if removed:
        if kept:
            data["hooks"][event] = kept
        else:
            del data["hooks"][event]
            if not data["hooks"]:
                del data["hooks"]
    return removed


def main(argv):
    if len(argv) < 4 or argv[1] not in ("install", "uninstall", "status") or argv[2] not in AGENTS:
        sys.stderr.write(__doc__)
        return 4
    action, agent, path = argv[1], argv[2], argv[3]
    data, raw, bom, newline = load(path)
    if action == "status":
        found = ours(data, agent, path)
        for h in found:
            print(h.get("command") or h.get("bash"))
        return 0 if found else 1
    if action == "install":
        if len(argv) < 5 or not argv[4].strip():
            sys.stderr.write("[merge_agent_hooks] install needs the hook command\n")
            return 4
        want = entry(agent, argv[4])
        if ours(data, agent, path) == [want]:
            print("unchanged {}".format(path))
            return 0
    removed = strip_ours(data, agent, path)
    if action == "uninstall" and not removed:
        print("unchanged {}".format(path))
        return 0
    if action == "install":
        if AGENTS[agent][0] in ("preToolUse", "beforeShellExecution"):
            data.setdefault("version", 1)
        lst = event_list(data, agent, path, True)
        _, grouped, matcher = AGENTS[agent]
        lst.append({"matcher": matcher, "hooks": [want]} if grouped else want)
    changed = save(path, data, raw, bom, newline)
    print("{} {}".format("updated" if changed else "unchanged", path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
