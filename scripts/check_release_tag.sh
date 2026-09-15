#!/usr/bin/env bash
# SCRIPT: check_release_tag.sh
# DESCRIPTION: Guard against tagging an existing release from a release/[v]X.Y.Z[-rcN] or release/[v]X.Y.Z[-rc.N] branch.
# USAGE: ./check_release_tag.sh --branch <branch> [--repo <path>] [--fetch-tags] [--print-version]
# EXAMPLE: ./check_release_tag.sh --branch release/1.2.3-rc.1 --fetch-tags
# PARAMETERS:
#   --branch <branch>    Release branch name (defaults to GITHUB_REF_NAME/GITHUB_HEAD_REF).
#   --repo <path>        Repository path (default: GITHUB_WORKSPACE or cwd).
#   --fetch-tags         Fetch tags before checking; exits 1 if the fetch fails.
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

if [[ ! "$branch" =~ ^release\/v?([0-9]+\.[0-9]+\.[0-9]+(-rc\.?[0-9]+)?)$ ]]; then
  log_info_safe "Skipping: '$branch' is not a release branch"
  exit 0
fi

version="${BASH_REMATCH[1]}"

# A fetch that fails leaves only the local tags to look at, which is exactly
# the case where a tag pushed from elsewhere is missing -- and the check would
# then report the version as available. When fetching was asked for, not being
# able to fetch is a failure, not a pass.
if $fetch_tags; then
  if ! fetch_err=$(git -C "$repo_dir" fetch --tags --prune --force 2>&1); then
    log_error_safe "Failed to fetch tags in $repo_dir; cannot tell whether $version is already tagged: ${fetch_err}"
    exit 1
  fi
fi

# Release branches accept an optional leading v, and so do the tags this
# repository and its consumers cut, so either spelling means the version is
# taken: release/2.0.0 must not pass while v2.0.0 exists, nor the reverse.
for candidate in "$version" "v$version"; do
  if git -C "$repo_dir" show-ref --tags -q "refs/tags/$candidate"; then
    log_error_safe "Tag $candidate already exists for release branch $branch"
    exit 1
  fi
done

log_info_safe "Tag $version is available for release branch $branch"
if $print_version; then
  echo "$version"
fi
