#!/usr/bin/env bash
# SCRIPT: local_test_gradle.sh
# DESCRIPTION: Lint, unit-test and assemble a Gradle project on the host.
# USAGE: bash scripts/local_test_gradle.sh [--quick] [--dir <path>] [--android]
#
# PARAMETERS:
#   --quick    Run unit tests only; skip lint and the assemble step.
#   --dir      Project directory containing gradlew (default: .).
#   --android  Use the Android task names (lintDebug, testDebugUnitTest,
#              assembleDebug) instead of the plain JVM ones (lint, test, build).
#              Autodetected from the presence of an Android plugin when omitted.
# EXIT_CODES:
#   0  All requested checks passed.
#   1  A check failed, or no Gradle wrapper was found.
# ----------------------------------------------------
set -euo pipefail

QUICK=false
GRADLE_DIR="."
ANDROID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true ;;
    --android) ANDROID=true ;;
    --dir)
      if [[ $# -lt 2 ]]; then
        echo "[local-test-gradle] --dir requires a path." >&2
        exit 1
      fi
      GRADLE_DIR="$2"
      shift
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ ! -d "$repo_root/$GRADLE_DIR" ]]; then
  echo "[local-test-gradle] Directory not found: $repo_root/$GRADLE_DIR" >&2
  exit 1
fi
cd "$repo_root/$GRADLE_DIR"

if [[ ! -x ./gradlew ]]; then
  echo "[local-test-gradle] No executable ./gradlew in $GRADLE_DIR (looked in $PWD)." >&2
  echo "[local-test-gradle] A system gradle would use a different version than the project pins." >&2
  exit 1
fi

# Autodetect Android when the caller did not say. The Android plugin is applied
# in a build file; a plain JVM project has no lintDebug/assembleDebug tasks and
# would fail on them.
if [[ -z "$ANDROID" ]]; then
  if grep -rqsE 'com\.android\.(application|library)' \
       --include='build.gradle' --include='build.gradle.kts' \
       --include='libs.versions.toml' . ; then
    ANDROID=true
  else
    ANDROID=false
  fi
fi

# An Android build needs the SDK location, and neither ANDROID_HOME nor a
# local.properties `sdk.dir` is reliably set in a plain shell — so a project that
# builds in an IDE fails here with "SDK location not found", which reads as a
# project fault rather than an environment one. Reuse the android module's lookup
# rather than repeating it; an already-set value wins.
if [[ "$ANDROID" == "true" ]]; then
  _sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -f "$_sh_dir/helpers.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_sh_dir/helpers.sh"
    shlib_import android >/dev/null 2>&1 || true
    if declare -f android_sdk_root >/dev/null 2>&1 && _sdk="$(android_sdk_root 2>/dev/null)"; then
      export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$_sdk}"
      export ANDROID_HOME="${ANDROID_HOME:-$_sdk}"
    fi
  fi
fi

if [[ "$ANDROID" == "true" ]]; then
  LINT_TASK="lintDebug"; TEST_TASK="testDebugUnitTest"; BUILD_TASK="assembleDebug"
else
  LINT_TASK="lint"; TEST_TASK="test"; BUILD_TASK="build"
fi

if [[ "$QUICK" == "false" ]]; then
  echo "[local-test-gradle] ./gradlew $LINT_TASK"
  ./gradlew --no-daemon "$LINT_TASK"
fi

echo "[local-test-gradle] ./gradlew $TEST_TASK"
./gradlew --no-daemon "$TEST_TASK"

if [[ "$QUICK" == "false" ]]; then
  echo "[local-test-gradle] ./gradlew $BUILD_TASK"
  ./gradlew --no-daemon "$BUILD_TASK"
fi

echo "[local-test-gradle] Done."
