#!/usr/bin/env bash
# SCRIPT: owner_scope.sh
# DESCRIPTION: Decide whether a repository belongs to a configured owner, failing closed. Sourced by the global hooks and the Claude Code hook.
# USAGE: source scripts/owner_scope.sh; scope_owners; scope_owner_of <url>; scope_in_scope <owners> [url...]
# PARAMETERS:
#   SCRIPT_HELPERS_OWNERS  Comma-separated GitHub users/orgs. Default:
#                          git config --global script-helpers.owners.
#   -h, --help             Executed directly: show this help.
# EXIT_CODES:
#   scope_owners returns 0 (owners printed, or none set) or 2 (git config unreadable).
#   scope_owner_of returns 0 with the owner printed, 1 for a non-github URL.
#   scope_in_scope returns 0 in scope, 1 out of scope.
#   scope_repo_urls returns 0, or 2 when git cannot list the remotes.
#   Executed directly: 0 for -h/--help, 2 otherwise (the file must be sourced).
# EXAMPLE:
#   source scripts/owner_scope.sh
#   scope_in_scope "$(scope_owners)" "$(git remote get-url origin)" && echo checked
# ----------------------------------------------------
#
# A repository is in scope (checked) when any URL given parses to github.com
# with an owner in the list, or when any URL merely looks like one of the owners'
# (the owner as a whole path segment on another host, e.g. a lookalike
# github.com.evil/<owner>/x or a mirror). Only URLs that parse cleanly to some
# other owner, or that name no owner at all, are out of scope.

# scope_owners: the configured owners, lower case, no spaces. Return 2 when git
# could not read its config (not the same as "unset", which is return 0 with
# no output).
scope_owners() {
  local o rc=0
  if [[ -n "${SCRIPT_HELPERS_OWNERS:-}" ]]; then
    o="$SCRIPT_HELPERS_OWNERS"
    # An inherited variable narrows or widens the scope: say so, every time.
    echo "[script-helpers] owners from SCRIPT_HELPERS_OWNERS ($o), not git config." >&2
  else
    o="$(git config --global --get script-helpers.owners 2>/dev/null)" || rc=$?
    # 1 = not set; anything else = git could not read the config.
    [[ "$rc" -eq 0 || "$rc" -eq 1 ]] || return 2
    # Your own GitHub account counts without being listed: setup-hooks.sh
    # records it in script-helpers.github-user. owners adds the organisations
    # you count as your own.
    local u
    u="$(git config --global --get script-helpers.github-user 2>/dev/null || true)"
    [[ -n "$u" ]] && o="${u}${o:+,$o}"
  fi
  printf '%s' "$o" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -d ' \t'
  return 0
}

# scope_owner_of <url>: the owner of a github.com URL, lower case, or return 1.
# Accepted: git@github.com:o/r, ssh://git@github.com[:22]/o/r,
# https://[user[:pass]@]github.com/o/r, github.com/o/r and the gh shorthand
# o/r; each with or without .git. The host must be exactly github.com.
scope_owner_of() {
  local u rest
  u="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  case "$u" in
    git@github.com:*)          rest="${u#git@github.com:}" ;;
    ssh://git@github.com/*)    rest="${u#ssh://git@github.com/}" ;;
    ssh://git@github.com:22/*) rest="${u#ssh://git@github.com:22/}" ;;
    https://github.com/*)      rest="${u#https://github.com/}" ;;
    https://*@github.com/*)
      rest="${u#https://}"
      # userinfo must not contain "/": https://evil.example/@github.com/o is not GitHub.
      [[ "${rest%%@github.com/*}" == */* ]] && return 1
      rest="${rest#*@github.com/}" ;;
    github.com/*)              rest="${u#github.com/}" ;;
    *://*|*@*|*:*)             return 1 ;;
    */*)                       rest="$u" ;;         # gh -R owner/repo
    *)                         return 1 ;;
  esac
  rest="${rest%/}"
  # Exactly owner/repo: two non-empty segments.
  case "$rest" in */*/*|/*|*/|"") return 1 ;; esac
  [[ "$rest" == */* ]] || return 1
  printf '%s' "${rest%%/*}"
}

# scope_in_scope <owners> [url...]: 0 = check, 1 = pass through.
scope_in_scope() {
  local owners="$1" u ns lu o
  shift
  for u in "$@"; do
    [[ -n "$u" ]] || continue
    if ns="$(scope_owner_of "$u")"; then
      case ",$owners," in *",$ns,"*) return 0 ;; esac
      continue                       # a clean parse to another owner
    fi
    # Unparsable: in scope when it looks like an owner's.
    lu="$(printf '%s' "$u" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    for o in $(printf '%s' "$owners" | LC_ALL=C tr ',' ' '); do
      [[ -n "$o" ]] || continue
      case "/$lu/" in *[/:@.]"$o"/*) return 0 ;; esac
    done
  done
  return 1
}

# scope_repo_urls: every fetch and push URL of every remote of the current
# repository, one per line. Return 2 when git failed.
scope_repo_urls() {
  local r names
  names="$(git remote 2>/dev/null)" || return 2
  for r in $names; do
    git remote get-url --all "$r" 2>/dev/null || return 2
    git remote get-url --push --all "$r" 2>/dev/null || return 2
  done
  return 0
}

# Executed rather than sourced: this file only defines functions, so print the
# header and stop (0 for -h/--help, 2 otherwise).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    -h|--help) sed -n '2,/^# ----/p' "${BASH_SOURCE[0]}" | sed -e '/^# ---/d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) sed -n '2,/^# ----/p' "${BASH_SOURCE[0]}" | sed -e '/^# ---/d' -e 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
fi
