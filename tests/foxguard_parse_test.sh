#!/usr/bin/env bash
# SCRIPT: foxguard_parse_test.sh
# DESCRIPTION: The pinned foxguard reads every tracked file. The pre-push hook
#              and the foxguard-diff action refuse a change to a file foxguard
#              skips (a parse error, over 1 MiB), so such a file cannot be
#              edited. Uses the hook's own scan, sec_foxguard_scan. The files
#              in `known` are skipped on purpose and must stay skipped, so the
#              list cannot go stale.
# USAGE: bash tests/foxguard_parse_test.sh
# PARAMETERS:
#   FOXGUARD_CMD      foxguard to use (default: foxguard on PATH). It must be
#                     the version in scanner-pins.env; else the test is skipped.
#   FOXGUARD_REQUIRE  1 makes a missing or other-version foxguard a failure.
# EXIT CODES:
#   0  Only the known files are skipped, or the test was skipped.
#   1  Another file is skipped, a known one is read, or the scan failed.
# ----------------------------------------------------
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# tests/fixtures/go-new/gonew.go: Go 1.26 new(expr), which is the fixture's point.
# vendor/script-helpers/templates/packaging/brew/app.rb: an upstream template
# with @PLACEHOLDER@ lines, not Ruby until it is filled in
# (https://github.com/nikolareljin/script-helpers/issues/282).
known="tests/fixtures/go-new/gonew.go
vendor/script-helpers/templates/packaging/brew/app.rb"

skip() {
  if [[ "${FOXGUARD_REQUIRE:-0}" == 1 ]]; then echo "FAIL $1 and FOXGUARD_REQUIRE=1" >&2; exit 1; fi
  echo "SKIP $1"
  exit 0
}

fox="${FOXGUARD_CMD:-$(command -v foxguard 2>/dev/null || true)}"
[[ -n "$fox" ]] || skip "foxguard is not installed"
pin="$(awk -F= '$1 == "FOXGUARD_VERSION" { print $2; exit }' "$root/scanner-pins.env")"
# shellcheck disable=SC2086  # FOXGUARD_CMD may carry arguments
got="$($fox --version 2>/dev/null | awk '{ print $2; exit }')"
[[ -n "$pin" && "$got" == "$pin" ]] || skip "foxguard is '$got', scanner-pins.env pins '$pin'"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# shellcheck source=/dev/null
source "$root/vendor/script-helpers/scripts/security_hooks.sh" || exit 1

git -C "$root" ls-files > "$work/files" || exit 1
printf '{}\n' > "$work/config"
if ! sec_foxguard_scan "$fox" "$work/config" "$root" "$work/out" "$work/files"; then
  echo "FAIL the foxguard scan failed" >&2
  exit 1
fi
sed -e 's/^warning: skipping //' -e 's/ ([^()]*)$//' "$work/out.skipped" | LC_ALL=C sort > "$work/skipped"
printf '%s\n' "$known" | LC_ALL=C sort > "$work/known"

failures=0
while IFS= read -r f; do
  echo "FAIL foxguard skips $f: a change to it cannot be pushed. Make it parse." >&2
  failures=$((failures + 1))
done < <(comm -23 "$work/skipped" "$work/known")
while IFS= read -r f; do
  echo "FAIL foxguard reads $f now: remove it from 'known' in this test." >&2
  failures=$((failures + 1))
done < <(comm -13 "$work/skipped" "$work/known")
[[ "$failures" -eq 0 ]] || exit 1
echo "PASS foxguard $pin reads every tracked file but the $(wc -l < "$work/known" | tr -d ' ') known ones"
