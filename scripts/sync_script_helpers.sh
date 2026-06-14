#!/usr/bin/env bash
# SCRIPT: sync_script_helpers.sh
# DESCRIPTION: Sync vendor/script-helpers to the latest release tag (or a specific ref).
# USAGE: ./sync_script_helpers.sh [--ref <ref>] [--repo-url <url>] [-h]
# PARAMETERS:
#   --ref <ref>        Git ref to pin (tag, branch, SHA). Defaults to latest semver tag.
#                      Can also be set via SCRIPT_HELPERS_REF env var.
#   --repo-url <url>   Upstream repository URL. Defaults to SCRIPT_HELPERS_REPO_URL env var
#                      or git@github.com:nikolareljin/script-helpers.git.
#   -h, --help         Show this help message.
# EXAMPLE: ./sync_script_helpers.sh
# EXAMPLE: ./sync_script_helpers.sh --ref v0.14.0
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}/vendor/script-helpers}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { display_help; }

REPO_URL="${SCRIPT_HELPERS_REPO_URL:-git@github.com:nikolareljin/script-helpers.git}"
REF="${SCRIPT_HELPERS_REF:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      [[ -z "${2-}" || "${2-}" == --* ]] && { log_error "Missing value for --ref"; usage; exit 2; }
      REF="$2"; shift 2 ;;
    --repo-url)
      [[ -z "${2-}" || "${2-}" == --* ]] && { log_error "Missing value for --repo-url"; usage; exit 2; }
      REPO_URL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

# Auto-detect latest semver tag when no ref is given.
if [[ -z "$REF" ]]; then
  log_info "Fetching latest release tag from ${REPO_URL} ..."
  REF="$(
    git ls-remote --tags --refs "$REPO_URL" \
      | awk '{print $2}' \
      | sed 's|refs/tags/||' \
      | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -V \
      | tail -n1
  )"
  if [[ -z "$REF" ]]; then
    log_error "No semver tags found in ${REPO_URL}"
    exit 1
  fi
  log_info "Latest tag: ${REF}"
fi

DEST_DIR="$ROOT_DIR/vendor/script-helpers"

# Skip if already at this commit.
current_sha=""
if [[ -f "${ROOT_DIR}/vendor/.script-helpers-sha" ]]; then
  current_sha="$(cat "${ROOT_DIR}/vendor/.script-helpers-sha")"
fi

# Clone to a temp dir so vendor is only replaced on success.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log_info "Cloning ${REPO_URL} @ ${REF} ..."
git clone --quiet --branch "$REF" --depth 1 "$REPO_URL" "$TMP_DIR/script-helpers"

COMMIT_HASH="$(git -C "$TMP_DIR/script-helpers" rev-parse HEAD)"

if [[ "$COMMIT_HASH" == "$current_sha" ]]; then
  log_info "Already up to date at ${REF} (${COMMIT_HASH}). Nothing to do."
  exit 0
fi

rm -rf "$DEST_DIR"
mkdir -p "$ROOT_DIR/vendor"
cp -r "$TMP_DIR/script-helpers" "$DEST_DIR"

# Remove .git directory to avoid nested git repositories.
rm -rf "$DEST_DIR/.git"

# Write SHA and ref lockfiles so vendor-drift checks can compare against upstream.
echo "$COMMIT_HASH" > "$ROOT_DIR/vendor/.script-helpers-sha"
echo "$REF"         > "$ROOT_DIR/vendor/.script-helpers-ref"

log_info "Synced script-helpers from ${REPO_URL}"
log_info "Ref: ${REF} — Commit: ${COMMIT_HASH}"
