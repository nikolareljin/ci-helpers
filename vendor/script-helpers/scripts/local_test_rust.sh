#!/usr/bin/env bash
# SCRIPT: local_test_rust.sh
# DESCRIPTION: Check, lint, and test a Rust project.
# USAGE: bash scripts/local_test_rust.sh [--quick] [--manifest <path>]
#
# PARAMETERS:
#   --quick      Skip cargo check/clippy; run tests only.
#   --manifest   Path to Cargo.toml (default: ./Cargo.toml).
# ----------------------------------------------------
set -euo pipefail

QUICK=false
MANIFEST="Cargo.toml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true ;;
    --manifest)
      if [[ $# -lt 2 ]]; then
        echo "[local-test-rust] --manifest requires a Cargo.toml path." >&2
        exit 1
      fi
      MANIFEST="$2"
      shift
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

if ! command -v cargo &>/dev/null; then
  echo "[local-test-rust] cargo not found in PATH." >&2; exit 1
fi

if [[ "$QUICK" == "false" ]]; then
  echo "[local-test-rust] cargo check"
  cargo check --manifest-path "$MANIFEST"
  if cargo clippy --version &>/dev/null 2>&1; then
    echo "[local-test-rust] cargo clippy"
    cargo clippy --manifest-path "$MANIFEST" -- -D warnings
  fi
fi

echo "[local-test-rust] cargo test"
cargo test --manifest-path "$MANIFEST"
echo "[local-test-rust] Done."
