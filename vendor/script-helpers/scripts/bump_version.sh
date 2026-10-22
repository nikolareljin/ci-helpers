#!/usr/bin/env bash
# SCRIPT: bump_version.sh
# DESCRIPTION: Bump the semantic version in a VERSION file using script-helpers.
# USAGE: ./bump_version.sh [major|minor|patch] [-f VERSION_FILE]
# PARAMETERS:
#   major|minor|patch   Which part of the version to increment.
#   -f, --file PATH     Version file path; a relative path is taken from the
#                       current directory. Default: VERSION at the project root,
#                       the top of the git work tree holding the cwd (the
#                       superproject when run inside a vendored script-helpers
#                       submodule), or the cwd outside git. Never the vendored
#                       copy's own VERSION. A missing file is created,
#                       starting from 0.1.0.
#   -h, --help          Show this help.
# EXIT_CODES:
#   0  Version bumped and written (also -h/--help).
#   1  No arguments, unknown or repeated argument, a version that is not X.Y.Z,
#      or the version file or its directory could not be written.
#   2  -f/--file without its value.
# EXAMPLE:
#   scripts/bump_version.sh minor -f VERSION
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

# Refuse a trailing -f here, as a usage error (2); version_bump does the rest.
args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file) require_value "$@" || exit 2; shift 2 ;;
    *) shift ;;
  esac
done

version_bump "${args[@]}" || exit $?
