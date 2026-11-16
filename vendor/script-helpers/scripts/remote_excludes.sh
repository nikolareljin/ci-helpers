#!/usr/bin/env bash
# SCRIPT: remote_excludes.sh
# DESCRIPTION: The commits a push target already has, for the push gates to leave out.
# USAGE: source scripts/remote_excludes.sh; remote_excludes <repo> <remote> | bash scripts/remote_excludes.sh <repo> <remote>
# PARAMETERS:
#   <repo>    Repository path.
#   <remote>  Remote pushed to (git's first pre-push argument).
# EXIT_CODES:
#   0 Prints the commit ids of refs/remotes/<remote>/, one per line (none when
#     the namespace is empty).
#   1 Refused: nothing may be left out, check the whole range.
#   2 Executed with the wrong arguments.
# EXAMPLE: bash scripts/remote_excludes.sh . origin
# ----------------------------------------------------
# One definition for check_sensitive.sh, security_hooks.sh and
# check_scan_output.py. Refused unless all of these hold:
# - <remote> is a configured remote (a bare URL has no tracking refs);
# - every URL git pushes to equals the URL it fetches from, after insteadOf and
#   pushInsteadOf: otherwise the tracking refs describe another repository;
# - every fetch refspec of <remote> writes under refs/remotes/<remote>/, and no
#   other remote's does (a remote named origin/x writes under origin/, and a
#   refspec ending in refs/remotes/* writes everywhere).
# Ids are checked to be hex, so callers can word-split them (gitleaks --log-opts).

remote_excludes() {
  local top="$1" remote="$2" remotes r spec dst url pu id
  [[ -n "$top" && -n "$remote" ]] || return 1
  remotes="$(git -C "$top" remote 2>/dev/null)" || return 1
  # Here-string, not a pipe: grep -q exits early and can SIGPIPE the writer (141 under pipefail).
  grep -qxF -- "$remote" <<< "$remotes" || return 1
  url="$(git -C "$top" remote get-url "$remote" 2>/dev/null)" || return 1
  while IFS= read -r pu; do
    [[ "$pu" == "$url" ]] || return 1
  done <<< "$(git -C "$top" remote get-url --push --all "$remote" 2>/dev/null || echo "-")"
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    while IFS= read -r spec; do
      [[ -n "$spec" ]] || { [[ "$r" == "$remote" ]] && return 1; continue; }
      # A negative refspec (^refs/heads/x) only narrows what is fetched.
      [[ "$spec" == ^* ]] && continue
      dst="${spec#+}"; [[ "$dst" == *:* ]] && dst="${dst#*:}" || dst=""
      if [[ "$r" == "$remote" ]]; then
        [[ "$dst" == "refs/remotes/$remote/"* ]] || return 1
      else
        [[ "$dst" == "refs/remotes/$remote/"* ]] && return 1
        # A wildcard above the namespace reaches into it too: other's
        # refs/remotes/* maps its branch origin/main to refs/remotes/origin/main.
        if [[ "$dst" == *'*'* && "refs/remotes/$remote/" == "${dst%%\**}"* ]]; then return 1; fi
      fi
    done <<< "$(git -C "$top" config --get-all "remote.$r.fetch" 2>/dev/null)"
  done <<< "$remotes"
  # Unique ids: many refs share a tip, and Windows caps a command line at 32 KiB.
  id="$(git -C "$top" for-each-ref --format='%(objectname)' "refs/remotes/$remote/" 2>/dev/null)" || return 1
  id="$(LC_ALL=C sort -u <<< "$id")" || return 1
  while IFS= read -r pu; do
    [[ -n "$pu" ]] || continue
    [[ "$pu" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
    printf '%s\n' "$pu"
  done <<< "$id"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    -h|--help) sed -n '2,/^# ----/p' "${BASH_SOURCE[0]}" | sed -e '/^# ---/d' -e 's/^# \{0,1\}//'; exit 0 ;;
  esac
  [[ $# -eq 2 ]] || { echo "usage: remote_excludes.sh <repo> <remote>" >&2; exit 2; }
  remote_excludes "$1" "$2"
fi
