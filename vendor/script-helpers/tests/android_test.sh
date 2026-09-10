#!/usr/bin/env bash
# SCRIPT: android_test.sh
# DESCRIPTION: Smoke tests for lib/android.sh and lib/gradle.sh.
# USAGE: ./tests/android_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/android_test.sh
# ----------------------------------------------------
#
# The Android SDK and a Gradle wrapper are not assumed. Anything needing them is
# a skip with a note, never a failure.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[android_test] $*"; }
error() { echo "[android_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import android

# 1) functions defined after import — including gradle's, which android loads
for fn in android_available android_sdk_root android_sdk_tool android_ensure_sdk \
          android_gradlew android_build android_artifact android_sign \
          android_avd_list android_avd_create android_emulator_start android_emulator_stop; do
  if declare -f "$fn" >/dev/null 2>&1; then
    note "$fn is defined"
  else
    error "$fn is NOT defined"
  fi
done

for fn in gradle_available gradle_wrapper gradle_run gradle_lint gradle_test gradle_assemble gradle_clean; do
  declare -f "$fn" >/dev/null 2>&1 \
    || error "$fn is not defined — android did not load the gradle module"
done
for fn in adb_ready_serials adb_getprop adb_available; do
  declare -f "$fn" >/dev/null 2>&1 \
    || error "$fn is not defined — android did not load the adb module"
done
note "dependency modules are loaded by import"

# 2) bad args return exactly 2
set +e
android_sdk_tool >/dev/null 2>&1;               [[ $? -eq 2 ]] || error "android_sdk_tool with no args did not return 2"
android_build . bogus apk >/dev/null 2>&1;      [[ $? -eq 2 ]] || error "android_build with a bad variant did not return 2"
android_build . debug bogus >/dev/null 2>&1;    [[ $? -eq 2 ]] || error "android_build with a bad format did not return 2"
android_avd_create >/dev/null 2>&1;             [[ $? -eq 2 ]] || error "android_avd_create with no name did not return 2"
android_sign >/dev/null 2>&1;                   [[ $? -eq 2 ]] || error "android_sign with no artifact did not return 2"
android_sign --bogus x >/dev/null 2>&1;         [[ $? -eq 2 ]] || error "android_sign with an unknown option did not return 2"
gradle_run >/dev/null 2>&1;                     [[ $? -eq 2 ]] || error "gradle_run with no args did not return 2"
gradle_run /nonexistent-dir test >/dev/null 2>&1; [[ $? -eq 2 ]] || error "gradle_run on a missing dir did not return 2"
set -e
note "bad arguments return 2"

# Canonicalised with `pwd -P`: on macOS /var is a symlink to /private/var, so
# mktemp returns /var/folders/... while anything resolving the path returns
# /private/var/folders/... . gradle_wrapper deliberately returns a resolved
# path, so an unresolved fixture path fails the comparison on macOS only.
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# 3) signing: a missing keystore is an error, unless the caller opted into the
#    debug-signed fallback. This is the branch a local build depends on.
printf 'fake apk' > "$tmp/app.apk"
set +e
android_sign "$tmp/app.apk" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "android_sign without a keystore returned $status (expected 2)"

set +e
android_sign "$tmp/app.apk" --allow-unsigned >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 0 ]] || error "android_sign --allow-unsigned returned $status (expected 0)"
note "the debug-signed fallback is opt-in and works"

# 4) an invalid base64 keystore is rejected, and leaves no temp file behind
set +e
SH_TEST_KS="not valid base64 !!!" android_sign "$tmp/app.apk" --base64-env SH_TEST_KS --alias x >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "android_sign with invalid base64 returned $status (expected 2)"

set +e
SH_TEST_EMPTY="" android_sign "$tmp/app.apk" --base64-env SH_TEST_EMPTY --alias x >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "android_sign with an empty base64 var returned $status (expected 2)"
note "a malformed base64 keystore is rejected"

# 5) gradle_wrapper prefers the project wrapper over a system gradle
mkdir -p "$tmp/proj"
printf '#!/usr/bin/env bash\necho gradlew "$@"\n' > "$tmp/proj/gradlew"
chmod +x "$tmp/proj/gradlew"
got="$(gradle_wrapper "$tmp/proj")"
[[ "$got" == "$tmp/proj/gradlew" ]] || error "gradle_wrapper gave '$got' (expected the project wrapper)"
gradle_available "$tmp/proj" || error "gradle_available said no with a wrapper present"
note "the project wrapper is preferred over a system gradle"

# 6) gradle_wrapper returns 3 when there is neither
mkdir -p "$tmp/bare"
if command -v gradle >/dev/null 2>&1; then
  note "a system gradle is installed — skipping the no-gradle assertion"
else
  set +e
  gradle_wrapper "$tmp/bare" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 3 ]] || error "gradle_wrapper with no gradle at all returned $status (expected 3)"
fi

# 7) android_artifact reports "not built" distinctly from "here it is"
set +e
android_artifact "$tmp/proj" debug apk >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || error "android_artifact with nothing built returned $status (expected 1)"

mkdir -p "$tmp/proj/app/build/outputs/apk/debug"
printf 'apk' > "$tmp/proj/app/build/outputs/apk/debug/app-debug.apk"
got="$(android_artifact "$tmp/proj" debug apk 2>/dev/null)"
[[ "$got" == *"app-debug.apk" ]] || error "android_artifact did not find the built APK (got '$got')"
note "android_artifact distinguishes not-built from built"

# 8) SDK-dependent paths degrade rather than crash
if android_available; then
  note "an Android SDK is present at $(android_sdk_root)"
else
  set +e
  android_sdk_root >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 3 ]] || error "android_sdk_root with no SDK returned $status (expected 3)"
  note "no Android SDK installed — skipping the SDK assertions (not a failure)"
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
