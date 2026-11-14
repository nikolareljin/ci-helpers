#!/usr/bin/env bash
# The sync and the verifier must exclude the same paths, and the vendored tree
# must hold none of them. A path excluded by one list only is either re-vendored
# by the next sync or never checked.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
list() { grep -E "^$1=\(" "$2" | sed -E 's/^[A-Z_]+=\((.*)\)$/\1/' | tr ' ' '\n' | tr -d '"' | LC_ALL=C sort; }

sync_list="$(list VENDOR_EXCLUDES "$ROOT_DIR/scripts/sync_script_helpers.sh")"
verify_list="$(list FORBIDDEN_PATHS "$ROOT_DIR/scripts/verify_vendor.sh")"
[[ -n "$sync_list" ]] || { echo "FAIL: VENDOR_EXCLUDES not found" >&2; exit 1; }
if [[ "$sync_list" != "$verify_list" ]]; then
  echo "FAIL: VENDOR_EXCLUDES and FORBIDDEN_PATHS differ" >&2
  diff <(echo "$sync_list") <(echo "$verify_list") >&2 || true
  exit 1
fi

fail=0
while IFS= read -r path; do
  if [[ -e "$ROOT_DIR/vendor/script-helpers/$path" ]]; then
    echo "FAIL: vendor/script-helpers/$path is vendored but excluded" >&2
    fail=1
  fi
done <<< "$sync_list"
[[ "$fail" -eq 0 ]] || exit 1

# Upstream's workflow-action gate names this repository; vendoring it trips the
# circular-reference check in verify_vendor.sh.
if grep -rq "nikolareljin/ci-helpers" "$ROOT_DIR/vendor/script-helpers"; then
  echo "FAIL: vendored tree references nikolareljin/ci-helpers" >&2
  exit 1
fi
echo "PASS: vendor exclusions agree and the vendored tree holds none of them"
