#!/usr/bin/env bash
# SCRIPT: setup-hooks.sh
# DESCRIPTION: Configure git to use shared or repository-local hook scripts.
# USAGE: bash scripts/setup-hooks.sh
# PARAMETERS:
#   No command-line parameters.
#   Hook directory priority:
#     1. .githooks/  (repo-local overrides with both pre-commit and pre-push)
#     2. git-hooks/ next to this script: the hooks bundled with this copy of
#        script-helpers, wherever it is vendored (scripts/script-helpers,
#        vendor/script-helpers, ...) or script-helpers' own scripts/git-hooks
#     3. scripts/script-helpers/scripts/git-hooks/, then scripts/git-hooks/
#   The shared pre-push hands over to .githooks/pre-push when a repository has
#   one (for example the protected-refs guard), so a repository with only
#   .githooks/pre-push gets the shared hooks and still runs its own.
# ----------------------------------------------------
# After running, hooks are active for all subsequent git operations in this repo.
set -euo pipefail

# This script's directory, both as the caller reached it and physically. Taken
# before the cd below: a relative path in BASH_SOURCE is relative to the
# caller's cwd.
script_dir_logical="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "[setup-hooks] ERROR: Run this script inside a Git worktree." >&2
  exit 1
fi
# The top as the caller sees it, symlinks kept: a vendored copy that is a symlink
# to a checkout elsewhere is inside the repository only in this view.
repo_root_logical="$(cd "./$(git rev-parse --show-cdup)" && pwd)"
cd "$repo_root"
repo_root="$(pwd -P)"

# bundled_under <script dir> <repository top>: the hooks next to this script as a
# repo-relative path, when that directory is inside the repository.
bundled_under() {
  if [[ "$1" == "$2"/* ]] && has_required_hooks "$1/git-hooks"; then
    echo "${1#"$2"/}/git-hooks"
  fi
}

# The bundled hooks next to this script, as a repo-relative path, or nothing:
# first as the caller reached them, then physically.
bundled_hooks() {
  local found
  found="$(bundled_under "$script_dir_logical" "$repo_root_logical")"
  [[ -n "$found" ]] || found="$(bundled_under "$script_dir" "$repo_root")"
  [[ -z "$found" ]] || echo "$found"
}

has_required_hooks() {
  local dir="$1"
  [[ -f "$dir/pre-commit" ]] && [[ -f "$dir/pre-push" ]]
}

resolve_hooks_dir() {
  # Returns a repo-relative path for git config storage; uses absolute paths for existence checks.
  if has_required_hooks "$repo_root/.githooks"; then
    echo ".githooks"
  elif [[ -n "$(bundled_hooks)" ]]; then
    bundled_hooks
  elif has_required_hooks "$repo_root/scripts/script-helpers/scripts/git-hooks"; then
    echo "scripts/script-helpers/scripts/git-hooks"
  elif has_required_hooks "$repo_root/scripts/git-hooks"; then
    echo "scripts/git-hooks"
  else
    echo ""
  fi
}

hooks_dir="$(resolve_hooks_dir)"   # relative — portable across clones
hooks_dir_abs="$repo_root/$hooks_dir"

if [[ -z "$hooks_dir" ]]; then
  echo "[setup-hooks] ERROR: No hooks directory found. Looked for pre-commit and pre-push in:" >&2
  echo "  .githooks/" >&2
  echo "  ${script_dir_logical}/git-hooks/  (next to this script)" >&2
  echo "  scripts/script-helpers/scripts/git-hooks/" >&2
  echo "  scripts/git-hooks/" >&2
  exit 1
fi

# Make all hook files executable
while IFS= read -r -d '' hook; do
  chmod +x "$hook"
done < <(find "$hooks_dir_abs" -maxdepth 1 -type f -print0)

git config core.hooksPath "$hooks_dir"
echo "[setup-hooks] core.hooksPath = $hooks_dir"
echo "[setup-hooks] Done. Hooks active for this repo."
