#!/usr/bin/env bash
# iOS device / simulator utilities — a general toolkit for inspecting iOS
# devices and simulators and installing builds, the iOS counterpart to the
# `adb` module.
#
# macOS ONLY: every function requires Apple's command-line tools (`xcrun`,
# `simctl`, `xctrace`), which exist only on macOS with Xcode. On other hosts
# each function returns non-zero without stdout output so callers degrade
# cleanly; prerequisite errors may still be written to stderr.

# --- discovery -------------------------------------------------------------

# Usage: ios_available; returns 0 only on macOS with Xcode's xcrun on PATH.
ios_available() {
  [[ "${OSTYPE:-}" == darwin* ]] || return 1
  command -v xcrun >/dev/null 2>&1
}

# Usage: ios_list_devices; prints attached physical iOS devices, one per line
# ("<name> (<udid>)"). Prints nothing when none are attached.
ios_list_devices() {
  ios_available || return 1
  # xctrace enumerates real + simulated devices; keep only physical iPhone/iPad
  # entries and normalize away the OS-version field. Capture first so an xcrun
  # failure surfaces as a non-zero return instead of empty-but-successful output.
  local out
  out=$(xcrun xctrace list devices 2>/dev/null) || return 1
  printf '%s\n' "$out" \
    | awk '
        /^== Devices ==/ { devices=1; next }
        /^== / { devices=0 }
        devices && /(iPhone|iPad)/ && match($0, /\([0-9A-Fa-f-]{8,}\)[[:space:]]*$/) {
          udid = substr($0, RSTART + 1, RLENGTH - 2)
          sub(/[[:space:]]+$/, "", udid)
          sub(/\)$/, "", udid)
          name = substr($0, 1, RSTART - 1)
          sub(/^[[:space:]]+/, "", name)
          sub(/[[:space:]]+\([^()]*\)[[:space:]]*$/, "", name)
          sub(/[[:space:]]+$/, "", name)
          print name " (" udid ")"
        }
      '
}

# Usage: ios_list_simulators; prints available simulators ("<name> (<udid>) (<state>)").
ios_list_simulators() {
  ios_available || return 1
  local out
  out=$(xcrun simctl list devices available 2>/dev/null) || return 1
  printf '%s\n' "$out" \
    | awk '/\(([0-9A-Fa-f-]{8,})\)/ {sub(/^[[:space:]]+/,""); print}'
}

# Usage: ios_booted_simulators; prints the udid of each currently booted simulator.
ios_booted_simulators() {
  ios_available || return 1
  local out
  out=$(xcrun simctl list devices booted 2>/dev/null) || return 1
  printf '%s\n' "$out" \
    | awk 'match($0, /\([0-9A-Fa-f-]{8,}\)/) { print substr($0, RSTART + 1, RLENGTH - 2) }'
}

# --- simulator control -----------------------------------------------------

# Usage: ios_boot_simulator <udid|name>; boots a simulator (no-op if already booted).
ios_boot_simulator() {
  ios_available || return 1
  local id="${1:-}"
  [[ -n "$id" ]] || return 1

  # Avoid masking genuine simctl failures while keeping an already-booted
  # simulator idempotent. Capture first so a simctl failure is not hidden by awk.
  local booted
  booted=$(xcrun simctl list devices booted 2>/dev/null) || return 1
  if printf '%s\n' "$booted" \
    | awk -v id="$id" '
        match($0, /\([0-9A-Fa-f-]{8,}\)/) {
          udid = substr($0, RSTART + 1, RLENGTH - 2)
          name = substr($0, 1, RSTART - 1)
          sub(/^[[:space:]]+/, "", name)
          sub(/[[:space:]]+$/, "", name)
          if (id == name || id == udid) found=1
        }
        END { exit !found }
      '; then
    return 0
  fi
  xcrun simctl boot "$id"
}

# Usage: ios_shutdown_simulators; shuts down all booted simulators.
ios_shutdown_simulators() {
  ios_available || return 1
  xcrun simctl shutdown all
}

# --- install / launch ------------------------------------------------------

# Usage: ios_install <udid> <path.app|path.ipa>; installs a build onto a booted
# simulator (.app) or an attached device (.ipa, via devicectl when available).
ios_install() {
  ios_available || return 1
  local id="${1:-}" artifact="${2:-}"
  [[ -n "$id" && -n "$artifact" ]] || return 1

  if [[ "$artifact" == *.ipa ]]; then
    if [[ ! -f "$artifact" ]]; then
      echo "ios_install: IPA artifact must be a file: $artifact" >&2
      return 1
    fi
    if ! xcrun devicectl --version >/dev/null 2>&1; then
      echo "ios_install: installing an IPA requires Xcode 15 or newer with devicectl" >&2
      return 1
    fi
    xcrun devicectl device install app --device "$id" "$artifact"
  elif [[ "$artifact" == *.app ]]; then
    if [[ ! -d "$artifact" ]]; then
      echo "ios_install: app artifact must be a directory: $artifact" >&2
      return 1
    fi
    xcrun simctl install "$id" "$artifact"
  else
    echo "ios_install: unsupported artifact (expected .app or .ipa): $artifact" >&2
    return 1
  fi
}

# Usage: ios_launch <udid> <bundle_id>; launches an installed app on a simulator.
ios_launch() {
  ios_available || return 1
  local id="${1:-}" bundle_id="${2:-}"
  [[ -n "$id" && -n "$bundle_id" ]] || return 1
  xcrun simctl launch "$id" "$bundle_id"
}

# --- build -----------------------------------------------------------------

# Usage: ios_build_release <flutter_project_dir> [export_options_plist]; builds
# a signed IPA when a plist is provided, or an unsigned iOS app otherwise.
ios_build_release() {
  ios_available || { echo "ios_build_release: requires macOS with Xcode" >&2; return 1; }
  command -v flutter >/dev/null 2>&1 || { echo "ios_build_release: flutter not on PATH" >&2; return 1; }
  local dir="${1:-.}" plist="${2:-}"
  ( cd "$dir" && flutter pub get && \
    if [[ -n "$plist" ]]; then
      [[ -f "$plist" ]] || { echo "ios_build_release: export options plist not found: $plist" >&2; exit 1; }
      flutter build ipa --release --export-options-plist "$plist"
    else
      flutter build ios --release --no-codesign
    fi )
}

# --- resolution ------------------------------------------------------------

# Usage: ios_resolve_device [preferred]; prints the simulator udid to act on.
# Uses <preferred> when it is booted, else IOS_DEVICE, else the only booted
# simulator. Returns 1 with a listing on stderr when the choice is ambiguous --
# the iOS counterpart of flutter_resolve_device, and ambiguity is a question for
# the caller rather than something to guess at.
# Usage: _ios__booted_udid_for <name|udid>; prints the UDID of the matching
# booted simulator, or nothing. Internal: ios_resolve_device needs a name-to-UDID
# step because a name is not something simctl install or launch accepts.
_ios__booted_udid_for() {
  local want="${1:-}" out
  [[ -n "$want" ]] || return 1
  out=$(xcrun simctl list devices booted 2>/dev/null) || return 1
  printf '%s\n' "$out" \
    | awk -v want="$want" '
        match($0, /\([0-9A-Fa-f-]{8,}\)/) {
          udid = substr($0, RSTART + 1, RLENGTH - 2)
          name = substr($0, 1, RSTART - 1)
          sub(/^[[:space:]]+/, "", name)
          sub(/[[:space:]]+$/, "", name)
          if (want == name || want == udid) { print udid; exit }
        }
      '
}

ios_resolve_device() {
  ios_available || return 1
  local preferred="${1:-${IOS_DEVICE:-}}" udid _sh_line
  local -a booted=()
  while IFS= read -r _sh_line; do
    [[ -n "$_sh_line" ]] && booted+=("$_sh_line")
  done < <(ios_booted_simulators 2>/dev/null)

  if [[ -n "$preferred" ]]; then
    for udid in "${booted[@]+"${booted[@]}"}"; do
      [[ "$udid" == "$preferred" ]] && { printf '%s\n' "$preferred"; return 0; }
    done
    # Not booted, but it may still be a known simulator the caller wants
    # started. Resolve the result back to a UDID: `preferred` may be a display
    # name, and simctl install/launch take a UDID (or the literal "booted"),
    # so echoing the name back would hand the caller something unusable.
    if ios_boot_simulator "$preferred" >/dev/null 2>&1; then
      udid="$(_ios__booted_udid_for "$preferred")"
      if [[ -n "$udid" ]]; then
        printf '%s\n' "$udid"
        return 0
      fi
    fi
    echo "ios_resolve_device: '$preferred' is not a booted simulator" >&2
    return 1
  fi

  if [[ ${#booted[@]} -eq 0 ]]; then
    echo "ios_resolve_device: no booted simulator (start one, or pass --device)" >&2
    return 1
  fi
  if [[ ${#booted[@]} -gt 1 ]]; then
    echo "ios_resolve_device: ${#booted[@]} simulators booted -- pass --device" >&2
    printf '  %s\n' "${booted[@]}" >&2
    return 1
  fi
  printf '%s\n' "${booted[0]}"
}

# Usage: ios_resolve_physical_device [preferred]; prints the UDID of an attached
# iPhone or iPad. The same none/one/many discipline as ios_resolve_device, but
# for real hardware: an .ipa installs through devicectl onto a device and can
# never be installed on a simulator, so the two need separate resolvers.
ios_resolve_physical_device() {
  ios_available || return 1
  local preferred="${1:-${IOS_DEVICE:-}}" line name udid
  local -a udids=() labels=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # ios_list_devices prints "<name> (<udid>)". The paren is escaped because
    # `*(` is the extglob "zero or more" operator: in a caller that has run
    # `shopt -s extglob` the unescaped form parses differently and returns the
    # whole line instead of the UDID, with no error to notice.
    udid="${line##*\(}"; udid="${udid%)}"
    name="${line% (*}"
    [[ -n "$udid" ]] || continue
    udids+=("$udid"); labels+=("$line")
    if [[ -n "$preferred" && ( "$preferred" == "$udid" || "$preferred" == "$name" ) ]]; then
      printf '%s\n' "$udid"
      return 0
    fi
  done < <(ios_list_devices 2>/dev/null)

  if [[ -n "$preferred" ]]; then
    echo "ios_resolve_physical_device: '$preferred' is not an attached device" >&2
    return 1
  fi
  if [[ ${#udids[@]} -eq 0 ]]; then
    echo "ios_resolve_physical_device: no iPhone or iPad attached (trust the Mac on the device, or pass --device)" >&2
    return 1
  fi
  if [[ ${#udids[@]} -gt 1 ]]; then
    echo "ios_resolve_physical_device: ${#udids[@]} devices attached -- pass --device" >&2
    printf '  %s\n' "${labels[@]}" >&2
    return 1
  fi
  printf '%s\n' "${udids[0]}"
}

# Usage: ios_bundle_id <path.app>; prints the CFBundleIdentifier of a built app.
# ios_launch needs a bundle id rather than a path, and reading it from the
# artifact is the only source that reflects the flavor actually built.
ios_bundle_id() {
  local app="${1:-}" plist id=""
  [[ -n "$app" && -d "$app" ]] || { echo "ios_bundle_id: not an .app directory: ${app:-<none>}" >&2; return 1; }
  plist="$app/Info.plist"
  [[ -f "$plist" ]] || { echo "ios_bundle_id: no Info.plist in $app" >&2; return 1; }

  if [[ -x /usr/libexec/PlistBuddy ]]; then
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)" || id=""
  fi
  if [[ -z "$id" ]] && command -v plutil >/dev/null 2>&1; then
    id="$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null)" || id=""
  fi
  [[ -n "$id" ]] || { echo "ios_bundle_id: could not read CFBundleIdentifier from $plist" >&2; return 1; }
  printf '%s\n' "$id"
}

# Usage: ios_artifact [dir=.] [mode=simulator]; prints the newest build output.
# mode is simulator (.app for the simulator), device (.app for a real device) or
# release/ipa (.ipa). The iOS counterpart of android_artifact.
ios_artifact() {
  local dir="${1:-.}" mode="${2:-simulator}" found
  local -a globs=()
  case "$mode" in
    simulator) globs=("$dir"/build/ios/iphonesimulator/*.app) ;;
    device)    globs=("$dir"/build/ios/iphoneos/*.app) ;;
    release|ipa) globs=("$dir"/build/ios/ipa/*.ipa) ;;
    *) echo "ios_artifact: unknown mode '$mode' (simulator|device|ipa)" >&2; return 2 ;;
  esac
  # `ls -t` rather than find, because newest-first is the point. These are build
  # outputs under a path the caller already controls.
  # shellcheck disable=SC2012
  found="$(ls -1td "${globs[@]}" 2>/dev/null | head -n1)"
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}
