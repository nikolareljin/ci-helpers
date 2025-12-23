#!/usr/bin/env bash
# SCRIPT: bump_version.sh
# DESCRIPTION: Bump the semantic version in a VERSION file using script-helpers.
# USAGE: ./bump_version.sh [major|minor|patch] [-f VERSION_FILE]
# EXAMPLE: ./bump_version.sh minor
# PARAMETERS:
#   major|minor|patch   Which part of the version to increment.
#   -f, --file PATH     Version file path (default: VERSION at project root).
# ----------------------------------------------------
set -euo pipefail

# Resolve script-helpers root and load modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging help env version

usage() { display_help; }

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

version_bump "$@" || exit $?
