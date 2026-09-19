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
#   unknown    the squash probe could not be built, or `git cherry` matched
#              the patch but the byte-exact confirmation did not (or could not
#              run), so the question was not answered. Deliberately distinct
#              from `unmerged`: both keep the branch, but only one of them
#              means "I checked and base lacks this work".
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

  if ! printf '%s\n' "$cherry" | grep -q '^-'; then
    printf 'unmerged\n'; return 0
  fi

  # `git cherry` said the patch is upstream, but its patch-ids ignore
  # whitespace. A branch that landed and then received a whitespace-only commit
  # -- a re-indent, which in Python or YAML changes what the code does -- still
  # matches, and would be deleted with that commit on it. Confirm the match
  # byte for byte before calling it squashed.
  #
  # A cherry match the byte-exact check cannot confirm is `unknown`, not
  # `unmerged`: the patch is upstream give or take whitespace, so "carries work
  # the base does not have" would overstate what was checked.
  if _git_branches__verbatim_match "$base" "$mb" "$synth"; then
    printf 'squashed\n'
  else
    printf 'unknown\n'
  fi
}

# Succeed when the probe commit's patch, compared byte for byte, equals the
# patch of a non-merge commit on base since the merge base. Fail when it does
# not, or when the comparison cannot be made.
#
# Only base commits touching the probe's paths are diffed: a commit with an
# identical patch necessarily touches exactly those paths, so the limit cannot
# lose a match, and it keeps a repository with a long, binary-heavy base from
# diffing every commit on it. `--full-history` so a side branch merged back
# with a TREESAME merge is not simplified away. The names come from `-z`
# listing and are passed as literal pathspecs, so a name with a space, a
# newline or pathspec magic characters is matched as itself; a probe touching
# very many paths is compared against the unlimited list instead of risking
# the argument-length limit.
#
# Plumbing on both sides with the same flags, so diff configuration cannot make
# the two patches differ. `--full-index` puts full blob ids in the patch, which
# is what tells two different binary changes to the same path apart; no
# `--binary`, which would inline every binary blob on base into the pipe.
_git_branches__verbatim_match() {
  local base="$1" mb="$2" synth="$3" path n=0
  local -a paths
  paths=()

  while IFS= read -r -d '' path; do
    paths[n]="$path"
    n=$((n + 1))
  done < <(git diff-tree -r -z --name-only --no-commit-id "$synth" 2>/dev/null)
  # Beyond this many paths skip the limit rather than risk the argument limit.
  if (( n > 1000 )); then n=0; paths=(); fi

  if git patch-id --verbatim </dev/null >/dev/null 2>&1; then
    _git_branches__patch_id_match "$base" "$mb" "$synth" "$n" ${paths[@]+"${paths[@]}"}
  else
    _git_branches__diff_hash_match "$base" "$mb" "$synth" "$n" ${paths[@]+"${paths[@]}"}
  fi
}

# Print the non-merge commits on base since the merge base that touch the given
# paths (all of them when no path is given).
_git_branches__candidates() {
  local base="$1" mb="$2" n="$3"; shift 3
  if (( n > 0 )); then
    git --literal-pathspecs rev-list --no-merges --full-history "${mb}..${base}" -- "$@"
  else
    git rev-list --no-merges "${mb}..${base}"
  fi
}

# git 2.39+: compare `git patch-id --verbatim` ids.
_git_branches__patch_id_match() {
  local base="$1" mb="$2" synth="$3" n="$4" want ids
  shift 4

  want="$(git diff-tree -p --full-index "$synth" 2>/dev/null | git patch-id --verbatim 2>/dev/null)" || return 1
  want="${want%% *}"
  [[ -n "$want" ]] || return 1

  ids="$(_git_branches__candidates "$base" "$mb" "$n" "$@" 2>/dev/null \
         | git diff-tree -p --full-index --stdin 2>/dev/null \
         | git patch-id --verbatim 2>/dev/null)" || return 1

  printf '%s\n' "$ids" | awk -v want="$want" '$1 == want { found = 1 } END { exit !found }'
}

# Older git: no `patch-id --verbatim`, so hash each patch after removing what a
# verbatim patch-id ignores -- the leading commit id line, hunk header line
# numbers and function context, and the `index` line of a text change (a
# landed change whose file differs elsewhere has other blob ids but the same
# patch). A binary change has no patch text, so its `index` line, which holds
# the blob ids, is kept for it.
_git_branches__diff_hash_match() {
  local base="$1" mb="$2" synth="$3" n="$4" want commit got list
  shift 4

  want="$(_git_branches__normalised_patch "$synth" | git hash-object --stdin 2>/dev/null)" || return 1
  [[ -n "$want" ]] || return 1

  list="$(_git_branches__candidates "$base" "$mb" "$n" "$@" 2>/dev/null)" || return 1
  for commit in $list; do
    got="$(_git_branches__normalised_patch "$commit" | git hash-object --stdin 2>/dev/null)" || return 1
    [[ "$got" == "$want" ]] && return 0
  done
  return 1
}

_git_branches__normalised_patch() {
  git diff-tree -p --full-index "$1" 2>/dev/null | awk '
    NR == 1                              { next }
    /^index /                            { idx = $0; next }
    /^Binary files /                     { print idx; print; next }
    /^GIT binary patch/                  { print idx; print; next }
    /^@@ -[0-9,]* [+][0-9,]* @@/          { print "@@"; next }
                                         { print }
  '
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
