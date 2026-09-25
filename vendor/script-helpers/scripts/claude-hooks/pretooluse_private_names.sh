#!/usr/bin/env bash
# SCRIPT: pretooluse_private_names.sh
# DESCRIPTION: Claude Code PreToolUse hook — stop an agent publishing text that names a private repository.
# USAGE: wired into a Claude Code settings.json PreToolUse hook for the Bash tool; reads the hook payload on stdin.
# EXIT_CODES:
#   0  the call may proceed
#   2  the call is blocked; the reason on stderr goes back to the agent
# ----------------------------------------------------
#
# The git hooks in scripts/git-hooks/ cover the tree and commit messages. They
# cannot cover the surface where this actually went wrong: a pull request body
# and an issue body never touch git, so `gh pr create --body ...` publishes text
# no git hook will ever see. This runs before the tool call does.
#
# Only the text being published is checked -- the title, body and message
# arguments -- not the whole command line. `gh pr create --repo <private-repo>`
# is legitimate when the pull request belongs to that private repository, and a
# gate that blocked it would be turned off within a day.
#
# It also refuses --no-verify on commit and push. An agent has no legitimate
# reason to skip a local gate, and without this the git hooks are advisory for
# the one actor they were written for. A human at a terminal is unaffected:
# this hook only ever sees an agent's calls.
#
# INSTALL: in the settings.json Claude Code reads for the directory,
#
#   "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command",
#     "command": "bash <path>/script-helpers/scripts/claude-hooks/pretooluse_private_names.sh" } ] } ] }
# ----------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/../check_private_names.sh"

command -v python3 >/dev/null 2>&1 || exit 0
[[ -f "$GATE" ]] || exit 0

# The payload goes to a file rather than a pipe: the parser below is itself fed
# to python on stdin, so a pipe would be overridden and python would end up
# reading its own source as the payload -- and every call would sail through.
payload_file="$(mktemp)"
# Guarded: a subshell inherits an EXIT trap, and bash runs it there when the
# subshell is signalled -- so this could tear down the caller's stack, or
# delete a directory, while the run is still using it. ${BASHPID-$$} rather
# than $BASHPID alone: bash 3.2, which macOS ships, does not define BASHPID,
# and $$ is the top-level shell's pid in every subshell, so the comparison
# degrades to always-true there rather than to always-false.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -f "$payload_file"; fi' EXIT
cat > "$payload_file"

# One python pass: is this a publishing command, which repository is it aimed
# at, and what text would it publish. Returns three NUL-free lines plus a body.
parsed="$(python3 - "$payload_file" <<'PY'
import json, shlex, sys, pathlib

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)

if data.get("tool_name") != "Bash":
    sys.exit(0)
command = (data.get("tool_input") or {}).get("command") or ""
if not command:
    sys.exit(0)

try:
    # punctuation_chars, so `;` and `&&` come back as their own tokens: plain
    # shlex.split yields "/tmp;" as one word, and a command after a semicolon
    # would never be seen. commenters is cleared because a body legitimately
    # contains "#", and the default lexer would truncate the line there.
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    args = list(lexer)
except ValueError:
    # An unparseable command is not a licence to publish: fall back to checking
    # the whole string rather than letting it through unread.
    print("VERDICT\tcheck")
    print("REPO\t")
    print("TEXT")
    print(command)
    sys.exit(0)

# One shell line can hold several commands, and the interesting one is rarely
# first: `cd repo && gh pr create --body ...` is the ordinary shape. Judging
# only the first word let exactly that through. Split on the separators and
# consider each command on its own.
SEPARATORS = {"&&", "||", ";", "|", "&", "\n"}
segments, current = [], []
for token in args:
    if token in SEPARATORS:
        if current:
            segments.append(current)
        current = []
    else:
        current.append(token)
if current:
    segments.append(current)

PUBLISHES = (("gh", "pr", "create"), ("gh", "pr", "edit"), ("gh", "pr", "comment"),
             ("gh", "issue", "create"), ("gh", "issue", "edit"), ("gh", "issue", "comment"),
             ("gh", "release", "create"), ("gh", "api"))

def is_publishing(seg):
    low = [a.lower() for a in seg]
    for seq in PUBLISHES:
        if len(low) >= len(seq) and tuple(low[:len(seq)]) == seq:
            return True
    return len(low) >= 2 and low[0] == "git" and low[1] == "commit"

def skips_hooks(seg):
    low = [a.lower() for a in seg]
    return (low[:1] == ["git"] and len(low) > 1 and low[1] in ("commit", "push")
            and "--no-verify" in low)

if any(skips_hooks(seg) for seg in segments):
    print("VERDICT\tno-verify")
    print("REPO\t")
    print("TEXT")
    sys.exit(0)

publishing_segments = [seg for seg in segments if is_publishing(seg)]
if not publishing_segments:
    sys.exit(0)
# Only the publishing commands' own arguments: a `--repo` belonging to some
# other command on the line is not this one's destination.
args = [a for seg in publishing_segments for a in seg]

TEXT_FLAGS = {"-b", "--body", "-t", "--title", "-m", "--message", "-c", "--comment", "-f", "--field"}
FILE_FLAGS = {"-F", "--body-file", "--file"}
REPO_FLAGS = {"-R", "--repo"}

pieces, repo = [], ""
i = 0
while i < len(args):
    a = args[i]
    nxt = args[i + 1] if i + 1 < len(args) else None
    if a in REPO_FLAGS and nxt:
        repo = nxt
        i += 2
        continue
    if a in TEXT_FLAGS and nxt:
        pieces.append(nxt)
        i += 2
        continue
    if a in FILE_FLAGS and nxt:
        try:
            pieces.append(pathlib.Path(nxt).read_text(encoding="utf-8", errors="replace"))
        except OSError:
            pass
        i += 2
        continue
    for flag in TEXT_FLAGS | FILE_FLAGS:
        if a.startswith(flag + "="):
            value = a.split("=", 1)[1]
            if flag in FILE_FLAGS:
                try:
                    value = pathlib.Path(value).read_text(encoding="utf-8", errors="replace")
                except OSError:
                    value = ""
            pieces.append(value)
            break
    i += 1

if not pieces:
    sys.exit(0)
print("VERDICT\tcheck")
print("REPO\t%s" % repo)
print("TEXT")
sys.stdout.write("\n".join(pieces))
PY
)"

[[ -z "$parsed" ]] && exit 0

verdict="$(printf '%s' "$parsed" | sed -n '1s/^VERDICT\t//p')"
repo="$(printf '%s' "$parsed" | sed -n '2s/^REPO\t//p')"
text="$(printf '%s' "$parsed" | sed -n '4,$p')"

if [[ "$verdict" == "no-verify" ]]; then
  echo "Refusing --no-verify: it skips the local gate that checks this commit for" >&2
  echo "the name of a private repository, among other things. If a hook is wrong," >&2
  echo "say which one and let the user decide -- do not bypass it unasked." >&2
  exit 2
fi

[[ "$verdict" == "check" ]] || exit 0

gate_args=(--stdin --only-public)
[[ -n "$repo" ]] && gate_args+=(--for-repo "$repo")

reason="$(printf '%s' "$text" | bash "$GATE" "${gate_args[@]}" 2>&1)"
rc=$?

case "$rc" in
  1)
    {
      echo "This text names a private repository, and the destination is public."
      echo "GitHub keeps the edit history of every pull request and issue body"
      echo "publicly, so this cannot be fixed by editing it afterwards."
      echo
      printf '%s\n' "$reason"
      echo
      echo "Cite the repository by its code instead. If this is a false positive,"
      echo "ask the user before overriding -- do not set PRIVATE_NAMES_ALLOW yourself."
    } >&2
    exit 2
    ;;
  *)
    # 0 is clean; 2 means the check could not run, which is a setup problem and
    # must not silently become a refusal of every publishing command.
    exit 0
    ;;
esac
