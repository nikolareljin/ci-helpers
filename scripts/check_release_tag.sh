#!/usr/bin/env bash
# SCRIPT: check_release_tag.sh
# DESCRIPTION: Guard against tagging an existing release from a release/X.Y.Z[-rcN] branch.
# USAGE: ./check_release_tag.sh --branch <branch> [--repo <path>] [--fetch-tags] [--print-version]
# EXAMPLE: ./check_release_tag.sh --branch release/1.2.3-rc.1 --fetch-tags
# PARAMETERS:
#   --branch <branch>    Release branch name (defaults to GITHUB_REF_NAME/GITHUB_HEAD_REF).
#   --repo <path>        Repository path (default: GITHUB_WORKSPACE or cwd).
#   --fetch-tags         Fetch tags before checking.
#   --print-version      Print the parsed version if eligible.
#   -h, --help           Show this help message.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}/vendor/script-helpers}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { display_help; }

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

if [[ ! "$branch" =~ ^release\/v?([0-9]+\.[0-9]+\.[0-9]+(?:-rc\.?[0-9]+)?)$ ]]; then
  log_info_safe "Skipping: '$branch' is not a release branch"
  exit 0
fi

version="${BASH_REMATCH[1]}"

if $fetch_tags; then
  git -C "$repo_dir" fetch --tags --prune --force >/dev/null 2>&1 || true
fi

if git -C "$repo_dir" rev-parse -q --verify "refs/tags/$version" >/dev/null; then
  log_error_safe "Tag $version already exists for release branch $branch"
  exit 1
fi

log_info_safe "Tag $version is available for release branch $branch"
if $print_version; then
  echo "$version"
fi
