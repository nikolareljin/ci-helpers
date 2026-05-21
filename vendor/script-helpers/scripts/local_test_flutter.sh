#!/usr/bin/env bash
# SCRIPT: local_test_flutter.sh
# DESCRIPTION: Fetch dependencies, analyze, and test a Flutter project.
# USAGE: bash scripts/local_test_flutter.sh [--quick] [--dir <path>]
#
# PARAMETERS:
#   --quick   Skip dependency install and flutter analyze; run tests only.
#   --dir     Project directory containing pubspec.yaml (default: .).
# ----------------------------------------------------
set -euo pipefail

QUICK=false
FLUTTER_DIR="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true ;;
    --dir)
      if [[ $# -lt 2 ]]; then
        echo "[local-test-flutter] --dir requires a path." >&2
        exit 1
      fi
      FLUTTER_DIR="$2"
      shift
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ ! -d "$repo_root/$FLUTTER_DIR" ]]; then
  echo "[local-test-flutter] Directory not found: $repo_root/$FLUTTER_DIR" >&2
  exit 1
fi
cd "$repo_root/$FLUTTER_DIR"

if ! command -v flutter &>/dev/null; then
  echo "[local-test-flutter] flutter not found in PATH." >&2; exit 1
fi

if [[ ! -f pubspec.yaml ]]; then
  echo "[local-test-flutter] No pubspec.yaml in $FLUTTER_DIR." >&2; exit 1
fi

if [[ "$QUICK" == "false" ]]; then
  echo "[local-test-flutter] flutter pub get"
  flutter pub get
  echo "[local-test-flutter] flutter analyze"
  flutter analyze
fi

echo "[local-test-flutter] flutter test"
flutter test
echo "[local-test-flutter] Done."
