#!/usr/bin/env bash
# SCRIPT: flutter_test.sh
# DESCRIPTION: Smoke tests for lib/flutter.sh (SDK resolution, build, devices).
# USAGE: ./tests/flutter_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/flutter_test.sh
# ----------------------------------------------------
#
# The Flutter SDK is not assumed. Anything needing it is a skip with a note,
# never a failure.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[flutter_test] $*"; }
error() { echo "[flutter_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import flutter

# 1) functions defined after import
for fn in flutter_available flutter_resolve_sdk flutter_run_cmd flutter_pub_get \
          flutter_analyze flutter_format_check flutter_test flutter_build \
          flutter_devices flutter_resolve_device; do
  if declare -f "$fn" >/dev/null 2>&1; then
    note "$fn is defined"
  else
    error "$fn is NOT defined"
  fi
done

# 2) bad args return exactly 2
set +e
flutter_run_cmd >/dev/null 2>&1;                  [[ $? -eq 2 ]] || error "flutter_run_cmd with no args did not return 2"
flutter_build >/dev/null 2>&1;                    [[ $? -eq 2 ]] || error "flutter_build with no target did not return 2"
flutter_build bogus >/dev/null 2>&1;              [[ $? -eq 2 ]] || error "flutter_build with an unknown target did not return 2"
flutter_build apk . --nonsense >/dev/null 2>&1;   [[ $? -eq 2 ]] || error "flutter_build with an unknown option did not return 2"
flutter_test --nonsense >/dev/null 2>&1;          [[ $? -eq 2 ]] || error "flutter_test with an unknown option did not return 2"
set -e
note "bad arguments return 2"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 3) a missing directory is an argument error, checked before the SDK lookup
set +e
flutter_run_cmd "$tmp/nonexistent" --version >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "flutter_run_cmd on a missing dir returned $status (expected 2)"

# 4) SDK resolution finds a stub via FLUTTER_ROOT — this is the path that four
#    consumer repos had pasted into their own scripts.
mkdir -p "$tmp/sdk/bin"
printf '#!/usr/bin/env bash\necho "stub flutter $*"\n' > "$tmp/sdk/bin/flutter"
chmod +x "$tmp/sdk/bin/flutter"

if command -v flutter >/dev/null 2>&1; then
  note "a real flutter is on PATH — skipping the FLUTTER_ROOT resolution assertion"
else
  got="$(FLUTTER_ROOT="$tmp/sdk" flutter_resolve_sdk 2>/dev/null)"
  [[ "$got" == "$tmp/sdk/bin/flutter" ]] \
    || error "flutter_resolve_sdk did not honour FLUTTER_ROOT (got '$got')"
  FLUTTER_ROOT="$tmp/sdk" flutter_available \
    || error "flutter_available said no with FLUTTER_ROOT set to a valid SDK"
  note "FLUTTER_ROOT is honoured when flutter is not on PATH"
fi

# 5) with no SDK anywhere, resolution returns 3 rather than a bare failure
set +e
( unset FLUTTER_ROOT FLUTTER_HOME
  PATH=/nonexistent HOME="$tmp/empty-home" flutter_resolve_sdk >/dev/null 2>&1 )
status=$?
set -e
[[ "$status" -eq 3 ]] || error "flutter_resolve_sdk with no SDK returned $status (expected 3)"
note "a missing SDK returns 3"

# 6) real-SDK paths, only when one is actually installed
if flutter_available; then
  note "flutter is installed at $(flutter_resolve_sdk)"
else
  set +e
  flutter_pub_get "$tmp" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 3 ]] || error "flutter_pub_get with no SDK returned $status (expected 3)"
  note "no Flutter SDK installed — skipping the real-SDK assertions (not a failure)"
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
