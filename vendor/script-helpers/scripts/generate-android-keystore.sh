#!/usr/bin/env bash
# Generate an Android signing keystore without placing passwords on a command line.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../helpers.sh
source "$ROOT_DIR/helpers.sh"
shlib_import android
if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: $0 <output.jks>"
  exit 0
fi
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <output.jks>" >&2
  exit 2
fi
android_generate_keystore "$1"
