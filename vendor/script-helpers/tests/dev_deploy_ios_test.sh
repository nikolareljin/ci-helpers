#!/usr/bin/env bash
# SCRIPT: dev_deploy_ios_test.sh
# DESCRIPTION: Tests the guard on `./dev deploy ios --release`.
# USAGE: bash tests/dev_deploy_ios_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/dev_deploy_ios_test.sh
# ----------------------------------------------------
#
# A release deploy without IOS_EXPORT_OPTIONS_PLIST used to install the wrong
# binary and report success: `ios_build_release` with no plist builds an
# unsigned .app under build/ios/iphoneos, while the install step globs
# build/ios/ipa newest-first, so an .ipa left by an earlier signed build was
# picked up and pushed to the device. Nothing on the path returns non-zero, so
# only a test that watches the build and install steps can catch it.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[dev_deploy_ios_test] $*"; }
error() { echo "[dev_deploy_ios_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A stand-in consumer repo running the real template: the bootstrap finds the
# library through scripts/script-helpers, which is the canonical layout.
repo="$tmp/repo"
mkdir -p "$repo/scripts"
git -C "$repo" init -q .
cp templates/dev-cli/cli.sh templates/dev-cli/_bootstrap.sh "$repo/scripts/"
ln -s "$ROOT_DIR" "$repo/scripts/script-helpers"
marks="$tmp/marks"

# Runs _deploy_ios against stubs and prints its exit status. The stubs replace
# shlib_import first: _deploy_ios imports the ios module itself, which would
# otherwise reload the real functions over these.
run_deploy_ios() {
  rm -rf "$marks"; mkdir -p "$marks"
  (
    # shellcheck source=/dev/null
    source "$repo/scripts/cli.sh"          # the source guard stops main
    shlib_import() { :; }
    ios_available() { :; }
    dev_is_flutter() { :; }
    dev_stack_dir() { echo "$repo"; }
    ios_resolve_physical_device() { : > "$marks/resolve"; echo "00008110-001"; }
    ios_build_release() { : > "$marks/build"; }
    ios_artifact() { : > "$marks/artifact"; echo "$repo/build/ios/ipa/App.ipa"; }
    ios_install() { : > "$marks/install"; }
    DEV_RELEASE=true
    DEV_DEVICE=""
    _deploy_ios
  ) >/dev/null 2>&1
  echo "$?"
}

ran() { [[ -e "$marks/$1" ]]; }

# 1) No plist: refused, and refused before the slow build runs.
unset IOS_EXPORT_OPTIONS_PLIST
rc="$(run_deploy_ios)"
[[ "$rc" -eq 1 ]] \
  && note "no plist: refused with exit 1" \
  || error "no plist: expected exit 1, got $rc"
ran build \
  && error "no plist: built anyway — the stale-IPA install is still reachable" \
  || note "no plist: no build ran"
ran install \
  && error "no plist: installed anyway" \
  || note "no plist: nothing was installed"

# 2) A plist that does not exist is a config error too, and is worth hearing
#    before the build rather than from xcodebuild.
export IOS_EXPORT_OPTIONS_PLIST="$tmp/missing.plist"
rc="$(run_deploy_ios)"
[[ "$rc" -eq 1 ]] \
  && note "missing plist file: refused with exit 1" \
  || error "missing plist file: expected exit 1, got $rc"
ran build \
  && error "missing plist file: built before checking the path" \
  || note "missing plist file: no build ran"

# 3) The guard must not block the case it exists to protect: with a real plist
#    the release path builds and installs as before.
export IOS_EXPORT_OPTIONS_PLIST="$tmp/export.plist"
: > "$IOS_EXPORT_OPTIONS_PLIST"
rc="$(run_deploy_ios)"
[[ "$rc" -eq 0 ]] \
  && note "with a plist: the release deploy runs" \
  || error "with a plist: expected exit 0, got $rc"
ran build && note "with a plist: the build ran" || error "with a plist: no build ran"
ran install && note "with a plist: the install ran" || error "with a plist: no install ran"

if [[ $failures -gt 0 ]]; then
  echo "[dev_deploy_ios_test] FAILED ($failures)" >&2
  exit 1
fi
note "all checks passed"
