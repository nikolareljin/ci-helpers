#!/usr/bin/env bash
# SCRIPT: install_tauri_signer.sh
# DESCRIPTION: Install the tauri-cli version pinned in toolchain-pins.env
#              under ROOT, for `cargo-tauri tauri signer sign` in a signing
#              job. Run it in a step that holds no secret: cargo builds the
#              crate and its dependencies here.
# USAGE: ROOT=<dir> bash scripts/install_tauri_signer.sh
# ENVIRONMENT:
#   ROOT            Install root (required); the binary lands in ROOT/bin.
#   RUNNER_TEMP     Parent of the private CARGO_HOME and work directory.
#   TOOLCHAIN_PINS  Pins file (default: toolchain-pins.env beside scripts/).
#   GITHUB_OUTPUT   Receives signer=<absolute path of the binary> when set.
# EXIT CODES:
#   0  Installed.
#   1  cargo failed, the binary is missing, or a .cargo/config sits
#      above the work directory.
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

# cargo reads .cargo/config* in every ancestor of its working directory
# and in CARGO_HOME, and honours CARGO_*/RUSTC*/RUSTFLAGS env: any of them
# can set rustc-wrapper or replace the registry. So: a fresh CARGO_HOME
# under RUNNER_TEMP, an empty working directory with no config above it,
# an allowlisted environment, and the wrappers and registry forced.
base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
cargo_home="$(mktemp -d "$base/cargo.XXXXXX")"
trap 'rm -rf "$cargo_home"' EXIT
mkdir "$cargo_home/home" "$cargo_home/cwd"
dir="$(cd "$cargo_home/cwd" && pwd -P)"
while :; do
  for c in "$dir/.cargo/config" "$dir/.cargo/config.toml"; do
    [[ ! -e "$c" && ! -L "$c" ]] || { echo "::error::$c exists above the cargo work directory; refusing to run cargo." >&2; exit 1; }
  done
  [[ "$dir" != / && -n "$dir" ]] || break
  dir="$(dirname -- "$dir")"
done
keep=(PATH="$PATH" HOME="${HOME:-}" CARGO_HOME="$cargo_home/home")
for v in RUSTUP_HOME USERPROFILE SYSTEMROOT SystemRoot TEMP TMP APPDATA LOCALAPPDATA; do
  [[ -z "${!v:-}" ]] || keep+=("$v=${!v}")
done
(cd "$cargo_home/cwd" && env -i "${keep[@]}" cargo install tauri-cli --version "=$version" --locked --root "$ROOT" \
  --config 'build.rustc-wrapper=""' --config 'build.rustc-workspace-wrapper=""' \
  --config 'registries.crates-io.protocol="sparse"')
bin="$ROOT/bin/cargo-tauri"
[[ -f "$bin.exe" ]] && bin="$bin.exe"
[[ -f "$bin" && ! -L "$bin" ]] || { echo "::error::cargo install left no $bin." >&2; exit 1; }
echo "signer=$bin"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "signer=$bin" >> "$GITHUB_OUTPUT"
fi
