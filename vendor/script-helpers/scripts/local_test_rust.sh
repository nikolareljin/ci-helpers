#!/usr/bin/env bash
# SCRIPT: local_test_rust.sh
# DESCRIPTION: Check, lint, and test a Rust project.
# USAGE: bash scripts/local_test_rust.sh [--dir <path>] [--quick] [--manifest <path>] [--any-cargo]
#
# PARAMETERS:
#   --dir     Project directory, relative to the repository root (default: .).
#   --quick      Skip cargo check/clippy; run tests only.
#   --manifest   Path to Cargo.toml (default: ./Cargo.toml).
#   --any-cargo  Use whatever cargo PATH offers, instead of rustup's.
#
# By default this runs against rustup's cargo, which is what CI installs
# (dtolnay/rust-toolchain@stable). A distribution cargo earlier on PATH is
# usually older, and the errors it produces name the lockfile rather than the
# toolchain -- so a gate claiming "this is what CI would have run" quietly
# runs something else. --any-cargo opts out for a repository that genuinely
# targets the system toolchain. RUST_TOOLCHAIN pins the channel or version
# resolved (default: stable).
# ----------------------------------------------------
set -euo pipefail

QUICK=false
ANY_CARGO=false
TEST_DIR="."
MANIFEST="Cargo.toml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true ;;
    --any-cargo) ANY_CARGO=true ;;
    --dir)
      if [[ $# -lt 2 ]]; then
        echo "[local-test-rust] --dir requires a path." >&2
        exit 1
      fi
      TEST_DIR="$2"
      shift
      ;;
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
if [[ ! -d "$repo_root/$TEST_DIR" ]]; then
  echo "[local-test-rust] Directory not found: $repo_root/$TEST_DIR" >&2
  exit 1
fi
cd "$repo_root/$TEST_DIR"

# Resolve the toolchain before looking for cargo: rustup's may not be on PATH
# at all yet, and the point is to run what CI runs.
if [[ "$ANY_CARGO" == "false" ]]; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)/helpers.sh"
  shlib_import rust
  rust_toolchain_ci_uses || {
    echo "[local-test-rust] Pass --any-cargo to run against PATH's cargo anyway." >&2
    exit 1
  }
fi

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
