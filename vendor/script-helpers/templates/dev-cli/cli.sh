#!/usr/bin/env bash
# SCRIPT: cli.sh
# DESCRIPTION: The ./dev entry point — one verb set, identical in every repo.
# USAGE: ./dev <verb> [target] [options]
#
# PARAMETERS:
#   Run ./dev with no arguments for the verb list.
# EXIT_CODES:
#   0  The verb succeeded, or is not applicable in this repo.
#   1  The verb failed.
#   2  Unknown verb.
# ----------------------------------------------------
#
# Copied from script-helpers templates/dev-cli/. Repo-specific behaviour belongs
# in scripts/project.sh, which is sourced below when it exists — not in here, so
# that this file can be refreshed from the template without losing local work.
#
# To override a verb, define project_<verb> in scripts/project.sh:
#
#     project_run() { flutter run -d "${DEV_DEVICE:-linux}"; }
#
# Anything not overridden falls back to the shared implementation, which drives
# script-helpers' android/flutter/gradle/screencap modules.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_bootstrap.sh"

shlib_import logging help manifest changelog

# Optional per-repo overrides and configuration.
# shellcheck source=/dev/null
[[ -f "$SCRIPT_DIR/project.sh" ]] && source "$SCRIPT_DIR/project.sh"

cd "$DEV_REPO_ROOT" || exit 1

# --- shared options --------------------------------------------------------

DEV_TARGET=""
DEV_DEVICE="${DEV_DEVICE:-}"
DEV_RELEASE=false
DEV_VERBOSE=false
# Android user to install into. 0 is the device owner. See the note in
# verb_deploy for why this is pinned rather than left to adb's default.
DEV_USER="${DEV_USER:-0}"
declare -a DEV_ARGS=()

parse_dev_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      android|ios|host|backend|frontend|linux|web|macos|windows)
        DEV_TARGET="$1"; shift ;;
      # Checked before shifting: `shift 2` with one argument left returns
      # non-zero, and set -e would kill the process before the validation below
      # could name what was missing.
      --device)
        [[ $# -ge 2 ]] || { log_error "--device needs a serial, e.g. --device R5CRC2WANMT"; exit 2; }
        DEV_DEVICE="$2"; shift 2 ;;
      --user)
        [[ $# -ge 2 ]] || { log_error "--user needs a profile id, e.g. --user 0"; exit 2; }
        DEV_USER="$2"; shift 2 ;;
      --release) DEV_RELEASE=true; shift ;;
      --verbose) DEV_VERBOSE=true; shift ;;
      # Asking a verb for help must not run the verb. Without this, `./dev
      # deploy --help` builds and installs on a device.
      -h|--help) usage; exit 0 ;;
      *) DEV_ARGS+=("$1"); shift ;;
    esac
  done
  [[ "$DEV_USER" =~ ^[0-9]+$ ]] || { log_error "--user must be a number, got '${DEV_USER:-<empty>}'"; exit 2; }
  [[ "$DEV_VERBOSE" == "true" ]] && set -x
  return 0
}

# not_applicable <verb> <reason>; a verb this repo cannot honour exits 0 with an
# explanation. It is never simply absent: a missing verb is indistinguishable
# from a typo, and that is what erodes a shared command set.
not_applicable() {
  log_info "$1: not applicable in this repo — $2"
  exit 0
}

# --- stack detection -------------------------------------------------------
#
# Delegated to preflight, which is the one implementation of it. Emits
# "<stack>\t<dir>" lines.

dev_projects() {
  bash "$SCRIPT_HELPERS_DIR/scripts/preflight.sh" --list 2>/dev/null || true
}

dev_has_stack() { dev_projects | grep -q "^$1	"; }

# Returns 1 when the stack is absent so callers can fall back. awk exits 0 when
# it matches nothing, so `dev_stack_dir x || echo .` would otherwise be dead
# code and the caller would receive an empty directory.
dev_stack_dir() {
  local dir
  dir="$(dev_projects | awk -F'\t' -v s="$1" '$1==s {print $2; exit}')"
  [[ -n "$dir" ]] || return 1
  printf '%s\n' "$dir"
}

dev_is_flutter() { [[ -f pubspec.yaml ]] || dev_has_stack flutter; }
dev_is_android() { dev_has_stack gradle || [[ -d android ]]; }

# --- verbs -----------------------------------------------------------------

# Point git at the shared hooks. In a repo that has deleted its build workflows
# the pre-push hook is the only remaining gate, and core.hooksPath lives in
# .git/config — untracked, so a fresh clone has no gate until something sets it.
# That something is install.
dev_install_hooks() {
  local setup="$SCRIPT_HELPERS_DIR/scripts/setup-hooks.sh"
  [[ -f "$setup" ]] || { log_warn "install: setup-hooks.sh not found — git hooks not configured"; return 0; }
  bash "$setup" || log_warn "install: could not configure git hooks — pushes will not be gated"
}

# Install Python dependencies without writing into an externally managed
# interpreter. On a PEP 668 host (modern Debian/Ubuntu) `pip install` into the
# system Python is refused by design, so use the same project-local .venv that
# local_test_python.sh resolves — one environment, not two.
dev_python_install() {
  local d="$1" py=python3
  command -v python3 >/dev/null 2>&1 || py=python
  command -v "$py" >/dev/null 2>&1 || { log_warn "install: no python interpreter — skipping $d"; return 0; }

  if [[ -x "$d/.venv/bin/python" ]]; then
    py="$d/.venv/bin/python"
  elif [[ -x "$d/venv/bin/python" ]]; then
    py="$d/venv/bin/python"
  elif "$py" -c 'import os,sys,sysconfig; sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_path("stdlib"),"EXTERNALLY-MANAGED")) else 1)' 2>/dev/null; then
    log_info "install: system Python is externally managed (PEP 668); using $d/.venv"
    shlib_import python
    python_ensure_venv "$py" "$d/.venv" >/dev/null || {
      log_error "install: could not create $d/.venv — install python3-venv"
      return 1
    }
    py="$d/.venv/bin/python"
  fi

  if [[ -f "$d/requirements.txt" ]]; then
    log_info "install: $py -m pip install -r $d/requirements.txt"
    "$py" -m pip install -r "$d/requirements.txt" --quiet
  fi
  # The dev extra is where a project declares its test and lint tools. Preflight
  # needs them, so install owes them too. Installed by path rather than by
  # cd-ing: $py is relative to the repo root, and a cd would break it.
  if [[ -f "$d/pyproject.toml" ]] && grep -qE '^[[:space:]]*dev[[:space:]]*=' "$d/pyproject.toml"; then
    # Braced: `$d[dev]` reads as an array subscript to shellcheck (SC1087) and
    # to anyone maintaining this, where the intent is the path plus a pip extra.
    log_info "install: $py -m pip install -e '${d}[dev]'"
    "$py" -m pip install -e "${d}[dev]" --quiet \
      || log_warn "install: the dev extra did not install; continuing"
  fi
}

verb_install() {
  declare -f project_install >/dev/null && { project_install; return; }
  log_info "install: submodules"
  git submodule update --init --recursive
  dev_install_hooks
  if dev_is_flutter; then
    shlib_import flutter
    flutter_pub_get "$(dev_stack_dir flutter || echo .)"
  fi
  if dev_has_stack python; then
    local d; d="$(dev_stack_dir python || echo .)"
    dev_python_install "$d"
  fi
  if dev_has_stack node; then
    local d; d="$(dev_stack_dir node || echo .)"
    log_info "install: npm ci in $d"
    ( cd "$d" && npm ci )
  fi
}

verb_build() {
  declare -f project_build >/dev/null && { project_build; return; }
  local mode=debug; [[ "$DEV_RELEASE" == "true" ]] && mode=release
  if dev_is_flutter; then
    shlib_import flutter
    local d; d="$(dev_stack_dir flutter || echo .)"
    case "${DEV_TARGET:-android}" in
      android) flutter_build apk "$d" "--$mode" ;;
      ios)
        shlib_import ios
        ios_available || not_applicable "build ios" "iOS builds need macOS with Xcode"
        if [[ "$mode" == "release" ]]; then
          # ios_build_release owns the ExportOptions plist and the --no-codesign
          # fallback; flutter_build reaches neither.
          ios_build_release "$d" "${IOS_EXPORT_OPTIONS_PLIST:-}"
        else
          flutter_build ios "$d" "--$mode" --simulator
        fi
        ;;
      *)       flutter_build "${DEV_TARGET}" "$d" "--$mode" ;;
    esac
    return
  fi
  if dev_is_android; then
    shlib_import android
    android_build "$(dev_stack_dir gradle || echo .)" "$mode" apk
    return
  fi
  not_applicable build "no Flutter or Gradle project detected"
}

verb_run() {
  declare -f project_run >/dev/null && { project_run; return; }
  if dev_is_flutter; then
    shlib_import flutter
    local d dev_id
    d="$(dev_stack_dir flutter || echo .)"
    if [[ "${DEV_TARGET:-}" == "ios" ]]; then
      # Resolve against booted simulators rather than `flutter devices`, so the
      # error when none is booted names the actual problem.
      shlib_import ios
      ios_available || not_applicable "run ios" "iOS needs macOS with Xcode"
      dev_id="$(ios_resolve_device "$DEV_DEVICE")" || exit 1
    else
      dev_id="$(flutter_resolve_device "$DEV_DEVICE" "$d")" || exit 1
    fi
    flutter_run_cmd "$d" run -d "$dev_id"
    return
  fi
  not_applicable run "no runnable target — use ./dev deploy to install on a device"
}

verb_test() {
  declare -f project_test >/dev/null && { project_test; return; }
  bash "$SCRIPT_HELPERS_DIR/scripts/preflight.sh" --quick --skip-security
}

verb_preflight() {
  declare -f project_preflight >/dev/null && { project_preflight; return; }
  bash "$SCRIPT_HELPERS_DIR/scripts/preflight.sh" "${DEV_ARGS[@]+"${DEV_ARGS[@]}"}"
}

# Deploy to a booted simulator (debug) or an attached device (release).
#
# Kept separate from the Android path because the two share no step: different
# build flag, different resolver, different installer. `./dev deploy ios` used
# to fall through to adb and install an APK.
#
# The two iOS modes are not interchangeable either. A debug build produces a
# simulator .app that installs through simctl; a release build produces a signed
# .ipa that installs through devicectl onto real hardware. Resolving a simulator
# UDID for an .ipa cannot work, so each mode resolves its own kind of device.
_deploy_ios() {
  shlib_import ios flutter
  ios_available || not_applicable "deploy ios" "iOS needs macOS with Xcode"
  dev_is_flutter || { log_error "deploy ios: no Flutter project detected"; exit 1; }

  local d mode=debug udid artifact bundle
  d="$(dev_stack_dir flutter || echo .)"
  [[ "$DEV_RELEASE" == "true" ]] && mode=release

  if [[ "$mode" == "release" ]]; then
    # Demanded before anything else runs, because without it this path installs
    # the wrong build and calls it a success. `ios_build_release` with no plist
    # falls back to `flutter build ios --release --no-codesign`, which writes an
    # unsigned .app under build/ios/iphoneos -- nothing at all under
    # build/ios/ipa. `ios_artifact ... ipa` then globs that directory newest
    # first, so an .ipa left by an earlier signed build is picked up and
    # installed: a stale binary on the device, with every step reporting
    # success. The .app it did build is no use here either, since ios_install
    # routes a .app to `simctl install`, which cannot address a physical device.
    [[ -n "${IOS_EXPORT_OPTIONS_PLIST:-}" ]] || {
      log_error "deploy ios --release: set IOS_EXPORT_OPTIONS_PLIST to your export options plist"
      log_error "deploy ios --release: a release deploy installs a signed .ipa on an attached device; without a plist the build is an unsigned .app that only a simulator can take"
      exit 1
    }
    [[ -f "$IOS_EXPORT_OPTIONS_PLIST" ]] || {
      log_error "deploy ios --release: IOS_EXPORT_OPTIONS_PLIST not found: $IOS_EXPORT_OPTIONS_PLIST"
      exit 1
    }
    # Make it absolute before handing it on. This check runs at the repo root;
    # ios_build_release re-checks it after `cd`-ing into the Flutter project.
    # In a repo whose app is nested -- mobile/, app/, the layout the shared dev
    # CLI assumes -- a relative plist path means two different files in those two
    # places, so the build either fails on a path that just passed validation or,
    # worse, signs with whichever plist happens to sit inside the project.
    case "$IOS_EXPORT_OPTIONS_PLIST" in
      /*) ;;
      *)  IOS_EXPORT_OPTIONS_PLIST="$PWD/$IOS_EXPORT_OPTIONS_PLIST" ;;
    esac
    # Resolved before building: a signed build is slow, and "no device attached"
    # is worth hearing before it rather than after.
    udid="$(ios_resolve_physical_device "$DEV_DEVICE")" || exit 1
    ios_build_release "$d" "$IOS_EXPORT_OPTIONS_PLIST" || exit 1
    artifact="$(ios_artifact "$d" ipa)" || {
      log_error "deploy ios: no IPA under $d/build/ios/ipa"
      exit 1
    }
  else
    udid="$(ios_resolve_device "$DEV_DEVICE")" || exit 1
    # `flutter build ios` targets a physical device; the .app it produces cannot
    # be installed on a simulator.
    flutter_build ios "$d" --debug --simulator || exit 1
    artifact="$(ios_artifact "$d" simulator)" || {
      log_error "deploy ios: no .app under $d/build/ios/iphonesimulator"
      exit 1
    }
  fi

  ios_install "$udid" "$artifact" || exit 1

  # Only the simulator can be launched from here: simctl launch has no devicectl
  # equivalent that works without a debug session, so a device install stops at
  # installed.
  if [[ "$artifact" == *.app ]]; then
    if bundle="$(ios_bundle_id "$artifact")" && [[ -n "$bundle" ]]; then
      ios_launch "$udid" "$bundle"
    else
      log_warn "deploy ios: installed, but the bundle id could not be read — launch it by hand."
    fi
  else
    log_info "deploy ios: installed on $udid — open it on the device."
  fi
}

_deploy_android() {
  shlib_import adb android
  local mode=debug; [[ "$DEV_RELEASE" == "true" ]] && mode=release
  local serial="$DEV_DEVICE" artifact _sh_line
  local -a _serials=()

  if [[ -z "$serial" ]]; then
    _serials=()
    while IFS= read -r _sh_line; do _serials+=("$_sh_line"); done < <(adb_ready_serials)
    [[ ${#_serials[@]} -eq 1 ]] || {
      log_error "deploy: ${#_serials[@]} devices ready — pass --device <serial>"
      adb_list_devices
      exit 1
    }
    serial="${_serials[0]}"
  fi

  if dev_is_flutter; then
    shlib_import flutter
    flutter_build apk "$(dev_stack_dir flutter || echo .)" "--$mode"
  else
    android_build "$(dev_stack_dir gradle || echo .)" "$mode" apk
  fi

  local gdir; gdir="$(dev_stack_dir gradle || echo .)"
  artifact="$(android_artifact "$gdir" "$mode" apk)" || {
    log_error "deploy: no APK found for variant $mode"
    exit 1
  }

  # Install into an explicit user, then confirm the package is actually visible
  # there. `adb install` can report Success into a work profile or Secure Folder
  # the shell cannot read back, leaving the app absent from the launcher while
  # every signal says the install worked. Verifying is what turns that from an
  # hour of debugging into one line of output.
  local pkg
  if pkg="$(android_package_name "$gdir" "$artifact" 2>/dev/null)" && [[ -n "$pkg" ]]; then
    adb_install_verified "$serial" "$artifact" "$pkg" --user "$DEV_USER"
  else
    log_warn "deploy: could not determine the package name — installing without the post-install check."
    log_warn "deploy: confirm by hand with: adb -s $serial shell pm list packages --user $DEV_USER"
    adb_install "$serial" "$artifact" --user "$DEV_USER"
  fi
}

verb_deploy() {
  declare -f project_deploy >/dev/null && { project_deploy; return; }
  case "${DEV_TARGET:-android}" in
    android) _deploy_android ;;
    ios)     _deploy_ios ;;
    *) not_applicable "deploy ${DEV_TARGET}" "deploy installs on a device; targets are android and ios" ;;
  esac
}

verb_devices() {
  declare -f project_devices >/dev/null && { project_devices; return; }
  shlib_import adb android os
  echo "Android devices:"
  adb_list_devices || true
  echo
  echo "Android AVDs:"
  android_avd_list 2>/dev/null || echo "  (none, or no SDK)"
  # is_macos, not a bare $OSTYPE read: this file runs under `set -u`, where a
  # caller that has unset OSTYPE aborts the CLI on the expansion, and lib/os.sh
  # is the one place that knows how to read it -- including the linux-musl and
  # linux-android spellings a hand-rolled check here would get wrong next.
  if is_macos; then
    shlib_import ios
    echo
    echo "iOS simulators (booted):"
    ios_booted_simulators 2>/dev/null || echo "  (none)"
  fi
}

verb_screenshot() {
  declare -f project_screenshot >/dev/null && { project_screenshot; return; }
  shlib_import screencap
  local -a args=()
  [[ -n "$DEV_DEVICE" ]] && args+=(--device "$DEV_DEVICE")
  [[ -n "$DEV_TARGET" ]] && args+=(--platform "$DEV_TARGET")
  screencap_shot "${args[@]+"${args[@]}"}" "${DEV_ARGS[@]+"${DEV_ARGS[@]}"}"
}

verb_record() {
  declare -f project_record >/dev/null && { project_record; return; }
  shlib_import screencap
  local -a args=()
  [[ -n "$DEV_DEVICE" ]] && args+=(--device "$DEV_DEVICE")
  [[ -n "$DEV_TARGET" ]] && args+=(--platform "$DEV_TARGET")
  screencap_record "${args[@]+"${args[@]}"}" "${DEV_ARGS[@]+"${DEV_ARGS[@]}"}"
}

verb_logs() {
  declare -f project_logs >/dev/null && { project_logs; return; }
  shlib_import adb
  local serial="$DEV_DEVICE" _sh_line
  local -a _serials=()
  if [[ -z "$serial" ]]; then
    _serials=()
    while IFS= read -r _sh_line; do _serials+=("$_sh_line"); done < <(adb_ready_serials)
    [[ ${#_serials[@]} -ge 1 ]] || { log_error "logs: no device ready"; exit 1; }
    serial="${_serials[0]}"
  fi
  log_info "logs: streaming from $serial (Ctrl-C to stop)"
  adb -s "$serial" logcat
}

verb_clean() {
  declare -f project_clean >/dev/null && { project_clean; return; }
  if dev_is_flutter; then
    shlib_import flutter
    flutter_run_cmd "$(dev_stack_dir flutter || echo .)" clean || true
  fi
  if dev_has_stack gradle; then
    shlib_import gradle
    gradle_clean "$(dev_stack_dir gradle)" || true
  fi
  log_info "clean: done. User data and .env files are untouched."
}

verb_update() {
  declare -f project_update >/dev/null && { project_update; return; }
  log_info "update: syncing submodules to their tracked branches"
  git submodule sync --recursive
  git submodule update --init --remote --recursive || {
    log_warn "update: --remote failed; falling back to the pinned commits"
    git submodule update --init --recursive
  }
  if dev_is_flutter; then
    shlib_import flutter
    flutter_pub_get "$(dev_stack_dir flutter || echo .)" || true
  fi
}

verb_release() {
  declare -f project_release >/dev/null && { project_release; return; }
  local version="${DEV_ARGS[0]:-}"
  [[ -n "$version" ]] || { log_error "release: need a version, e.g. ./dev release 1.4.0"; exit 2; }
  manifest_sync_version . "$version"
  changelog_new_section CHANGELOG.md "$version"
  log_info "release: manifests and CHANGELOG updated for $version."
  log_info "release: review the changes, then commit on a release/$version branch."
  log_info "release: this does NOT tag or push. Tagging happens on merge."
}

# --- dispatch --------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: ./dev <verb> [target] [options]

Core
  install       Install dependencies and initialize submodules. Idempotent.
  build         Produce artifacts. Never starts anything.
  run           Start the app in the foreground.
  test          Run the test suite.
  preflight     Run every check CI would have run. The pre-push hook calls this.
  deploy        Build, then install and launch on a connected device.
  clean         Remove build output and caches. Never touches user data.
  update        Sync submodules and refresh pinned dependencies.

Mobile
  devices       List connected devices, emulators, AVDs and simulators.
  screenshot    Capture a PNG from a device.        [--out <path>]
  record        Capture screen video.               [--seconds <n>] [--gif]
  logs          Stream filtered device logs.
  release       Bump the version across manifests and open a CHANGELOG section.

Targets   android ios host backend frontend linux web macos windows
Options   --device <id>  --user <id>  --release  --verbose

--user is the Android profile to install into, default 0 (the device owner).
deploy verifies the package is visible there afterwards: an unqualified install
can succeed into a work profile or Secure Folder the shell cannot read back,
leaving the app absent from the launcher while adb reports Success.
List profiles with: adb shell pm list users

Captured media defaults to docs/screenshots/. Override with $SCREENCAP_DIR.
EOF
}

main() {
  local verb="${1:-}"
  [[ $# -gt 0 ]] && shift || true
  case "$verb" in
    ""|-h|--help|help) usage; exit 0 ;;
  esac
  parse_dev_options "$@"
  case "$verb" in
    install)    verb_install ;;
    build)      verb_build ;;
    run)        verb_run ;;
    test)       verb_test ;;
    preflight)  verb_preflight ;;
    deploy)     verb_deploy ;;
    devices)    verb_devices ;;
    screenshot) verb_screenshot ;;
    record)     verb_record ;;
    logs)       verb_logs ;;
    clean)      verb_clean ;;
    update)     verb_update ;;
    release)    verb_release ;;
    *)
      echo "Unknown verb: $verb" >&2
      echo >&2
      usage >&2
      exit 2
      ;;
  esac
}

# Guarded so the verb functions can be exercised by a test without running the
# CLI. Under `./dev`, which execs `bash .../scripts/cli.sh`, $0 and BASH_SOURCE
# are the same path, so this still runs.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
