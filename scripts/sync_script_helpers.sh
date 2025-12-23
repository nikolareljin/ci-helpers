#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${1:-}"

if [[ -z "$SRC_DIR" ]]; then
  if [[ -d "$ROOT_DIR/../script-helpers" ]]; then
    SRC_DIR="$ROOT_DIR/../script-helpers"
  else
    echo "Usage: sync_script_helpers.sh /path/to/script-helpers" >&2
    exit 2
  fi
fi

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Source path not found: $SRC_DIR" >&2
  exit 2
fi

rm -rf "$ROOT_DIR/vendor/script-helpers"
mkdir -p "$ROOT_DIR/vendor"
cp -R "$SRC_DIR" "$ROOT_DIR/vendor/script-helpers"

echo "Synced script-helpers from $SRC_DIR"
