#!/usr/bin/env bash
# SCRIPT: dispatch.sh
# DESCRIPTION: Git hook dispatcher: security checks for the configured owners' repositories, then the hooks that ran before.
# USAGE: dispatch.sh [--local] <hook-name> [git's hook arguments...]  (called by the wrappers setup-hooks.sh writes)
# PARAMETERS:
#   <hook-name>            The git hook being run: pre-push, pre-commit, commit-msg, ...
#   SCRIPT_HELPERS_OWNERS  Comma-separated GitHub users/orgs whose repositories are
#                          checked. Default: git config --global script-helpers.owners.
# ----------------------------------------------------
#
# Installed by `setup-hooks.sh --global` and pointed at by the global
# core.hooksPath, so it runs in every repository without its own core.hooksPath.
#
# 1. Is this repository one of the owners'? The URL being pushed to (pre-push)
#    and every remote URL decide, failing closed: see scripts/owner_scope.sh.
#    No owners configured, another owner, or no remote: no checks at all, and
#    nothing printed (except one notice per push while owners are unset).
# 2. If so, the security steps of scripts/security_hooks.sh for this hook.
# 3. Always: the hook git would have run without this install, the previous
#    global core.hooksPath's <hook> if one was set, else .git/hooks/<hook>.
#    Committed hooks (.githooks/<hook>, scripts/git-hooks/<hook>) first, only
#    in an owner's repository whose clone set script-helpers.trust-repo-hooks.
#    Its exit status is this hook's.
set -uo pipefail

# --local: called by a per-repository install (setup-hooks.sh with no mode),
# which saved what git ran before in .git/config. See "chaining" below.
local_mode=false
if [[ "${1:-}" == --local ]]; then local_mode=true; shift; fi
hook="${1:?dispatch.sh needs the hook name}"
shift

base="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # <install>/scripts
install_dir="$(cd "$base/.." && pwd)"
self_wrapper="$install_dir/hooks/$hook"

stdin_file=""
stdin_dir=""
cleanup() { [[ -n "$stdin_dir" ]] && rm -rf "$stdin_dir"; }
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then cleanup; fi' EXIT
case "$hook" in
  pre-push|post-rewrite|reference-transaction|pre-receive|post-receive|proc-receive)
    # A private per-run directory (mktemp -d, mode 700), never a bare file in TMPDIR.
    stdin_dir="$(mktemp -d "${TMPDIR:-/tmp}/dispatch.XXXXXX" 2>/dev/null)" && [[ -n "$stdin_dir" && -d "$stdin_dir" && ! -L "$stdin_dir" ]] || {
      echo "[script-helpers] global hooks: could not create a private temp directory; refused." >&2
      exit 1
    }
    chmod 700 "$stdin_dir" 2>/dev/null || true
    stdin_file="$stdin_dir/stdin"
    cat > "$stdin_file" || exit 1
    ;;
esac

# Both libraries come from this install, never from the repository.
export SCRIPT_HELPERS_SECURITY_DIR="$base"
# shellcheck source=/dev/null
if ! source "$base/owner_scope.sh" || ! source "$base/security_hooks.sh"; then
  echo "[script-helpers] global hooks: install at $install_dir is broken; rerun setup-hooks.sh --global." >&2
  exit 1
fi

# scope_failed <reason>: scope could not be decided. Fail closed for the hooks
# that publish or record (pre-push, pre-commit, commit-msg); others pass.
scope_failed() {
  case "$hook" in
    pre-push|pre-commit|commit-msg) sec_unchecked "$hook" "$1" || exit 1 ;;
  esac
}

in_scope=false
if git rev-parse --git-dir >/dev/null 2>&1; then
  if ! owners="$(scope_owners)"; then
    scope_failed "could not read git config script-helpers.owners"
  elif [[ -z "$owners" ]]; then
    [[ "$hook" == pre-push ]] && echo "[script-helpers] global hooks: no owners set (run setup-hooks.sh signed in to gh, or git config --global script-helpers.owners <user-or-org>); security checks skipped." >&2
  elif ! remote_urls="$(scope_repo_urls)"; then
    # Cannot tell whose repository this is: check it rather than guess.
    echo "[script-helpers] global hooks: could not list this repository's remotes; checking it." >&2
    in_scope=true
  else
    # pre-push: the URL being pushed to, and every remote's URLs. Any one of
    # them an owner's (or looking like one) puts the push in scope, so an
    # owner's commits pushed to a mirror or a second remote are checked too.
    urls=()
    [[ "$hook" == pre-push ]] && urls+=("${2:-}")
    while IFS= read -r u; do urls+=("$u"); done <<EOF_URLS
$remote_urls
EOF_URLS
    scope_in_scope "$owners" "${urls[@]+"${urls[@]}"}" && in_scope=true
  fi
fi

# The SSH keepalive note, before the checks and the repository's own pre-push
# (a first or large push can take a while): once per push, SSH remotes only.
if [[ "$hook" == pre-push && -f "$base/ssh_keepalive.sh" ]] && grep -qv '^[^ ]* 0* ' "$stdin_file" 2>/dev/null; then
  # shellcheck source=/dev/null
  source "$base/ssh_keepalive.sh" && ssh_keepalive_note "${2:-}" "[script-helpers]"
fi

if [[ "$in_scope" == true ]]; then
  top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  case "$hook" in
    pre-push)
      # No ref lines at all: an up-to-date or rejected push, or a wrapper that
      # lost git's stdin. HEAD's commits the remote lacks are checked instead
      # (sec_push_head_line), in a file of their own: chained hooks still get
      # exactly what git sent.
      checks_file="$stdin_file"
      if ! grep -q '[^[:space:]]' "$stdin_file"; then
        checks_file="$stdin_dir/checks"
        (cd "$top" && sec_push_head_line "${1:-}") > "$checks_file"
      fi
      # Nothing to check when no ref adds commits: deletions, or refs already
      # at the remote's sha.
      deletions_only=true
      # shellcheck disable=SC2034
      while read -r lref lsha rref rsha; do
        [[ -n "${lsha:-}" ]] || continue
        [[ "$lsha" =~ ^0+$ ]] && continue
        [[ "$lsha" =~ ^[0-9a-f]{40,64}$ && "$lsha" == "${rsha:-}" ]] || deletions_only=false
      done < "$checks_file"
      if [[ "$deletions_only" == false ]]; then
        (cd "$top" && sec_pre_push "$checks_file" "${1:-}" "${2:-}") || exit 1
        # Hygiene and lint of what the push changes, as the bundled pre-push does.
        if [[ -f "$base/push_checks.sh" ]]; then
          # shellcheck source=/dev/null
          (cd "$top" && source "$base/push_checks.sh" && push_checks "$checks_file" "${1:-}" "${2:-}" && push_tests) || exit 1
          # A chained script-helpers pre-push skips the same checks for this
          # same push (the hash of its ref lines), instead of running them twice.
          SCRIPT_HELPERS_PUSH_CHECKED="$(git hash-object --stdin < "$checks_file" 2>/dev/null || true)"
          export SCRIPT_HELPERS_PUSH_CHECKED
        fi
      fi
      ;;
    pre-commit) (cd "$top" && sec_pre_commit) || exit 1 ;;
    commit-msg)
      msg="$1"; [[ "$msg" == /* ]] || msg="$(pwd)/$msg"
      (cd "$top" && sec_commit_msg "$msg") || exit 1
      ;;
  esac
fi

# An opt-in the global hooks will not act on is said, not dropped: outside the
# repositories of your account and organisations they run none of their checks,
# tests included.
if [[ "$hook" == pre-push && "$in_scope" != true ]] && \
   [[ -n "$(git config --get script-helpers.push-tests 2>/dev/null || true)" ]]; then
  echo "[script-helpers] script-helpers.push-tests is set, but this repository is not yours (script-helpers.github-user, script-helpers.owners); tests not run." >&2
fi

# ------------------------------------------------------------- chaining
# run_hook <path> [args]: run a repository's hook the way git would.
run_hook() {
  local h="$1"; shift
  if [[ -n "$stdin_file" ]]; then
    if [[ -x "$h" ]]; then "$h" "$@" < "$stdin_file"; else bash "$h" "$@" < "$stdin_file"; fi
  else
    if [[ -x "$h" ]]; then "$h" "$@"; else bash "$h" "$@"; fi
  fi
}

# is_abs <path>: absolute, also as Git for Windows writes it (C:/x, C:\\x).
is_abs() { case "$1" in /*|[A-Za-z]:[\\/]*) return 0 ;; esac; return 1; }

top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
[[ -n "$common" ]] && ! is_abs "$common" && common="$(pwd)/$common"

# expand_hooks_path <value>: a core.hooksPath as git reads it: "~/" is the home
# directory, a relative path is relative to the top of the work tree.
expand_hooks_path() {
  local v="$1"
  # shellcheck disable=SC2088  # a literal "~/" saved from git config
  case "$v" in "~/"*) v="${HOME:-}/${v#\~/}" ;; esac
  [[ -n "$v" && -n "$top" ]] && ! is_abs "$v" && v="$top/$v"
  printf '%s' "$v"
}

if [[ "$local_mode" == true ]]; then
  # Per repository, everything runs, in order, and the first failure stops it:
  # 1. this repository's committed hooks (script-helpers.hooks-target, the
  #    directory setup-hooks.sh would otherwise point core.hooksPath at), only
  #    while this clone keeps script-helpers.trust-repo-hooks;
  # 2. what git ran before the install: the saved local core.hooksPath, else
  #    the global one, else .git/hooks. Git ran those before; they run as git
  #    would (a hooks-directory file only when executable).
  if [[ "$(git config --local --bool --get script-helpers.trust-repo-hooks 2>/dev/null)" == true ]]; then
    target="$(git config --local --get script-helpers.hooks-target 2>/dev/null || true)"
    if [[ -n "$target" && -n "$top" && -f "$top/$target/$hook" ]]; then
      run_hook "$top/$target/$hook" "$@" || exit $?
    fi
  fi
  prev="$(git config --local --get script-helpers.previous-hooksPath 2>/dev/null || true)"
  if [[ -z "$prev" ]]; then
    prev="$(expand_hooks_path "$(git config --global --get core.hooksPath 2>/dev/null || true)")"
    # The machine-wide install of this dispatcher: its checks just ran here, so
    # chain to what it chains to (saved by setup-hooks.sh --global), not to it.
    if [[ -n "$prev" && -f "$prev/../scripts/global-hooks/dispatch.sh" ]]; then
      prev="$(cat "$prev/../previous-hooksPath" 2>/dev/null || true)"
      [[ "$prev" == "(unset)" ]] && prev=""
    fi
  fi
  prev="$(expand_hooks_path "$prev")"
  if [[ -n "$prev" ]]; then
    native="$prev/$hook"
  else
    native="${common:+$common/hooks/$hook}"
  fi
  if [[ -n "$native" && -f "$native" && -x "$native" ]] && \
     ! [[ "$native" -ef "$self_wrapper" || "$native" -ef "${BASH_SOURCE[0]}" ]]; then
    run_hook "$native" "$@"
    exit $?
  fi
  exit 0
fi
previous=""
if [[ -f "$install_dir/previous-hooksPath" ]]; then
  previous="$(cat "$install_dir/previous-hooksPath")"
  [[ "$previous" == "(unset)" ]] && previous=""
  # shellcheck disable=SC2088  # a literal "~/" saved from git config
  case "$previous" in "~/"*) previous="${HOME:-}/${previous#\~/}" ;; esac
fi
# Committed hooks (.githooks, scripts/git-hooks, or a relative earlier
# core.hooksPath, which points into the work tree) run only in an owner's
# repository whose clone opted in locally:
#   git config --local script-helpers.trust-repo-hooks true
# (set by the per-repository setup-hooks.sh). Anything else would execute code
# from whatever was cloned, which git never does by itself. Only local and
# global git config decide; nothing in the work tree does.
trusted=false
if [[ "$in_scope" == true && -n "$top" ]] && \
   [[ "$(git config --local --bool --get script-helpers.trust-repo-hooks 2>/dev/null)" == true ]]; then
  trusted=true
fi
if [[ -n "$previous" ]] && ! is_abs "$previous"; then
  if [[ "$trusted" == true ]]; then previous="$top/$previous"; else previous=""; fi
fi

# Where git itself would have looked without this install: the previous global
# hooks directory if there was one, else .git/hooks (local, never committed).
if [[ -n "$previous" ]]; then
  native="$previous/$hook"
else
  native="${common:+$common/hooks/$hook}"
fi
tracked1=""; tracked2=""
if [[ "$trusted" == true ]]; then
  tracked1="$top/.githooks/$hook"; tracked2="$top/scripts/git-hooks/$hook"
fi
for candidate in "$tracked1" "$tracked2" "$native"; do
  [[ -n "$candidate" && -f "$candidate" ]] || continue
  [[ "$candidate" -ef "$self_wrapper" || "$candidate" -ef "${BASH_SOURCE[0]}" ]] && continue
  # git runs a hooks-directory file only when it is executable; keep that rule.
  [[ "$candidate" == "$native" && ! -x "$candidate" ]] && continue
  run_hook "$candidate" "$@"
  exit $?
done
exit 0
