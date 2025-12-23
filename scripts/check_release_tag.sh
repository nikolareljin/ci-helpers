#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS_DIR="$ROOT_DIR/vendor/script-helpers"
if [[ -f "$HELPERS_DIR/helpers.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HELPERS_DIR/helpers.sh"
  shlib_import logging
fi

usage() {
  cat <<'USAGE'
Usage: check_release_tag.sh --branch <branch> [--repo <path>] [--fetch-tags] [--print-version]

Checks if a release branch (release/X.Y.Z) already has a tag in the repo.
Exits 0 if branch is not a release branch or tag does not exist.
Exits 1 if the tag already exists.
Exits 2 on invalid input.
USAGE
}

log_info_safe() {
  if declare -F log_info >/dev/null 2>&1; then
    log_info "$*"
  else
    echo "[INFO] $*" >&2
  fi
}

log_error_safe() {
  if declare -F log_error >/dev/null 2>&1; then
    log_error "$*"
  else
    echo "[ERROR] $*" >&2
  fi
}

branch=""
repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
fetch_tags=false
print_version=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) branch="$2"; shift 2;;
    --repo) repo_dir="$2"; shift 2;;
    --fetch-tags) fetch_tags=true; shift;;
    --print-version) print_version=true; shift;;
    -h|--help) usage; exit 0;;
    *) log_error_safe "Unknown argument: $1"; usage; exit 2;;
  esac
done

if [[ -z "$branch" ]]; then
  branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
fi

if [[ -z "$branch" ]]; then
  log_error_safe "Branch not provided and GITHUB_REF_NAME/GITHUB_HEAD_REF not set"
  exit 2
fi

if [[ ! "$branch" =~ ^release\/v?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  log_info_safe "Skipping: '$branch' is not a release branch"
  exit 0
fi

version="${BASH_REMATCH[1]}"

if $fetch_tags; then
  git -C "$repo_dir" fetch --tags --prune --force >/dev/null 2>&1 || true
fi

if git -C "$repo_dir" show-ref --tags -q "refs/tags/$version"; then
  log_error_safe "Tag $version already exists for release branch $branch"
  exit 1
fi

log_info_safe "Tag $version is available for release branch $branch"
if $print_version; then
  echo "$version"
fi
