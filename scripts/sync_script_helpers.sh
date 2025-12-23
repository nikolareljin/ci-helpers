#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$ROOT_DIR/vendor/script-helpers"
REPO_URL="${SCRIPT_HELPERS_REPO_URL:-git@github.com:nikolareljin/script-helpers.git}"
REF="${SCRIPT_HELPERS_REF:-}"

rm -rf "$DEST_DIR"
mkdir -p "$ROOT_DIR/vendor"
git clone "$REPO_URL" "$DEST_DIR"

if [[ -n "$REF" ]]; then
  (cd "$DEST_DIR" && git checkout "$REF")
fi

echo "Synced script-helpers from $REPO_URL"
