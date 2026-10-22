#!/usr/bin/env bash
# SCRIPT: generate-android-keystore.sh
# DESCRIPTION: Generate an Android signing keystore without placing passwords on a command line.
# USAGE: bash scripts/generate-android-keystore.sh <output.jks>
# PARAMETERS:
#   <output.jks>  Required new keystore path. Existing files are refused.
# EXIT_CODES:
#   0  Keystore generated.
#   1  The output directory could not be created; a keytool failure exits with keytool's code.
#   2  Invalid arguments, or the output path already exists.
#   3  keytool was not found; install a JDK.
# EXAMPLE: bash scripts/generate-android-keystore.sh ./release.jks
# ----------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../helpers.sh
source "$ROOT_DIR/helpers.sh"
shlib_import android
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: $0 <output.jks>"
  exit 0
fi
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <output.jks>" >&2
  exit 2
fi
android_generate_keystore "$1"
