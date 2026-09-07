#!/usr/bin/env bash
# MODULE: git_branches.sh
# DESCRIPTION: Decide, safely, whether a branch has already landed and can go.
#
# The question "is this branch merged?" has two answers, and `git branch
# --merged` only knows one of them. It tests whether the branch tip is an
# ancestor of the base, which is true for a merge commit and false for every
# squash merge and every rebase merge -- the default on most forges. A repo
# that squash-merges accumulates branches that `--merged` will never list.
#
# The opposite mistake is worse. A branch whose work landed and which then
# received NEW commits is not disposable, and a check that only asks "are these
# changes in main?" will happily delete it. That case is not hypothetical: it
# is what happens when someone pushes to a branch after its pull request was
# merged, which is silent -- the push succeeds and nothing says the pull
# request closed hours ago.
#
# Both tests here are therefore about the branch tip as it stands now, so a
# commit added after the merge makes the branch un-deletable again by
# construction rather than by a separate rule someone has to remember.

# Resolve the branch other work is merged into.
#
# Order matters: the remote's own HEAD is authoritative and survives a repo
# whose default branch is neither main nor master. The name guesses are a
# fallback for a clone that never fetched HEAD, not the primary answer.
#
# Returns 1 and prints nothing when no base can be determined. Callers must
# treat that as "refuse to act", never as "assume main" -- guessing the base
# wrong is how this module would delete unmerged work.
git_branches_default_branch() {
  local remote="${1:-origin}" ref name

  ref="$(git symbolic-ref --quiet "refs/remotes/${remote}/HEAD" 2>/dev/null || true)"
  if [[ -n "$ref" ]]; then
    printf '%s\n' "${ref#refs/remotes/"${remote}"/}"
    return 0
  fi

  for name in main master trunk develop; do
    if git show-ref --verify --quiet "refs/remotes/${remote}/${name}" \
       || git show-ref --verify --quiet "refs/heads/${name}"; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 1
}

# Classify a branch against a base. Prints exactly one word:
#
#   merged     the tip is an ancestor of base -- an ordinary merge
#   squashed   the tip is not an ancestor, but the branch's cumulative change
#              is already in base -- a squash or rebase merge, or a cherry-pick
#   unmerged   the branch carries work base does not have
#   unrelated  the two share no history at all
#   unknown    the squash probe could not be built, so the question was not
#              answered. Deliberately distinct from `unmerged`: both keep the
#              branch, but only one of them means "I checked".
#
# Returns 2 on bad arguments. Prints to stdout and nothing else, so it can be
# used in a command substitution without a subshell swallowing a diagnostic.
git_branches_merge_state() {
  local base="${1:-}" branch="${2:-}"
  [[ -n "$base" && -n "$branch" ]] || return 2

  local mb
  mb="$(git merge-base "$base" "$branch" 2>/dev/null)" || { printf 'unrelated\n'; return 0; }
  [[ -n "$mb" ]] || { printf 'unrelated\n'; return 0; }

  if git merge-base --is-ancestor "$branch" "$base" 2>/dev/null; then
    printf 'merged\n'; return 0
  fi

  # A branch whose tree already equals the base's tree carries no unique
  # content, whatever its history looks like. Checked before the patch
  # comparison below because an empty diff has no patch-id to match and would
  # otherwise be reported as unmerged.
  if git diff --quiet "$base" "$branch" 2>/dev/null; then
    printf 'squashed\n'; return 0
  fi

  # The squash test. Build a throwaway commit carrying the branch's tree on top
  # of the merge base -- that is exactly the single commit a squash merge would
  # have produced -- and ask git whether an equivalent patch is already
  # upstream. `git cherry` prefixes such a commit with `-` and an absent one
  # with `+`; it compares patch-ids, so it sees through a different sha,
  # author, date or message.
  #
  # The commit is dangling and unreferenced; git will garbage-collect it.
  # The probe carries its own identity.
  #
  # `git commit-tree` refuses to run without an author and a committer, and an
  # environment with no git identity -- CI, a fresh container, a cron user --
  # is exactly where this runs unattended. Without this, the probe fails, the
  # error is swallowed, and every squash-merged branch is reported `unmerged`:
  # the tool silently stops doing the one thing it exists for, while still
  # printing a confident answer.
  #
  # Passed as environment rather than written with `git config`, because the
  # commit is a throwaway that is never referenced and nothing should outlive
  # it. A real identity is never appropriate here -- this object is a probe,
  # not a contribution.
  #
  # A failure now reports `unknown` rather than `unmerged`. Both keep the
  # branch, but only one of them means the question was answered.
  local tree synth
  tree="$(git rev-parse "${branch}^{tree}" 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  synth="$(
    GIT_AUTHOR_NAME='prune-branches probe'  GIT_AUTHOR_EMAIL='probe@localhost' \
    GIT_COMMITTER_NAME='prune-branches probe' GIT_COMMITTER_EMAIL='probe@localhost' \
    git commit-tree "$tree" -p "$mb" -m 'prune-branches probe' 2>/dev/null
  )" || { printf 'unknown\n'; return 0; }
  [[ -n "$synth" ]] || { printf 'unknown\n'; return 0; }

  local cherry
  cherry="$(git cherry "$base" "$synth" 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  [[ -n "$cherry" ]] || { printf 'unknown\n'; return 0; }

  if printf '%s\n' "$cherry" | grep -q '^-'; then
    printf 'squashed\n'
  else
    printf 'unmerged\n'
  fi
}

# True when the branch has commits its upstream does not.
#
# A branch with no upstream returns 1, not 0: never having been pushed is not
# the same as having unpushed work, and the merge state is what decides whether
# such a branch is disposable.
git_branches_has_unpushed() {
  local branch="${1:-}" upstream
  [[ -n "$branch" ]] || return 2
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name "${branch}@{upstream}" 2>/dev/null)" || return 1
  [[ -n "$upstream" ]] || return 1
  # --max-count=1: the question is "are there any", not "how many". A
  # long-lived branch can be thousands of commits ahead, and listing all of
  # them to test a string for emptiness is work nobody asked for.
  [[ -n "$(git rev-list --max-count=1 "${upstream}..${branch}" 2>/dev/null)" ]]
}

# Print the worktree a branch is checked out in, or nothing.
#
# git refuses to delete such a branch anyway, but it refuses with an error in
# the middle of a run. Knowing beforehand turns that into a skipped row with a
# reason.
git_branches_worktree_of() {
  local branch="${1:-}"
  [[ -n "$branch" ]] || return 2
  git worktree list --porcelain 2>/dev/null | awk -v want="refs/heads/${branch}" '
    /^worktree /  { wt = substr($0, 10) }
    /^branch /    { if (substr($0, 8) == want) { print wt; exit } }
  '
}

# True when a branch is protected and must never be deleted.
#
# The defaults are the long-lived names plus release/* and hotfix/*, which in
# this fleet carry the tags a release is cut from -- deleting one loses the
# branch a published tag points into. Extra patterns are passed as further
# arguments and matched with the same shell globbing.
git_branches_is_protected() {
  local branch="${1:-}"; shift || true
  [[ -n "$branch" ]] || return 2
  local pattern
  for pattern in main master trunk develop production 'release/*' 'hotfix/*' "$@"; do
    [[ -n "$pattern" ]] || continue
    # shellcheck disable=SC2053  # the right-hand side is a glob on purpose
    [[ "$branch" == $pattern ]] && return 0
  done
  return 1
}
