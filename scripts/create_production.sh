#!/usr/bin/env bash
# SCRIPT: create_production.sh
# DESCRIPTION: Point the production tag AND branch at a specific version tag and push both.
# USAGE: ./create_production.sh -t <tag> [--name <name>] [--remote <name>] [--repo <path>] [--fetch-tags] [--no-branch] [--base-branch <name>] [--allow-prerelease] [--allow-rollback] [--dry-run]
# PARAMETERS:
#   -t, --tag <tag>         Required. Tag to point the production tag at. It must exist on the remote at the same commit as locally.
#   --name <name>           Name for both the tag and branch to update (default: production). Both refs/tags/<name> and refs/heads/<name> are updated unless --no-branch is set. main, master and HEAD are refused.
#   --remote <name>         Remote name to push to (default: origin).
#   --repo <path>           Repository path (default: GITHUB_WORKSPACE or cwd).
#   --fetch-tags            Fetch tags from the remote before updating; exits 1 if the fetch fails.
#   --no-branch             Skip updating the production branch (tag-only update).
#   --base-branch <name>    Branch the tag must be on, as the remote has it (default: the remote's default branch).
#   --allow-prerelease      Accept X.Y.Z-<suffix> tags. Default: only X.Y.Z or vX.Y.Z.
#   --allow-rollback        Accept a tag older than the release production is on now.
#   --dry-run               Run every check, report what would move, push nothing.
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
base_branch=""
allow_prerelease=false
allow_rollback=false
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tag) tag="$2"; shift 2;;
    --name|--tag-name) prod_tag="$2"; shift 2;;
    --remote) remote="$2"; shift 2;;
    --repo) repo_dir="$2"; shift 2;;
    --fetch-tags) fetch_tags=true; shift;;
    --no-branch) update_branch=false; shift;;
    --base-branch) base_branch="$2"; shift 2;;
    --allow-prerelease) allow_prerelease=true; shift;;
    --allow-rollback) allow_rollback=true; shift;;
    --dry-run) dry_run=true; shift;;
    -h|--help) usage; exit 0;;
    *) log_error_safe "Unknown argument: $1"; usage; exit 2;;
  esac
done

if [[ -z "$tag" ]]; then
  log_error_safe "Tag is required (-t <tag>)"
  usage
  exit 2
fi

# Only release tags move production. Anything else pushed as a tag (9.9.9-beta,
# a typo, a branch-like name) used to move it, because the trigger is "*.*.*".
release_re='^v?[0-9]+\.[0-9]+\.[0-9]+$'
prerelease_re='^v?[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z][0-9A-Za-z.-]*$'
if [[ ! "$tag" =~ $release_re ]]; then
  if ! $allow_prerelease; then
    log_error_safe "Tag ${tag} is not a release (X.Y.Z or vX.Y.Z); pass --allow-prerelease to promote a candidate"
    exit 1
  fi
  if [[ ! "$tag" =~ $prerelease_re ]]; then
    log_error_safe "Tag ${tag} is not X.Y.Z or X.Y.Z-<suffix>"
    exit 1
  fi
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

# Compare two versions (X.Y.Z with an optional -suffix, optional leading v).
# Prints gt, eq or lt. Components compare as digit strings, so 1.10.0 > 1.9.0
# and a leading zero is not octal. Same core: a final release is greater than
# any of its candidates; two candidates order by `sort -V` on the suffix.
version_cmp() {
  local a="${1#v}" b="${2#v}" a_pre="" b_pre="" i x y
  [[ "$a" == *-* ]] && { a_pre="${a#*-}"; a="${a%%-*}"; }
  [[ "$b" == *-* ]] && { b_pre="${b#*-}"; b="${b%%-*}"; }
  local -a ap bp
  IFS=. read -r -a ap <<<"$a"
  IFS=. read -r -a bp <<<"$b"
  for i in 0 1 2; do
    x="${ap[$i]#"${ap[$i]%%[!0]*}"}"; x="${x:-0}"
    y="${bp[$i]#"${bp[$i]%%[!0]*}"}"; y="${y:-0}"
    if (( ${#x} != ${#y} )); then
      (( ${#x} > ${#y} )) && echo gt || echo lt
      return
    fi
    if [[ "$x" != "$y" ]]; then
      [[ "$(printf '%s\n%s\n' "$x" "$y" | LC_ALL=C sort | tail -n1)" == "$x" ]] && echo gt || echo lt
      return
    fi
  done
  if [[ "$a_pre" == "$b_pre" ]]; then echo eq; return; fi
  [[ -z "$a_pre" ]] && { echo gt; return; }
  [[ -z "$b_pre" ]] && { echo lt; return; }
  [[ "$(printf '%s\n%s\n' "$a_pre" "$b_pre" | LC_ALL=C sort -V | tail -n1)" == "$a_pre" ]] && echo gt || echo lt
}

# The release must be on the base branch as the remote has it. A tag pushed
# from a side branch or a fork's commit used to move production, which every
# consumer then ran. Fail closed: a fetch error or missing history refuses too.
if [[ -z "$base_branch" ]]; then
  if ! head_out=$(git -C "$repo_dir" ls-remote --symref "$remote" HEAD); then
    log_error_safe "Failed to query remote ${remote} for its default branch"
    exit 1
  fi
  base_branch=$(printf '%s\n' "$head_out" | awk '$1 == "ref:" && $3 == "HEAD" {sub("^refs/heads/", "", $2); print $2; exit}')
  if [[ -z "$base_branch" ]]; then
    log_error_safe "Remote ${remote} reports no default branch; pass --base-branch"
    exit 1
  fi
fi
# The name goes into a fetch refspec, where "a:refs/heads/b" would also write
# a local ref. Accept branch names only.
if ! git check-ref-format --branch "$base_branch" >/dev/null 2>&1 || [[ "$base_branch" == *:* ]]; then
  log_error_safe "Invalid base branch name: ${base_branch}"
  exit 2
fi
if ! base_err=$(git -C "$repo_dir" fetch --quiet "$remote" "refs/heads/${base_branch}" 2>&1); then
  log_error_safe "Failed to fetch ${base_branch} from ${remote}: ${base_err}"
  exit 1
fi
base_sha=$(git -C "$repo_dir" rev-parse FETCH_HEAD)
if ! git -C "$repo_dir" merge-base --is-ancestor "$target_sha" "$base_sha" 2>/dev/null; then
  log_error_safe "Tag ${tag} (${target_sha:0:8}) is not on ${remote}/${base_branch}; refusing to move ${prod_tag}"
  exit 1
fi

# Production only moves forward. Two releases close together used to race, and
# the older one could land last with both runs green. A rollback is a separate,
# manual decision (--allow-rollback, used by update-production.yml).
if ! cur_out=$(git -C "$repo_dir" ls-remote "$remote" "refs/tags/${prod_tag}" "refs/tags/${prod_tag}^{}"); then
  log_error_safe "Failed to query remote ${remote} for tag ${prod_tag}"
  exit 1
fi
current_sha=$(printf '%s\n' "$cur_out" | awk -v r="refs/tags/${prod_tag}^{}" '$2 == r {print $1; exit}')
[[ -z "$current_sha" ]] && current_sha=$(printf '%s\n' "$cur_out" | awk -v r="refs/tags/${prod_tag}" '$2 == r {print $1; exit}')
if [[ -n "$current_sha" && "$current_sha" != "$target_sha" ]] && ! $allow_rollback; then
  # The version production is on now: the highest version tag at its commit.
  current_version=""
  while IFS= read -r t; do
    [[ "$t" =~ $release_re || "$t" =~ $prerelease_re ]] || continue
    if [[ -z "$current_version" || "$(version_cmp "$t" "$current_version")" == gt ]]; then
      current_version="$t"
    fi
  done < <(git -C "$repo_dir" tag --points-at "$current_sha")
  if [[ -z "$current_version" ]]; then
    log_error_safe "${prod_tag} is on ${current_sha:0:8}, which has no version tag here (fetch tags with --fetch-tags); cannot prove ${tag} is newer"
    exit 1
  fi
  if [[ "$(version_cmp "$tag" "$current_version")" != gt ]]; then
    log_error_safe "Tag ${tag} is not newer than ${current_version}, where ${prod_tag} is now; pass --allow-rollback to move it back"
    exit 1
  fi
fi

if $dry_run; then
  log_info_safe "Dry run: ${prod_tag} would move from ${current_sha:0:8} to ${tag} (${target_sha:0:8}); nothing pushed"
  exit 0
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
# an existing tag ref even after a fresh tag fetch, so the tag is force-updated
# (`+` refspec) and only the branch is leased.
if $update_branch; then
  log_info_safe "Advancing ${prod_tag} tag and branch to ${tag} (${target_sha:0:8})"
  # One atomic push: when the branch lease is refused (someone moved the branch
  # since it was read), the tag is not moved either, rather than leaving the
  # production tag on the new release and the branch on the old one.
  git -C "$repo_dir" push --atomic "$remote" \
    "+refs/tags/${prod_tag}:refs/tags/${prod_tag}" \
    "${target_sha}:refs/heads/${prod_tag}" \
    "--force-with-lease=refs/heads/${prod_tag}:${observed_branch_sha}"
  log_info_safe "Production tag and branch ${prod_tag} now point to ${tag}"
else
  git -C "$repo_dir" push "$remote" "refs/tags/${prod_tag}:refs/tags/${prod_tag}" --force
  log_info_safe "Production tag ${prod_tag} now points to ${tag}"
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
