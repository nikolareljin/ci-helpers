#!/usr/bin/env bash
# SCRIPT: ci_ios.sh
# DESCRIPTION: Run iOS Flutter CI steps (analyze, test, release build) on a macOS host.
# USAGE: scripts/ci_ios.sh [--workdir <path>] [--skip-analyze] [--skip-test] [--skip-build] [--export-plist <path>]
# PARAMETERS:
#   --workdir <path>       Working directory for flutter commands (default: current dir).
#   --skip-analyze         Skip flutter analyze.
#   --skip-test            Skip flutter test.
#   --skip-build           Skip the iOS build step.
#   --export-plist <path>  ExportOptions.plist, relative to --workdir, for a signed IPA
#                          (default: build an unsigned iOS app).
#   -h, --help             Show this help message.
# EXIT_CODES:
#   0  All requested steps passed (also -h/--help).
#   1  Unknown argument, flutter not on PATH, or --workdir not found.
#   2  An option without its value.
#   3  Not macOS with Xcode: the Apple toolchain cannot run here.
#   N  A failing flutter or xcodebuild step exits with its own code.
# EXAMPLE:
#   scripts/ci_ios.sh --skip-build
# NOTE: Apple's toolchain runs only on macOS, so unlike the Docker-based ci_*.sh
#       helpers this runs on the host with no image. It exits early elsewhere.
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import help logging ios

WORKDIR="."
SKIP_ANALYZE=false
SKIP_TEST=false
SKIP_BUILD=false
EXPORT_PLIST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)
      require_value "$@" || exit 2
      WORKDIR="$2"; shift 2;;
    --skip-analyze) SKIP_ANALYZE=true; shift;;
    --skip-test) SKIP_TEST=true; shift;;
    --skip-build) SKIP_BUILD=true; shift;;
    --export-plist)
      require_value "$@" || exit 2
      EXPORT_PLIST="$2"; shift 2;;
    -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

if ! ios_available; then
  log_error "ci_ios.sh requires macOS with Xcode (Apple's toolchain does not run on this host)."
  exit 3
fi

if ! command -v flutter >/dev/null 2>&1; then
  log_error "flutter is not on PATH."
  exit 1
fi

cd "$WORKDIR"
flutter pub get

if [[ "$SKIP_ANALYZE" != true ]]; then
  log_info "flutter analyze"
  flutter analyze
fi

if [[ "$SKIP_TEST" != true ]]; then
  log_info "flutter test"
  flutter test
fi

if [[ "$SKIP_BUILD" != true ]]; then
  log_info "building iOS release"
  # Reuse the module helper: signed when an export plist is given, else unsigned.
  ios_build_release "." "$EXPORT_PLIST"
fi

print_success "iOS CI steps complete."
