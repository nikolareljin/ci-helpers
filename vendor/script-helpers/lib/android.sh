#!/usr/bin/env bash
# Android build / SDK / emulator utilities — the build-side counterpart to the
# `adb` module, which owns everything that happens on an already-running device.
#
# Split of responsibility:
#   adb.sh       devices that exist  — install, logcat, push/pull, properties
#   android.sh   getting there       — SDK, Gradle build, AVDs, emulators, signing
#   gradle.sh    the build tool      — wrapper resolution, task invocation
#
# Depends on the `gradle` and `adb` modules. Both are loaded below if the caller
# did not ask for them, using the loader's own `_SHLIB_LIB_DIR`, so
# `shlib_import android` is sufficient on its own.
#
# All functions return non-zero when a prerequisite is missing, so callers
# degrade cleanly. Exit codes: 2 = bad arguments, 3 = required tool unavailable.

_android__require_module() {
  local module="$1" probe="$2"
  declare -f "$probe" >/dev/null 2>&1 && return 0
  [[ -n "${_SHLIB_LIB_DIR:-}" && -f "${_SHLIB_LIB_DIR}/${module}.sh" ]] || return 1
  # shellcheck source=/dev/null
  source "${_SHLIB_LIB_DIR}/${module}.sh"
}

_android__require_module gradle gradle_run
_android__require_module adb adb_ready_serials

# --- SDK -------------------------------------------------------------------

# Usage: android_sdk_root; prints the Android SDK root, honouring
# ANDROID_SDK_ROOT then ANDROID_HOME then the two conventional install paths.
# Returns 3 with no output when none of them exists.
android_sdk_root() {
  local candidate
  for candidate in \
    "${ANDROID_SDK_ROOT:-}" \
    "${ANDROID_HOME:-}" \
    "$HOME/Android/Sdk" \
    "$HOME/Library/Android/sdk"
  do
    [[ -n "$candidate" && -d "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 3
}

# Usage: android_available; returns 0 when an Android SDK root is resolvable.
android_available() { android_sdk_root >/dev/null 2>&1; }

# Usage: android_sdk_tool <name>; prints the path to an SDK tool (sdkmanager,
# avdmanager, emulator, apksigner, zipalign, adb), searching the SDK's several
# layouts and then PATH. Returns 3 when it cannot be found.
android_sdk_tool() {
  local name="${1:-}" root candidate
  [[ -n "$name" ]] || { log_error "android_sdk_tool: need <name>"; return 2; }
  if root="$(android_sdk_root)"; then
    for candidate in \
      "$root/cmdline-tools/latest/bin/$name" \
      "$root/cmdline-tools/bin/$name" \
      "$root/tools/bin/$name" \
      "$root/platform-tools/$name" \
      "$root/emulator/$name"
    do
      [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    done
    # build-tools are versioned; take the highest that has the tool. `ls | sort -V`
    # rather than find, because the ordering is the point and these are SDK
    # directory names, which are always plain semver.
    # shellcheck disable=SC2012
    for candidate in $(ls -1d "$root"/build-tools/*/ 2>/dev/null | sort -Vr); do
      [[ -x "$candidate$name" ]] && { printf '%s\n' "$candidate$name"; return 0; }
    done
  fi
  command -v "$name" >/dev/null 2>&1 && { command -v "$name"; return 0; }
  return 3
}

# Usage: android_ensure_sdk [api=34] [build_tools=34.0.0]; accept licenses and
# install platform-tools, the platform for <api> and the given build-tools.
# Idempotent — sdkmanager skips anything already present. Returns 3 when
# sdkmanager is not installed, since bootstrapping the bootstrapper is a
# deliberate human step, not something a build script should do silently.
android_ensure_sdk() {
  local api="${1:-34}" build_tools="${2:-34.0.0}" sdkmanager
  sdkmanager="$(android_sdk_tool sdkmanager)" || {
    log_error "android_ensure_sdk: sdkmanager not found. Install the Android command-line tools and set ANDROID_SDK_ROOT."
    return 3
  }
  log_info "android: accepting SDK licenses"
  yes 2>/dev/null | "$sdkmanager" --licenses >/dev/null 2>&1 || true
  log_info "android: installing platform-tools, platforms;android-$api, build-tools;$build_tools"
  "$sdkmanager" "platform-tools" "platforms;android-$api" "build-tools;$build_tools"
}

# --- build -----------------------------------------------------------------

# Usage: android_gradlew <dir> <task...>; run Gradle tasks in an Android project
# with ANDROID_HOME and ANDROID_SDK_ROOT exported for the build.
#
# The export is the point. The Android Gradle plugin resolves the SDK from those
# variables or from a local.properties `sdk.dir`, and neither is reliably set in
# a plain shell — so a build that works in an IDE fails from a script with
# "SDK location not found", which reads as a project fault rather than an
# environment one. This module can already locate the SDK; passing that on is the
# difference between the shared verb working from a clean clone and not.
#
# An existing value is respected, so a caller targeting a second SDK is not
# overridden.
android_gradlew() {
  local root
  if root="$(android_sdk_root 2>/dev/null)"; then
    ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$root}" \
    ANDROID_HOME="${ANDROID_HOME:-$root}" \
    gradle_run "$@"
    return $?
  fi
  # No SDK found. Let Gradle emit its own diagnostic rather than guessing.
  gradle_run "$@"
}

# Usage: android_build [dir=.] [debug|release] [apk|aab]; assemble an APK or
# bundle an AAB. This is the one spelling of the debug/release toggle — the
# fleet had four. Returns 2 on an unknown variant or format.
android_build() {
  local dir="${1:-.}" variant="${2:-debug}" format="${3:-apk}" task
  case "$variant" in
    debug|release) ;;
    *) log_error "android_build: variant must be debug or release, got '$variant'"; return 2 ;;
  esac
  case "$format" in
    apk) task="assemble" ;;
    aab) task="bundle" ;;
    *) log_error "android_build: format must be apk or aab, got '$format'"; return 2 ;;
  esac
  # Gradle capitalizes the variant in the task name: assembleDebug, bundleRelease.
  task+="$(tr '[:lower:]' '[:upper:]' <<<"${variant:0:1}")${variant:1}"
  # Via android_gradlew, so the SDK location reaches the build.
  android_gradlew "$dir" "$task"
}

# Usage: android_artifact [dir=.] [debug|release] [apk|aab]; prints the path to
# the most recently built artifact for that variant. Returns 1 when none exists,
# so a caller can tell "not built yet" from "built and here it is".
android_artifact() {
  local dir="${1:-.}" variant="${2:-debug}" format="${3:-apk}" found
  local -a globs=()
  if [[ "$format" == "aab" ]]; then
    globs=("$dir"/*/build/outputs/bundle/"$variant"/*.aab "$dir"/build/outputs/bundle/"$variant"/*.aab)
  else
    globs=("$dir"/*/build/outputs/apk/"$variant"/*.apk "$dir"/build/outputs/apk/"$variant"/*.apk)
  fi
  # `ls -t` rather than find, because newest-first is the point. These are build
  # outputs under a path the caller already controls.
  # shellcheck disable=SC2012
  found="$(ls -1t "${globs[@]}" 2>/dev/null | head -n1)"
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

# Usage: android_package_name [dir=.] [artifact]; print the application id.
# Reads it from the built artifact with aapt/aapt2 when one is available, since
# that is the only source that accounts for applicationIdSuffix and flavors.
# Falls back to parsing `applicationId` out of the Gradle build file. Returns 1
# when neither works — a caller that needs a package name should say so rather
# than guessing one.
android_package_name() {
  local dir="${1:-.}" artifact="${2:-}" aapt out pkg=""
  if [[ -n "$artifact" && -f "$artifact" ]]; then
    if aapt="$(android_sdk_tool aapt2 2>/dev/null)" || aapt="$(android_sdk_tool aapt 2>/dev/null)"; then
      out="$("$aapt" dump badging "$artifact" 2>/dev/null | grep -m1 '^package:')" || out=""
      pkg="$(sed -n "s/.*name='\([^']*\)'.*/\1/p" <<<"$out")"
      [[ -n "$pkg" ]] && { printf '%s\n' "$pkg"; return 0; }
    fi
  fi
  # applicationIdSuffix is not accounted for here; that is why the artifact is
  # preferred above.
  pkg="$(grep -rhoE 'applicationId[[:space:]]*=?[[:space:]]*"[^"]+"' \
          "$dir" --include='build.gradle' --include='build.gradle.kts' 2>/dev/null \
        | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
  [[ -n "$pkg" ]] || return 1
  printf '%s\n' "$pkg"
}

# --- signing ---------------------------------------------------------------

# Usage: android_sign <artifact> [--keystore <path>] [--base64-env <VAR>]
#                     [--storepass <pw>] [--alias <name>] [--keypass <pw>]
#                     [--allow-unsigned]
#
# Sign an APK or AAB with apksigner (preferred) or jarsigner. The keystore comes
# either from a file or, for a CI-shaped secret, base64-decoded out of the named
# environment variable into a temp file that is removed on return.
#
# Passwords may also come from ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS and
# ANDROID_KEY_PASSWORD. With --allow-unsigned, a missing keystore is a warning
# and success rather than a failure — the debug-signed fallback that lets a
# local build proceed without release credentials.
#
# Returns 2 on bad arguments, 3 when no signer tool is available.
android_sign() {
  local artifact="" keystore="" b64var="" storepass="${ANDROID_KEYSTORE_PASSWORD:-}"
  local alias="${ANDROID_KEY_ALIAS:-}" keypass="${ANDROID_KEY_PASSWORD:-}"
  local allow_unsigned=0 tmp_keystore="" signer rc=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keystore) keystore="${2:-}"; shift 2 ;;
      --base64-env) b64var="${2:-}"; shift 2 ;;
      --storepass) storepass="${2:-}"; shift 2 ;;
      --alias) alias="${2:-}"; shift 2 ;;
      --keypass) keypass="${2:-}"; shift 2 ;;
      --allow-unsigned) allow_unsigned=1; shift ;;
      -*) log_error "android_sign: unknown option $1"; return 2 ;;
      *) artifact="$1"; shift ;;
    esac
  done

  [[ -n "$artifact" ]] || { log_error "android_sign: need <artifact>"; return 2; }
  [[ -f "$artifact" ]] || { log_error "android_sign: not found: $artifact"; return 2; }

  if [[ -z "$keystore" && -n "$b64var" ]]; then
    [[ -n "${!b64var:-}" ]] || {
      log_error "android_sign: \$$b64var is empty"
      return 2
    }
    tmp_keystore="$(mktemp)" || return 1
    # Older macOS base64 spells the decode flag -D; without the fallback the
    # failure took the branch below and blamed the caller's input.
    { printf '%s' "${!b64var}" | base64 -d > "$tmp_keystore" 2>/dev/null ||
      printf '%s' "${!b64var}" | base64 -D > "$tmp_keystore" 2>/dev/null; } || {
      rm -f "$tmp_keystore"
      log_error "android_sign: \$$b64var is not valid base64"
      return 2
    }
    keystore="$tmp_keystore"
  fi

  if [[ -z "$keystore" || ! -f "$keystore" ]]; then
    [[ -n "$tmp_keystore" ]] && rm -f "$tmp_keystore"
    if [[ "$allow_unsigned" -eq 1 ]]; then
      log_warn "android_sign: no keystore — leaving $artifact as built (debug-signed)."
      return 0
    fi
    log_error "android_sign: no keystore. Pass --keystore, or --base64-env, or --allow-unsigned."
    return 2
  fi

  [[ -n "$alias" ]] || {
    [[ -n "$tmp_keystore" ]] && rm -f "$tmp_keystore"
    log_error "android_sign: need --alias (or \$ANDROID_KEY_ALIAS)"
    return 2
  }

  if signer="$(android_sdk_tool apksigner 2>/dev/null)"; then
    log_info "android: signing $artifact with apksigner"
    ANDROID_SIGN_STOREPASS="$storepass" ANDROID_SIGN_KEYPASS="${keypass:-$storepass}" \
    "$signer" sign \
      --ks "$keystore" \
      --ks-key-alias "$alias" \
      --ks-pass env:ANDROID_SIGN_STOREPASS \
      --key-pass env:ANDROID_SIGN_KEYPASS \
      "$artifact"
    rc=$?
  elif command -v jarsigner >/dev/null 2>&1; then
    log_info "android: signing $artifact with jarsigner (apksigner not found)"
    jarsigner -verbose:0 \
      -sigalg SHA256withRSA -digestalg SHA-256 \
      -keystore "$keystore" \
      -storepass "$storepass" \
      -keypass "${keypass:-$storepass}" \
      "$artifact" "$alias" >/dev/null
    rc=$?
  else
    [[ -n "$tmp_keystore" ]] && rm -f "$tmp_keystore"
    log_error "android_sign: neither apksigner nor jarsigner is available"
    return 3
  fi

  [[ -n "$tmp_keystore" ]] && rm -f "$tmp_keystore"
  return $rc
}

# --- emulators -------------------------------------------------------------

# Usage: android_avd_list; prints the name of each defined AVD, one per line.
android_avd_list() {
  local avdmanager
  avdmanager="$(android_sdk_tool avdmanager)" || return 3
  "$avdmanager" list avd 2>/dev/null | awk -F': *' '/^ *Name:/{print $2}'
}

# Usage: android_avd_create <name> [api=34] [abi=x86_64]; create an AVD if it
# does not already exist. Requires the matching system image to be installed —
# run android_ensure_sdk first, and install `system-images;android-<api>;google_apis;<abi>`.
android_avd_create() {
  local name="${1:-}" api="${2:-34}" abi="${3:-x86_64}" avdmanager
  [[ -n "$name" ]] || { log_error "android_avd_create: need <name>"; return 2; }
  avdmanager="$(android_sdk_tool avdmanager)" || return 3
  if android_avd_list 2>/dev/null | grep -qx "$name"; then
    log_info "android: AVD '$name' already exists"
    return 0
  fi
  log_info "android: creating AVD '$name' (api $api, $abi)"
  printf 'no\n' | "$avdmanager" create avd \
    --name "$name" \
    --package "system-images;android-$api;google_apis;$abi" \
    --force
}

# Usage: android_emulator_start <avd> [--no-window] [--wait <seconds>]; start an
# emulator in the background and wait for it to report boot completion. Prints
# the serial of the booted emulator. Returns 1 if it does not boot in time.
android_emulator_start() {
  local avd="" no_window=0 wait_for=180 emulator serial waited=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-window) no_window=1; shift ;;
      --wait) wait_for="${2:-180}"; shift 2 ;;
      -*) log_error "android_emulator_start: unknown option $1"; return 2 ;;
      *) avd="$1"; shift ;;
    esac
  done
  [[ -n "$avd" ]] || { log_error "android_emulator_start: need <avd>"; return 2; }
  emulator="$(android_sdk_tool emulator)" || return 3

  log_info "android: starting emulator '$avd'"
  if [[ "$no_window" -eq 1 ]]; then
    "$emulator" -avd "$avd" -no-snapshot-load -no-window -no-audio >/dev/null 2>&1 &
  else
    "$emulator" -avd "$avd" -no-snapshot-load >/dev/null 2>&1 &
  fi

  while [[ "$waited" -lt "$wait_for" ]]; do
    for serial in $(adb_ready_serials 2>/dev/null); do
      [[ "$serial" == emulator-* ]] || continue
      if [[ "$(adb_getprop "$serial" sys.boot_completed 2>/dev/null)" == "1" ]]; then
        log_info "android: emulator ready as $serial"
        printf '%s\n' "$serial"
        return 0
      fi
    done
    sleep 3
    waited=$((waited + 3))
  done
  log_error "android_emulator_start: '$avd' did not report boot completion within ${wait_for}s"
  return 1
}

# Usage: android_emulator_stop [serial]; stop one emulator, or every running
# emulator when no serial is given.
android_emulator_stop() {
  local serial="${1:-}" s stopped=0
  adb_available 2>/dev/null || return 3
  if [[ -n "$serial" ]]; then
    log_info "android: stopping $serial"
    adb -s "$serial" emu kill >/dev/null 2>&1
    return $?
  fi
  for s in $(adb_ready_serials 2>/dev/null); do
    [[ "$s" == emulator-* ]] || continue
    log_info "android: stopping $s"
    adb -s "$s" emu kill >/dev/null 2>&1
    stopped=$((stopped + 1))
  done
  [[ "$stopped" -gt 0 ]] || log_info "android: no running emulators"
  return 0
}
