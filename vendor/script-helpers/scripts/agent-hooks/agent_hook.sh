#!/usr/bin/env bash
# SCRIPT: agent_hook.sh
# DESCRIPTION: Run the script-helpers security check for an AI coding agent other than Claude Code: translate its pre-command hook payload to the Claude PreToolUse shape, run pretooluse_private_names.sh, and answer in that agent's terms.
# USAGE: agent_hook.sh <codex|gemini|copilot|cursor>   (the agent writes its JSON payload on stdin)
# PARAMETERS:
#   codex     PreToolUse; payload as Claude's (tool_name, tool_input.command, cwd).
#   gemini    BeforeTool; tool run_shell_command, tool_input.command, cwd.
#   copilot   preToolUse; toolName bash/powershell, toolArgs (object or JSON text), cwd.
#   cursor    beforeShellExecution; command and cwd at the top level.
# EXIT_CODES:
#   0  allowed
#   2  refused: the reason is on stderr, and on stdout in the agent's JSON form.
#      Every other outcome of the check (a crash, a missing script) is also 2,
#      because Cursor lets a command run on any other non-zero exit.
# ----------------------------------------------------
set -uo pipefail

agent="${1:-}"
case "$agent" in codex|gemini|copilot|cursor) ;; *)
  echo "[agent_hook] unknown agent '${agent}'; refused" >&2
  printf '%s\n' '{"decision":"deny","reason":"script-helpers agent_hook.sh: unknown agent"}'
  exit 2 ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/../claude-hooks/pretooluse_private_names.sh"

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -I -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then
    PY="$c"; break
  fi
done

payload="$(cat)"

# refuse <reason>: exit 2 with the agent's deny JSON (when Python can write it).
refuse() {
  echo "[agent_hook] $1" >&2
  [[ -n "$PY" ]] && "$PY" -I -c '
import json, sys
agent, r = sys.argv[1], sys.argv[2]
if agent == "codex":
    o = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": r}}
elif agent == "gemini":
    o = {"decision": "deny", "reason": r}
elif agent == "copilot":
    o = {"permissionDecision": "deny", "permissionDecisionReason": r}
else:
    o = {"permission": "deny", "user_message": r, "agent_message": r}
print(json.dumps(o))' "$agent" "$1"
  exit 2
}
# An agent always sends a payload: none, or one that is not a JSON object,
# cannot be judged, so it is refused rather than passed.
[[ -n "${payload//[[:space:]]/}" ]] || refuse "empty hook payload; refused"

# The payload in Claude's shape. Without Python it goes through unchanged: the
# check then scans the raw text, which still holds the command.
claude_payload="$payload"
if [[ -n "$PY" ]]; then
  claude_payload="$(printf '%s' "$payload" | "$PY" -I -c '
import json, sys
agent = sys.argv[1]
try:
    d = json.loads(sys.stdin.read() or "{}")
except ValueError:
    sys.exit(3)
if not isinstance(d, dict):
    sys.exit(3)
cmd = None
if agent == "cursor":
    cmd = d.get("command")
elif agent == "copilot":
    args = d.get("toolArgs")
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except ValueError:
            args = {"command": args}
    if isinstance(args, dict):
        cmd = args.get("command")
else:
    ti = d.get("tool_input")
    if isinstance(ti, dict):
        cmd = ti.get("command")
if not isinstance(cmd, str):
    # Not a shell command we can read: the check scans the whole payload text.
    cmd = json.dumps(d)
# No cwd in the payload: the agents run project hooks from the project, and the
# check treats a missing cwd as out of scope (allowed).
import os
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": cmd}, "cwd": d.get("cwd") or os.getcwd()}))
' "$agent")" || refuse "the hook payload is not a JSON object; refused"
fi

out_file="$(mktemp 2>/dev/null)" || { echo "[agent_hook] could not create a temp file; refused" >&2; exit 2; }
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -f "$out_file"; fi' EXIT
rc=0
if [[ -f "$check" ]]; then
  printf '%s' "$claude_payload" | bash "$check" > "$out_file" || rc=$?
else
  echo "[agent_hook] $check is missing; refused" >&2
  rc=2
fi
[[ "$rc" -eq 0 ]] && exit 0

# Refused (or the check failed): the reason from the check's JSON, else a fixed one.
reason="Refused by the script-helpers security gate; see stderr."
if [[ -n "$PY" && -s "$out_file" ]]; then
  r="$("$PY" -I -c '
import json, sys
import re
try:
    r = json.load(open(sys.argv[1]))["hookSpecificOutput"]["permissionDecisionReason"]
    print(re.sub(r"\x1b\[[0-9;]*m", "", r).strip())
except Exception:
    pass' "$out_file" 2>/dev/null)"
  [[ -n "$r" ]] && reason="$r"
fi
[[ "$rc" -ne 2 ]] && reason="The script-helpers security check failed (exit $rc); refused."
# The check wrote its reason to stderr already; refuse() repeats it only when it did not run.
if [[ "$rc" -eq 2 ]]; then refuse "$reason" 2>/dev/null; else refuse "$reason"; fi
