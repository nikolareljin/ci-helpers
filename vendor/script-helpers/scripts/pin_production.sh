#!/usr/bin/env bash
# SCRIPT: pin_production.sh
# DESCRIPTION: Point the production branch at a specific tag, forward or (explicitly) backward.
# USAGE: scripts/pin_production.sh <tag> [--allow-rewind] [--remote <name>] [--branch <name>] [--repo <path>] [--dry-run]
# PARAMETERS:
#   <tag>             Release tag to point production at (e.g. 0.10.0).
#   --allow-rewind    Permit moving production to a tag that is NOT ahead of it —
#                     i.e. a rollback, or a move onto a diverged history. Without
#                     this flag such a move is refused rather than attempted.
#   --remote <name>   Remote to read and push (default: origin).
#   --branch <name>   Branch to move (default: production). main, master and HEAD are refused.
#   --repo <path>     Repository to act on (default: the git repository containing the
#                     current directory, NOT the one this script lives in).
#   --dry-run         Report what would change and push nothing.
#   -h, --help        Show this help message.
# EXAMPLE:
#   scripts/pin_production.sh 0.10.0                   # roll forward
#   scripts/pin_production.sh 0.9.0 --allow-rewind     # roll back, deliberately
# ----------------------------------------------------
#
# Why the rewind is a separate flag, and why this verifies the result.
#
# The move used to be `git merge --ff-only "$TAG"`, and rolling back was
# documented as a supported use. It never worked, and it never said so: when
# the target is an ANCESTOR of production, `--ff-only` reports "Already up to
# date" and exits 0. The script then pushed nothing of consequence and printed
# "production now points to tag <tag>". Exit 0, success message, production
# untouched — the operator had to notice on their own that the rollback they
# asked for had not happened.
#
# So: a backward or diverged move is now named (--allow-rewind) rather than
# silently attempted, and the end state is read back from the remote before
# anything claims success.
# ----------------------------------------------------
set -euo pipefail

TAG=""
REMOTE="origin"
BRANCH="production"
REPO_DIR=""
ALLOW_REWIND=false
DRY_RUN=false

# Exit codes: 1 an error, 2 bad arguments, 3 a refused move (the target is not
# ahead and --allow-rewind was not given). 3 is distinct so a wrapper can tell
# "this needs a human decision" from "something is broken".
EXIT_REFUSED=3

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --allow-rewind) ALLOW_REWIND=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --remote|--branch|--repo)
      # Guard the value before shifting: `shift 2` with one argument left
      # returns non-zero, and under `set -e` that ends the script with no
      # output at all -- indistinguishable from a deliberate refusal.
      if [[ $# -lt 2 ]]; then
        echo "Option $1 requires a value." >&2
        exit 2
      fi
      case "$1" in
        --remote) REMOTE="$2" ;;
        --branch) BRANCH="$2" ;;
        --repo)   REPO_DIR="$2" ;;
      esac
      shift 2
      ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$TAG" ]]; then
        echo "Unexpected argument: $1" >&2
        exit 2
      fi
      TAG="$1"; shift
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  usage >&2
  exit 1
fi

case "$BRANCH" in
  main|master|HEAD|"")
    echo "Refusing to move branch '$BRANCH'." >&2
    exit 1
    ;;
esac

if ! command -v git >/dev/null 2>&1; then
  echo "git is required." >&2
  exit 1
fi

# Act on the repository the caller is standing in, not on the one this script
# happens to live in. Consumers vendor script-helpers as a submodule, so
# resolving from the script's own path meant that running the vendored copy
# from a consumer repository targeted script-helpers itself -- which, now that
# --allow-rewind can force-move a branch, would rewind the library's own
# production ref and break every downstream consumer while reporting success.
if [[ -z "$REPO_DIR" ]]; then
  if ! REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    {
      echo "Not inside a git repository, and --repo was not given."
      echo "Run this from the repository whose '$BRANCH' should move, or pass --repo <path>."
    } >&2
    exit 1
  fi
fi

if [[ ! -d "$REPO_DIR/.git" && ! -f "$REPO_DIR/.git" ]]; then
  echo "Not a git repository: $REPO_DIR" >&2
  exit 1
fi
cd "$REPO_DIR"

# Say out loud which repository and remote are about to be touched. The failure
# this guards against is doing the right thing to the wrong repository.
remote_url="$(git remote get-url "$REMOTE" 2>/dev/null || echo '<unknown>')"
echo "Repository: $REPO_DIR"
echo "Remote:     $REMOTE ($remote_url)"

# The working tree is never touched — the move is a refspec push — so a dirty
# tree is no longer a reason to refuse, and the caller is not left standing on
# a checked-out production branch the way the old implementation left them.
git fetch --tags --force "$REMOTE" >/dev/null 2>&1 || {
  echo "Failed to fetch tags from '$REMOTE'." >&2
  exit 1
}
git fetch --force "$REMOTE" "refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH" >/dev/null 2>&1 || true

if ! target="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}")"; then
  echo "Tag not found: $TAG" >&2
  exit 1
fi

# The remote is the authority on where the branch currently is. A stale local
# copy is exactly how a move gets reasoned about against the wrong base.
current="$(git ls-remote "$REMOTE" "refs/heads/$BRANCH" | awk '{print $1}')"

# The ancestry tests below need that commit present locally. The branch fetch
# above is deliberately tolerant (the branch may simply not exist yet), so a
# fetch that failed for some other reason would leave the object missing — and
# `merge-base --is-ancestor` answers "no" to a commit it cannot see, which would
# be reported as a divergence and answered with advice to force the move. Say
# what actually happened instead.
if [[ -n "$current" ]] && ! git cat-file -e "${current}^{commit}" 2>/dev/null; then
  {
    echo "$BRANCH is at $current on '$REMOTE', but that commit is not available locally,"
    echo "so this cannot tell a fast-forward from a rollback. Fetching it failed:"
    echo "  git fetch $REMOTE refs/heads/$BRANCH"
  } >&2
  exit 1
fi

describe_move() {
  echo "  tag              $TAG"
  echo "  target commit    $target"
  echo "  $BRANCH before    ${current:-<does not exist>}"
}

if [[ -z "$current" ]]; then
  kind="create"
elif [[ "$current" == "$target" ]]; then
  echo "$BRANCH already points at $TAG ($target). Nothing to do."
  exit 0
elif git merge-base --is-ancestor "$current" "$target" 2>/dev/null; then
  kind="fast-forward"
elif git merge-base --is-ancestor "$target" "$current" 2>/dev/null; then
  kind="rewind"
else
  kind="diverged"
fi

if [[ "$kind" == "rewind" || "$kind" == "diverged" ]] && [[ "$ALLOW_REWIND" != true ]]; then
  {
    echo "Refusing to move $BRANCH: $TAG is not ahead of it ($kind)."
    describe_move
    echo
    echo "This is the case that used to report success and do nothing."
    echo "If you mean to roll back, say so:"
    echo "  scripts/pin_production.sh $TAG --allow-rewind"
  } >&2
  exit "$EXIT_REFUSED"
fi

echo "Moving $BRANCH to $TAG ($kind)."
describe_move

if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run: nothing pushed."
  exit 0
fi

if [[ "$kind" == "rewind" || "$kind" == "diverged" ]]; then
  # --force-with-lease pinned to the value just read, so a concurrent move by
  # someone else aborts this push rather than being overwritten by it.
  git push --force-with-lease="refs/heads/$BRANCH:$current" \
    "$REMOTE" "$target:refs/heads/$BRANCH"
else
  git push "$REMOTE" "$target:refs/heads/$BRANCH"
fi

# Read it back. `git push` exiting 0 is not by itself evidence that the branch
# is where it was asked to go.
landed="$(git ls-remote "$REMOTE" "refs/heads/$BRANCH" | awk '{print $1}')"
if [[ "$landed" != "$target" ]]; then
  echo "Push reported success but $BRANCH is at ${landed:-<missing>}, not $target." >&2
  exit 1
fi

echo "$BRANCH now points to tag $TAG ($target)."
