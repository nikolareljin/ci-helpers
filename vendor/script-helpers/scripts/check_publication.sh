#!/usr/bin/env bash
# SCRIPT: check_publication.sh
# DESCRIPTION: Refuse credentials, personal data and scanner output before publication.
# USAGE: scripts/check_publication.sh --file <path> | --stdin
# PARAMETERS:
#   --file PATH  Check a complete publication file; repeatable.
#   --stdin      Check publication text on stdin.
#   -h, --help   Show help.
# Built binaries and packages (ELF, Mach-O, PE, AppImage, deb, rpm, APK/AAB/JAR,
# disk images, <name>.split-NNN parts), found by their magic bytes, get the
# secrets-only profile: credentials and a local home path block; email, phone
# and card patterns and a CI runner's home path do not. Each downgrade is
# named on stderr ("NOTICE: security policy:"), never with the matched value.
# EXIT_CODES:
#   0 Clear; 1 refused; 2 unable to check; 3 a file above 64 MiB was not fully
#   checked (local runs only; CI prints a warning and exits 0).
#   Never publish on a nonzero exit.
# EXAMPLE: scripts/check_publication.sh --file pr-body.md
# ----------------------------------------------------
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$dir/security_notice.sh"
case "${1:-}" in -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;; esac
umask 077
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf -- "$tmp"; fi' EXIT
if [[ "${1:-}" == --stdin && $# -eq 1 ]]; then
  cat > "$tmp/text"
  set -- --file "$tmp/text"
fi
[[ "${1:-}" == --file ]] || exit 2
text_files=()
binary_files=()
for ((i = 1; i <= $#; i += 2)); do
  j=$((i + 1))
  [[ "${!i}" == --file && $j -le $# ]] || exit 2
  f="${!j}"
  kind=""
  kind="$(bash "$dir/check_scan_output.sh" --classify "$f" 2>/dev/null)" || kind=""
  case "$kind" in
    "") security_notice Security; exit 2 ;;
    text) text_files+=(--file "$f") ;;
    *)
      binary_files+=(--file "$f")
      printf 'NOTICE: security policy: %s: %s: built binary: email, phone and card patterns and CI runner home paths do not block; secrets and local home paths do\n' \
        "$(printf '%s' "$f" | tr -d '\000-\037\177')" "$kind" >&2 ;;
  esac
done
# forward_incomplete: show the checker's own incomplete-check lines (path and reason only).
forward_incomplete() {
  grep -E '^::warning title=Security check incomplete::' "$tmp/check" || true
  grep -E '^WARNING: security check incomplete' "$tmp/check" >&2 || true
}
# forward_notices: policy downgrades (path and category only).
forward_notices() {
  grep -E '^NOTICE: security policy: ' "$tmp/check" >&2 || true
}
rc=0
bash "$dir/check_scan_output.sh" "$@" >"$tmp/check" 2>&1 || rc=$?
incomplete=0
forward_notices
if [[ "$rc" -eq 0 || "$rc" -eq 3 ]]; then
  forward_incomplete
  [[ "$rc" -eq 3 ]] && incomplete=3
  rc=0
fi
if [[ "$rc" -ne 0 ]]; then
  security_notice "$(security_notice_tool "$tmp/check")"
  [[ "$rc" -eq 1 ]] && exit 1
  exit 2
fi
# check_sensitive <args...>: credentials, personal terms and data; exits on a finding.
check_sensitive() {
  local rc=0
  bash "$dir/check_sensitive.sh" --no-inline-allow "$@" >"$tmp/check" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    security_notice "$(security_notice_tool "$tmp/check")"
    [[ "$rc" -eq 1 ]] && exit 1
    exit 2
  fi
}
[[ ${#text_files[@]} -eq 0 ]] || check_sensitive "${text_files[@]}"
[[ ${#binary_files[@]} -eq 0 ]] || check_sensitive --binary "${binary_files[@]}"
exit "$incomplete"
