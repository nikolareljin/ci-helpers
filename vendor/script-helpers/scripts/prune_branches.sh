#!/usr/bin/env bash
# SCRIPT: prune_branches.sh
# DESCRIPTION: Remove branches whose work has already landed, and only those.
# USAGE: scripts/prune_branches.sh [--apply] [--remote] [OPTIONS]
# PARAMETERS:
#   --apply           Actually delete. Without it nothing is removed: the
#                     default is a report, because the failure mode of this
#                     script is losing work.
#   --remote          Also consider branches on the remote. Local only by
#                     default -- a local branch is recoverable from the reflog
#                     for weeks; a deleted remote branch is not.
#   --repo <path>     Repository to operate on (default: current directory).
#   --base <branch>   Branch that work merges into (default: the remote's HEAD,
#                     then main/master/trunk/develop).
#   --remote-name <n> Remote to use (default: origin).
#   --keep <pattern>  Never touch branches matching this glob. Repeatable.
#   --no-fetch        Skip the fetch. Faster, and wrong if the remote moved:
#                     a stale base makes a landed branch look unmerged.
#   -h, --help        Show this help message.
# EXAMPLE: bash scripts/script-helpers/scripts/prune_branches.sh --remote --apply
# ----------------------------------------------------
#
# `git branch --merged` is not enough on its own. It asks whether the branch
# tip is an ancestor of the base, which is true after a merge commit and false
# after every squash merge and every rebase merge. Repositories that squash --
# most of them -- accumulate branches it will never list.
#
# The dangerous direction is the other one. A branch whose work landed and
# which then received new commits still has something to lose, and a check that
# only asks "are these changes in the base?" deletes it. That case is real: a
# push to a branch whose pull request has already merged succeeds silently, and
# the commit sits somewhere no pull request will ever pick it up.
#
# So both tests here look at the branch tip as it stands now. A commit added
# after the merge changes the tip, which changes the tree, which fails both
# tests -- the protection falls out of the check rather than being a separate
# rule someone has to remember to write.
#
# What is never touched, whatever its merge state: the base branch, the branch
# currently checked out, a branch checked out in another worktree, anything
# matching a protected name (main, master, trunk, develop, production,
# release/*, hotfix/*), and any branch holding commits its upstream does not.
# ----------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging git_branches >/dev/null 2>&1 || true
type log_info  >/dev/null 2>&1 || log_info()  { printf '[INFO] %s\n' "$*"; }
type log_warn  >/dev/null 2>&1 || log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
type log_error >/dev/null 2>&1 || log_error() { printf '[ERROR] %s\n' "$*" >&2; }

if ! type git_branches_merge_state >/dev/null 2>&1; then
  log_error "lib/git_branches.sh did not load from ${SCRIPT_HELPERS_DIR}"
  exit 1
fi

APPLY=false
DO_REMOTE=false
REPO=""
BASE=""
REMOTE_NAME="origin"
DO_FETCH=true
KEEP=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)        APPLY=true; shift ;;
    --remote)       DO_REMOTE=true; shift ;;
    --repo)         REPO="${2:?--repo needs a path}"; shift 2 ;;
    --base)         BASE="${2:?--base needs a branch}"; shift 2 ;;
    --remote-name)  REMOTE_NAME="${2:?--remote-name needs a name}"; shift 2 ;;
    --keep)         KEEP+=("${2:?--keep needs a pattern}"); shift 2 ;;
    --no-fetch)     DO_FETCH=false; shift ;;
    -h|--help)      sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)              log_error "Unknown argument: $1"; exit 2 ;;
  esac
done

if [[ -n "$REPO" ]]; then
  cd "$REPO" || { log_error "cannot enter $REPO"; exit 1; }
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  log_error "not a git repository: $(pwd)"
  exit 1
}
cd "$(git rev-parse --show-toplevel)" || exit 1

# A stale base is the one input that turns this script from safe into
# destructive: work merged an hour ago still looks unmerged, so nothing is
# deleted -- but a base that has been force-moved backwards makes landed
# branches look unmerged too, and a base fetched from the wrong remote is worse
# still. The fetch is on by default and prunes, so remote-tracking refs for
# branches deleted on the forge disappear rather than being reported as live.
if [[ "$DO_FETCH" == "true" ]]; then
  if git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
    log_info "fetching $REMOTE_NAME (use --no-fetch to skip)"
    git fetch --quiet --prune "$REMOTE_NAME" || log_warn "fetch failed; continuing with what is already local"
  else
    log_warn "no remote named $REMOTE_NAME; continuing with local refs only"
  fi
fi

if [[ -z "$BASE" ]]; then
  BASE="$(git_branches_default_branch "$REMOTE_NAME")" || {
    log_error "could not determine the base branch; pass --base <branch>"
    exit 1
  }
fi

# Reduce the base to a plain branch name before anything compares against it.
#
# `--base` is a human-facing flag and people pass what they see: `main`,
# `origin/main`, `refs/heads/main`, `refs/remotes/origin/main`. All four mean
# the same branch, but the guard that keeps the base alive compares branch
# names -- so an un-normalised `origin/main` matches no local branch, the base
# stops being recognised as the base, and it classifies as merged against
# itself. That is the bug this guard exists to prevent, arriving through the
# flag instead.
#
# Every configured remote is stripped, not just the selected one, because
# `--base upstream/main` is a reasonable thing to type.
BASE="${BASE#refs/heads/}"
BASE="${BASE#refs/remotes/}"
while IFS= read -r _remote; do
  [[ -n "$_remote" ]] || continue
  BASE="${BASE#"${_remote}/"}"
done < <(git remote 2>/dev/null)

# Compare against the remote's copy of the base when there is one. The local
# copy can be behind by exactly the merge that makes a branch disposable, and
# then nothing is ever prunable.
BASE_REF="$BASE"
if git show-ref --verify --quiet "refs/remotes/${REMOTE_NAME}/${BASE}"; then
  BASE_REF="${REMOTE_NAME}/${BASE}"
fi
git rev-parse --verify --quiet "$BASE_REF" >/dev/null || {
  log_error "base branch not found: $BASE_REF"
  exit 1
}

CURRENT="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"

log_info "base: $BASE_REF"
[[ "$APPLY" == "true" ]] || log_info "dry run — nothing will be deleted. Add --apply to act."
printf '\n%-42s %-10s %s\n' "BRANCH" "STATE" "VERDICT"
printf -- '%s\n' "----------------------------------------------------------------------------"

deletable_local=()
deletable_remote=()
kept=0

# Decide one branch: print its row, and return 0 only when it is disposable.
# The caller collects on that return code, so the row a person reads and the
# list the script acts on come from the same decision and cannot disagree.
classify_row() {
  local branch="$1" scope="$2" ref="$3" state reason worktree

  # The base first, before anything else and for both scopes.
  #
  # Every branch is an ancestor of itself, so the base classifies as `merged`
  # against itself and a pruner that forgets this deletes it. The protected
  # names below do not save a repository whose base is called `staging` or
  # `trunk-2`, and neither does the current-branch check, because the base is
  # usually not the branch you are standing on when you prune.
  if [[ "$branch" == "$BASE" ]]; then
    printf '%-42s %-10s %s\n' "$branch" "-" "keep: this is the base branch"
    return 1
  fi

  if git_branches_is_protected "$branch" ${KEEP[@]+"${KEEP[@]}"}; then
    printf '%-42s %-10s %s\n' "$branch" "-" "keep: protected name"
    return 1
  fi
  if [[ "$scope" == "local" && "$branch" == "$CURRENT" ]]; then
    printf '%-42s %-10s %s\n' "$branch" "-" "keep: checked out here"
    return 1
  fi
  if [[ "$scope" == "local" ]]; then
    worktree="$(git_branches_worktree_of "$branch")"
    if [[ -n "$worktree" ]]; then
      printf '%-42s %-10s %s\n' "$branch" "-" "keep: checked out in $worktree"
      return 1
    fi
    if git_branches_has_unpushed "$branch"; then
      printf '%-42s %-10s %s\n' "$branch" "-" "keep: commits its upstream does not have"
      return 1
    fi
  fi

  state="$(git_branches_merge_state "$BASE_REF" "$ref")"
  case "$state" in
    merged)   reason="delete: merged" ;;
    squashed) reason="delete: squash-merged (content already in base)" ;;
    unmerged) reason="keep: carries work the base does not have" ;;
    unrelated) reason="keep: shares no history with the base" ;;
    unknown)  reason="keep: could not determine whether it landed" ;;
    *)        reason="keep: could not classify" ;;
  esac
  printf '%-42s %-10s %s\n' "$branch" "$state" "$reason"
  [[ "$state" == "merged" || "$state" == "squashed" ]] || return 1
  return 0
}

while IFS= read -r branch; do
  [[ -n "$branch" ]] || continue
  if classify_row "$branch" local "refs/heads/$branch"; then
    deletable_local+=("$branch")
  else
    kept=$((kept + 1))
  fi
done < <(git for-each-ref --format='%(refname:short)' refs/heads/ | sort)

if [[ "$DO_REMOTE" == "true" ]]; then
  printf '\n'
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    branch="${ref#"${REMOTE_NAME}/"}"
    [[ "$branch" == "HEAD" ]] && continue
    if classify_row "$branch" remote "refs/remotes/$ref"; then
      deletable_remote+=("$branch")
    else
      kept=$((kept + 1))
    fi
  done < <(git for-each-ref --format='%(refname:short)' "refs/remotes/${REMOTE_NAME}/" | sort)
fi

printf '\n'
log_info "${#deletable_local[@]} local, ${#deletable_remote[@]} remote deletable; $kept kept"

if [[ "$APPLY" != "true" ]]; then
  [[ ${#deletable_local[@]} -gt 0 || ${#deletable_remote[@]} -gt 0 ]] \
    && log_info "re-run with --apply to delete them"
  exit 0
fi

status=0
for branch in ${deletable_local[@]+"${deletable_local[@]}"}; do
  # -D, not -d: -d applies git's own ancestor test, which by design rejects
  # every squash-merged branch this script exists to find. The safety is the
  # classification above, and it is stricter than -d rather than looser.
  if git branch -D "$branch" >/dev/null 2>&1; then
    log_info "deleted local $branch"
  else
    log_error "could not delete local $branch"
    status=1
  fi
done

for branch in ${deletable_remote[@]+"${deletable_remote[@]}"}; do
  if git push --quiet "$REMOTE_NAME" --delete "$branch" 2>/dev/null; then
    log_info "deleted ${REMOTE_NAME}/$branch"
  else
    log_error "could not delete ${REMOTE_NAME}/$branch"
    status=1
  fi
done

exit "$status"
