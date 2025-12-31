#!/usr/bin/env bash
# SCRIPT: create_production.sh
# DESCRIPTION: Point a production branch at a specific tag and push it to the remote.
# USAGE: ./create_production.sh -t <tag> [--branch <name>] [--remote <name>] [--repo <path>] [--fetch-tags]
# PARAMETERS:
#   -t, --tag <tag>         Required. Tag to point the production branch at.
#   --branch <name>         Branch name to update (default: production).
#   --remote <name>         Remote name to push to (default: origin).
#   --repo <path>           Repository path (default: GITHUB_WORKSPACE or cwd).
#   --fetch-tags            Fetch tags before updating the branch.
#   -h, --help              Show this help message.
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

tag=""
branch="production"
remote="origin"
repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
fetch_tags=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tag) tag="$2"; shift 2;;
    --branch) branch="$2"; shift 2;;
    --remote) remote="$2"; shift 2;;
    --repo) repo_dir="$2"; shift 2;;
    --fetch-tags) fetch_tags=true; shift;;
    -h|--help) usage; exit 0;;
    *) log_error_safe "Unknown argument: $1"; usage; exit 2;;
  esac
done

if [[ -z "$tag" ]]; then
  log_error_safe "Tag is required (-t <tag>)"
  usage
  exit 2
fi

if $fetch_tags; then
  git -C "$repo_dir" fetch --tags --prune --force >/dev/null 2>&1 || true
fi

if ! git -C "$repo_dir" rev-parse "refs/tags/$tag" >/dev/null 2>&1; then
  log_error_safe "Tag $tag not found in $repo_dir"
  exit 1
fi

log_info_safe "Updating ${branch} to tag ${tag}"
git -C "$repo_dir" branch -f "$branch" "$tag"
git -C "$repo_dir" push "$remote" "refs/heads/${branch}:refs/heads/${branch}" --force-with-lease
log_info_safe "Production branch ${branch} now points to ${tag}"
