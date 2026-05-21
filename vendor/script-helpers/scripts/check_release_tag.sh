#!/usr/bin/env bash
# SCRIPT: check_release_tag.sh
# DESCRIPTION: Guard against tagging an existing release from a release/[v]X.Y.Z[-rcN] or release/[v]X.Y.Z[-rc.N] branch.
# USAGE: scripts/check_release_tag.sh --branch <branch> [--repo <path>] [--remote <name>] [--fetch-tags] [--print-version]
# PARAMETERS:
#   --branch <branch>    Release branch name (defaults to GITHUB_REF_NAME/GITHUB_HEAD_REF).
#   --repo <path>        Repository path (default: GITHUB_WORKSPACE or cwd).
#   --remote <name>      Git remote used with --fetch-tags (default: origin).
#   --fetch-tags         Fetch tags from --remote before checking.
#   --print-version      Print the parsed version if eligible.
#   -h, --help           Show this help message.
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { show_help "${BASH_SOURCE[0]}"; }

branch=""
repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
remote="origin"
fetch_tags=false
print_version=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) branch="$2"; shift 2 ;;
    --repo) repo_dir="$2"; shift 2 ;;
    --remote) remote="$2"; shift 2 ;;
    --fetch-tags) fetch_tags=true; shift ;;
    --print-version) print_version=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

if [[ -z "$branch" ]]; then
  branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
fi

if [[ -z "$branch" ]]; then
  log_error "Branch not provided and GITHUB_REF_NAME/GITHUB_HEAD_REF not set"
  exit 2
fi

if [[ ! "$branch" =~ ^release\/v?([0-9]+\.[0-9]+\.[0-9]+(-rc\.?[0-9]+)?)$ ]]; then
  log_info "Skipping: '$branch' is not a release branch"
  exit 0
fi

version="${BASH_REMATCH[1]}"

if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log_error "Repository path is not a valid git work tree: $repo_dir"
  exit 2
fi

if [[ "$fetch_tags" == "true" ]]; then
  if ! git -C "$repo_dir" fetch "$remote" --tags >/dev/null 2>&1; then
    log_error "Failed to fetch tags from remote '$remote' in repository: $repo_dir"
    exit 1
  fi
fi

if git -C "$repo_dir" show-ref --tags --verify --quiet "refs/tags/$version"; then
  log_error "Tag $version already exists for release branch $branch"
  exit 1
fi

log_info "Tag $version is available for release branch $branch"
if [[ "$print_version" == "true" ]]; then
  echo "$version"
fi
