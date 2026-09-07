#!/usr/bin/env bash
# SCRIPT: manifest_test.sh
# DESCRIPTION: Smoke tests for lib/manifest.sh (detect, read, write, sync, versionCode).
# USAGE: ./tests/manifest_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/manifest_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[manifest_test] $*"; }
error() { echo "[manifest_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import manifest

# 1) functions defined after import
for fn in manifest_kind manifest_detect manifest_read_version \
          manifest_write_version manifest_android_version_code manifest_sync_version; do
  if declare -f "$fn" >/dev/null 2>&1; then
    note "$fn is defined"
  else
    error "$fn is NOT defined"
  fi
done

# 2) bad args return exactly 2
set +e
manifest_kind >/dev/null 2>&1;              [[ $? -eq 2 ]] || error "manifest_kind with no args did not return 2"
manifest_read_version >/dev/null 2>&1;      [[ $? -eq 2 ]] || error "manifest_read_version with no args did not return 2"
manifest_write_version >/dev/null 2>&1;     [[ $? -eq 2 ]] || error "manifest_write_version with no args did not return 2"
manifest_android_version_code >/dev/null 2>&1; [[ $? -eq 2 ]] || error "manifest_android_version_code with no args did not return 2"
manifest_kind foo.txt >/dev/null 2>&1;      [[ $? -eq 2 ]] || error "manifest_kind on an unknown name did not return 2"
set -e
note "bad arguments return 2"

# 3) versionCode arithmetic, and a refusal rather than a wrong number
[[ "$(manifest_android_version_code 1.2.3)"  == "10203" ]] || error "1.2.3 should map to 10203"
[[ "$(manifest_android_version_code 2.11.7)" == "21107" ]] || error "2.11.7 should map to 21107"
[[ "$(manifest_android_version_code 1.2.3 5)" == "10208" ]] || error "offset is not applied"
set +e
manifest_android_version_code "not-a-version" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "a non-semver version returned $status (expected 2)"
note "versionCode arithmetic is correct"

# 4) round-trip each manifest kind in a temp tree
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/android/app"
printf 'name: demo\nversion: 1.2.3+45\n'                                    > "$tmp/pubspec.yaml"
printf 'android {\n  defaultConfig {\n    versionCode 10203\n    versionName "1.2.3"\n  }\n}\n' > "$tmp/android/app/build.gradle"
printf '1.2.3\n'                                                            > "$tmp/VERSION"
printf '{\n  "name": "demo",\n  "version": "1.2.3"\n}\n'                    > "$tmp/package.json"
printf '[project]\nversion = "1.2.3"\n'                                     > "$tmp/pyproject.toml"

for f in pubspec.yaml android/app/build.gradle VERSION package.json pyproject.toml; do
  got="$(manifest_read_version "$tmp/$f" 2>/dev/null)"
  if [[ "$got" == "1.2.3" ]]; then
    note "read $f -> 1.2.3"
  else
    error "read $f gave '$got' (expected 1.2.3)"
  fi
done

# detect finds every one of them
found="$(manifest_detect "$tmp" | wc -l)"
[[ "$found" -eq 5 ]] || error "manifest_detect found $found manifests (expected 5)"

# 5) sync writes them all, preserves the pubspec build number, recomputes versionCode
manifest_sync_version "$tmp" 2.0.0 >/dev/null 2>&1 || error "manifest_sync_version failed"
for f in pubspec.yaml android/app/build.gradle VERSION package.json pyproject.toml; do
  got="$(manifest_read_version "$tmp/$f" 2>/dev/null)"
  [[ "$got" == "2.0.0" ]] || error "after sync, $f reads '$got' (expected 2.0.0)"
done
grep -q 'version: 2.0.0+45' "$tmp/pubspec.yaml" \
  || error "pubspec build number '+45' was not preserved"
grep -q 'versionCode 20000' "$tmp/android/app/build.gradle" \
  || error "versionCode was not recomputed to 20000"
note "sync updates every manifest and preserves the build number"

# 6) a rewrite is refused rather than emptying a file
set +e
manifest_write_version "$tmp/VERSION" "not-a-version" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "writing a non-semver version returned $status (expected 2)"
[[ -s "$tmp/VERSION" ]] || error "VERSION was emptied by a rejected write"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
