#!/usr/bin/env bash
# SCRIPT: ios_test.sh
# DESCRIPTION: Regression tests for the iOS helper module.
# USAGE: ./tests/ios_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ios_test.sh
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=/dev/null
source ./helpers.sh
shlib_import ios

OSTYPE=darwin
boot_calls=0
install_calls=0
simctl_output=""
boot_status=0
boot_reveal_after=0
boot_reveals=""
# `trap ... EXIT` replaces the handler rather than adding to it, and this file
# creates temporaries in three places -- which is how the last one silently
# orphaned the ones before it. One handler, one list appended to as each
# temporary appears, so a new one cannot introduce that bug again.
_cleanup_paths=()
_cleanup() { [[ ${#_cleanup_paths[@]} -gt 0 ]] && rm -rf "${_cleanup_paths[@]+"${_cleanup_paths[@]}"}"; return 0; }
trap _cleanup EXIT

boot_poll_file="$(mktemp)"
_cleanup_paths+=("$boot_poll_file")
shutdown_status=0
devicectl_available=false
xctrace_output=""

xcrun() {
  if [[ "$1 $2 ${3:-}" == "xctrace list devices" ]]; then
    printf '%s' "$xctrace_output"
    return 0
  fi
  if [[ "$1 $2 ${3:-}" == "simctl list devices" ]]; then
    # A listing that fails outright, for the polling loop's error path.
    [[ "${list_status:-0}" -ne 0 ]] && return "$list_status"
    # `booted` with boot_reveal_after set models the real thing: simctl boot
    # returns while the device is still Booting, and it does not appear in this
    # listing until it reaches Booted.
    if [[ "${4:-}" == "booted" && "$boot_reveal_after" -gt 0 ]]; then
      # Counted in a file, not a variable: every caller of this listing reads it
      # through $( ) or process substitution, and a subshell's increment is lost.
      local n; n=$(cat "$boot_poll_file" 2>/dev/null || echo 0)
      n=$((n + 1)); echo "$n" > "$boot_poll_file"
      [[ "$n" -lt "$boot_reveal_after" ]] && return 0
    fi
    printf '%s' "$simctl_output"
    return 0
  fi
  if [[ "$1 $2" == "simctl boot" ]]; then
    boot_calls=$((boot_calls + 1))
    # A successful boot makes the device appear in `list devices booted` -- but
    # only once it reaches Booted, which boot_reveal_after models.
    [[ "$boot_status" -eq 0 && -n "$boot_reveals" ]] && \
      simctl_output="${simctl_output:+$simctl_output$'\n'}$boot_reveals"
    return "$boot_status"
  fi
  if [[ "$1 $2 ${3:-}" == "simctl shutdown all" ]]; then
    return "$shutdown_status"
  fi
  if [[ "$1 $2" == "devicectl --version" ]]; then
    "$devicectl_available"
    return
  fi
  if [[ "$1 $2" == "simctl install" ]]; then
    install_calls=$((install_calls + 1))
    return 0
  fi
  return 1
}

xctrace_output='== Devices ==
Nikos iPhone (18.5) (00008110-001234567890001E)
Office iPad (17.7.8) (00008101-00ABCDEF1234001E)
Apple Watch (11.5) (00008120-00FEDCBA4321001E)
== Simulators ==
iPhone 15 Simulator (18.5) (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)'
output="$(ios_list_devices)"
expected='Nikos iPhone (00008110-001234567890001E)
Office iPad (00008101-00ABCDEF1234001E)'
[[ "$output" == "$expected" ]] || {
  echo "unexpected physical device list: $output" >&2
  exit 1
}

if ios_launch "simulator-id"; then
  echo "ios_launch accepted a missing bundle id" >&2
  exit 1
fi

output="$(ios_booted_simulators)"
[[ -z "$output" ]] || { echo "expected no booted simulator output" >&2; exit 1; }

simctl_output='    iPhone 15 (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) (Booted)'
output="$(ios_booted_simulators)"
[[ "$output" == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" ]] || {
  echo "unexpected booted simulator UDID: $output" >&2
  exit 1
}

ios_boot_simulator "iPhone 15"
[[ "$boot_calls" -eq 0 ]] || { echo "already-booted simulator was booted again" >&2; exit 1; }

boot_status=0
# "iPhone 15 Pro Max" must not match the booted "iPhone 15", so a boot runs --
# and a real boot ends with the device listed as Booted, which the stub models.
boot_reveals='    iPhone 15 Pro Max (11111111-2222-3333-4444-555555555555) (Booted)'
IOS_BOOT_TIMEOUT=5 ios_boot_simulator "iPhone 15 Pro Max"
[[ "$boot_calls" -eq 1 ]] || { echo "partial simulator name incorrectly matched" >&2; exit 1; }

# A boot that has started but not finished. `simctl boot` returns immediately
# and the device is Booting, not Booted; until 0.27.0 ios_boot_simulator
# returned there too, so ios_resolve_device's next lookup found nothing and
# reported a simulator it had just started as "not a booted simulator".
simctl_output=""
boot_reveal_after=6
: > "$boot_poll_file"
boot_reveals='    iPhone 15 Pro Max (11111111-2222-3333-4444-555555555555) (Booted)'
resolved="$(IOS_BOOT_TIMEOUT=10 ios_resolve_device "iPhone 15 Pro Max" 2>/dev/null)"
[[ "$resolved" == "11111111-2222-3333-4444-555555555555" ]] || {
  echo "a simulator still Booting was not waited for: got '$resolved'" >&2
  exit 1
}
boot_reveal_after=0
boot_reveals=""
boot_calls=1

# A malformed timeout is refused before the loop, not fed to it. "10s" in an
# arithmetic test errors on every iteration, so the deadline was never reached.
# The stubs are named functions defined outside the substitution: bash 3.2's
# parser cannot cope with a `case` pattern's `)` inside `$( )`.
_stub_xcrun_quiet() { return 0; }
bad_rc=0; out="$( (
  xcrun() { _stub_xcrun_quiet "$@"; }
  IOS_BOOT_TIMEOUT=10s ios_boot_simulator "iPhone 15 Pro Max" 2>&1 >/dev/null
) )" || bad_rc=$?
if [[ $bad_rc -eq 2 && "$out" == *"whole number of seconds"* ]]; then
  echo "[ios_test] a malformed IOS_BOOT_TIMEOUT is refused with exit 2"
else
  echo "[ios_test] malformed IOS_BOOT_TIMEOUT not refused: rc=$bad_rc out=$out" >&2; exit 1
fi

# simctl breaking *after* a successful boot command. The polling loop used to
# embed the listing in [[ -n "$( )" ]], discarding its exit status, so a broken
# simctl was reported as a 60-second timeout instead of as itself.
list_status=0
: > "$boot_poll_file"
boot_reveal_after=0
boot_reveals=""
simctl_output=""
_stub_xcrun_listfail() {
  if [[ "$1 $2 ${3:-}" == "simctl list devices" ]]; then
    [[ "${4:-}" == booted && -n "${LIST_FAIL_AFTER_BOOT:-}" ]] && return 9
    printf '%s' "$simctl_output"; return 0
  fi
  [[ "$1 $2" == "simctl boot" ]] && LIST_FAIL_AFTER_BOOT=1
  return 0
}
poll_err="$( (
  xcrun() { _stub_xcrun_listfail "$@"; }
  start=$(date +%s)
  IOS_BOOT_TIMEOUT=30 ios_boot_simulator "iPhone 15 Pro Max" 2>&1 >/dev/null
  echo "rc=$? elapsed=$(( $(date +%s) - start ))"
) )"
case "$poll_err" in
  *"could not list booted simulators"*"rc=1 elapsed=0"*|*"could not list booted simulators"*"rc=1 elapsed=1"*)
    echo "[ios_test] a simctl failure while polling is reported as itself, immediately" ;;
  *) echo "[ios_test] simctl failure while polling was not propagated: $poll_err" >&2; exit 1 ;;
esac


simctl_output=""
boot_status=7
if ios_boot_simulator "missing-simulator"; then
  echo "simctl boot failure was masked" >&2
  exit 1
fi
[[ "$boot_calls" -eq 2 ]] || { echo "expected two simctl boot attempts" >&2; exit 1; }

shutdown_status=9
if ios_shutdown_simulators 2>/dev/null; then
  echo "simctl shutdown failure was masked" >&2
  exit 1
fi

ipa_dir="$(mktemp -d)"
_cleanup_paths+=("$ipa_dir")
ipa_file="$ipa_dir/app.ipa"
: > "$ipa_file"
if ios_install "device-id" "$ipa_file" 2>/dev/null; then
  echo "IPA installation succeeded without devicectl" >&2
  exit 1
fi

unsupported_file="$ipa_dir/app.zip"
: > "$unsupported_file"
if ios_install "simulator-id" "$unsupported_file" 2>/dev/null; then
  echo "unsupported artifact was accepted" >&2
  exit 1
fi

invalid_app="$ipa_dir/not-a-directory.app"
: > "$invalid_app"
if ios_install "simulator-id" "$invalid_app" 2>/dev/null; then
  echo ".app file was accepted instead of requiring a directory" >&2
  exit 1
fi

invalid_ipa="$ipa_dir/not-a-file.ipa"
mkdir "$invalid_ipa"
if ios_install "device-id" "$invalid_ipa" 2>/dev/null; then
  echo ".ipa directory was accepted instead of requiring a file" >&2
  exit 1
fi
[[ "$install_calls" -eq 0 ]] || {
  echo "invalid artifact reached simctl" >&2
  exit 1
}

# ios_list_simulators keeps only lines carrying a UDID and strips the leading
# indentation from `simctl list devices available` (headers are dropped).
simctl_output='== Devices ==
-- iOS 18.5 --
    iPhone 15 (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) (Shutdown)
    iPhone 15 Pro (11111111-2222-3333-4444-555555555555) (Booted)
-- Unavailable --'
output="$(ios_list_simulators)"
expected='iPhone 15 (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) (Shutdown)
iPhone 15 Pro (11111111-2222-3333-4444-555555555555) (Booted)'
[[ "$output" == "$expected" ]] || {
  echo "unexpected simulator list: $output" >&2
  exit 1
}

# --- ios_resolve_device ----------------------------------------------------
#
# The wiring of `./dev deploy ios` hangs off this: an ambiguous or absent
# simulator has to be an error naming the fix, not a guess. Before this the verb
# ignored its target word entirely and installed an APK over adb.

ios_booted_simulators() { printf '%s\n' $booted_fixture; }

booted_fixture="11111111-2222-3333-4444-555555555555"
got="$(ios_resolve_device 2>/dev/null)" || got="FAILED"
[[ "$got" == "11111111-2222-3333-4444-555555555555" ]] || {
  echo "one booted simulator should resolve to it, got: $got" >&2
  exit 1
}

booted_fixture=""
if ios_resolve_device >/dev/null 2>&1; then
  echo "no booted simulator should not resolve" >&2
  exit 1
fi
msg="$(ios_resolve_device 2>&1)" || true
case "$msg" in
  *"no booted simulator"*) ;;
  *) echo "the no-simulator error should say so: $msg" >&2; exit 1 ;;
esac

booted_fixture="AAAAAAAA-1111-2222-3333-444444444444 BBBBBBBB-1111-2222-3333-444444444444"
if ios_resolve_device >/dev/null 2>&1; then
  echo "two booted simulators should be ambiguous" >&2
  exit 1
fi
msg="$(ios_resolve_device 2>&1)" || true
case "$msg" in
  *"--device"*) ;;
  *) echo "the ambiguity error should name --device: $msg" >&2; exit 1 ;;
esac

# An explicitly requested simulator that is booted is honoured.
got="$(ios_resolve_device AAAAAAAA-1111-2222-3333-444444444444 2>/dev/null)" || got="FAILED"
[[ "$got" == "AAAAAAAA-1111-2222-3333-444444444444" ]] || {
  echo "an explicit booted udid should be honoured, got: $got" >&2
  exit 1
}

# A simulator named rather than identified must come back as a UDID: simctl
# install and launch do not accept a display name, so returning the name would
# fail at the point of use rather than here.
booted_fixture=""
simctl_output='== Devices ==
-- iOS 18.5 --
    iPhone 15 Pro (CCCCCCCC-1111-2222-3333-444444444444) (Booted)'
got="$(ios_resolve_device "iPhone 15 Pro" 2>/dev/null)" || got="FAILED"
[[ "$got" == "CCCCCCCC-1111-2222-3333-444444444444" ]] || {
  echo "a simulator name should resolve to its UDID, got: $got" >&2
  exit 1
}

# A name that matches no booted simulator stays an error rather than echoing back.
got="$(ios_resolve_device "iPhone 99" 2>/dev/null)" && {
  echo "an unknown simulator name should not resolve, got: $got" >&2
  exit 1
}

# --- ios_resolve_physical_device -------------------------------------------
#
# A release deploy installs a signed .ipa, which devicectl puts on real
# hardware. Resolving a simulator UDID for it could never work, so this is a
# separate resolver with the same none/one/many discipline.

xctrace_output='== Devices ==
Nikos iPhone (18.5) (00008110-001234567890001E)
== Simulators ==
iPhone 15 Simulator (18.5) (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)'
got="$(ios_resolve_physical_device 2>/dev/null)" || got="FAILED"
[[ "$got" == "00008110-001234567890001E" ]] || {
  echo "one attached device should resolve to it, got: $got" >&2
  exit 1
}

# A name is accepted and still comes back as a UDID.
got="$(ios_resolve_physical_device "Nikos iPhone" 2>/dev/null)" || got="FAILED"
[[ "$got" == "00008110-001234567890001E" ]] || {
  echo "a device name should resolve to its UDID, got: $got" >&2
  exit 1
}

# A simulator is not a device: its UDID must not resolve here.
if ios_resolve_physical_device "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" >/dev/null 2>&1; then
  echo "a simulator UDID resolved as a physical device" >&2
  exit 1
fi

xctrace_output='== Devices =='
if ios_resolve_physical_device >/dev/null 2>&1; then
  echo "no attached device should not resolve" >&2
  exit 1
fi
msg="$(ios_resolve_physical_device 2>&1)" || true
case "$msg" in
  *"no iPhone or iPad attached"*) ;;
  *) echo "the no-device error should say so: $msg" >&2; exit 1 ;;
esac

xctrace_output='== Devices ==
Nikos iPhone (18.5) (00008110-001234567890001E)
Office iPad (17.7.8) (00008101-00ABCDEF1234001E)'
if ios_resolve_physical_device >/dev/null 2>&1; then
  echo "two attached devices should be ambiguous" >&2
  exit 1
fi
msg="$(ios_resolve_physical_device 2>&1)" || true
case "$msg" in
  *"--device"*) ;;
  *) echo "the ambiguity error should name --device: $msg" >&2; exit 1 ;;
esac

# The same, with extglob on. `*(` is the extglob "zero or more" operator, so a
# pattern written as ${line##*(} parses differently in a caller that enabled it
# and returns the whole line rather than the UDID -- silently, with no error.
# Consumer repos do run `shopt -s extglob`, so this is not hypothetical.
shopt -s extglob
xctrace_output='== Devices ==
Nikos iPhone (18.5) (00008110-001234567890001E)'
got="$(ios_resolve_physical_device 2>/dev/null)" || got="FAILED"
[[ "$got" == "00008110-001234567890001E" ]] || {
  echo "under extglob the device UDID parsed wrong: $got" >&2
  shopt -u extglob
  exit 1
}
got="$(ios_resolve_physical_device "Nikos iPhone" 2>/dev/null)" || got="FAILED"
[[ "$got" == "00008110-001234567890001E" ]] || {
  echo "under extglob the device name did not resolve: $got" >&2
  shopt -u extglob
  exit 1
}
shopt -u extglob

# --- ios_artifact ----------------------------------------------------------
art_tmp="$(mktemp -d)"
_cleanup_paths+=("$art_tmp")

if ios_artifact "$art_tmp" simulator >/dev/null 2>&1; then
  echo "ios_artifact should fail when nothing is built" >&2
  exit 1
fi

mkdir -p "$art_tmp/build/ios/iphonesimulator/Runner.app"
got="$(ios_artifact "$art_tmp" simulator)" || got="FAILED"
[[ "$got" == "$art_tmp/build/ios/iphonesimulator/Runner.app" ]] || {
  echo "simulator artifact not found: $got" >&2
  exit 1
}

mkdir -p "$art_tmp/build/ios/ipa"
: > "$art_tmp/build/ios/ipa/Runner.ipa"
got="$(ios_artifact "$art_tmp" ipa)" || got="FAILED"
[[ "$got" == "$art_tmp/build/ios/ipa/Runner.ipa" ]] || {
  echo "ipa artifact not found: $got" >&2
  exit 1
}

# Captured rather than tested through $?: this file runs under `set -e`, which
# would abort on the deliberate failure before the assertion could read it.
art_rc=0
ios_artifact "$art_tmp" nonsense >/dev/null 2>&1 || art_rc=$?
[[ "$art_rc" -eq 2 ]] || {
  echo "an unknown artifact mode should exit 2, got $art_rc" >&2
  exit 1
}

# --- ios_bundle_id ---------------------------------------------------------
# PlistBuddy and plutil are macOS-only and are called by absolute path, so only
# the argument handling is assertable off a Mac. The happy path is covered by
# the manual macOS checklist.
if ios_bundle_id "$art_tmp/nope.app" >/dev/null 2>&1; then
  echo "ios_bundle_id should reject a missing .app" >&2
  exit 1
fi
if ios_bundle_id "$art_tmp/build/ios/iphonesimulator/Runner.app" >/dev/null 2>&1; then
  echo "ios_bundle_id should reject an .app with no Info.plist" >&2
  exit 1
fi

echo "ios tests passed"
