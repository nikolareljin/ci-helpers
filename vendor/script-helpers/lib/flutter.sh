#!/usr/bin/env bash
# Flutter project helpers — analyze, test, build and device selection.
#
# `flutter_resolve_sdk` exists because Flutter is routinely installed somewhere
# that is not on a non-interactive shell's PATH (a snap, a tarball under $HOME,
# fvm). Consumer repos worked around that by pasting the same candidate-path
# loop into every script that needed it. This is that loop, once.
#
# All functions return non-zero when Flutter is unreachable, so callers degrade
# cleanly. Exit codes: 2 = bad arguments, 3 = flutter unavailable.

# Usage: flutter_resolve_sdk; prints the path to a usable `flutter` executable,
# searching PATH first and then the conventional install locations. Honours
# FLUTTER_ROOT and FLUTTER_HOME when set. Returns 3 with no output when none is
# found. Does not modify PATH — the caller decides.
flutter_resolve_sdk() {
  local candidate
  command -v flutter >/dev/null 2>&1 && { command -v flutter; return 0; }
  for candidate in \
    "${FLUTTER_ROOT:-}/bin/flutter" \
    "${FLUTTER_HOME:-}/bin/flutter" \
    "$HOME/flutter/bin/flutter" \
    "$HOME/development/flutter/bin/flutter" \
    "$HOME/.local/flutter/bin/flutter" \
    "$HOME/fvm/default/bin/flutter" \
    "/opt/flutter/bin/flutter" \
    "/usr/local/flutter/bin/flutter" \
    "/snap/bin/flutter"
  do
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 3
}

# Usage: flutter_available; returns 0 when a flutter executable is resolvable.
flutter_available() { flutter_resolve_sdk >/dev/null 2>&1; }

# Usage: flutter_run_cmd <dir> <arg...>; run the resolved flutter with <arg...>
# in <dir>. Every other function in this module goes through here, so SDK
# resolution and the "not installed" message live in exactly one place.
flutter_run_cmd() {
  local dir="${1:-}"; shift || true
  local bin
  [[ -n "$dir" && $# -gt 0 ]] || { log_error "flutter_run_cmd: need <dir> <arg...>"; return 2; }
  [[ -d "$dir" ]] || { log_error "flutter_run_cmd: not a directory: $dir"; return 2; }
  bin="$(flutter_resolve_sdk)" || {
    log_error "flutter_run_cmd: flutter not found. Install it, or set FLUTTER_ROOT."
    return 3
  }
  log_info "flutter: $* (in $dir)"
  ( cd "$dir" && "$bin" "$@" )
}

# Usage: flutter_pub_get [dir=.]; fetch dependencies.
flutter_pub_get() { flutter_run_cmd "${1:-.}" pub get; }

# Usage: flutter_analyze [dir=.]; run the static analyzer.
flutter_analyze() { flutter_run_cmd "${1:-.}" analyze; }

# Usage: flutter_format_check [dir=.]; fail when any Dart file is unformatted.
# `--set-exit-if-changed` is what makes this a check rather than a rewrite.
flutter_format_check() {
  local dir="${1:-.}" bin
  bin="$(flutter_resolve_sdk)" || return 3
  log_info "flutter: dart format --set-exit-if-changed (in $dir)"
  ( cd "$dir" && "${bin%/flutter}/dart" format --output=none --set-exit-if-changed . )
}

# Usage: flutter_test [dir=.] [--coverage]; run the test suite.
flutter_test() {
  local dir="." coverage=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --coverage) coverage=1; shift ;;
      -*) log_error "flutter_test: unknown option $1"; return 2 ;;
      *) dir="$1"; shift ;;
    esac
  done
  if [[ "$coverage" -eq 1 ]]; then
    flutter_run_cmd "$dir" test --coverage
  else
    flutter_run_cmd "$dir" test
  fi
}

# Usage: flutter_build <apk|appbundle|ios|web|linux> [dir=.] [--release|--debug]
#                      [--flavor <name>] [--simulator]
#
# Build an artifact. Defaults to --release, because a Flutter build with no mode
# flag is a debug build and that is rarely what a caller of a build function
# means. Returns 2 on an unknown target.
#
# --simulator applies to the ios target only: `flutter build ios` targets a
# physical device, and the .app it produces cannot be installed on a simulator.
flutter_build() {
  local target="${1:-}"; shift || true
  local dir="." mode="--release" flavor="" simulator=0
  case "$target" in
    apk|appbundle|ios|web|linux|macos|windows) ;;
    "") log_error "flutter_build: need <apk|appbundle|ios|web|linux>"; return 2 ;;
    *) log_error "flutter_build: unknown target '$target'"; return 2 ;;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release) mode="--release"; shift ;;
      --debug) mode="--debug"; shift ;;
      --profile) mode="--profile"; shift ;;
      --flavor) flavor="${2:-}"; shift 2 ;;
      --simulator) simulator=1; shift ;;
      -*) log_error "flutter_build: unknown option $1"; return 2 ;;
      *) dir="$1"; shift ;;
    esac
  done
  local -a extra=()
  if [[ "$simulator" -eq 1 ]]; then
    if [[ "$target" != "ios" ]]; then
      log_error "flutter_build: --simulator applies to the ios target only"
      return 2
    fi
    extra+=(--simulator)
  fi
  if [[ -n "$flavor" ]]; then
    flutter_run_cmd "$dir" build "$target" "$mode" --flavor "$flavor" "${extra[@]+"${extra[@]}"}"
  else
    flutter_run_cmd "$dir" build "$target" "$mode" "${extra[@]+"${extra[@]}"}"
  fi
}

# Usage: flutter_devices [dir=.]; prints one "<id>\t<name>" line per connected
# device. Parses `flutter devices --machine` with jq when available and falls
# back to the human-readable table when it is not, so this works on a machine
# without jq installed.
flutter_devices() {
  local dir="${1:-.}" bin out
  bin="$(flutter_resolve_sdk)" || return 3
  if command -v jq >/dev/null 2>&1; then
    out="$( cd "$dir" && "$bin" devices --machine 2>/dev/null )" || return 1
    printf '%s' "$out" | jq -r '.[] | "\(.id)\t\(.name)"' 2>/dev/null && return 0
  fi
  out="$( cd "$dir" && "$bin" devices 2>/dev/null )" || return 1
  # The table lists "<name> (<category>) • <id> • <platform> • <version>".
  printf '%s\n' "$out" | awk -F' *• *' 'NF>=3 && $2 !~ /^[[:space:]]*$/ {
    name=$1; sub(/[[:space:]]+\([^()]*\)[[:space:]]*$/, "", name);
    sub(/^[[:space:]]+/, "", name);
    print $2 "\t" name
  }'
}

# Usage: flutter_resolve_device [preferred] [dir=.]; prints the device id to
# build against. Uses <preferred> if it is connected, else FLUTTER_DEVICE, else
# the only connected device. Returns 1 with a listing on stderr when the choice
# is ambiguous — an ambiguous device is a question for the caller, not a guess.
flutter_resolve_device() {
  local preferred="${1:-${FLUTTER_DEVICE:-}}" dir="${2:-.}" ids
  local _sh_line
  local -a devices=()
  devices=()
  while IFS= read -r _sh_line; do devices+=("$_sh_line"); done < <(flutter_devices "$dir" 2>/dev/null)
  if [[ -n "$preferred" ]]; then
    for ids in "${devices[@]}"; do
      [[ "${ids%%$'\t'*}" == "$preferred" ]] && { printf '%s\n' "$preferred"; return 0; }
    done
    log_error "flutter_resolve_device: '$preferred' is not connected"
    return 1
  fi
  if [[ ${#devices[@]} -eq 1 ]]; then
    printf '%s\n' "${devices[0]%%$'\t'*}"
    return 0
  fi
  if [[ ${#devices[@]} -eq 0 ]]; then
    log_error "flutter_resolve_device: no devices connected"
    return 1
  fi
  log_error "flutter_resolve_device: ${#devices[@]} devices connected — pass one explicitly:"
  printf '  %s\n' "${devices[@]}" >&2
  return 1
}
