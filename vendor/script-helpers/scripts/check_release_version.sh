#!/usr/bin/env bash
# SCRIPT: check_release_version.sh
# DESCRIPTION: Validate VERSION against release/* branch and tag state.
# USAGE: scripts/check_release_version.sh [--branch <name>] [--version-file <path>] [--fetch-tags] [OPTIONS]
# PARAMETERS:
#   --branch <name>        Override branch name (default: current git branch).
#   --version-file <path>  Path to VERSION file (default: VERSION).
#   --fetch-tags           Fetch tags from origin before checks.
#   -h, --help             Show this help message.
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "Usage: scripts/check_release_version.sh [--branch <name>] [--version-file <path>] [--fetch-tags]"
}

BRANCH_NAME=""
VERSION_FILE="VERSION"
FETCH_TAGS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) BRANCH_NAME="$2"; shift 2;;
    --version-file) VERSION_FILE="$2"; shift 2;;
    --fetch-tags) FETCH_TAGS=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

cd "$ROOT_DIR"

if [[ -z "$BRANCH_NAME" ]]; then
  BRANCH_NAME="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
fi

if [[ -z "$BRANCH_NAME" ]]; then
  exit 0
fi

if [[ "$FETCH_TAGS" == "true" ]]; then
  git fetch --tags origin >/dev/null 2>&1 || true
fi

if [[ "$BRANCH_NAME" =~ ^release/([0-9]+)\.([0-9]+)\.([0-9]+)(-rc[0-9]+)?$ ]]; then
  release_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}${BASH_REMATCH[4]:-}"
  version_file="$(head -n1 "$VERSION_FILE" | xargs || true)"
  if [[ -z "$version_file" ]]; then
    echo "[check_release_version] VERSION is empty; aborting." >&2
    exit 1
  fi
  if [[ "$version_file" != "$release_version" ]]; then
    echo "[check_release_version] VERSION mismatch for release branch." >&2
    echo "  Branch: $BRANCH_NAME" >&2
    echo "  VERSION: $version_file" >&2
    exit 1
  fi
  if git rev-parse -q --verify "refs/tags/$release_version" >/dev/null; then
    echo "[check_release_version] Tag $release_version already exists; aborting." >&2
    exit 1
  fi
  if [[ "$release_version" =~ -rc[0-9]+$ ]]; then
    base_version="${release_version%-rc*}"
    if git rev-parse -q --verify "refs/tags/$base_version" >/dev/null; then
      echo "[check_release_version] Warning: base tag $base_version already exists. This can be expected when creating an RC after a final release, but verify that creating $release_version is intentional." >&2
    fi
  fi
fi
