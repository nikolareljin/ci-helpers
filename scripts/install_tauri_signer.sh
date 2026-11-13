#!/usr/bin/env bash
# SCRIPT: install_tauri_signer.sh
# DESCRIPTION: Install the tauri-cli version pinned in toolchain-pins.env
#              under ROOT, for `cargo-tauri tauri signer sign` in a signing
#              job. Run it in a step that holds no secret: cargo builds the
#              crate and its dependencies here.
# USAGE: ROOT=<dir> bash scripts/install_tauri_signer.sh
# ENVIRONMENT:
#   ROOT            Install root (required); the binary lands in ROOT/bin.
#   TOOLCHAIN_PINS  Pins file (default: toolchain-pins.env beside scripts/).
#   GITHUB_OUTPUT   Receives signer=<absolute path of the binary> when set.
# EXIT CODES:
#   0  Installed.
#   1  cargo failed or the binary is missing.
#   2  Usage error: no ROOT, no pin, a pin not X.Y.Z, no cargo.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="${TOOLCHAIN_PINS:-$script_dir/../toolchain-pins.env}"
[[ -n "${ROOT:-}" ]] || { echo "::error::ROOT is not set." >&2; exit 2; }
[[ -f "$pins" ]] || { echo "::error::Pins file $pins is missing." >&2; exit 2; }
version="$(awk -F= '$1 == "TAURI_CLI_VERSION" { print $2; exit }' "$pins")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::TAURI_CLI_VERSION in $pins is '$version', not X.Y.Z." >&2; exit 2; }
command -v cargo >/dev/null || { echo "::error::no cargo on PATH." >&2; exit 2; }

# A fresh CARGO_HOME and an empty working directory: no cargo config from
# HOME or the current directory (rustc-wrapper, source replacement) applies.
cargo_home="$(mktemp -d)"
trap 'rm -rf "$cargo_home"' EXIT
mkdir "$cargo_home/home" "$cargo_home/cwd"
(cd "$cargo_home/cwd" && CARGO_HOME="$cargo_home/home" cargo install tauri-cli --version "=$version" --locked --root "$ROOT")
bin="$ROOT/bin/cargo-tauri"
[[ -f "$bin.exe" ]] && bin="$bin.exe"
[[ -f "$bin" && ! -L "$bin" ]] || { echo "::error::cargo install left no $bin." >&2; exit 1; }
echo "signer=$bin"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "signer=$bin" >> "$GITHUB_OUTPUT"
fi
