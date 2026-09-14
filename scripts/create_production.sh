#!/usr/bin/env bash
# SCRIPT: create_production.sh
# DESCRIPTION: Point the production tag AND branch at a specific version tag and push both.
# USAGE: ./create_production.sh -t <tag> [--name <name>] [--remote <name>] [--repo <path>] [--fetch-tags] [--no-branch]
# PARAMETERS:
#   -t, --tag <tag>         Required. Tag to point the production tag at. It must exist on the remote at the same commit as locally.
#   --name <name>           Name for both the tag and branch to update (default: production). Both refs/tags/<name> and refs/heads/<name> are updated unless --no-branch is set. main, master and HEAD are refused.
#   --remote <name>         Remote name to push to (default: origin).
#   --repo <path>           Repository path (default: GITHUB_WORKSPACE or cwd).
#   --fetch-tags            Fetch tags from the remote before updating; exits 1 if the fetch fails.
#   --no-branch             Skip updating the production branch (tag-only update).
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

log_warn_safe() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$*"
  else
    echo "[WARN] $*" >&2
  fi
}

tag=""
prod_tag="production"
remote="origin"
repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
fetch_tags=false
update_branch=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tag) tag="$2"; shift 2;;
    --name|--tag-name) prod_tag="$2"; shift 2;;
    --remote) remote="$2"; shift 2;;
    --repo) repo_dir="$2"; shift 2;;
    --fetch-tags) fetch_tags=true; shift;;
    --no-branch) update_branch=false; shift;;
    -h|--help) usage; exit 0;;
    *) log_error_safe "Unknown argument: $1"; usage; exit 2;;
  esac
done

if [[ -z "$tag" ]]; then
  log_error_safe "Tag is required (-t <tag>)"
  usage
  exit 2
fi

# Moving the production ref by hand onto a branch that other work lands on
# would force-push over it. Refuse the names that are never a production alias.
case "$prod_tag" in
  main|master|HEAD)
    log_error_safe "Refusing --name ${prod_tag}: it would force-move the ${prod_tag} branch"
    exit 2
    ;;
esac

# A failed fetch used to be ignored, so the run continued on whatever tags the
# checkout happened to have. When fetching was asked for, not fetching is fatal.
if $fetch_tags; then
  if ! fetch_err=$(git -C "$repo_dir" fetch "$remote" --tags --prune --force 2>&1); then
    log_error_safe "Failed to fetch tags from ${remote}: ${fetch_err}"
    exit 1
  fi
fi

if ! git -C "$repo_dir" rev-parse "refs/tags/$tag" >/dev/null 2>&1; then
  log_error_safe "Tag $tag not found in $repo_dir"
  exit 1
fi

target_sha=$(git -C "$repo_dir" rev-parse "refs/tags/$tag^{}")

# The local tag is only a copy. Production must point at the release the remote
# published, so resolve the tag there too and refuse to move anything when it
# is missing or names a different commit (a tag re-cut locally, or never pushed).
# The verification at the end compares against target_sha, so without this it
# would confirm a wrong commit against itself.
if ! remote_src_out=$(git -C "$repo_dir" ls-remote "$remote" "refs/tags/${tag}" "refs/tags/${tag}^{}"); then
  log_error_safe "Failed to query remote ${remote} for tag ${tag}"
  exit 1
fi
# ls-remote patterns match on trailing path components, so compare names exactly.
remote_src_sha=$(printf '%s\n' "$remote_src_out" | awk -v r="refs/tags/${tag}^{}" '$2 == r {print $1; exit}')
[[ -z "$remote_src_sha" ]] && remote_src_sha=$(printf '%s\n' "$remote_src_out" | awk -v r="refs/tags/${tag}" '$2 == r {print $1; exit}')
if [[ -z "$remote_src_sha" ]]; then
  log_error_safe "Tag $tag not found on remote ${remote}; push it before pointing ${prod_tag} at it"
  exit 1
fi
if [[ "$remote_src_sha" != "$target_sha" ]]; then
  log_error_safe "Tag $tag differs between $repo_dir (${target_sha:0:8}) and remote ${remote} (${remote_src_sha:0:8}); refusing to move ${prod_tag}"
  exit 1
fi

# Record where the production branch is on the remote BEFORE pushing anything,
# and lease the branch push on exactly that value. A bare --force-with-lease
# compares against the remote-tracking ref, and fetching that ref immediately
# before the push made the lease agree with whatever was there -- including a
# concurrent move it exists to catch. An empty value means the branch does not
# exist yet, and the lease then requires that it still does not.
if $update_branch; then
  if ! observed_branch_out=$(git -C "$repo_dir" ls-remote "$remote" "refs/heads/${prod_tag}"); then
    log_error_safe "Failed to query remote ${remote} for branch ${prod_tag}"
    exit 1
  fi
  observed_branch_sha=$(printf '%s\n' "$observed_branch_out" | awk -v r="refs/heads/${prod_tag}" '$2 == r {print $1; exit}')
fi

log_info_safe "Updating ${prod_tag} tag to ${tag}"
git -C "$repo_dir" tag -f "$prod_tag" "$tag"
# `--force-with-lease` is reliable for branches, but Git rejects it for moving
# an existing tag ref even after a fresh tag fetch. Use `--force` for tag alias updates.
git -C "$repo_dir" push "$remote" "refs/tags/${prod_tag}:refs/tags/${prod_tag}" --force
log_info_safe "Production tag ${prod_tag} now points to ${tag}"

if $update_branch; then
  log_info_safe "Advancing ${prod_tag} branch to ${tag} (${target_sha:0:8})"
  git -C "$repo_dir" push "$remote" "${target_sha}:refs/heads/${prod_tag}" \
    "--force-with-lease=refs/heads/${prod_tag}:${observed_branch_sha}"
  log_info_safe "Production branch ${prod_tag} now points to ${tag}"
fi

# Verify both refs on remote now point to target_sha.
# Annotated tags: ls-remote returns both the tag-object SHA and a peeled ^{} commit SHA;
# lightweight tags return only the commit SHA. Prefer the peeled entry when present.
if ! remote_tag_out=$(git -C "$repo_dir" ls-remote "$remote" "refs/tags/${prod_tag}" "refs/tags/${prod_tag}^{}"); then
  log_error_safe "Failed to query remote ${remote} for tag ${prod_tag}"
  exit 1
fi
remote_tag_sha=$(printf '%s\n' "$remote_tag_out" | awk '/\^\{\}$/{print $1; exit}')
[[ -z "$remote_tag_sha" ]] && remote_tag_sha=$(printf '%s\n' "$remote_tag_out" | awk 'NR==1{print $1}')
if [[ -z "$remote_tag_sha" || "$remote_tag_sha" != "$target_sha" ]]; then
  log_error_safe "Verification failed: ${prod_tag} tag on remote is '${remote_tag_sha:0:8}', expected '${target_sha:0:8}'"
  exit 1
fi
if $update_branch; then
  if ! remote_branch_sha=$(git -C "$repo_dir" ls-remote "$remote" "refs/heads/${prod_tag}" | awk '{print $1}'); then
    log_error_safe "Failed to query remote ${remote} for branch ${prod_tag}"
    exit 1
  fi
  if [[ -z "$remote_branch_sha" || "$remote_branch_sha" != "$target_sha" ]]; then
    log_error_safe "Verification failed: ${prod_tag} branch on remote is '${remote_branch_sha:0:8}', expected '${target_sha:0:8}'"
    exit 1
  fi
  log_info_safe "Verified: ${prod_tag} tag and branch both point to ${target_sha:0:8}"
else
  log_info_safe "Verified: ${prod_tag} tag points to ${target_sha:0:8}"
fi
