#!/usr/bin/env bash
# SCRIPT: setup-hooks.sh
# DESCRIPTION: Configure git to use shared or repository-local hook scripts, and install the Claude Code security hook.
# USAGE: bash scripts/setup-hooks.sh [--claude-repo|--agent-repo <list>|--global|--claude|--agent <list>|--all|--managed] [--uninstall] | --repair | --status [--porcelain] | --doctor | --install-gitleaks | --install-foxguard
# PARAMETERS:
#   (none)        Set up this repository. With no hooks running here yet, point its
#                 core.hooksPath at the shared hooks. If hooks already run (a local or
#                 global core.hooksPath set by another tool, or .git/hooks), keep them:
#                 save the old value in .git/config and chain, in order, the security
#                 checks (owners' repositories only), this repository's committed
#                 hooks, then the hooks that ran before. Only untracked files change.
#                 --uninstall alone undoes it and restores the previous value.
#   --global      Install the git hooks machine-wide: copy them, with their own copy of
#                 the check scripts, to <data>/script-helpers/git-hooks and set the
#                 GLOBAL core.hooksPath there, after printing the old value and saving it.
#   --claude      Install the Claude Code PreToolUse hook for this user: copy it to
#                 <data>/script-helpers/claude-hooks and add one entry to
#                 ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json (matcher Bash, timeout
#                 60 s, shell bash). Every other key and hook in the file is kept; an
#                 older entry for the same hook is replaced; a backup is written first.
#   --claude-repo Install the Claude Code hook for this repository only: one entry in
#                 .claude/settings.local.json, listed in .git/info/exclude so it is never
#                 committed; backups go under .git/script-helpers/. With --uninstall:
#                 remove it, and the file too when this script created it.
#   --agent-repo <list>  The same check for other AI agents, this repository only.
#                 <list>: codex, gemini, copilot, cursor, comma-separated, or all.
#                 Writes our entry into the agent's project hook file, listed in
#                 .git/info/exclude so it is never committed; other entries stay:
#                   codex    .codex/hooks.json            (PreToolUse, matcher Bash)
#                   gemini   .gemini/settings.json        (BeforeTool, run_shell_command)
#                   copilot  .github/hooks/script-helpers.json (preToolUse, bash|powershell)
#                   cursor   .cursor/hooks.json           (beforeShellExecution, failClosed)
#                 Each runs scripts/agent-hooks/agent_hook.sh <agent> from a copy in
#                 <data>/script-helpers/agent-repo-hooks. Codex and Gemini ask you to
#                 trust a project hook before it runs (Codex: /hooks). With
#                 --uninstall: remove our entry, and the file when this script made it.
#   --agent <list>  The same for this user: ~/.codex/hooks.json, ~/.gemini/settings.json,
#                 ${COPILOT_HOME:-~/.copilot}/hooks/script-helpers.json, ~/.cursor/hooks.json;
#                 copy in <data>/script-helpers/agent-hooks.
#   --all         --global and --claude.
#   --managed     Install the Claude hook into the OS managed settings file instead,
#                 which no user or project setting can turn off. Needs admin rights;
#                 refuses (exit 2) without write access, and never runs sudo itself.
#                   Linux    /etc/claude-code/managed-settings.json
#                   macOS    /Library/Application Support/ClaudeCode/managed-settings.json
#                   Windows  C:\Program Files\ClaudeCode\managed-settings.json
#                 The hook copy goes to script-helpers/ next to that file.
#   --uninstall   With --global, --claude, --all or --managed: undo that install.
#                 Other settings and hooks are left as they are.
#   --repair      In this repository: if another tool replaced core.hooksPath after
#                 the setup here (husky does on npm install), chain again: the new
#                 value becomes the previous one, so its hooks and ours both run. The
#                 value it replaced is kept as script-helpers.previous-hooksPath-history.
#                 Also chains a direct setup that runs the repository's own hooks
#                 without the current security checks (unscanned=yes below).
#                 Also sets up again a setup whose hooks directory is gone (broken=yes).
#                 Nothing to repair: exit 0. Not set up here: exit 1.
#   --status      Show what is installed, and the prerequisites.
#   --porcelain   With --status, in a repository: one line of tab-separated key=value
#                 fields for scripts: mode (chained, direct, none), taken_over (yes,
#                 no), core_hooksPath, expected, previous, target, claude_repo (yes,
#                 no), global (yes when the --global hooks run here), agents (the
#                 other agents with our hook here, comma-separated), unscanned (yes when
#                 a direct setup points at hooks other than this copy's own, such as
#                 an older vendored script-helpers or .githooks, so the current
#                 security checks do not run; --repair chains them), broken (yes when
#                 core.hooksPath names a missing directory, or our setup's has no
#                 pre-push, so no push checks run; --repair sets it up again).
#                 With --claude, anywhere: claude_user (ok; absent; unknown: no
#                 Python to read the settings; broken: the script it runs is
#                 missing; stale: it runs a file outside the installed copy, such
#                 as a checkout), hook, installed (version).
#   --doctor      The prerequisites, then four probes through the installed Claude
#                 hook, from a throwaway repository under the first owner: a private
#                 name from your list, an SSN-shaped number, and git push --no-verify
#                 (each must be refused for that reason, with the deny decision on
#                 stdout), and ls (must pass), with the time each took. A refusal for
#                 another reason (no name list, no gitleaks) is a failure. Exit 1 on
#                 any failure.
#   --install-gitleaks  Download the pinned gitleaks (SHA-256 checked) into the cache.
#   --install-foxguard  Download the pinned foxguard (SHA-256 checked) into the cache.
#   Every install offers both (asked on a terminal, printed otherwise); a push
#   with one missing installs it (not in CI, nor with
#   SCRIPT_HELPERS_NO_AUTO_INSTALL=1), and says what did not run when it cannot.
#   <data> is %LOCALAPPDATA% on Windows (Git Bash), else ${XDG_DATA_HOME:-~/.local/share}.
#   Installing refuses (exit 2) until owners are configured:
#     git config --global script-helpers.owners <user-or-org>[,<another>]
#   Only those owners' github.com repositories are checked; every other repository
#   runs only its own hooks. See docs/security-gates.md.
#   Hook directory priority (no option):
#     1. .githooks/  (repo-local overrides with both pre-commit and pre-push)
#     2. git-hooks/ next to this script: the hooks bundled with this copy of
#        script-helpers, wherever it is vendored (scripts/script-helpers,
#        vendor/script-helpers, ...) or script-helpers' own scripts/git-hooks
#     3. scripts/script-helpers/scripts/git-hooks/, then scripts/git-hooks/
#   Only this copy's own bundled hooks are used directly. Any other hooks
#   directory (.githooks, an older vendored script-helpers) runs chained after
#   the current security checks, so a clone is never only as safe as its copy.
#   The shared pre-push hands over to .githooks/pre-push when a repository has
#   one (for example the protected-refs guard), so a repository with only
#   .githooks/pre-push gets the shared hooks and still runs its own.
#   The pre-push hook blocks on security, hygiene and lint of the changed files
#   (scripts/push_checks.sh); it runs no tests (make test or ./dev test)
#   unless the repository opts in: git config script-helpers.push-tests quick. git
#   holds the push's connection open meanwhile. Over SSH a long run (a first or
#   very large push) is cut off (exit 141) unless a
#   keepalive is set: ~/.ssh/config "Host github.com" + "ServerAliveInterval 20"
#   (every repository), git config core.sshCommand "ssh -o ServerAliveInterval=20"
#   (one repository), or GIT_SSH_COMMAND="ssh -o ServerAliveInterval=20" git push
#   (one push). HTTPS remotes are not affected. The hook and --status say so.
# EXIT_CODES:
#   0 done; 1 failed (or a --doctor probe failed); 2 refused (no owners, no
#   Python 3, no write access, bad arguments); 3 settings.json is not valid JSON
# ----------------------------------------------------
# After running, hooks are active for all subsequent git operations in this repo.
set -euo pipefail

GLOBAL=false; CLAUDE=false; CLAUDE_REPO=false; MANAGED=false; UNINSTALL=false; STATUS=false; DOCTOR=false; GITLEAKS=false; FOXGUARD=false
REPAIR=false; PORCELAIN=false; AGENT_REPO=""; AGENT_USER=""; CLAUDE_FLAG=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --global) GLOBAL=true ;;
    --claude) CLAUDE=true; CLAUDE_FLAG=true ;;
    --claude-repo) CLAUDE_REPO=true ;;
    --all) GLOBAL=true; CLAUDE=true ;;
    --managed) MANAGED=true ;;
    --uninstall) UNINSTALL=true ;;
    --status) STATUS=true ;;
    --porcelain) PORCELAIN=true ;;
    --repair) REPAIR=true ;;
    --agent-repo|--agent)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { echo "[setup-hooks] $1 needs a list: codex,gemini,copilot,cursor or all" >&2; exit 2; }
      [[ "$1" == --agent-repo ]] && AGENT_REPO="$2" || AGENT_USER="$2"
      shift ;;
    --doctor) DOCTOR=true ;;
    --install-gitleaks) GITLEAKS=true ;;
    --install-foxguard) FOXGUARD=true ;;
    -h|--help) sed -n '2,/^# ------/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[setup-hooks] unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ "$CLAUDE_REPO" == true ]] && [[ "$GLOBAL" == true || "$CLAUDE" == true || "$MANAGED" == true ]]; then
  echo "[setup-hooks] --claude-repo is for this repository only; run it on its own, not with --global, --claude, --all or --managed" >&2; exit 2
fi
# agent_list <list>: the agents named, one per line; refuses an unknown name (exit 2).
agent_list() {
  local a out=""
  [[ "$1" == all ]] && { printf '%s\n' codex gemini copilot cursor; return 0; }
  for a in ${1//,/ }; do
    case "$a" in codex|gemini|copilot|cursor) out="$out$a"$'\n' ;;
      claude) echo "[setup-hooks] Claude Code has its own options: --claude-repo, --claude" >&2; exit 2 ;;
      *) echo "[setup-hooks] unknown agent '$a': codex, gemini, copilot, cursor or all" >&2; exit 2 ;;
    esac
  done
  printf '%s' "$out"
}
AGENTS_REPO=""; AGENTS_USER=""
if [[ -n "$AGENT_REPO" ]]; then AGENTS_REPO="$(agent_list "$AGENT_REPO")" || exit 2; fi
if [[ -n "$AGENT_USER" ]]; then AGENTS_USER="$(agent_list "$AGENT_USER")" || exit 2; fi
if [[ -n "$AGENT_REPO" || -n "$AGENT_USER" ]] && \
   [[ "$GLOBAL" == true || "$CLAUDE" == true || "$MANAGED" == true || "$CLAUDE_REPO" == true || "$STATUS" == true || "$REPAIR" == true || ( -n "$AGENT_REPO" && -n "$AGENT_USER" ) ]]; then
  echo "[setup-hooks] --agent-repo and --agent run on their own (with --uninstall at most)" >&2; exit 2
fi
if [[ "$PORCELAIN" == true && "$STATUS" != true ]]; then
  echo "[setup-hooks] --porcelain goes with --status" >&2; exit 2
fi
# A status call never writes: before, --global, --all or --managed with
# --status --porcelain fell through to the install.
if [[ "$PORCELAIN" == true ]] && [[ "$GLOBAL" == true || "$MANAGED" == true || "$CLAUDE_REPO" == true || "$UNINSTALL" == true || "$REPAIR" == true || "$DOCTOR" == true || ( "$CLAUDE" == true && "$CLAUDE_FLAG" != true ) ]]; then
  echo "[setup-hooks] --status --porcelain takes only --claude" >&2; exit 2
fi
if [[ "$REPAIR" == true ]] && [[ "$GLOBAL" == true || "$CLAUDE" == true || "$MANAGED" == true || "$CLAUDE_REPO" == true || "$UNINSTALL" == true || "$STATUS" == true ]]; then
  echo "[setup-hooks] --repair is for this repository's git hooks; run it on its own" >&2; exit 2
fi
if [[ "$MANAGED" == true && "$CLAUDE" == true ]]; then
  echo "[setup-hooks] --managed is an alternative to --claude/--all, not an addition" >&2; exit 2
fi

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"    # this script-helpers copy

ON_WINDOWS=false
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=true ;; esac

# unix_path <path>: a Windows path (C:\x) as Git Bash sees it; others unchanged.
unix_path() {
  if [[ "$ON_WINDOWS" == true ]] && command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}
# native_path <path>: the form a Windows program reads (C:/x); others unchanged.
native_path() {
  if [[ "$ON_WINDOWS" == true ]] && command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

if [[ "$ON_WINDOWS" == true && -n "${LOCALAPPDATA:-}" ]]; then
  data_base="$(unix_path "$LOCALAPPDATA")"
else
  data_base="${XDG_DATA_HOME:-${HOME:-}/.local/share}"
fi
global_dir="${SCRIPT_HELPERS_HOOKS_HOME:-$data_base/script-helpers/git-hooks}"
global_hooks="$(native_path "$global_dir/hooks")"   # as git stores it (C:/... on Windows)
backup_file="$global_dir/previous-hooksPath"
# The per-repository copy: separate from the global one, so --global --uninstall
# never breaks a repository that chains through it.
repo_hooks_dir="${SCRIPT_HELPERS_REPO_HOOKS_HOME:-$data_base/script-helpers/repo-hooks}"
repo_hooks="$(native_path "$repo_hooks_dir/hooks")"
claude_settings="$(unix_path "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}")/settings.json"
claude_home="$data_base/script-helpers/claude-hooks"
# Per-repository installs use their own copy, so removing the user-wide hook
# never breaks a repository that points at it.
claude_repo_home="$data_base/script-helpers/claude-repo-hooks"
if [[ -n "${SCRIPT_HELPERS_MANAGED_SETTINGS:-}" ]]; then
  managed_settings="$(unix_path "$SCRIPT_HELPERS_MANAGED_SETTINGS")"
else
  case "$(uname -s)" in
    Darwin) managed_settings="/Library/Application Support/ClaudeCode/managed-settings.json" ;;
    MINGW*|MSYS*|CYGWIN*) managed_settings="$(unix_path 'C:\Program Files\ClaudeCode')/managed-settings.json" ;;
    *) managed_settings="/etc/claude-code/managed-settings.json" ;;
  esac
fi
managed_home="$(dirname "$managed_settings")/script-helpers"
HOOK_REL="scripts/claude-hooks/pretooluse_private_names.sh"
MERGE_REL="scripts/claude-hooks/merge_settings.py"
AGENT_HOOK_REL="scripts/agent-hooks/agent_hook.sh"
AGENT_MERGE_REL="scripts/agent-hooks/merge_agent_hooks.py"
agent_user_home="$data_base/script-helpers/agent-hooks"
agent_repo_home="$data_base/script-helpers/agent-repo-hooks"
# Every hook git runs from core.hooksPath: with a global hooksPath set, git no
# longer reads .git/hooks, so each one needs a wrapper that chains to it.
GLOBAL_HOOK_NAMES="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push post-rewrite push-to-checkout pre-auto-gc sendemail-validate reference-transaction post-index-change"

configured_owners() {
  local o u
  if [[ -n "${SCRIPT_HELPERS_OWNERS:-}" ]]; then printf '%s' "$SCRIPT_HELPERS_OWNERS"; return; fi
  o="$(git config --global --get script-helpers.owners 2>/dev/null || true)"
  u="$(git config --global --get script-helpers.github-user 2>/dev/null || true)"
  printf '%s' "${u}${u:+${o:+,}}${o}"
}

# detect_github_user: record the signed-in GitHub account (gh) as
# script-helpers.github-user, once. Its repositories are then checked without
# listing it in script-helpers.owners. No gh, not signed in: nothing changes.
detect_github_user() {
  local u
  [[ -z "${SCRIPT_HELPERS_OWNERS:-}" ]] || return 0
  [[ -z "$(git config --global --get script-helpers.github-user 2>/dev/null || true)" ]] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  # Bounded where timeout(1) exists (not on stock macOS): a dead network must
  # not hang setup.
  if command -v timeout >/dev/null 2>&1; then
    u="$(GH_PROMPT_DISABLED=1 timeout 15 gh api user --jq .login 2>/dev/null || true)"
  else
    u="$(GH_PROMPT_DISABLED=1 gh api user --jq .login 2>/dev/null || true)"
  fi
  [[ "$u" =~ ^[A-Za-z0-9-]+$ ]] || return 0
  git config --global script-helpers.github-user "$u" || return 0
  echo "[setup-hooks] Your GitHub account, $u, is checked (git config --global script-helpers.github-user)."
}

require_owners() {
  detect_github_user
  if [[ -z "$(configured_owners)" ]]; then
    echo "[setup-hooks] ERROR: no owners configured, so the hooks would check nothing." >&2
    echo "[setup-hooks] Sign in to gh (gh auth login) so your account is found, or set it, then run this again:" >&2
    echo "[setup-hooks]   git config --global script-helpers.owners <user-or-org>[,<another>]" >&2
    exit 2
  fi
}

# python3, else a "python" that is 3.x (Windows names it python.exe; its
# "python3" may be a store stub that does not run).
PY=""
for _c in python3 python; do
  if command -v "$_c" >/dev/null 2>&1 && "$_c" -I -c 'import sys; sys.exit(sys.version_info[0] != 3)' >/dev/null 2>&1; then
    PY="$_c"; break
  fi
done

version_stamp() {
  printf '%s %s\n' "$(git -C "$src_root" describe --tags --always 2>/dev/null || cat "$src_root/VERSION" 2>/dev/null || echo unknown)" "$(date -u +%Y-%m-%d)"
}

# stage_and_swap <dest> <stage>: move the staged scripts/, lib/, hooks/ (when
# present), helpers.sh and VERSION into <dest>. Stage, then swap: a half-copied
# install must never be what runs.
stage_and_swap() {
  local dest="$1" stage="$2" name
  rm -rf "$dest/scripts.old" "$dest/hooks.old" "$dest/lib.old" "$dest/config.old"
  for name in scripts hooks lib config; do
    [[ -e "$stage/$name" ]] || continue
    [[ -e "$dest/$name" ]] && mv "$dest/$name" "$dest/$name.old"
    mv "$stage/$name" "$dest/$name"
  done
  mv -f "$stage/helpers.sh" "$dest/helpers.sh"; mv -f "$stage/VERSION" "$dest/VERSION"
  rm -rf "$stage" "$dest/scripts.old" "$dest/hooks.old" "$dest/lib.old" "$dest/config.old"
}

# stage_common <dest>: a new stage directory with helpers.sh, lib/ and the check
# scripts every hook runs. Prints its path.
stage_common() {
  local stage name
  mkdir -p "$1" || return 1
  stage="$(mktemp -d "$1/.stage.XXXXXX")" || return 1
  mkdir -p "$stage/scripts" || return 1
  cp "$src_root/helpers.sh" "$stage/" && cp -R "$src_root/lib" "$stage/lib" || { rm -rf "$stage"; return 1; }
  # The default allow list check_private_names.sh seeds a machine's list from.
  if [[ -f "$src_root/config/private-names-allow" ]]; then
    mkdir -p "$stage/config" && cp "$src_root/config/private-names-allow" "$stage/config/" || { rm -rf "$stage"; return 1; }
  fi
  for name in owner_scope.sh check_sensitive.sh check_private_names.sh refresh_private_names.sh ssh_keepalive.sh push_checks.sh run_repo_tests.sh foxguard_report.sh; do
    cp "$src_root/scripts/$name" "$stage/scripts/$name" || { rm -rf "$stage"; return 1; }
  done
  version_stamp > "$stage/VERSION"
  printf '%s\n' "$stage"
}

gitleaks_found() {
  # The order check_sensitive.sh uses: when GITLEAKS_BIN is set, only it counts.
  if [[ -n "${GITLEAKS_BIN:-}" ]]; then [[ -x "$GITLEAKS_BIN" ]]; return; fi
  command -v gitleaks >/dev/null 2>&1 && return 0
  ( # shellcheck source=/dev/null
    source "$src_root/helpers.sh" && shlib_import logging foxguard gitleaks >/dev/null 2>&1 && gitleaks_bin >/dev/null 2>&1 )
}

foxguard_found() {
  if [[ -n "${FOXGUARD_CMD:-}" ]]; then return 0; fi
  command -v foxguard >/dev/null 2>&1 && return 0
  ( # shellcheck source=/dev/null
    source "$src_root/helpers.sh" && shlib_import logging foxguard >/dev/null 2>&1 && foxguard_bin >/dev/null 2>&1 )
}

install_foxguard() {
  # shellcheck source=/dev/null
  ( source "$src_root/helpers.sh" && shlib_import logging foxguard && foxguard_install )
}

# offer_foxguard: as offer_gitleaks. Without it the push's static-analysis
# scan does not run (its findings are warnings, so nothing is refused).
offer_foxguard() {
  local answer=""
  foxguard_found && return 0
  echo "[setup-hooks] foxguard is missing. Without it the push's static-analysis scan does not run."
  if [[ -t 0 && -t 1 ]]; then
    printf '[setup-hooks] Install the pinned foxguard now (download, SHA-256 checked)? [y/N] '
    read -r answer || answer=""
  fi
  case "$answer" in
    y|Y|yes) install_foxguard || echo "[setup-hooks] foxguard install failed; see above." >&2 ;;
    *) echo "[setup-hooks] To install it later: bash $src_root/scripts/setup-hooks.sh --install-foxguard" ;;
  esac
}

install_gitleaks() {
  # shellcheck source=/dev/null
  ( source "$src_root/helpers.sh" && shlib_import logging foxguard gitleaks && gitleaks_install )
}

# offer_gitleaks: asked on a terminal, printed otherwise; never installed silently.
offer_gitleaks() {
  local answer=""
  gitleaks_found && return 0
  echo "[setup-hooks] gitleaks is missing. Without it the hook refuses publishing commands in your repositories."
  if [[ -t 0 && -t 1 ]]; then
    printf '[setup-hooks] Install the pinned gitleaks now (download, SHA-256 checked)? [y/N] '
    read -r answer || answer=""
  fi
  case "$answer" in
    y|Y|yes) install_gitleaks || echo "[setup-hooks] gitleaks install failed; see above." >&2 ;;
    *) echo "[setup-hooks] To install it later: bash $src_root/scripts/setup-hooks.sh --install-gitleaks" ;;
  esac
}

file_age_days() {  # <date YYYY-MM-DD>: days since then, or nothing
  [[ -n "$PY" ]] || return 0
  "$PY" -I -c 'import datetime,sys
try:
    d = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d").date()
    print((datetime.date.today() - d).days)
except ValueError:
    pass' "$1" 2>/dev/null || true
}

# prereqs: one line per prerequisite. Returns the number of missing required ones.
prereqs() {
  local missing=0 list terms stamp age perms owners
  echo "[setup-hooks] prerequisites:"
  printf '  bash      ok (%s)\n' "${BASH_VERSION:-?}"
  if [[ -n "$PY" ]]; then
    printf '  python    ok (%s: %s)\n' "$PY" "$("$PY" --version 2>&1)"
  else
    echo "  python    MISSING: install Python 3 (python3, or python on Windows)"; missing=$((missing+1))
  fi
  if command -v git >/dev/null 2>&1; then
    printf '  git       ok (%s)\n' "$(git --version 2>/dev/null)"
  else
    echo "  git       MISSING: install git"; missing=$((missing+1))
  fi
  if gitleaks_found; then
    echo "  gitleaks  ok"
  else
    echo "  gitleaks  MISSING: every command in your repositories is refused until it is installed;"
    echo "            bash $src_root/scripts/setup-hooks.sh --install-gitleaks"
  fi
  if foxguard_found; then
    echo "  foxguard  ok"
  else
    echo "  foxguard  WARN: the push's static-analysis scan does not run;"
    echo "            bash $src_root/scripts/setup-hooks.sh --install-foxguard"
  fi
  owners="$(configured_owners)"
  if [[ -n "$owners" ]]; then
    echo "  owners    ok ($owners)"
  else
    echo "  owners    MISSING: sign in to gh and run setup, or git config --global script-helpers.owners <user-or-org>"; missing=$((missing+1))
  fi
  list="${PRIVATE_NAMES_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/private-names.tsv}"
  if [[ -s "$list" ]]; then
    stamp="$(sed -n 's/^# generated: \([0-9-]*\).*/\1/p' "$list" | head -1)"
    age="$(file_age_days "$stamp")"
    echo "  names     ok ($list, generated ${stamp:-at an unknown date}${age:+, $age days ago})"
  else
    # Without a list the name check cannot run, so the hook refuses every
    # command in your repositories as "could not check".
    echo "  names     MISSING ($list): every command in your repositories is refused until it exists; run refresh_private_names.sh"
    missing=$((missing+1))
  fi
  # Not a refusal: without a keepalive a push whose pre-push checks run long is
  # cut off by GitHub (exit 141) after they pass.
  if command -v ssh >/dev/null 2>&1; then
    if [[ "$(ssh -G github.com 2>/dev/null | awk '$1 == "serveraliveinterval" { print $2; exit }')" =~ ^[1-9] ]]; then
      echo "  ssh       ok (keepalive set for github.com)"
    else
      echo "  ssh       WARN: no keepalive for github.com; a push with long pre-push checks can be cut off"
      echo "            (exit 141). In ~/.ssh/config: Host github.com / ServerAliveInterval 20"
    fi
  fi
  # Not required: push_checks.sh lints a file type only when its tool is here.
  local t have="" lack=""
  for t in shellcheck ruff actionlint gofmt rustfmt pwsh; do
    if command -v "$t" >/dev/null 2>&1; then have="$have $t"; else lack="$lack $t"; fi
  done
  echo "  lint      on push:${have:- none}${lack:+; not installed (those files are not linted):$lack}"
  terms="${SENSITIVE_TERMS_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/sensitive-terms.txt}"
  if [[ -f "$terms" ]]; then
    perms="$(ls -ld "$terms" | cut -c5-10)"
    if [[ "$perms" == "------" ]]; then
      echo "  terms     ok ($terms, readable by you only)"
    else
      echo "  terms     WARN: $terms is readable by others; chmod 600 it"
    fi
  else
    echo "  terms     none ($terms): only built-in patterns are checked"
  fi
  return "$missing"
}

show_global_status() {
  local cur local_path
  cur="$(git config --global --get core.hooksPath 2>/dev/null || true)"
  echo "[setup-hooks] global core.hooksPath: ${cur:-(unset)}"
  if [[ -n "$cur" && "$cur" == "$global_hooks" ]]; then
    echo "[setup-hooks] global hooks: installed at $global_dir ($(cat "$global_dir/VERSION" 2>/dev/null || echo unknown version))"
    echo "[setup-hooks] previous global value: $(cat "$backup_file" 2>/dev/null || echo '(none saved)')"
  else
    echo "[setup-hooks] global hooks: not active"
  fi
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local_path="$(git config --local --get core.hooksPath 2>/dev/null || true)"
    if [[ -n "$local_path" && "$local_path" == "$repo_hooks" ]]; then
      echo "[setup-hooks] this repository: chained: security checks (configured owners only)," \
        "then $(git config --local --get script-helpers.hooks-target 2>/dev/null || echo '(no committed hooks)')," \
        "then $(git config --local --get script-helpers.previous-hooksPath 2>/dev/null || echo 'the global core.hooksPath or .git/hooks')"
    elif [[ -n "$local_path" ]]; then
      echo "[setup-hooks] this repository: core.hooksPath = $local_path (overrides the global one; the checks run only if those hooks run them)"
    else
      echo "[setup-hooks] this repository: no local core.hooksPath; the global value applies"
    fi
    local expected
    expected="$(git config --local --get script-helpers.expected-hooksPath 2>/dev/null || true)"
    if [[ -n "$expected" && "$local_path" != "$expected" ]]; then
      echo "[setup-hooks] this repository: WARN: core.hooksPath was changed after the setup here (was $expected); our hooks do not run. Fix: setup-hooks.sh --repair"
    fi
    local top_dir
    top_dir="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$top_dir" && -f "$top_dir/.claude/settings.local.json" && -n "$PY" ]] && \
       "$PY" -I "$(native_path "$src_root/$MERGE_REL")" status "$(native_path "$top_dir/.claude/settings.local.json")" >/dev/null 2>&1; then
      echo "[setup-hooks] this repository: Claude hook in .claude/settings.local.json"
    fi
    local a agents=""
    for a in codex gemini copilot cursor; do
      [[ -n "$top_dir" && -f "$top_dir/$(agent_repo_rel "$a")" && -n "$PY" ]] && \
        agent_merge status "$a" "$(native_path "$top_dir/$(agent_repo_rel "$a")")" >/dev/null 2>&1 && agents="$agents $a"
    done
    # An if, not `&&`: as the last command a false test made the function, and
    # under set -e the whole --status, exit 1 before the prerequisites.
    if [[ -n "$agents" ]]; then echo "[setup-hooks] this repository: agent hooks:$agents"; fi
  fi
}

# ---- Other AI agents (--agent, --agent-repo) --------------------------------
# agent_repo_rel <agent>: the agent's project hook file, relative to the top.
agent_repo_rel() {
  case "$1" in
    codex) echo ".codex/hooks.json" ;; gemini) echo ".gemini/settings.json" ;;
    copilot) echo ".github/hooks/script-helpers.json" ;; cursor) echo ".cursor/hooks.json" ;;
  esac
}
# agent_user_file <agent>: the agent's hook file for this user.
agent_user_file() {
  case "$1" in
    codex) echo "$(unix_path "${CODEX_HOME:-${HOME:-}/.codex}")/hooks.json" ;;
    gemini) echo "${HOME:-}/.gemini/settings.json" ;;
    copilot) echo "$(unix_path "${COPILOT_HOME:-${HOME:-}/.copilot}")/hooks/script-helpers.json" ;;
    cursor) echo "${HOME:-}/.cursor/hooks.json" ;;
  esac
}
agent_merge() { "$PY" -I "$(native_path "$src_root/$AGENT_MERGE_REL")" "$@"; }

# require_agent_tools: what every agent install needs; refuses (exit 2) first.
require_agent_tools() {
  require_owners
  [[ -n "$PY" ]] || { echo "[setup-hooks] ERROR: Python 3 is needed (python3, or python on Windows)." >&2; exit 2; }
  if [[ "$ON_WINDOWS" == true ]] && ! command -v cygpath >/dev/null 2>&1; then
    echo "[setup-hooks] ERROR: run this from Git Bash (Git for Windows); the agents run the hook there." >&2; exit 2
  fi
}

# copy_agent_hooks <home>: the check, the Claude hook it wraps and the adapter.
copy_agent_hooks() {
  local home="$1" stage
  stage="$(stage_common "$home")" || { echo "[setup-hooks] ERROR: could not stage $home" >&2; exit 1; }
  mkdir -p "$stage/scripts/claude-hooks" "$stage/scripts/agent-hooks" \
    && cp "$src_root/$HOOK_REL" "$stage/$HOOK_REL" && cp "$src_root/$MERGE_REL" "$stage/$MERGE_REL" \
    && cp "$src_root/$AGENT_HOOK_REL" "$stage/$AGENT_HOOK_REL" && cp "$src_root/$AGENT_MERGE_REL" "$stage/$AGENT_MERGE_REL" \
    || { rm -rf "$stage"; echo "[setup-hooks] ERROR: could not copy the agent hooks" >&2; exit 1; }
  stage_and_swap "$home" "$stage"
}
# agent_command <home> <agent>: the command the agent runs. On Windows, Git
# Bash's own bash.exe by full path: a bare "bash" there can be WSL's.
agent_bash() {
  if [[ "$ON_WINDOWS" == true ]]; then printf '"%s"' "$(native_path "$BASH")"; else printf 'bash'; fi
}
agent_command() { printf '%s "%s/%s" %s' "$(agent_bash)" "$(native_path "$1")" "$AGENT_HOOK_REL" "$2"; }

install_agents_user() {
  local a f rc
  require_agent_tools
  for a in $AGENTS_USER; do      # validate every file before anything is written
    f="$(agent_user_file "$a")"
    rc=0; [[ -f "$f" ]] && { agent_merge status "$a" "$(native_path "$f")" >/dev/null || rc=$?; }
    [[ "$rc" -le 1 ]] || exit "$rc"
  done
  copy_agent_hooks "$agent_user_home"
  for a in $AGENTS_USER; do
    f="$(agent_user_file "$a")"
    mkdir -p "$(dirname "$f")" || exit 1
    rc=0; agent_merge install "$a" "$(native_path "$f")" "$(agent_command "$agent_user_home" "$a")" || rc=$?
    [[ "$rc" -eq 0 ]] || exit "$rc"
    echo "[setup-hooks] $a: hook set in $f"
  done
  echo "[setup-hooks] Codex and Gemini ask you to trust a new hook before it runs (Codex: /hooks)."
  offer_gitleaks
  offer_foxguard
}
uninstall_agents_user() {
  local a f rc left=false
  for a in $AGENTS_USER; do
    f="$(agent_user_file "$a")"
    [[ -f "$f" ]] || continue
    [[ -n "$PY" ]] || { echo "[setup-hooks] ERROR: Python 3 is needed to edit $f" >&2; exit 2; }
    rc=0; agent_merge uninstall "$a" "$(native_path "$f")" || rc=$?
    [[ "$rc" -eq 0 ]] || exit "$rc"
  done
  # The copy goes only when no agent's user file still runs it.
  for a in codex gemini copilot cursor; do
    f="$(agent_user_file "$a")"
    [[ -f "$f" && -n "$PY" ]] && agent_merge status "$a" "$(native_path "$f")" >/dev/null 2>&1 && left=true
  done
  if [[ "$left" == false ]]; then
    rm -rf "${agent_user_home:?}/scripts" "${agent_user_home:?}/lib" "${agent_user_home:?}/config" "${agent_user_home:?}/helpers.sh" "${agent_user_home:?}/VERSION"
    rmdir "$agent_user_home" 2>/dev/null || true
  fi
  echo "[setup-hooks] agent hooks removed: $(echo $AGENTS_USER)"
}

# claude_supports_onfailure: 0 when the installed claude is 2.1.295 or newer,
# which honours "onFailure": "block" (a timeout or crash blocks, not passes).
ONFAILURE_MIN="2.1.295"
claude_supports_onfailure() {
  local v
  command -v claude >/dev/null 2>&1 && [[ -n "$PY" ]] || return 1
  v="$(claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [[ -n "$v" ]] || return 1
  "$PY" -I -c 'import sys
a = [int(x) for x in sys.argv[1].split(".")]; b = [int(x) for x in sys.argv[2].split(".")]
sys.exit(0 if a >= b else 1)' "$v" "$ONFAILURE_MIN"
}

# claude_onfailure <settings>: the onFailure value of our entry, or nothing.
claude_onfailure() {
  [[ -n "$PY" && -f "$1" ]] || return 0
  "$PY" -I "$(native_path "$src_root/$MERGE_REL")" status "$(native_path "$1")" 2>/dev/null \
    | sed -n 's/^onFailure=//p' | head -1 || true
}

# claude_entry <settings>: the hook command in that file, or nothing.
claude_entry() {
  [[ -n "$PY" && -f "$1" ]] || return 0
  "$PY" -I "$(native_path "$src_root/$MERGE_REL")" status "$(native_path "$1")" 2>/dev/null | head -1 || true
}

# claude_hook_path <entry>: the script an entry's command runs. The forms
# merge_settings.py counts as ours: optional "bash ", the path in double or
# single quotes or bare, a leading ~/ or $HOME/, surrounding spaces. Expands
# only what the shell would: ~/ when bare, $HOME/ when bare or double-quoted.
claude_hook_path() {
  local hook="$1" quote=""
  hook="${hook#"${hook%%[![:space:]]*}"}"; hook="${hook%"${hook##*[![:space:]]}"}"
  case "$hook" in
    bash[[:space:]]*) hook="${hook#bash}"; hook="${hook#"${hook%%[![:space:]]*}"}" ;;
  esac
  case "$hook" in
    \"*\") quote=d; hook="${hook#\"}"; hook="${hook%\"}" ;;
    \'*\') quote=s; hook="${hook#\'}"; hook="${hook%\'}" ;;
  esac
  # shellcheck disable=SC2016 # the patterns match a literal $HOME in the entry
  case "$quote:$hook" in
    :\~/*) hook="${HOME:-}/${hook#\~/}" ;;
    [d]:'$HOME/'*|:'$HOME/'*) hook="${HOME:-}/${hook#\$HOME/}" ;;
    [d]:'${HOME}/'*|:'${HOME}/'*) hook="${HOME:-}/${hook#\$\{HOME\}/}" ;;
  esac
  unix_path "$hook"
}

# claude_state <settings> <copy dir>: unknown (no Python to read it), ok, absent, broken (the script the entry
# runs does not exist, so the hook fails) or stale (it runs a file outside the
# installed copy, such as a checkout, which a branch switch or pull changes or
# removes).
claude_state() {
  local entry hook home
  [[ -n "$PY" ]] || { echo unknown; return; }       # the settings cannot be read
  entry="$(claude_entry "$1")"
  [[ -n "$entry" ]] || { echo absent; return; }
  hook="$(claude_hook_path "$entry")"
  home="$(cd "$2" 2>/dev/null && pwd -P || echo "$2")"
  if [[ ! -f "$hook" ]]; then echo broken
  elif [[ "$(cd "$(dirname "$hook")" && pwd -P)/$(basename "$hook")" != "$home/$HOOK_REL" ]]; then echo stale
  else echo ok
  fi
}

show_claude_status() {
  local entry pair kind file home state
  for pair in "user|$claude_settings|$claude_home" "managed|$managed_settings|$managed_home"; do
    IFS='|' read -r kind file home <<<"$pair"
    entry="$(claude_entry "$file")"
    if [[ -n "$entry" ]]; then
      echo "[setup-hooks] claude hook ($kind): $file -> $entry"
      echo "[setup-hooks]   installed copy: $home ($(cat "$home/VERSION" 2>/dev/null || echo 'MISSING: the hook cannot run'))"
      state="$(claude_state "$file" "$home")"
      case "$state" in
        broken) echo "[setup-hooks]   BROKEN: $(claude_hook_path "$entry") does not exist; the hook cannot run. Fix: setup-hooks.sh --$([[ "$kind" == user ]] && echo claude || echo managed)" ;;
        stale)  echo "[setup-hooks]   STALE: the entry runs $(claude_hook_path "$entry"), not the installed copy; a branch switch or pull there changes or removes it. Fix: setup-hooks.sh --$([[ "$kind" == user ]] && echo claude || echo managed)" ;;
      esac
      if [[ "$(claude_onfailure "$file")" == block ]]; then
        echo "[setup-hooks]   onFailure: block (a timeout or crash blocks the command)"
      else
        echo "[setup-hooks]   WARN: no onFailure: a timeout or crash lets the command run. Claude Code $ONFAILURE_MIN or newer supports it; update it, then run --claude again."
      fi
    elif [[ "$kind" == user ]]; then
      echo "[setup-hooks] claude hook ($kind): not in $file"
    fi
  done
}

# install_claude <settings> <copy dir>
install_claude() {
  local settings="$1" home="$2" stage cmd onfailure rc=0
  require_owners
  if [[ -z "$PY" ]]; then
    echo "[setup-hooks] ERROR: Python 3 is needed (python3, or python on Windows): the hook and this installer use it." >&2
    exit 2
  fi
  if [[ "$ON_WINDOWS" == true ]] && ! command -v cygpath >/dev/null 2>&1; then
    echo "[setup-hooks] ERROR: run this from Git Bash (Git for Windows); Claude Code runs the hook there." >&2
    exit 2
  fi
  # Validate first: nothing is copied for a settings file that cannot be merged.
  "$PY" -I "$(native_path "$src_root/$MERGE_REL")" status "$(native_path "$settings")" >/dev/null || rc=$?
  [[ "$rc" -le 1 ]] || exit "$rc"

  stage="$(stage_common "$home")" || { echo "[setup-hooks] ERROR: could not stage $home" >&2; exit 1; }
  mkdir -p "$stage/scripts/claude-hooks" \
    && cp "$src_root/$HOOK_REL" "$stage/$HOOK_REL" \
    && cp "$src_root/$MERGE_REL" "$stage/$MERGE_REL" \
    || { rm -rf "$stage"; echo "[setup-hooks] ERROR: could not copy the hook" >&2; exit 1; }
  stage_and_swap "$home" "$stage"
  echo "[setup-hooks] hook copied to $home ($(cat "$home/VERSION"))"

  cmd="bash \"$(native_path "$home")/$HOOK_REL\""
  onfailure=""
  if claude_supports_onfailure; then onfailure=block; fi
  rc=0
  "$PY" -I "$(native_path "$home/$MERGE_REL")" install "$(native_path "$settings")" "$cmd" 60 $onfailure || rc=$?
  [[ "$rc" -eq 0 ]] || exit "$rc"
  echo "[setup-hooks] PreToolUse hook (matcher Bash, timeout 60 s, shell bash${onfailure:+, onFailure block}): $cmd"
  if [[ -z "$onfailure" ]]; then
    echo "[setup-hooks] WARN: Claude Code older than $ONFAILURE_MIN (or not found): a hook timeout or crash lets the command run."
  fi
  echo "[setup-hooks] New Claude Code sessions use it; /hooks lists it. Check it with: bash $src_root/scripts/setup-hooks.sh --doctor"
  offer_gitleaks
  offer_foxguard
}

uninstall_claude() {
  local settings="$1" home="$2" rc=0
  if [[ -f "$settings" ]]; then
    [[ -n "$PY" ]] || { echo "[setup-hooks] ERROR: Python 3 is needed to edit $settings" >&2; exit 2; }
    "$PY" -I "$(native_path "$src_root/$MERGE_REL")" uninstall "$(native_path "$settings")" || rc=$?
    [[ "$rc" -eq 0 ]] || exit "$rc"
  fi
  rm -rf "${home:?}/scripts" "${home:?}/lib" "${home:?}/config" "${home:?}/helpers.sh" "${home:?}/VERSION"
  rmdir "$home" 2>/dev/null || true
  echo "[setup-hooks] claude hook removed from $settings and $home"
}

# require_managed_access: the managed file, or its folder, must be writable by
# this user. No sudo here: the person runs this as admin, knowingly.
require_managed_access() {
  local dir probe
  dir="$(dirname "$managed_settings")"
  probe="$dir"
  while [[ ! -d "$probe" && "$probe" != "/" && "$probe" != "." ]]; do probe="$(dirname "$probe")"; done
  if { [[ -e "$managed_settings" ]] && [[ ! -w "$managed_settings" ]]; } || [[ ! -w "$probe" ]] \
     || { [[ -d "$dir" && ! -w "$dir" ]]; }; then
    echo "[setup-hooks] ERROR: no write access to $managed_settings. --managed needs an admin:" >&2
    if [[ "$ON_WINDOWS" == true ]]; then
      echo "[setup-hooks]   run Git Bash or PowerShell as Administrator, then setup-hooks --managed" >&2
    else
      echo "[setup-hooks]   sudo bash $src_root/scripts/setup-hooks.sh --managed" >&2
    fi
    exit 2
  fi
}

# install_hook_copy <dir> <dispatch flag>: copy the check scripts and
# dispatch.sh to <dir>, with one wrapper per git hook in <dir>/hooks. The flag
# ("" machine-wide, "--local" per repository) tells dispatch.sh which earlier
# hooks to chain to.
install_hook_copy() {
  local dir="$1" flag="$2" stage name
  stage="$(stage_common "$dir")" || return 1
  mkdir -p "$stage/scripts/global-hooks" "$stage/hooks" || { rm -rf "$stage"; return 1; }
  cp "$src_root/scripts/security_hooks.sh" "$stage/scripts/" \
    && cp "$src_root/scripts/global-hooks/dispatch.sh" "$stage/scripts/global-hooks/" || { rm -rf "$stage"; return 1; }
  for name in $GLOBAL_HOOK_NAMES; do
    printf '#!/usr/bin/env bash\nexec bash "%s/scripts/global-hooks/dispatch.sh" %s%s "$@"\n' "$dir" "${flag:+$flag }" "$name" > "$stage/hooks/$name"
    chmod +x "$stage/hooks/$name"
  done
  stage_and_swap "$dir" "$stage"
}

install_global() {
  local cur owners
  require_owners
  owners="$(configured_owners)"
  cur="$(git config --global --get core.hooksPath 2>/dev/null || true)"
  echo "[setup-hooks] current global core.hooksPath: ${cur:-(unset)}"
  mkdir -p "$global_dir" || exit 1
  if [[ "$cur" != "$global_hooks" ]]; then
    printf '%s\n' "${cur:-(unset)}" > "$backup_file"
    echo "[setup-hooks] saved it to $backup_file; --global --uninstall restores it"
  fi

  install_hook_copy "$global_dir" "" || exit 1

  git config --global core.hooksPath "$global_hooks"
  echo "[setup-hooks] global core.hooksPath = $global_hooks"
  echo "[setup-hooks] Checked: github.com repositories of: $owners. Others run only their own hooks."
  echo "[setup-hooks] A repository with its own core.hooksPath ignores this; run setup-hooks.sh in it."
  offer_gitleaks
  offer_foxguard
}

uninstall_global() {
  local cur prev
  cur="$(git config --global --get core.hooksPath 2>/dev/null || true)"
  if [[ "$cur" != "$global_hooks" ]]; then
    echo "[setup-hooks] global core.hooksPath is '${cur:-(unset)}', not $global_hooks; left as is." >&2
  else
    prev="$(cat "$backup_file" 2>/dev/null || echo '(unset)')"
    if [[ "$prev" == "(unset)" || -z "$prev" ]]; then
      git config --global --unset core.hooksPath
      echo "[setup-hooks] global core.hooksPath unset (as before --global)"
    else
      git config --global core.hooksPath "$prev"
      echo "[setup-hooks] global core.hooksPath restored to $prev"
    fi
  fi
  rm -rf "${global_dir:?}/hooks" "${global_dir:?}/scripts" "${global_dir:?}/lib" "${global_dir:?}/config" "${global_dir:?}/helpers.sh" "${global_dir:?}/VERSION" "$backup_file"
  rmdir "$global_dir" 2>/dev/null || true
  echo "[setup-hooks] global hooks removed"
}

now_ms() { "$PY" -I -c 'import time; print(int(time.time() * 1000))'; }

# probe_name: a private name from the list the hook reads, for the name probe.
# Read as check_private_names.sh reads it: columns by the header, else the v1
# order (visibility, namespace, name, code, flags); only "private" rows; never
# a name the machine allowlist or PRIVATE_NAMES_ALLOW lets through. Printed
# as namespace/name: the gate matches a qualified-only or ambiguous name only in
# that form, so a bare name would pass and fail the probe on a working hook.
probe_name() {
  local list="${PRIVATE_NAMES_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/private-names.tsv}"
  local allow="${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/private-names-allow"
  [[ -s "$list" ]] || return 1
  { printf '%s\n' "${PRIVATE_NAMES_ALLOW:-}" | tr ',' '\n'; if [[ -f "$allow" ]]; then cat "$allow"; fi; echo ' --end-of-allow-- '; } \
    | tr -d ' \t\r' | tr '[:upper:]' '[:lower:]' | awk -F'\t' '
    !inlist { if ($0 == "--end-of-allow--") inlist = 1; else if ($0 != "") skip[$0] = 1; next }
    /^# *visibility/ && !hh { for (i = 1; i <= NF; i++) { h = $i; sub(/^# */, "", h); col[h] = i }; hh = 1; next }
    /^#/ || NF == 0 { next }
    {
      vi = ("visibility" in col) ? col["visibility"] : 1
      ni = ("namespace" in col) ? col["namespace"] : 2
      mi = ("name" in col) ? col["name"] : 3
      fi = ("flags" in col) ? col["flags"] : 5
      n = $mi; ns = $ni
      if ($vi == "private" && $fi !~ /ambiguous/ && n ~ /^[A-Za-z0-9._-]+$/ && length(n) > 4 && !(tolower(n) in skip) \
          && ns ~ /^[A-Za-z0-9._-]+$/) { print ns "/" n; exit }
    }' - "$list"
}

# probe <want rc> <label> <expect> <command> <hook>: run the hook once on a
# Bash call, from a throwaway repository under the first owner. Passes only on
# the expected exit code AND, for a refusal, when stderr carries <expect> (the
# reason this probe is about) and stdout carries the deny decision. A refusal
# for any other reason (no name list, no gitleaks, a crash) is a failure: the
# gate is not working, it is refusing everything.
probe() {
  local want="$1" label="$2" expect="$3" command="$4" hook="$5" dir t0 t1 rc=0 why=""
  dir="$(mktemp -d)" || { printf '  FAIL  %-44s could not create a temp directory\n' "$label"; return 1; }
  mkdir "$dir/repo" && git init -q "$dir/repo" 2>/dev/null \
    && git -C "$dir/repo" remote add origin "https://github.com/$(configured_owners | cut -d, -f1 | tr -d ' ')/doctor-probe.git" \
    || { rm -rf "$dir"; printf '  FAIL  %-44s could not create the probe repository\n' "$label"; return 1; }
  # JSON-encoded by Python: a path may hold a quote or a backslash.
  "$PY" -I -c 'import json,sys; print(json.dumps({"cwd": sys.argv[1], "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' \
    "$(native_path "$dir/repo")" "$command" > "$dir/payload" \
    || { rm -rf "$dir"; printf '  FAIL  %-44s could not build the payload\n' "$label"; return 1; }
  t0="$(now_ms)"
  (cd "$dir/repo" && bash "$hook" < "$dir/payload" > "$dir/out" 2> "$dir/err") || rc=$?
  t1="$(now_ms)"
  if [[ "$rc" != "$want" ]]; then
    why="exit $rc (want $want)"
  elif [[ "$want" == 2 ]] && ! grep -qF -- "$expect" "$dir/err"; then
    why="refused, but for another reason"
  elif [[ "$want" == 2 ]] && ! grep -q '"permissionDecision": *"deny"' "$dir/out"; then
    why="refused without the deny decision on stdout"
  fi
  if [[ -z "$why" ]]; then
    printf '  ok    %-44s exit %s in %s ms\n' "$label" "$rc" "$((t1 - t0))"
  else
    printf '  FAIL  %-44s %s in %s ms\n' "$label" "$why" "$((t1 - t0))"
    # The hook's first lines say why. Never the probe text: it may be a private name.
    [[ -s "$dir/err" ]] && grep -v '^[[:space:]]*$' "$dir/err" | head -4 | sed 's/^/          hook: /'
  fi
  rm -rf "$dir"
  [[ -z "$why" ]]
}

doctor() {
  local entry hook home settings failed=0 name ssn fix=--claude
  prereqs || failed=1
  show_claude_status
  settings="$claude_settings"; home="$claude_home"; entry="$(claude_entry "$settings")"
  [[ -n "$entry" ]] || { settings="$managed_settings"; home="$managed_home"; fix=--managed; entry="$(claude_entry "$settings")"; }
  if [[ -z "$entry" || -z "$PY" ]]; then
    echo "[setup-hooks] no Claude hook installed; run: bash $src_root/scripts/setup-hooks.sh --claude" >&2
    return 1
  fi
  hook="$(claude_hook_path "$entry")"
  if [[ ! -f "$hook" ]]; then
    echo "[setup-hooks] the hook in settings does not exist: $hook (it would fail open); run $fix again" >&2
    return 1
  fi
  # Probed anyway: it runs today. It fails the doctor because it will not
  # survive the next branch switch or pull in the place it points at.
  if [[ "$(claude_state "$settings" "$home")" == stale ]]; then
    echo "[setup-hooks] FAIL: the hook in settings is not the installed copy: $hook; run $fix again" >&2
    failed=1
  fi
  # Both entries run; one in good order does not excuse the other.
  if [[ "$settings" == "$claude_settings" ]]; then
    case "$(claude_state "$managed_settings" "$managed_home")" in
      broken|stale) echo "[setup-hooks] FAIL: the managed-settings hook is broken or stale; run --managed again" >&2; failed=1 ;;
    esac
  fi
  if [[ -z "$(configured_owners)" ]]; then
    echo "[setup-hooks] no owners configured: the hook acts in no repository, so nothing can be probed" >&2
    return 1
  fi
  echo "[setup-hooks] probes through $hook (a timeout lets the command run, so each must be well under 60 s):"
  if name="$(probe_name)" && [[ -n "$name" ]]; then
    probe 2 "a private name from your list (refused)" "names a private repository" \
      "gh pr create --title probe --body \"see $name\"" "$hook" || failed=1
  else
    printf '  FAIL  %-44s no usable private name in the list (missing, empty or all ambiguous)\n' "a private name from your list (refused)"
    failed=1
  fi
  # An SSN-shaped number, built here so this file carries none.
  ssn="219-09-""9999"
  probe 2 "a personal identifier (refused)" "carries a credential, a personal identifier or PII" \
    "gh pr create --title probe --body \"ssn $ssn\"" "$hook" || failed=1
  probe 2 "git push --no-verify (refused)" "skips or replaces the git hooks" \
    "git push --no-verify origin main" "$hook" || failed=1
  probe 0 "ls (must pass)" "" "ls" "$hook" || failed=1
  return "$failed"
}

if [[ "$GITLEAKS" == true || "$FOXGUARD" == true ]]; then
  rc=0
  if [[ "$GITLEAKS" == true ]]; then install_gitleaks || rc=$?; fi
  if [[ "$FOXGUARD" == true ]]; then install_foxguard || rc=$?; fi
  exit "$rc"
fi
if [[ "$DOCTOR" == true ]]; then
  rc=0; doctor || rc=$?
  exit "$rc"
fi
if [[ "$STATUS" == true && "$PORCELAIN" == true && "$CLAUDE_FLAG" == true ]]; then
  # The user's Claude hook, for scripts; works outside a repository.
  entry="$(claude_entry "$claude_settings")"
  printf 'claude_user=%s\thook=%s\tinstalled=%s\n' "$(claude_state "$claude_settings" "$claude_home")" \
    "$([[ -n "$entry" ]] && claude_hook_path "$entry")" "$(cat "$claude_home/VERSION" 2>/dev/null || true)"
  exit 0
fi
if [[ "$STATUS" == true && "$PORCELAIN" != true ]]; then
  show_global_status
  show_claude_status
  prereqs || true
  exit 0
fi
if [[ -n "$AGENTS_USER" ]]; then
  if [[ "$UNINSTALL" == true ]]; then uninstall_agents_user; else install_agents_user; fi
  exit 0
fi
if [[ "$GLOBAL" == true || "$CLAUDE" == true || "$MANAGED" == true ]]; then
  if [[ "$UNINSTALL" == true ]]; then
    [[ "$GLOBAL" == true ]] && uninstall_global
    [[ "$CLAUDE" == true ]] && uninstall_claude "$claude_settings" "$claude_home"
    [[ "$MANAGED" == true ]] && { require_managed_access; uninstall_claude "$managed_settings" "$managed_home"; }
  else
    [[ "$GLOBAL" == true ]] && install_global
    [[ "$CLAUDE" == true ]] && install_claude "$claude_settings" "$claude_home"
    [[ "$MANAGED" == true ]] && { require_managed_access; install_claude "$managed_settings" "$managed_home"; }
  fi
  exit 0
fi

# This script's directory, both as the caller reached it and physically. Taken
# before the cd below: a relative path in BASH_SOURCE is relative to the
# caller's cwd.
script_dir_logical="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "[setup-hooks] ERROR: Run this script inside a Git worktree." >&2
  exit 1
fi
# The top as the caller sees it, symlinks kept: a vendored copy that is a symlink
# to a checkout elsewhere is inside the repository only in this view.
repo_root_logical="$(cd "./$(git rev-parse --show-cdup)" && pwd)"
cd "$repo_root"
repo_root="$(pwd -P)"

# bundled_under <script dir> <repository top>: the hooks next to this script as a
# repo-relative path, when that directory is inside the repository.
bundled_under() {
  if [[ "$1" == "$2"/* ]] && has_required_hooks "$1/git-hooks"; then
    echo "${1#"$2"/}/git-hooks"
  fi
}

# The bundled hooks next to this script, as a repo-relative path, or nothing:
# first as the caller reached them, then physically.
bundled_hooks() {
  local found
  found="$(bundled_under "$script_dir_logical" "$repo_root_logical")"
  [[ -n "$found" ]] || found="$(bundled_under "$script_dir" "$repo_root")"
  [[ -z "$found" ]] || echo "$found"
}

has_required_hooks() {
  local dir="$1"
  [[ -f "$dir/pre-commit" ]] && [[ -f "$dir/pre-push" ]]
}

resolve_hooks_dir() {
  # Returns a repo-relative path for git config storage; uses absolute paths for existence checks.
  if has_required_hooks "$repo_root/.githooks"; then
    echo ".githooks"
  elif [[ -n "$(bundled_hooks)" ]]; then
    bundled_hooks
  elif has_required_hooks "$repo_root/scripts/script-helpers/scripts/git-hooks"; then
    echo "scripts/script-helpers/scripts/git-hooks"
  elif has_required_hooks "$repo_root/scripts/git-hooks"; then
    echo "scripts/git-hooks"
  else
    echo ""
  fi
}

hooks_dir="$(resolve_hooks_dir)"   # relative — portable across clones
common_dir="$(git rev-parse --git-common-dir)"
case "$common_dir" in /*|[A-Za-z]:[\\/]*) ;; *) common_dir="$repo_root/$common_dir" ;; esac
cur_local="$(git config --local --get core.hooksPath 2>/dev/null || true)"
cur_global="$(git config --global --get core.hooksPath 2>/dev/null || true)"

# set_by_us <value>: a core.hooksPath this script set: the per-repository
# copy, a script-helpers hooks directory, or the value it recorded in
# script-helpers.set-hooksPath. A repository's own .githooks set by its owner
# is not ours, even when it is the directory this script would pick.
set_by_us() {
  [[ -n "$1" ]] || return 1
  [[ "$1" == "$repo_hooks" ]] && return 0
  case "$1" in */script-helpers/scripts/git-hooks) return 0 ;; esac
  [[ "$(git config --local --get script-helpers.set-hooksPath 2>/dev/null)" == "$1" ]]
}

# hooks_executable: 0 when every git hook in the target directory is executable,
# so git can run it without this script changing a tracked file's mode.
hooks_executable() {
  local name
  for name in $GLOBAL_HOOK_NAMES; do
    [[ -f "$repo_root/$hooks_dir/$name" && ! -x "$repo_root/$hooks_dir/$name" ]] && return 1
  done
  return 0
}

# native_hooks: 0 when .git/hooks holds a hook git would run (executable, not a .sample).
native_hooks() {
  local f
  for f in "$common_dir"/hooks/*; do
    [[ -f "$f" && -x "$f" && "$f" != *.sample ]] && return 0
  done
  return 1
}

# unset_local <key>: remove a local key; a missing key is not an error.
unset_local() { git config --local --unset "$1" 2>/dev/null || true; }

# The setup here, as recorded in .git/config: mode (chained, direct, none) and the
# core.hooksPath it set. A setup from 0.49.0 recorded neither; it is read from
# the keys it did write. taken_over: the value is no longer the one we set
# (another tool replaced or removed it), so our hooks no longer run.
setup_mode=""; setup_expected=""; taken_over=no; unscanned=no; broken=no
# direct_allowed <hooks dir>: pointing git straight at the repository's hooks
# keeps the current security checks only when those hooks are this copy's own.
# Without a dispatcher to chain through, direct is the only way.
have_dispatch=false
[[ -f "$src_root/scripts/global-hooks/dispatch.sh" && -f "$src_root/scripts/security_hooks.sh" ]] && have_dispatch=true
direct_allowed() {
  [[ "$have_dispatch" != true ]] || [[ -n "$1" && "$1" == "$(bundled_hooks)" ]]
}
read_setup_state() {
  setup_mode="$(git config --local --get script-helpers.mode 2>/dev/null || true)"
  setup_expected="$(git config --local --get script-helpers.expected-hooksPath 2>/dev/null || true)"
  if [[ -z "$setup_mode" ]]; then
    if [[ "$cur_local" == "$repo_hooks" ]] || \
       git config --local --get script-helpers.hooks-target >/dev/null 2>&1 || \
       git config --local --get script-helpers.previous-hooksPath >/dev/null 2>&1; then
      setup_mode=chained; setup_expected="$repo_hooks"
    elif [[ -n "$(git config --local --get script-helpers.set-hooksPath 2>/dev/null)" ]]; then
      setup_mode=direct; setup_expected="$(git config --local --get script-helpers.set-hooksPath)"
    elif [[ "$(git config --local --bool --get script-helpers.trust-repo-hooks 2>/dev/null)" == true ]]; then
      # Direct without a recorded value only when the repository already pointed
      # at its own hooks; any other value means a chained setup was replaced.
      if [[ -n "$hooks_dir" && "$cur_local" == "$hooks_dir" ]]; then
        setup_mode=direct; setup_expected="$hooks_dir"
      else
        setup_mode=chained; setup_expected="$repo_hooks"
      fi
    else
      setup_mode=none
    fi
  fi
  taken_over=no
  if [[ "$setup_mode" != none && "$cur_local" != "$setup_expected" ]]; then taken_over=yes; fi
  unscanned=no
  if [[ "$setup_mode" == direct ]] && ! direct_allowed "$setup_expected"; then unscanned=yes; fi
  # broken: core.hooksPath names a directory that is gone (a branch without it,
  # a deleted copy), or our setup's directory lost its pre-push. Git then runs
  # no push checks, and says nothing. A repository's own hooks directory with
  # only a pre-commit is its choice, not broken.
  broken=no
  if [[ -n "$cur_local" ]]; then
    local hp="$cur_local"
    case "$hp" in
      \~/*) hp="${HOME:-}/${hp#\~/}" ;;
      /*|[A-Za-z]:[\\/]*) ;;
      *) hp="$repo_root/$hp" ;;
    esac
    # Our setup's directory only: one another tool took over is taken_over,
    # and whether it has a pre-push is that tool's choice.
    if [[ ! -d "$hp" ]] || [[ "$setup_mode" != none && "$taken_over" == no && ! -f "$hp/pre-push" ]]; then
      broken=yes
    fi
  fi
}

# record_setup <mode> <value>: what this run set, for --status and --repair.
record_setup() {
  git config --local script-helpers.mode "$1"
  git config --local script-helpers.expected-hooksPath "$2"
}

read_setup_state
if [[ "$STATUS" == true && "$PORCELAIN" == true ]]; then
  # Read from the file itself: when a .gitignore already covers it, no
  # exclude marker is written.
  claude_repo=no
  if [[ -f "$repo_root/.claude/settings.local.json" && -n "$PY" ]] && \
     "$PY" -I "$(native_path "$src_root/$MERGE_REL")" status "$(native_path "$repo_root/.claude/settings.local.json")" >/dev/null 2>&1; then
    claude_repo=yes
  fi
  # The machine-wide hooks run here when no local core.hooksPath overrides them.
  global=no
  [[ -n "$cur_global" && "$cur_global" == "$global_hooks" && -z "$cur_local" ]] && global=yes
  # The other agents whose project hook file holds our entry.
  agents=""
  for a in codex gemini copilot cursor; do
    f="$repo_root/$(agent_repo_rel "$a")"
    [[ -f "$f" && -n "$PY" ]] && agent_merge status "$a" "$(native_path "$f")" >/dev/null 2>&1 && agents="${agents:+$agents,}$a"
  done
  printf 'mode=%s\ttaken_over=%s\tcore_hooksPath=%s\texpected=%s\tprevious=%s\ttarget=%s\tclaude_repo=%s\tglobal=%s\tagents=%s\tunscanned=%s\tbroken=%s\n' \
    "$setup_mode" "$taken_over" "$cur_local" "$setup_expected" \
    "$(git config --local --get script-helpers.previous-hooksPath 2>/dev/null || true)" \
    "$(git config --local --get script-helpers.hooks-target 2>/dev/null || true)" "$claude_repo" "$global" "$agents" "$unscanned" "$broken"
  exit 0
fi
if [[ "$REPAIR" == true ]]; then
  if [[ "$setup_mode" == none ]]; then
    echo "[setup-hooks] not set up in this repository; run setup-hooks.sh first" >&2; exit 1
  fi
  if [[ "$taken_over" == no && "$unscanned" == no && "$broken" == no ]]; then
    echo "[setup-hooks] nothing to repair: core.hooksPath is still ${cur_local:-(unset)}"; exit 0
  fi
  if [[ "$broken" == yes && "$taken_over" == no ]]; then
    echo "[setup-hooks] core.hooksPath ${cur_local} is missing or has no pre-push, so no push checks run; setting up again."
    # A direct setup pointed at the repository's own hooks. With no complete pair
    # there on this branch, the lookup finds none; keep that directory as the
    # target anyway, so its pre-commit still runs, and its pre-push once a
    # branch has one (the dispatcher skips a hook file that is not there).
    if [[ "$setup_mode" == direct && -z "$hooks_dir" && -n "$setup_expected" && "$setup_expected" != "$repo_hooks" ]]; then
      hooks_dir="$setup_expected"
    fi
  elif [[ "$taken_over" == no ]]; then
    # The value is still the one we set: the install below chains it as ours,
    # so --uninstall later leaves what was there before the first setup.
    echo "[setup-hooks] $setup_expected runs without the current security checks; chaining them in front."
  else
    echo "[setup-hooks] core.hooksPath was changed to '${cur_local:-(unset)}' after the setup here; chaining again."
    if [[ "$setup_mode" == chained ]] && set_by_us "$cur_local"; then
      # Another copy of these hooks (an older vendored setup-hooks.sh run again):
      # not a new tool, so the chain stays as it was, the saved previous included.
      cur_local="$repo_hooks"
    else
      old_prev="$(git config --local --get script-helpers.previous-hooksPath 2>/dev/null || true)"
      [[ -n "$old_prev" ]] && git config --local script-helpers.previous-hooksPath-history "$old_prev"
      # The value we set is gone: forget it, so the new one is read as foreign below.
      unset_local script-helpers.set-hooksPath
    fi
  fi
fi

# ---- Other AI agents, this repository only (--agent-repo) -------------------
# The same rules as --claude-repo: the file is listed in .git/info/exclude
# before it is written, backups go under .git/script-helpers/<agent>-backups,
# and uninstall removes the file only when this script created it.
agent_exclude_mark() { echo "# script-helpers setup-hooks.sh --agent-repo $1"; }

# What this script created is recorded per worktree, in the worktree's own git
# directory: .git/config and .git/info/exclude are shared by every linked
# worktree, so a marker there let an uninstall in one worktree forget, or
# un-exclude, the file another worktree still has. A key from 0.49.0 in
# .git/config is still read, and cleared only from the main worktree.
wt_state="$(git rev-parse --absolute-git-dir 2>/dev/null)/script-helpers"
in_main_worktree() { [[ "$(git rev-parse --absolute-git-dir)" == "$(cd "$common_dir" && pwd -P)" || "$(git rev-parse --absolute-git-dir)" == "$common_dir" ]]; }
mark_set() { mkdir -p "$wt_state" && printf '%s\n' "$2" > "$wt_state/$1"; }
mark_get() {
  if [[ -f "$wt_state/$1" ]]; then cat "$wt_state/$1"
  elif in_main_worktree; then git config --local --get "script-helpers.$1" 2>/dev/null || true
  fi
}
mark_clear() {
  rm -f "$wt_state/$1"
  in_main_worktree && unset_local "script-helpers.$1"
  rmdir "$wt_state" 2>/dev/null || true
}
# other_worktree_has <rel> <status command...>: 0 when another worktree of this
# repository still has the file with our entry, so its exclude line stays.
other_worktree_has() {
  local rel="$1" wt; shift
  while IFS= read -r wt; do
    wt="${wt#worktree }"
    [[ "$(cd "$wt" 2>/dev/null && pwd -P)" == "$repo_root" ]] && continue
    [[ -f "$wt/$rel" ]] && "$@" "$(native_path "$wt/$rel")" >/dev/null 2>&1 && return 0
  done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree ')
  return 1
}

# remove_exclude <mark> <line>: only the marker and the line right after it.
remove_exclude() {
  local f="$common_dir/info/exclude"
  [[ -f "$f" ]] && grep -qxF "$1" "$f" || return 0
  awk -v m="$1" -v l="$2" '
    skip { skip = 0; if ($0 == l) next }
    $0 == m { skip = 1; next }
    { print }' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
}
move_agent_backups() {
  local b dest="$common_dir/script-helpers/$1-backups"
  for b in "$2".bak-*; do
    [[ -f "$b" ]] || continue
    mkdir -p "$dest" && mv -f "$b" "$dest/" || return 1
  done
}

if [[ -n "$AGENTS_REPO" ]]; then
  for a in $AGENTS_REPO; do
    rel="$(agent_repo_rel "$a")"
    # A committed symlink anywhere on the path would send the write outside the
    # repository; a tracked file is the project's, not ours to change.
    d="$repo_root"; part=""
    for part in ${rel//\// }; do
      d="$d/$part"
      if [[ -L "$d" ]]; then echo "[setup-hooks] ERROR: $a: ${d#"$repo_root"/} is a symlink; nothing changed." >&2; exit 2; fi
    done
    if git ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
      echo "[setup-hooks] ERROR: $a: $rel is tracked by git; nothing changed." >&2; exit 2
    fi
  done
  if [[ "$UNINSTALL" == true ]]; then
    for a in $AGENTS_REPO; do
      rel="$(agent_repo_rel "$a")"; f="$repo_root/$rel"
      if [[ -f "$f" ]]; then
        [[ -n "$PY" ]] || { echo "[setup-hooks] ERROR: Python 3 is needed to edit $f" >&2; exit 2; }
        rc=0; agent_merge uninstall "$a" "$(native_path "$f")" || rc=$?
        [[ "$rc" -eq 0 ]] || exit "$rc"
        move_agent_backups "$a" "$f" || exit 1
        if [[ "$(mark_get "$a-local-created")" == true ]] && \
           "$PY" -I -c 'import json,sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if all(not v for k, v in d.items() if k != "version") else 1)' "$(native_path "$f")" 2>/dev/null; then
          rm -f "$f"
          # Up to the first directory this script made, each only when empty.
          top_made="$(mark_get "$a-created-dir")"
          if [[ -n "$top_made" ]]; then
            d="$(dirname "$f")"
            while [[ "$d" == "$repo_root/$top_made"* ]]; do rmdir "$d" 2>/dev/null || break; d="$(dirname "$d")"; done
          fi
        fi
      fi
      mark_clear "$a-local-created"
      mark_clear "$a-created-dir"
      other_worktree_has "$rel" agent_merge status "$a" || remove_exclude "$(agent_exclude_mark "$a")" "/$rel*"
      echo "[setup-hooks] $a: hook removed from this repository."
    done
    if [[ -z "$(git config --local --get-regexp '^script-helpers\.' 2>/dev/null || true)" ]]; then
      git config --local --remove-section script-helpers 2>/dev/null || true
    fi
    exit 0
  fi
  # Everything that can refuse runs before anything is written.
  require_agent_tools
  for a in $AGENTS_REPO; do
    f="$repo_root/$(agent_repo_rel "$a")"
    rc=0; [[ -f "$f" ]] && { agent_merge status "$a" "$(native_path "$f")" >/dev/null || rc=$?; }
    [[ "$rc" -le 1 ]] || exit "$rc"
  done
  copy_agent_hooks "$agent_repo_home"
  for a in $AGENTS_REPO; do
    rel="$(agent_repo_rel "$a")"; f="$repo_root/$rel"
    existed=false; [[ -e "$f" ]] && existed=true
    if ! git check-ignore -q --no-index -- "$rel" 2>/dev/null && ! grep -qxF "$(agent_exclude_mark "$a")" "$common_dir/info/exclude" 2>/dev/null; then
      mkdir -p "$common_dir/info" && printf '%s\n%s\n' "$(agent_exclude_mark "$a")" "/$rel*" >> "$common_dir/info/exclude" || exit 1
    fi
    # The first directory on the path that does not exist yet: uninstall removes
    # it again (when empty), and nothing above it.
    made="$(dirname "$f")"; first_made=""
    while [[ "$made" != "$repo_root" && ! -d "$made" ]]; do first_made="$made"; made="$(dirname "$made")"; done
    mkdir -p "$(dirname "$f")" || exit 1
    [[ -n "$first_made" ]] && mark_set "$a-created-dir" "${first_made#"$repo_root"/}"
    rc=0; agent_merge install "$a" "$(native_path "$f")" "$(agent_command "$agent_repo_home" "$a")" || rc=$?
    [[ "$rc" -eq 0 ]] || exit "$rc"
    move_agent_backups "$a" "$f" || exit 1
    [[ "$existed" == true ]] || mark_set "$a-local-created" true
    echo "[setup-hooks] $a: hook set for this repository only: $rel (in .git/info/exclude)."
  done
  echo "[setup-hooks] Codex and Gemini ask you to trust a new project hook before it runs (Codex: /hooks)."
  detect_github_user
  offer_gitleaks
  offer_foxguard
  exit 0
fi

# ---- Claude Code hook, this repository only (--claude-repo) ----------------
# Writes .claude/settings.local.json, which Claude Code reads for this project
# only, and lists it in .git/info/exclude so it can never be committed. Backups
# of the file go under .git/script-helpers/, not next to it.
claude_local="$repo_root/.claude/settings.local.json"
exclude_file="$common_dir/info/exclude"
EXCLUDE_MARK="# script-helpers setup-hooks.sh --claude-repo"
EXCLUDE_LINE="/.claude/settings.local.json*"

# move_claude_backups: the merge script's <file>.bak-* copies, out of the work tree.
move_claude_backups() {
  local b dest="$common_dir/script-helpers/claude-backups"
  for b in "$claude_local".bak-*; do
    [[ -f "$b" ]] || continue
    mkdir -p "$dest" && mv -f "$b" "$dest/" || return 1
  done
}

if [[ "$CLAUDE_REPO" == true ]]; then
  # Both paths come from the work tree, which is whatever was cloned: a
  # committed symlink would send the write (and the merge script follows
  # symlinks on purpose) to a file outside the repository.
  if [[ -L "$repo_root/.claude" || -L "$claude_local" ]] || \
     git ls-files --error-unmatch -- .claude/settings.local.json >/dev/null 2>&1; then
    echo "[setup-hooks] ERROR: .claude or .claude/settings.local.json is a symlink or tracked by git; nothing changed." >&2
    exit 2
  fi
  if [[ "$UNINSTALL" == true ]]; then
    if [[ -f "$claude_local" ]]; then
      [[ -n "$PY" ]] || { echo "[setup-hooks] ERROR: Python 3 is needed to edit $claude_local" >&2; exit 2; }
      rc=0; "$PY" -I "$(native_path "$src_root/$MERGE_REL")" uninstall "$(native_path "$claude_local")" || rc=$?
      [[ "$rc" -eq 0 ]] || exit "$rc"
      move_claude_backups || exit 1
      # A file this script created and that now holds nothing is removed again.
      if [[ "$(mark_get claude-local-created)" == true ]] && \
         "$PY" -I -c 'import json,sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if all(not v for v in d.values()) else 1)' "$(native_path "$claude_local")" 2>/dev/null; then
        rm -f "$claude_local"
        rmdir "$repo_root/.claude" 2>/dev/null || true
      fi
    fi
    mark_clear claude-local-created
    # Only the marker and the line right after it: a line the user added stays.
    # Kept while another worktree still has its own file with our entry.
    if [[ -f "$exclude_file" ]] && grep -qxF "$EXCLUDE_MARK" "$exclude_file" && \
       ! other_worktree_has .claude/settings.local.json "$PY" -I "$(native_path "$src_root/$MERGE_REL")" status; then
      awk -v m="$EXCLUDE_MARK" -v l="$EXCLUDE_LINE" '
        skip { skip = 0; if ($0 == l) next }
        $0 == m { skip = 1; next }
        { print }' "$exclude_file" > "$exclude_file.tmp" && mv -f "$exclude_file.tmp" "$exclude_file"
    fi
    if [[ -z "$(git config --local --get-regexp '^script-helpers\.' 2>/dev/null || true)" ]]; then
      git config --local --remove-section script-helpers 2>/dev/null || true
    fi
    echo "[setup-hooks] Claude hook removed from this repository."
    exit 0
  fi
  # Everything that can refuse runs before anything is written.
  require_owners
  [[ -n "$PY" ]] || { echo "[setup-hooks] ERROR: Python 3 is needed (python3, or python on Windows)." >&2; exit 2; }
  if [[ -f "$claude_local" ]]; then
    rc=0; "$PY" -I "$(native_path "$src_root/$MERGE_REL")" status "$(native_path "$claude_local")" >/dev/null || rc=$?
    [[ "$rc" -le 1 ]] || exit "$rc"
  fi
  existed=false; [[ -e "$claude_local" ]] && existed=true
  # Excluded before the file is written, unless git already ignores it.
  if ! git check-ignore -q --no-index -- .claude/settings.local.json 2>/dev/null; then
    mkdir -p "$(dirname "$exclude_file")" && printf '%s\n%s\n' "$EXCLUDE_MARK" "$EXCLUDE_LINE" >> "$exclude_file" || exit 1
  fi
  mkdir -p "$repo_root/.claude" || exit 1
  install_claude "$claude_local" "$claude_repo_home"
  move_claude_backups || exit 1
  # Recorded only after a successful install: uninstall removes the file only then.
  [[ "$existed" == true ]] || mark_set claude-local-created true
  echo "[setup-hooks] Claude hook set for this repository only: $claude_local (in .git/info/exclude)."
  exit 0
fi

if [[ "$UNINSTALL" == true ]]; then
  if [[ "$cur_local" == "$repo_hooks" ]]; then
    prev="$(git config --local --get script-helpers.previous-hooksPath 2>/dev/null || true)"
    if [[ -n "$prev" ]]; then
      git config --local core.hooksPath "$prev"
      echo "[setup-hooks] core.hooksPath restored to $prev"
    else
      unset_local core.hooksPath
      echo "[setup-hooks] core.hooksPath unset (as before)"
    fi
  elif set_by_us "$cur_local"; then
    unset_local core.hooksPath
    echo "[setup-hooks] core.hooksPath unset"
  elif [[ -n "$cur_local" ]]; then
    echo "[setup-hooks] core.hooksPath is '$cur_local', which this script did not set; left as is." >&2
  fi
  unset_local script-helpers.previous-hooksPath
  unset_local script-helpers.hooks-target
  unset_local script-helpers.trust-repo-hooks
  unset_local script-helpers.set-hooksPath
  unset_local script-helpers.mode
  unset_local script-helpers.expected-hooksPath
  unset_local script-helpers.previous-hooksPath-history
  if [[ -z "$(git config --local --get-regexp '^script-helpers\.' 2>/dev/null || true)" ]]; then
    git config --local --remove-section script-helpers 2>/dev/null || true
  fi
  echo "[setup-hooks] Hooks removed from this repository."
  exit 0
fi

# What git ran here before, when this script did not set it: a local
# core.hooksPath, a global one, or hooks in .git/hooks. Pointing core.hooksPath
# at our hooks alone would silently stop those, so they are chained instead.
foreign=""
if [[ "$cur_local" == "$repo_hooks" ]]; then
  foreign="(chained before)"
elif [[ -n "$cur_local" ]]; then
  set_by_us "$cur_local" || [[ "$cur_local" == "$hooks_dir" ]] || foreign="$cur_local"
elif [[ -n "$cur_global" && "$cur_global" != "$global_hooks" ]]; then
  foreign="global core.hooksPath $cur_global"
elif [[ "$cur_global" == "$global_hooks" && -s "$backup_file" && "$(cat "$backup_file")" != "(unset)" ]]; then
  # --global is ours; the hooks it chains to (saved when it was installed) are not.
  foreign="global core.hooksPath before --global: $(cat "$backup_file")"
elif native_hooks; then
  foreign="$common_dir/hooks"
fi

direct=false
if [[ -z "$foreign" && -n "$hooks_dir" ]] && direct_allowed "$hooks_dir"; then
  if hooks_executable; then
    direct=true
  elif [[ "$have_dispatch" != true ]]; then
    # No dispatcher to run them through bash: the old way, which changes the
    # files' mode (tracked, shows in git status).
    echo "[setup-hooks] WARN: hooks in $hooks_dir are not executable; making them executable (a tracked mode change)." >&2
    for name in $GLOBAL_HOOK_NAMES; do
      [[ -f "$repo_root/$hooks_dir/$name" ]] && chmod +x "$repo_root/$hooks_dir/$name"
    done
    direct=true
  fi
fi

if [[ "$direct" == true ]]; then
  # Nothing to keep: point git straight at this repository's hooks.
  # Recorded as ours unless the repository already had exactly this value.
  if [[ "$cur_local" != "$hooks_dir" ]] || set_by_us "$cur_local"; then
    git config --local script-helpers.set-hooksPath "$hooks_dir"
  fi
  git config core.hooksPath "$hooks_dir"
  record_setup direct "$hooks_dir"
  # This clone opted in: if the machine-wide hooks ever run here (no local
  # core.hooksPath), they may chain to this repository's committed hooks.
  git config --local script-helpers.trust-repo-hooks true
  echo "[setup-hooks] core.hooksPath = $hooks_dir"
  echo "[setup-hooks] Done. Hooks active for this repo, security checks included."
  detect_github_user
  offer_gitleaks
  offer_foxguard
  exit 0
fi

if [[ "$have_dispatch" != true ]]; then
  if [[ -z "$hooks_dir" ]]; then
    echo "[setup-hooks] ERROR: No hooks directory found. Looked for pre-commit and pre-push in:" >&2
    echo "  .githooks/" >&2
    echo "  ${script_dir_logical}/git-hooks/  (next to this script)" >&2
    echo "  scripts/script-helpers/scripts/git-hooks/" >&2
    echo "  scripts/git-hooks/" >&2
    exit 1
  fi
  echo "[setup-hooks] ERROR: this repository already runs hooks ($foreign), and this copy of" >&2
  echo "  script-helpers ($src_root) has no dispatch.sh to chain them; nothing changed." >&2
  echo "  Run setup-hooks.sh from a full script-helpers checkout or release." >&2
  exit 2
fi

# Chain: our checks (the configured owners' repositories only), then this
# repository's committed hooks, then what git ran before. Everything written is
# untracked: the hook copy outside the repository, and keys in .git/config.
install_hook_copy "$repo_hooks_dir" --local || exit 1
if [[ "$cur_local" != "$repo_hooks" ]]; then
  if [[ -n "$cur_local" ]] && ! set_by_us "$cur_local"; then
    git config --local script-helpers.previous-hooksPath "$cur_local"
  else
    unset_local script-helpers.previous-hooksPath
  fi
fi
unset_local script-helpers.set-hooksPath
# The committed hooks run as the target, unless they are the saved previous
# value already (the repository pointed at them itself): never twice.
if [[ -n "$hooks_dir" && "$(git config --local --get script-helpers.previous-hooksPath 2>/dev/null)" != "$hooks_dir" ]]; then
  git config --local script-helpers.hooks-target "$hooks_dir"
else
  unset_local script-helpers.hooks-target
fi
git config --local core.hooksPath "$repo_hooks"
record_setup chained "$repo_hooks"
git config --local script-helpers.trust-repo-hooks true
echo "[setup-hooks] core.hooksPath = $repo_hooks"
echo "[setup-hooks] Chained, in order: security checks (configured owners only)${hooks_dir:+, then $hooks_dir}, then what ran before: $foreign"
echo "[setup-hooks] Undo: setup-hooks.sh --uninstall (restores the previous value)."
detect_github_user
offer_gitleaks
offer_foxguard
