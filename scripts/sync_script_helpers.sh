#!/usr/bin/env bash
# SCRIPT: sync_script_helpers.sh
# DESCRIPTION: Sync vendor/script-helpers from the upstream repository.
# USAGE: ./sync_script_helpers.sh [-h]
# EXAMPLE: ./sync_script_helpers.sh
# PARAMETERS:
#   -h, --help   Show this help message.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}/vendor/script-helpers}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { display_help; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

DEST_DIR="$ROOT_DIR/vendor/script-helpers"
REPO_URL="${SCRIPT_HELPERS_REPO_URL:-git@github.com:nikolareljin/script-helpers.git}"
REF="${SCRIPT_HELPERS_REF:-}"

rm -rf "$DEST_DIR"
mkdir -p "$ROOT_DIR/vendor"
git clone "$REPO_URL" "$DEST_DIR"

if [[ -n "$REF" ]]; then
  (cd "$DEST_DIR" && git checkout "$REF")
fi

# Get the commit hash for reference (before removing .git)
COMMIT_HASH=$(cd "$DEST_DIR" && git rev-parse HEAD)

# Remove .git directory to avoid nested git repositories
rm -rf "$DEST_DIR/.git"

echo "Synced script-helpers from $REPO_URL"
echo "Commit: $COMMIT_HASH"
echo "Note: .git directory removed to avoid conflicts with parent repository"
