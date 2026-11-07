#!/usr/bin/env bash
# SCRIPT: check_publication.sh
# DESCRIPTION: Refuse credentials, personal data and scanner output before publication.
# USAGE: scripts/check_publication.sh --file <path> | --stdin
# PARAMETERS:
#   --file PATH  Check a complete publication file; repeatable.
#   --stdin      Check publication text on stdin.
#   -h, --help   Show help.
# EXIT_CODES:
#   0 Clear; 1 refused; 2 unable to check. Never publish on a nonzero exit.
# EXAMPLE: scripts/check_publication.sh --file pr-body.md
# ----------------------------------------------------
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$dir/security_notice.sh"
case "${1:-}" in -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;; esac
umask 077
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
if [[ "${1:-}" == --stdin && $# -eq 1 ]]; then
  cat > "$tmp/text"
  set -- --file "$tmp/text"
fi
[[ "${1:-}" == --file ]] || exit 2
rc=0
bash "$dir/check_scan_output.sh" "$@" >"$tmp/check" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  security_notice "$(security_notice_tool "$tmp/check")"
  [[ "$rc" -eq 1 ]] && exit 1
  exit 2
fi
rc=0
bash "$dir/check_sensitive.sh" --no-inline-allow "$@" >"$tmp/check" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  security_notice "$(security_notice_tool "$tmp/check")"
  [[ "$rc" -eq 1 ]] && exit 1
  exit 2
fi
