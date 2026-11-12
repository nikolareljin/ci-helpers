#!/usr/bin/env bash
# SCRIPT: tauri_updater_sign.sh
# DESCRIPTION: Write a Tauri updater signature (<file>.sig) for each FILE
#              with the pinned tauri-cli, the way `tauri build` does when
#              the updater key is set. The signer runs in an empty
#              directory, so no tauri.conf, Cargo.toml or package.json is
#              read and no bundler hook runs.
# USAGE: SIGNER=<cargo-tauri> TAURI_SIGNING_PRIVATE_KEY=... \
#          bash scripts/tauri_updater_sign.sh FILE...
# ENVIRONMENT:
#   SIGNER                              Absolute path of cargo-tauri (required).
#   TAURI_SIGNING_PRIVATE_KEY           The updater key (required).
#   TAURI_SIGNING_PRIVATE_KEY_PASSWORD  Its password (may be empty).
# EXIT CODES:
#   0  Every FILE has a non-empty .sig.
#   1  The signer failed or wrote no signature.
#   2  Usage error: no FILE, no key, no signer, a FILE that is not a
#      regular file or starts with '-'.
# ----------------------------------------------------
set -euo pipefail

[[ $# -gt 0 ]] || { echo "::error::no files to sign." >&2; exit 2; }
[[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ]] || { echo "::error::TAURI_SIGNING_PRIVATE_KEY is empty; nothing is signed." >&2; exit 2; }
[[ -n "${SIGNER:-}" && "$SIGNER" == /* && -f "$SIGNER" ]] || [[ -n "${SIGNER:-}" && "$SIGNER" =~ ^[A-Za-z]:[\\/] && -f "$SIGNER" ]] \
  || { echo "::error::SIGNER '${SIGNER:-}' is not an absolute path to a file." >&2; exit 2; }
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
files=()
for f in "$@"; do
  [[ "$(basename -- "$f")" != -* ]] || { echo "::error::'$f' starts with '-'." >&2; exit 2; }
  [[ -f "$f" && ! -L "$f" ]] || { echo "::error::'$f' is not a regular file." >&2; exit 2; }
  files+=("$(cd "$(dirname -- "$f")" && pwd)/$(basename -- "$f")")
done
empty="$(mktemp -d)"
trap 'rm -rf "$empty"' EXIT
cd "$empty"
for f in "${files[@]}"; do
  rm -f -- "$f.sig"
  "$SIGNER" tauri signer sign "$f"
  [[ -s "$f.sig" && ! -L "$f.sig" ]] || { echo "::error::no signature written for $(basename -- "$f")." >&2; exit 1; }
  echo "signed: $(basename -- "$f").sig"
done
