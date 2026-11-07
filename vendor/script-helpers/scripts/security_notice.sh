#!/usr/bin/env bash
# SCRIPT: security_notice.sh
# DESCRIPTION: Show the tool, branch and local remediation without scanner results.
# USAGE: source scripts/security_notice.sh; security_notice <Gitleaks|Foxguard|Security> [local-report]
# PARAMETERS:
#   <tool>          Known checker name; other values become Security.
#   <local-report>  Shown only outside CI.
#   SH_SECURITY_BRANCH  Branch being checked; defaults to GitHub's head or Git.
# EXIT_CODES:
#   0 Message written to stderr. The caller preserves its failure status.
# EXAMPLE: bash scripts/security_notice.sh Gitleaks
# ----------------------------------------------------

security_python() {
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -I -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

security_notice() {
  local tool="${1:-Security}" branch="${SH_SECURITY_BRANCH:-${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}}"
  case "$tool" in Gitleaks|Foxguard|Security) ;; *) tool=Security ;; esac
  if [[ -z "$branch" ]]; then
    branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || true)"
  fi
  [[ -n "$branch" ]] || branch='your working branch'
  printf '%s check failed.\nBranch: %s\n' "$tool" "$branch" >&2
  printf 'Leak-Lock: https://nikolareljin.github.io/leak-lock/\n' >&2
  printf 'Check out this branch locally and run Scan Repository in Leak-Lock. Fix the issues, then rerun the repository tests on this branch before pushing.\n' >&2
  if [[ -z "${CI:-}" && -z "${GITHUB_ACTIONS:-}" && -n "${2:-}" ]]; then
    printf 'Local report: %s\n' "$2" >&2
  fi
}

security_notice_tool() {
  if [[ ! -r "${1:-}" ]]; then printf '%s\n' Security; return; fi
  if grep -qi '^Foxguard check failed' "$1"; then
    printf '%s\n' Foxguard
  elif grep -Eqi '^Gitleaks check failed|\[sensitive\].*gitleaks|GITLEAKS_BIN' "$1"; then
    printf '%s\n' Gitleaks
  else
    printf '%s\n' Security
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
  security_notice "$@"
fi
