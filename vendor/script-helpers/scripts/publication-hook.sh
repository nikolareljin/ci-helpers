#!/usr/bin/env bash
# SCRIPT: publication-hook.sh
# DESCRIPTION: CI outbound hook: refuse sensitive content before Git transfers it.
# USAGE: publication-hook.sh <pre-push|pre-commit|commit-msg> [hook arguments]
# PARAMETERS:
#   <hook>  Hook installed by install-publication-hooks.sh.
# EXIT_CODES:
#   0 Clear; 1 refused, including incomplete checks.
# EXAMPLE: Installed automatically by scripts/install-publication-hooks.sh --ci
# ----------------------------------------------------
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;; esac
umask 077
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$dir/security_notice.sh"
hook="${1:-}"; shift
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf -- "$tmp"; fi' EXIT
fail() { security_notice "$(security_notice_tool "$tmp/check")"; exit 1; }
case "$hook" in
  pre-push)
    cat > "$tmp/refs" || fail
    if [[ ! -s "$tmp/refs" ]]; then
      head="$(git rev-parse --verify HEAD)" || fail
      printf 'HEAD %s HEAD %s\n' "$head" "${head//?/0}" > "$tmp/refs"
    fi
    # A deletion or unchanged ref transports no new objects.
    changed=false
    while read -r lref lsha rref rsha; do
      [[ -n "$lref" && -n "$rref" && "$lsha" =~ ^[0-9a-f]{40,64}$ && "$rsha" =~ ^[0-9a-f]{40,64}$ ]] || fail
      [[ "$lsha" =~ ^0+$ || "$lsha" == "$rsha" ]] || changed=true
    done < "$tmp/refs"
    [[ "$changed" == true ]] || exit 0
    args=(--push-refs "$tmp/refs" --remote "${1:-}") ;;
  pre-commit) args=(--staged) ;;
  commit-msg) args=(--file "${1:?}") ;;
  *) fail ;;
esac
if ! bash "$dir/check_scan_output.sh" "${args[@]}" >"$tmp/check" 2>&1; then fail; fi
# CI: a file above 64 MiB that was not fully checked is a warning, not a stop.
grep -E '^::warning title=Security check incomplete::' "$tmp/check" || true
if ! bash "$dir/check_sensitive.sh" --no-inline-allow "${args[@]}" >"$tmp/check" 2>&1; then fail; fi
