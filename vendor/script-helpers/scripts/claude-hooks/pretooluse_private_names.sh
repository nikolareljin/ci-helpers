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
# SCOPE (owner decision): only the repository the session is in, from the
# payload cwd. Its origin on github.com under a configured owner: every check
# runs. Anything else exits 0 at once (another owner, no repository, no usable
# cwd, no owners). A command acting on another repository is out of scope; that
# repository's pre-push hook covers its pushes.
#
# EVERY WAY THIS HOOK ALLOWS A CALL (exit 0), and why each is safe:
#   - out of scope, as above;
#   - the whole-command pass found nothing: it reads every Bash call (any
#     other tool: every string of its input), the raw payload when it is not
#     valid JSON, not UTF-8, or python3 is missing, and the files it names;
#   - after that pass, the parser found nothing it publishes (or the payload
#     is unreadable and does not look like publishing);
#   - a check could not run and the USER set SECURITY_GATE_ALLOW_UNCHECKED=1
#     in this hook's own environment (a command that sets it is refused);
#   - an empty command: nothing runs.
# There is no allow before the whole-command pass. The private-name prefilter
# only decides whether the slow full check is needed, and errs towards it.
#
# INSTALL: in the settings.json Claude Code reads for the directory,
#
#   "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command",
#     "command": "bash <path>/script-helpers/scripts/claude-hooks/pretooluse_private_names.sh" } ] } ] }
# ----------------------------------------------------
set -uo pipefail
export LC_ALL=C   # bytes: BSD tr/sed abort on non-UTF-8 input under a UTF-8 locale

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# private_name_candidate <file>: 0 when the text could name a listed repository
# and the full check must run; 1 when no listed name occurs in it in any form.
# check_private_names.sh takes seconds on a large list, and this hook reads
# every command, so the cheap test comes first. It is a superset: lower case,
# with "-", "_", "." and spaces removed on both sides, any substring counts. No
# list, an unreadable one, or one without a name column: the full check runs
# and reports that itself.
private_name_candidate() {
  local list
  [[ -n "${PRIVATE_NAMES_ALLOW:-}" ]] && return 0
  list="${PRIVATE_NAMES_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/private-names.tsv}"
  [[ -f "$list" && -r "$list" && -s "$list" ]] || return 0   # not a readable file: the full check decides
  awk -F'\t' '
    function norm(x) { x = tolower(x); gsub(/[-_. \t]/, "", x); return x }
    FILENAME == ARGV[1] {
      if ($0 ~ /^# *visibility\t/ || $1 == "visibility") { for (i = 1; i <= NF; i++) { h = $i; sub(/^# */, "", h); if (h == "name") col = i } next }
      if ($0 ~ /^#/ || col == 0) next
      n = norm($col); if (length(n) >= 3) names[n] = 1; count++
      next
    }
    { text = text norm($0) }
    END {
      if (col == 0 || count == 0) exit 0
      for (n in names) if (index(text, n)) exit 0
      exit 1
    }' "$list" "$1"
}
GATE="${SCRIPT_DIR}/../check_private_names.sh"

PUBLISH_RE='(^|[^[:alnum:]_-])(gh[[:space:]]+(pr|issue|release|api)|git[[:space:]]+commit)([^[:alnum:]_-]|$)'

# Without python3 the text cannot be extracted. A command that looks like it
# publishes is refused rather than waved through; anything else proceeds.
# Without python3 the command cannot be parsed. Nothing is allowed for that
# reason alone: the raw payload is scanned as a whole below, and a payload that
# looks like publishing is refused as "could not check".
# python3, else a "python" that is 3.x: Windows installs name it python.exe.
HAVE_PY=false; PY=python3
if command -v python3 >/dev/null 2>&1 && python3 -I -c 'import sys; sys.exit(sys.version_info[0] != 3)' >/dev/null 2>&1; then
  HAVE_PY=true
elif command -v python >/dev/null 2>&1 && python -I -c 'import sys; sys.exit(sys.version_info[0] != 3)' >/dev/null 2>&1; then
  HAVE_PY=true; PY=python
fi


# The payload goes to a file rather than a pipe: the parser below is itself fed
# to python on stdin, so a pipe would be overridden and python would end up
# reading its own source as the payload -- and every call would sail through.
# Every file this hook writes lives in one private directory (mktemp -d is
# mode 700), so another user cannot predict or replace any of them.
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pretooluse.XXXXXX" 2>/dev/null)" && [[ -d "$work_dir" && ! -L "$work_dir" ]] || {
  echo "The security gate could not create a private temp directory; refused." >&2
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"The security gate could not create a temp directory."}}'
  exit 2
}
chmod 700 "$work_dir" 2>/dev/null
payload_file="$work_dir/payload"
# Guarded: a subshell inherits an EXIT trap, and bash runs it there when the
# subshell is signalled -- so this could tear down the caller's stack, or
# delete a directory, while the run is still using it. ${BASHPID-$$} rather
# than $BASHPID alone: bash 3.2, which macOS ships, does not define BASHPID,
# and $$ is the top-level shell's pid in every subshell, so the comparison
# degrades to always-true there rather than to always-false.
# Claude Code blocks only on exit 2; any other non-zero exit lets the command
# run. So a crash here (set -u, a failed command) is turned into a refusal.
# stderr is collected in a file while the hook runs and copied to the real
# stderr at exit; on a refusal the same text also goes to stdout as a
# PreToolUse deny decision, for agents that read JSON rather than exit codes.
err_file="$work_dir/err"
exec 3>&2 2>"$err_file"
deny_json() {
  if [[ "$HAVE_PY" == true ]]; then
    "$PY" -I -c 'import json,sys
r = open(sys.argv[1], encoding="utf-8", errors="replace").read().strip() or "Refused by the security gate."
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
      "permissionDecision": "deny", "permissionDecisionReason": r}}))' "$err_file" 2>/dev/null && return 0
  fi
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Refused by the security gate; see stderr."}}'
}
on_exit() {
  local rc="$1"
  if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
    echo "The publishing check failed (exit $rc), so this command was NOT checked; refused." >&2
    rc=2
  fi
  cat "$err_file" >&3 2>/dev/null
  [[ "$rc" -eq 2 ]] && deny_json
  rm -rf "$work_dir"
  exit "$rc"
}
# shellcheck disable=SC2154  # _rc is assigned inside the trap string
trap '_rc=$?; if [[ ${BASHPID-$$} == "$$" ]]; then on_exit "$_rc"; fi' EXIT
cat > "$payload_file"
# The session directory is the payload's cwd field: the scope decision below
# reads its origin. When it is missing, relative or cannot be entered, cwd_ok
# stays false and the call is out of scope (exit 0).
cwd_ok=false
payload_cwd=""
if [[ "$HAVE_PY" == true ]]; then
  payload_cwd="$("$PY" -I -c 'import json,sys
try:
    c = json.load(open(sys.argv[1], encoding="utf-8")).get("cwd")
    print(c if isinstance(c, str) else "")
except Exception:
    print("")' "$payload_file" 2>/dev/null)"
fi
if [[ -z "$payload_cwd" ]]; then
  payload_cwd="$(LC_ALL=C sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload_file" | head -1)"
fi
case "$payload_cwd" in
  /*|[A-Za-z]:[/\\]*)
    if [[ -d "$payload_cwd" ]] && cd "$payload_cwd" 2>/dev/null; then cwd_ok=true; fi ;;
esac

# Scope, by the owner's decision: only the repository the session is in. When
# its origin is on github.com under a configured owner, every check below
# runs on the command. Anything else (another owner, no repository, no usable
# cwd, no owners configured): exit 0 and nothing is done. The command is not
# read to widen or narrow this: a push to another repository is that
# repository's pre-push hook's business.
SCOPE_LIB="${SCRIPT_DIR}/../owner_scope.sh"
session_scope=0
if [[ "$cwd_ok" != true ]]; then
  session_scope=1
elif [[ ! -f "$SCOPE_LIB" ]]; then
  session_scope=2
else
  ( # shellcheck source=/dev/null
    source "$SCOPE_LIB" || exit 2
    owners="$(scope_owners 2>/dev/null)" || exit 2
    [[ -n "$owners" ]] || exit 1
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 1
    # Every fetch and push URL of every remote, as the git hooks read them
    # (get-url applies url.<base>.insteadOf): a repository with only an
    # "upstream", or an owner's push URL behind another fetch URL, is the
    # owner's. scope_in_scope fails closed: a URL that does not parse but
    # names an owner as a path segment (ssh://github.com/<owner>/x) is in.
    urls="$(scope_repo_urls)" || exit 2
    [[ -n "$urls" ]] || exit 1
    set -f
    # shellcheck disable=SC2086  # one URL per line, no spaces in a URL
    scope_in_scope "$owners" $urls && exit 0
    exit 1
  ) || session_scope=$?
fi
[[ "$session_scope" -eq 1 ]] && exit 0
if [[ "$session_scope" -ne 0 ]]; then
  echo "The security gate could not tell whether this repository is in scope (owner_scope.sh missing or git config unreadable); refused." >&2
  exit 2
fi

# One python pass: is this a publishing command, which repository is it aimed
# at, and what text would it publish. Returns three NUL-free lines plus a body.
parsed=""
parse_rc=0
if [[ "$HAVE_PY" == true ]]; then
parsed="$("$PY" -I - "$payload_file" <<'PY'
import json, shlex, sys, pathlib

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    # Not judged here: the shell side refuses it if it looks like publishing.
    print("VERDICT\tbad-payload")
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
    #
    # Reported, not enforced, for everyday words. We could not parse it, so we
    # do not know it publishes anything -- and a heredoc of Python containing
    # `s.index(...)` is not a pull request body. Blocking those trains people
    # to switch the hook off.
    print("VERDICT\tcheck-unparsed")
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

import re
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
GIT_OPTS_WITH_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}

def normalize(seg):
    # The command itself: leading VAR=value words, env [-i] [VAR=value],
    # command, and the global options of git (-C <dir>, -c k=v, --no-pager)
    # dropped, so GH_TOKEN=x gh pr create and git -C repo commit are seen.
    # (No quote or backtick characters in this block: bash 3.2 parses a heredoc
    # inside $(...) for them and fails on an unbalanced one.)
    seg = list(seg)
    while seg:
        if ASSIGN.match(seg[0]):
            seg.pop(0)
        elif seg[0] in ("env", "command", "builtin", "exec", "nohup", "time"):
            seg.pop(0)
            while seg and seg[0].startswith("-") and seg[0] != "--":
                opt = seg.pop(0)
                if opt in ("-u", "--unset", "-C", "--chdir", "-S", "--split-string") and seg:
                    seg.pop(0)
            if seg and seg[0] == "--":
                seg.pop(0)
        else:
            break
    if seg and seg[0].lower() == "git":
        out, i = [seg[0]], 1
        while i < len(seg) and seg[i].startswith("-"):
            if seg[i] in GIT_OPTS_WITH_VALUE:
                i += 2
            else:
                i += 1
        seg = out + seg[i:]
    return seg


# Where each command runs: the last cd <dir> before it, or -C <dir> of git.
# The scope check reads the remotes there too, not only those of the session.
workdir, dirs = "", []
for seg in segments:
    if len(seg) >= 2 and seg[0] == "cd":
        workdir = seg[1]
    d = workdir
    if seg and seg[0].lower() == "git":
        for k in range(1, len(seg) - 1):
            if seg[k] == "-C":
                d = seg[k + 1]
            elif not seg[k].startswith("-"):
                break
    dirs.append(d)
segments = [normalize(seg) for seg in segments]
dirs = [d for seg, d in zip(segments, dirs) if seg]
segments = [seg for seg in segments if seg]

PUBLISHES = (("gh", "pr", "create"), ("gh", "pr", "edit"), ("gh", "pr", "comment"),
             ("gh", "issue", "create"), ("gh", "issue", "edit"), ("gh", "issue", "comment"),
             ("gh", "release", "create"), ("gh", "api"))

def is_publishing(seg):
    low = [a.lower() for a in seg]
    for seq in PUBLISHES:
        if len(low) >= len(seq) and tuple(low[:len(seq)]) == seq:
            return True
    # git tag -a/-m: the annotation is published with the tag.
    return len(low) >= 2 and low[0] == "git" and low[1] in ("commit", "tag")

COMMIT_VALUE_SHORTS = set("mFcCt")   # git commit short options that take a value

def skips_hooks(seg):
    low = [a.lower() for a in seg]
    if not (low[:1] == ["git"] and len(low) > 1 and low[1] in ("commit", "push")):
        return False
    # git accepts any unambiguous prefix: --no-veri, --no-verif.
    if any(a.startswith("--no-ver") for a in low):
        return True
    if low[1] != "commit":
        return False
    # git commit -n is --no-verify too, alone or in a cluster such as -an.
    # The rest of a cluster after a value option (-mtext) is its value.
    skip_next = False
    for a in seg[2:]:
        if skip_next:
            skip_next = False
            continue
        if a == "--":
            break
        if a.startswith("-") and not a.startswith("--") and len(a) > 1:
            for k, ch in enumerate(a[1:]):
                if ch == "n":
                    return True
                if ch in COMMIT_VALUE_SHORTS:
                    skip_next = (k == len(a) - 2)
                    break
    return False

if any(skips_hooks(seg) for seg in segments):
    print("VERDICT\tno-verify")
    print("REPO\t")
    print("TEXT")
    sys.exit(0)

publishing_segments = [seg for seg in segments if is_publishing(seg)]
pub_dirs = sorted({d for seg, d in zip(segments, dirs) if is_publishing(seg)})
if not publishing_segments:
    sys.exit(0)
# Only the publishing commands' own arguments: a `--repo` belonging to some
# other command on the line is not this one's destination.
args = [a for seg in publishing_segments for a in seg]

TEXT_FLAGS = {"-b", "--body", "-t", "--title", "-m", "--message", "-c", "--comment",
              "-f", "--field", "--raw-field", "-n", "--notes"}
FILE_FLAGS = {"-F", "--body-file", "--file", "--input", "--notes-file"}
SHORT_TEXT = {f for f in TEXT_FLAGS if len(f) == 2}
SHORT_FILE = {f for f in FILE_FLAGS if len(f) == 2}
REPO_FLAGS = {"-R", "--repo"}

pieces, repo, unreadable = [], "", []

def read_value(path):
    # The text of a file. "-" is stdin (a heredoc), which this hook cannot see.
    try:
        if path == "-":
            raise OSError("stdin")
        pieces.append(pathlib.Path(path).read_text(encoding="utf-8", errors="replace"))
    except OSError:
        unreadable.append(path)

def file_value(value):
    # gh api -F/--field key=value is a field, and key=@path reads a file.
    if "=" in value and not pathlib.Path(value).exists():
        field = value.split("=", 1)[1]
        if field.startswith("@"):
            read_value(field[1:])
        else:
            pieces.append(field)
        return
    read_value(value)

i = 0
while i < len(args):
    a = args[i]
    nxt = args[i + 1] if i + 1 < len(args) else None
    if a in REPO_FLAGS and nxt:
        repo = nxt
        i += 2
        continue
    if a in TEXT_FLAGS and nxt is not None:
        pieces.append(nxt)
        i += 2
        continue
    if a in FILE_FLAGS and nxt is not None:
        file_value(nxt)
        i += 2
        continue
    # Short flags also take their value attached: -bTEXT, -mTEXT.
    if len(a) > 2 and a[:2] in SHORT_TEXT | SHORT_FILE and a[2] != "=":
        a = a[:2] + "=" + a[2:]
    for flag in TEXT_FLAGS | FILE_FLAGS:
        if a.startswith(flag + "="):
            value = a.split("=", 1)[1]
            if flag in FILE_FLAGS:
                file_value(value)
            else:
                pieces.append(value)
            break
    i += 1

if unreadable:
    print("VERDICT\tunreadable")
    print("REPO\t%s\t%s" % (repo, "\x1f".join(pub_dirs)))
    print("TEXT")
    sys.stdout.write("\n".join(unreadable))
    sys.exit(0)
if not pieces:
    sys.exit(0)
print("VERDICT\tcheck")
print("REPO\t%s\t%s" % (repo, "\x1f".join(pub_dirs)))
print("TEXT")
sys.stdout.write("\n".join(pieces))
PY
)"
parse_rc=$?
fi

# The decision follows the checkers exactly: 0 allow, 1 refuse with the
# reason, anything else refuse as "could not check" unless the user set
# SECURITY_GATE_ALLOW_UNCHECKED=1. Refusal is exit 2 with the reason on stderr,
# which Claude Code returns to the agent and does not run the command.
reason=""
unchecked() {  # <what>
  if [[ "${SECURITY_GATE_ALLOW_UNCHECKED:-}" == 1 ]]; then
    echo "WARNING: $1 could not run; SECURITY_GATE_ALLOW_UNCHECKED=1, allowed unchecked." >&2
    return 0
  fi
  {
    echo "$1 could not run, so this text was NOT checked; refused."
    [[ -n "$reason" ]] && { echo; printf '%s\n' "$reason"; }
    echo
    echo "Fix the cause, or ask the user to allow it once with SECURITY_GATE_ALLOW_UNCHECKED=1."
    echo "Do not set it yourself."
  } >&2
  exit 2
}

if [[ "$parse_rc" -ne 0 ]]; then
  reason="the command parser exited $parse_rc"
  unchecked "The publishing-command parser"
  exit 0
fi
# ------------------------------------------------------------ whole command
# Every Bash call, whatever it looks like: classifying commands as publishing
# or not was the gap every bypass used (bash -c, $(...), aliases, quoting).
#   - --no-verify, git commit -n and any core.hooksPath override: refused;
#   - setting the gate's own overrides or configuration: refused;
#   - eval, xargs, source or a variable as the command next to a publishing
#     verb: refused, it cannot be read;
#   - the whole command text (also with quoting removed) plus every file it
#     names that can be read (--body-file X, -F X, @X, < X): private names and
#     sensitive data. The parsed text further down adds the strict checks.
#   - scope for sensitive data: the owners (config) against the session
#     directory, every cd <dir> and -C <dir>, and -R/--repo; any one of them an
#     owner's, or a directory that cannot be entered: checked.
SENSITIVE="${SCRIPT_DIR}/../check_sensitive.sh"
# Overrides count only from this hook's own environment, set by the user. A
# command that sets one, or the gate's configuration, for what it runs is
# refused: SECURITY_GATE_ALLOW_UNCHECKED=1 git push would switch off the git
# hook's refusal from inside the call being judged.
OVERRIDE_RE='(SECURITY_GATE_ALLOW_UNCHECKED|SENSITIVE_ALLOW[A-Z_]*|SENSITIVE_NO_MACHINE|SENSITIVE_MACHINE_IDS_FILE|SENSITIVE_TERMS_FILE|SENSITIVE_PUBLIC_IP_CACHE|PRIVATE_NAMES_ALLOW|PRIVATE_NAMES_FILE|PRIVATE_NAMES_AUTO_REFRESH|GITLEAKS_BIN|SCRIPT_HELPERS_OWNERS|SCRIPT_HELPERS_SECURITY_DIR|SCRIPT_HELPERS_HOOKS_HOME|XDG_CONFIG_HOME|HOME)=|(^|[^[:alnum:]_])(export|declare|typeset|unset)[[:space:]][^;&|]*(SECURITY_GATE_|SENSITIVE_|PRIVATE_NAMES_|GITLEAKS_BIN|SCRIPT_HELPERS_)|script-helpers\.(owners|trust-repo-hooks)|(>|tee|cp|mv|rm|ln|sed[[:space:]]+-i|truncate|chmod)[^;&|]*(sensitive-allow|sensitive-terms|private-names[.-])'
# Obfuscated command words: quotes and backslashes removed (g''it, "git",
# \git, $'git'), then eval, xargs, source and variable indirection ($G push,
# ${X:-git}) next to a publishing verb cannot be read, so they are refused.
INDIRECT_RE='(^|[^[:alnum:]_])(eval|xargs|source)([^[:alnum:]_]|$)|(^|[;&|(`])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*\$\{?[A-Za-z_]|(^|[;&|(`])[[:space:]]*\.[[:space:]]'
VERB_RE='(^|[^[:alnum:]_-])(push|commit|tag|pr|issue|release|api|gist)([^[:alnum:]_-]|$)|github'
cmd_file="${payload_file}.cmd"
: > "$cmd_file"
{
  if [[ "$HAVE_PY" != true ]] || ! "$PY" -I -c '
import json, sys
def walk(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for x in v.values():
            yield from walk(x)
    elif isinstance(v, list):
        for x in v:
            yield from walk(x)
d = json.load(open(sys.argv[1], encoding="utf-8"))
ti = d.get("tool_input") or {}
if d.get("tool_name") == "Bash" and isinstance(ti, dict):
    sys.stdout.write(ti.get("command") or "")
else:
    sys.stdout.write("\n".join(walk(ti)))
' "$payload_file" > "$cmd_file" 2>/dev/null; then
    # Not readable as a payload: the raw bytes are the text to check.
    cp "$payload_file" "$cmd_file" 2>/dev/null || { reason="could not copy the payload"; unchecked "Reading the command"; }
    if [[ "$HAVE_PY" != true ]] && grep -qE "$PUBLISH_RE" "$payload_file"; then
      reason="python3 is missing, so the publishing command cannot be parsed"
      unchecked "Parsing the command"
    fi
  fi
  # The same text with quoting removed, as bash would see the words.
  tr -d "'\"\\\\" < "$cmd_file" > "$cmd_file.plain" || { reason="could not prepare the command text"; unchecked "Reading the command"; }
  # The override and indirection checks read the command without the body of
  # a here-document that only becomes a file: `cat > f <<'EOF'` or `tee f
  # <<'EOF'` alone on its line, nothing piped or chained, the delimiter quoted
  # (unquoted, bash expands $(...) in the body). That body is data, and
  # a test or a doc that mentions HOME= or the owners key is not an override.
  # Running the file later is a separate call, checked then. The names and
  # sensitive scans below still read the body.
  awk -v sq="'" '
    BEGIN { re = "^[[:space:]]*(cat|tee)[[:space:]][^|;&`$()<]*<<-?[[:space:]]*(" sq "[A-Za-z_][A-Za-z0-9_]*" sq "|\"[A-Za-z_][A-Za-z0-9_]*\")[[:space:]]*$" }
    skip != "" { t = $0; if (strip_tabs) sub(/^\t+/, "", t); if (t == skip) skip = ""; next }
    {
      print
      if ($0 ~ re && ($0 ~ />/ || $0 ~ /^[[:space:]]*tee[[:space:]]/)) {
        d = $0; sub(/.*<<-?[[:space:]]*/, "", d); gsub("[" sq "\" \t]", "", d)
        strip_tabs = ($0 ~ /<<-/); skip = d
      }
    }' "$cmd_file" > "$cmd_file.code" || { reason="could not prepare the command text"; unchecked "Reading the command"; }
  tr -d "'\"\\\\" < "$cmd_file.code" > "$cmd_file.codeplain" || { reason="could not prepare the command text"; unchecked "Reading the command"; }
  if grep -qE -- "$OVERRIDE_RE" "$cmd_file.code"; then
    rm -f "$cmd_file" "$cmd_file.plain" "$cmd_file.code" "$cmd_file.codeplain"
    echo "Refusing a command that sets the security gate's own overrides or configuration" >&2
    echo "(SECURITY_GATE_ALLOW_UNCHECKED, *_ALLOW, the owners, the name or terms lists)." >&2
    echo "Only the user sets those, outside the command. Ask them." >&2
    exit 2
  fi
  if grep -qiE -- "$VERB_RE" "$cmd_file.codeplain" && grep -qE -- "$INDIRECT_RE" "$cmd_file.codeplain"; then
    rm -f "$cmd_file" "$cmd_file.plain" "$cmd_file.code" "$cmd_file.codeplain"
    echo "Refusing a command that may publish through eval, xargs, source or a variable as" >&2
    echo "the command: this hook cannot read what it would run. Write the command out plainly." >&2
    exit 2
  fi
  cat "$cmd_file.plain" >> "$cmd_file"
  rm -f "$cmd_file.plain" "$cmd_file.code" "$cmd_file.codeplain"
}
# names_check <text file> [gate args]: the private-name check. 0: clean.
# 1: a hit. Else: could not check. reason is set on 1 and above. The
# prefilter only skips text that cannot match.
names_check() {
  local f="$1" rc out pc=0
  shift
  private_name_candidate "$f" || pc=$?
  [[ "$pc" -eq 1 ]] && return 0      # no listed name in the text; awk failing (2+) runs the full check
  if [[ ! -f "$GATE" ]]; then reason="check_private_names.sh is missing next to this hook"; return 2; fi
  out="$(bash "$GATE" --stdin "$@" < "$f" 2>&1)"; rc=$?
  if [[ "$rc" -ne 0 ]]; then reason="$out"; return "$rc"; fi
  return 0
}
if [[ -s "$cmd_file" ]]; then
    if grep -qiE -- '--no-ver|core\.hookspath|GIT_CONFIG_(COUNT|KEY|VALUE|PARAMETERS|GLOBAL|SYSTEM|NOSYSTEM)|GIT_CONFIG=|include\.path|includeif\.' "$cmd_file" \
       || grep -qE -- '(^|[^[:alnum:]_-])commit([[:space:]][^;&|]*)?[[:space:]]-[abeiopqsuvz]*n[a-zA-Z]*([[:space:]]|$)' "$cmd_file"; then
      rm -f "$cmd_file"
      echo "Refusing a command that skips or replaces the git hooks (--no-verify, git commit -n," >&2
      echo "a core.hooksPath override, or another git config source). If a hook is wrong, say which one and let the user decide." >&2
      exit 2
    fi
    broad_text="${payload_file}.text"
    # The same text the decision reads: nothing is removed before the scan.
    cp "$cmd_file" "$broad_text" \
      || { reason="could not prepare the command text"; unchecked "Reading the command"; }
    while IFS= read -r f; do
      f="${f#@}"; f="${f#\'}"; f="${f%\'}"; f="${f#\"}"; f="${f%\"}"   # "$(<f)" and "$(cat f)": the ")" and quotes went in sed
      [[ -n "$f" && "$f" != "-" && -f "$f" && -r "$f" ]] && { printf '\n'; head -c 2000000 "$f"; } >> "$broad_text"   # a body is never that large; a log might be
    done < <(grep -oE -- '(--body-file|--notes-file|--input|--file|-F)[= ]+[^;&|[:space:]]+|@[^;&|[:space:]]+|<[[:space:]]*[^<;&|[:space:]]+|\$\([[:space:]]*cat[[:space:]]+[^;&|)[:space:]]+' "$cmd_file" \
               | sed -E 's/^\$\([[:space:]]*cat[[:space:]]+//; s/^(--body-file|--notes-file|--input|--file|-F)[= ]+//; s/^<[[:space:]]*//; s/^[^=@]*=@?//; s/[)"'"'"']+$//')
    rc=0
    names_check "$broad_text" || rc=$?
    if [[ "$rc" -eq 1 ]]; then
      { echo "This command names a private repository, and the destination is public."
        echo; printf '%s\n' "$reason"; echo
        echo "Cite the repository by its code instead. Ask the user before overriding."; } >&2
      rm -f "$cmd_file" "$broad_text"; exit 2
    elif [[ "$rc" -ne 0 ]]; then
      rm -f "$cmd_file" "$broad_text"; unchecked "The private-name check (exit $rc)"
    fi
    if [[ -f "$SENSITIVE" ]]; then
      # The whole command names local paths, so this machine's identifiers
      # are left out here; the parsed text below is checked with them.
      reason="$(bash "$SENSITIVE" --stdin --no-machine --no-inline-allow < "$broad_text" 2>&1)"
      rc=$?
      if [[ "$rc" -eq 1 ]]; then
        { echo "This command carries a credential, a personal identifier or PII."
          echo; printf '%s\n' "$reason"; echo
          echo "Remove it. If this is a false positive, ask the user before allowing it."; } >&2
        rm -f "$cmd_file" "$broad_text"; exit 2
      elif [[ "$rc" -ne 0 ]]; then
        rm -f "$cmd_file" "$broad_text"; unchecked "The sensitive-data check (exit $rc)"
      fi
    else
      reason="check_sensitive.sh is missing next to this hook"
      rm -f "$cmd_file" "$broad_text"; unchecked "The sensitive-data check"
    fi
    rm -f "$broad_text"
fi
rm -f "$cmd_file"

# Allowed: the whole text passed above, and the parser found nothing it
# publishes (or python3 is missing and nothing looked like publishing).
[[ -z "$parsed" ]] && exit 0

if [[ "$parsed" == "VERDICT"$'\t'"bad-payload"* ]]; then
  # Scanned whole above. Allowed only when it does not look like publishing.
  grep -qE "$PUBLISH_RE" "$payload_file" || exit 0
  reason="the hook payload is not valid JSON"
  unchecked "Reading the command"
  exit 0
fi

verdict="$(printf '%s' "$parsed" | sed -n '1s/^VERDICT\t//p')"
text="$(printf '%s' "$parsed" | sed -n '4,$p')"

if [[ "$verdict" == "no-verify" ]]; then
  echo "Refusing --no-verify: it skips the local gate that checks this commit for" >&2
  echo "the name of a private repository, among other things. If a hook is wrong," >&2
  echo "say which one and let the user decide -- do not bypass it unasked." >&2
  exit 2
fi
if [[ "$verdict" == "unreadable" ]]; then
  reason="body file(s) this hook cannot read: $(printf '%s' "$text" | tr '\n' ' ')(use a real file with --body-file, not stdin)"
  unchecked "Reading the text to publish"
  exit 0
fi

[[ "$verdict" == "check" || "$verdict" == "check-unparsed" ]] || exit 0

# Strict here, warn elsewhere: nothing reads a warning from a hook that then
# allows the call. Strict only when a publishing command was actually
# identified (see the unparseable fallback above).
gate_args=()
[[ "$verdict" == "check" ]] && gate_args+=(--strict-ambiguous)
printf '%s' "$text" > "${payload_file}.parsed"
rc=0
names_check "${payload_file}.parsed" ${gate_args[@]+"${gate_args[@]}"} || rc=$?
rm -f "${payload_file}.parsed"
case "$rc" in
  0) ;;
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
  *) unchecked "The private-name check (exit $rc)" ;;
esac

# Then credentials, personal identifiers and PII in the parsed text. An
# unparsed command is the whole command line, which names local paths, so
# there this machine's identifiers are left out (--no-machine).
if [[ ! -f "$SENSITIVE" ]]; then
  reason="check_sensitive.sh is missing next to this hook"
  unchecked "The sensitive-data check"
  exit 0
fi

# The agent wrote the text, so a sensitive:allow marker in it is not the user's.
sens_args=(--stdin --no-inline-allow)
if [[ "$verdict" == "check-unparsed" ]]; then
  # Any command shlex cannot split lands here, most of them not publishing
  # anything. Only one that names a publishing command is scanned.
  printf '%s' "$text" | grep -qE "$PUBLISH_RE" || exit 0
  sens_args+=(--no-machine)
fi
reason="$(printf '%s' "$text" | bash "$SENSITIVE" "${sens_args[@]}" 2>&1)"
rc=$?
case "$rc" in
  0) exit 0 ;;
  1)
    {
      echo "This text carries a credential, a personal identifier or PII."
      echo
      printf '%s\n' "$reason"
      echo
      echo "Remove it. If this is a false positive, ask the user before allowing it."
    } >&2
    exit 2
    ;;
  *) unchecked "The sensitive-data check (exit $rc)" ;;
esac
exit 0
