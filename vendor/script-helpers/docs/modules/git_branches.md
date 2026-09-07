# git_branches

Decide, safely, whether a branch has already landed and can be removed.

Import with `shlib_import git_branches`. The entry point built on it is
[`scripts/prune_branches.sh`](../../scripts/prune_branches.sh), which is
callable from any repository that vendors these helpers:

```bash
bash scripts/script-helpers/scripts/prune_branches.sh            # report
bash scripts/script-helpers/scripts/prune_branches.sh --apply    # act
bash scripts/script-helpers/scripts/prune_branches.sh --remote --apply
```

## Why not `git branch --merged`

`--merged` asks whether the branch tip is an *ancestor* of the base. That is
true after a merge commit and false after every squash merge and every rebase
merge, which is how most forges land a pull request by default. A repository
that squash-merges accumulates branches `--merged` will never list, so people
delete by hand, and deleting by hand is how the wrong one goes.

The opposite mistake is the costly one. A branch whose work landed and which
then received **new commits** still has something to lose, and a check that
only asks "are these changes in the base?" removes it. That is not a
hypothetical: pushing to a branch whose pull request has already merged
succeeds silently, and the commit then sits where no pull request will pick it
up.

Both tests here look at the branch tip **as it stands now**, so a commit added
after the merge changes the tip, changes the tree, and fails both tests. The
protection falls out of the check rather than being a separate rule.

## Functions

### `git_branches_default_branch [remote]`

Print the branch other work merges into. Consults the remote's own `HEAD`
first, then falls back to the names `main`, `master`, `trunk`, `develop`.

- **Returns** 0 and the name; 1 and nothing when it cannot tell.
- Callers must treat 1 as *refuse to act*. Guessing the base wrong is how a
  pruner deletes unmerged work.

### `git_branches_merge_state <base> <branch>`

Print exactly one of:

| Word | Meaning |
|---|---|
| `merged` | The tip is an ancestor of the base — an ordinary merge. |
| `squashed` | The tip is not an ancestor, but the branch's cumulative change is already in the base — a squash merge, a rebase merge or a cherry-pick. |
| `unmerged` | The branch carries work the base does not have. |
| `unrelated` | The two share no history. |
| `unknown` | The squash probe could not be built, so the question was not answered. Distinct from `unmerged` on purpose: both keep the branch, but only one means "I checked". |

- **Returns** 2 on missing arguments.
- The probe commit carries its own throwaway identity. `git commit-tree`
  refuses to run without an author and a committer, and an environment with no
  git identity — CI, a fresh container, a cron user — is exactly where this
  runs unattended. Without it the probe fails, the error is swallowed, and
  every squash-merged branch comes back `unmerged`: the check stops working
  while still printing a confident answer.
- The squash test builds a throwaway commit carrying the branch's tree on top
  of the merge base — exactly the commit a squash merge would produce — and
  asks `git cherry` whether an equivalent patch is upstream. `git cherry`
  compares patch-ids, so it sees through a different sha, author, date or
  message. The probe commit is dangling and is garbage-collected.
- A branch whose tree already equals the base's tree is reported `squashed`
  before that test runs: an empty diff has no patch-id to match and would
  otherwise be misreported as `unmerged`.

### `git_branches_has_unpushed <branch>`

True when the branch holds commits its upstream does not. A branch with **no**
upstream returns false — never having been pushed is not the same as having
unpushed work, and the merge state decides whether it is disposable.

### `git_branches_worktree_of <branch>`

Print the worktree path a branch is checked out in, or nothing. git refuses to
delete such a branch anyway; knowing first turns an error mid-run into a
skipped row with a reason.

### `git_branches_is_protected <branch> [extra-pattern...]`

True for `main`, `master`, `trunk`, `develop`, `production`, `release/*`,
`hotfix/*`, and any extra glob passed in. `release/*` is protected because in
this fleet those branches are what release tags are cut from.

## `--base` spellings

`--base` accepts `main`, `origin/main`, `refs/heads/main` and
`refs/remotes/origin/main`, and reduces all of them to a bare branch name
before anything compares against it. That normalisation is load-bearing rather
than a convenience: the guard that keeps the base alive compares branch names,
so an un-normalised `origin/main` matches no local branch, the base stops being
recognised as the base, and it is deleted as merged against itself. Every
configured remote is stripped, not only the selected one, because
`--base upstream/main` is a reasonable thing to type.

## What `prune_branches.sh` never touches

The base branch, the branch checked out here, a branch checked out in another
worktree, any protected name, and any branch holding commits its upstream does
not have.

It is a **dry run by default**; `--apply` is required to delete anything, and
`--remote` is required before a remote branch is considered at all. It fetches
with `--prune` first unless told not to, because a stale base makes landed work
look unmerged.

It deletes with `git branch -D` rather than `-d` on purpose: `-d` applies
git's own ancestor test, which by design rejects every squash-merged branch
this exists to find. The safety is the classification, and it is stricter than
`-d` rather than looser.
