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
    ios_build_release() { : > "$marks/build"; printf '%s' "${2:-}" > "$marks/build_plist"; }
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

# 4) A nested app plus a relative plist. The guard checks the path from the repo
#    root -- which is where the dev CLI puts you -- while ios_build_release
#    re-checks it after cd-ing into the project. When those are different
#    directories (mobile/, app/: the layout the shared dev CLI assumes) a
#    relative path names two different files, so the build either dies on a path
#    that just validated or signs with whichever plist sits inside the project.
#    What is handed on must therefore be absolute.
mkdir -p "$repo/mobile/ios"
: > "$repo/ExportOptions.plist"
rm -rf "$marks"; mkdir -p "$marks"
(
  # shellcheck source=/dev/null
  source "$repo/scripts/cli.sh"          # the bootstrap cds to the repo root
  shlib_import() { :; }
  ios_available() { :; }
  dev_is_flutter() { :; }
  dev_stack_dir() { echo "mobile"; }     # relative, as detection returns it
  ios_resolve_physical_device() { echo "00008110-001"; }
  ios_build_release() { printf '%s' "${2:-}" > "$marks/build_plist"; }
  ios_artifact() { echo "mobile/build/ios/ipa/App.ipa"; }
  ios_install() { :; }
  ios_bundle_id() { echo "com.example.app"; }
  ios_launch() { :; }
  # Read by _deploy_ios through dynamic scope, not by anything lexically here.
  # shellcheck disable=SC2034
  DEV_RELEASE=true
  DEV_DEVICE=""
  IOS_EXPORT_OPTIONS_PLIST="ExportOptions.plist"   # relative to the repo root
  _deploy_ios
) >/dev/null 2>&1
nested_plist_arg="$(cat "$marks/build_plist" 2>/dev/null)"
case "$nested_plist_arg" in
  /*) note "nested project: the plist handed on is absolute ($nested_plist_arg)" ;;
  "") error "nested project: ios_build_release never ran" ;;
  *)  error "nested project: relative plist passed through as '$nested_plist_arg' -- inside the project dir that names a different file" ;;
esac
[[ -n "$nested_plist_arg" && -f "$nested_plist_arg" ]] \
  && note "nested project: it resolves to the file the guard validated" \
  || error "nested project: '$nested_plist_arg' is not the validated file"

if [[ $failures -gt 0 ]]; then
  echo "[dev_deploy_ios_test] FAILED ($failures)" >&2
  exit 1
fi
note "all checks passed"
