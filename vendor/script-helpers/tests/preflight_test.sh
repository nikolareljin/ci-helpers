#!/usr/bin/env bash
# SCRIPT: preflight_test.sh
# DESCRIPTION: Tests for preflight stack detection, chiefly the iOS stack.
# USAGE: bash tests/preflight_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

failures=0
note()  { echo "[preflight_test] $*"; }
error() { echo "[preflight_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

PF="$ROOT_DIR/scripts/preflight.sh"
# preflight refuses to run under CI by design; these are detection tests.
run_list() { CI="" bash "$PF" --dir "$1" --list 2>/dev/null; }

has_pair() {
  # has_pair <output> <stack> <dir>
  #
  # Fixed-string, not grep: preflight --list emits a literal "<stack><TAB><dir>"
  # line, and the dir for a root project is ".", which as a regex matches any
  # character. A regex here would pass on output it should reject.
  local want="$2	$3"
  case $'\n'"$1"$'\n' in
    *$'\n'"$want"$'\n'*) return 0 ;;
  esac
  return 1
}

# --- a Flutter app at the repo root ----------------------------------------
mkdir -p "$tmp/root/ios" "$tmp/root/android"
printf 'name: demo\n' > "$tmp/root/pubspec.yaml"
printf "platform :ios, '13.0'\n" > "$tmp/root/ios/Podfile"
out="$(run_list "$tmp/root")"
if has_pair "$out" flutter .; then note "root: flutter detected"; else error "root: no flutter pair in [$out]"; fi
# The ios pair must point at the Flutter project, not at its ios/ folder --
# ci_ios.sh takes the project root as --workdir.
if has_pair "$out" ios .; then note "root: ios pair points at the project root"; else error "root: no 'ios .' pair in [$out]"; fi

# --- a Flutter app in a subdirectory ---------------------------------------
mkdir -p "$tmp/nested/mobile/ios"
printf 'name: demo\n' > "$tmp/nested/mobile/pubspec.yaml"
printf "platform :ios\n" > "$tmp/nested/mobile/ios/Podfile"
out="$(run_list "$tmp/nested")"
if has_pair "$out" ios mobile; then note "nested: ios pair carries the project dir"; else error "nested: no 'ios mobile' pair in [$out]"; fi

# --- a Flutter app with no ios/ directory ----------------------------------
mkdir -p "$tmp/androidonly/android"
printf 'name: demo\n' > "$tmp/androidonly/pubspec.yaml"
out="$(run_list "$tmp/androidonly")"
if has_pair "$out" ios .; then error "android-only project was given an ios stack"; else note "no ios/ directory means no ios stack"; fi

# --- a project that is not Flutter at all ----------------------------------
mkdir -p "$tmp/node"
printf '{}\n' > "$tmp/node/package.json"
out="$(run_list "$tmp/node")"
if has_pair "$out" ios .; then error "a node project was given an ios stack"; else note "a node project gets no ios stack"; fi

# --- ios is a known stack --------------------------------------------------
CI="" bash "$PF" --dir "$tmp/root" --stack ios --list >/dev/null 2>&1
if [[ $? -eq 0 ]]; then note "--stack ios is accepted"; else error "--stack ios was rejected"; fi
CI="" bash "$PF" --dir "$tmp/root" --stack nonesuch >/dev/null 2>&1
if [[ $? -eq 2 ]]; then note "an unknown stack still exits 2"; else error "unknown stack did not exit 2"; fi

# --- off macOS, iOS must SKIP rather than FAIL ------------------------------
# A Linux box failing an iOS check would be noise on every run; a skip is
# reported separately so it cannot be mistaken for a pass either.
if [[ "$(uname -s)" != "Darwin" ]]; then
  out="$(CI="" bash "$PF" --dir "$tmp/androidonly" --quick --skip-security 2>&1)"
  case "$out" in
    *"SKIP  ios"*|*"skipping ios"*) note "ios reports SKIP on a non-macOS host" ;;
    *) note "ios stack absent for this fixture (no ios/ directory) — nothing to skip" ;;
  esac
  out="$(CI="" bash "$PF" --dir "$tmp/root" --quick --skip-security 2>&1)"
  case "$out" in
    *"SKIP  ios"*) note "ios reports SKIP, not FAIL, off macOS" ;;
    *"FAIL  ios"*) error "ios FAILED on a non-macOS host instead of skipping" ;;
    *) error "ios produced neither a skip nor a failure: $out" ;;
  esac
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
