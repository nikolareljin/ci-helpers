#!/usr/bin/env bash
# Locate and load script-helpers.
#
# This file is COPIED into a consumer repo, not sourced from the library,
# because finding the library is the thing it does. Everything else in
# templates/dev-cli/ can be replaced by a submodule update; this cannot.
#
# It replaces roughly 700 lines of five mutually incompatible load_helpers()
# implementations across the fleet. Do not add repo-specific logic here — put
# that in scripts/project.sh, which cli.sh sources if it exists.
#
# Sourced, not executed. Callers set strict mode themselves.

# Repo root, resolving symlinks so a root-level symlink shim still works.
_dev_self="${BASH_SOURCE[0]}"
while [[ -L "$_dev_self" ]]; do
  _dev_link="$(readlink "$_dev_self")"
  [[ "$_dev_link" == /* ]] && _dev_self="$_dev_link" || _dev_self="$(dirname "$_dev_self")/$_dev_link"
done
DEV_SCRIPT_DIR="$(cd "$(dirname "$_dev_self")" && pwd)"
# Written out rather than as `git ... || cd .. && pwd`: that parses as
# `(git || cd) && pwd`, which emits the git output AND the pwd output, and the
# variable ends up holding two lines.
DEV_REPO_ROOT="$(git -C "$DEV_SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$DEV_REPO_ROOT" ]]; then
  DEV_REPO_ROOT="$(cd "$DEV_SCRIPT_DIR/.." && pwd)"
fi
unset _dev_self _dev_link

# The canonical path is scripts/script-helpers. The others are the layouts that
# exist in the fleet today and are being migrated away from; they stay here so a
# repo mid-migration is not broken by the order of its PRs.
_dev_helper_candidates=(
  "$DEV_REPO_ROOT/scripts/script-helpers"
  "$DEV_REPO_ROOT/vendor/script-helpers"
  "$DEV_REPO_ROOT/script-helpers"
  "$DEV_REPO_ROOT/scripts/helpers"
  "$DEV_REPO_ROOT/tools/script-helpers"
  "$DEV_REPO_ROOT/.script-helpers"
  "$DEV_REPO_ROOT/externals/script-helpers"
)

dev_find_helpers() {
  local candidate
  [[ -n "${SCRIPT_HELPERS_DIR:-}" && -f "${SCRIPT_HELPERS_DIR}/helpers.sh" ]] && {
    printf '%s\n' "$SCRIPT_HELPERS_DIR"; return 0
  }
  for candidate in "${_dev_helper_candidates[@]}"; do
    [[ -f "$candidate/helpers.sh" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

# Self-heal an uninitialized submodule. A fresh `git clone` without --recursive
# leaves the directory present but empty, which is the single most common
# "nothing works" report in this fleet.
dev_init_helpers() {
  local candidate
  for candidate in "${_dev_helper_candidates[@]}"; do
    [[ -d "$candidate" ]] || continue
    echo "[dev] initializing script-helpers submodule at ${candidate#"$DEV_REPO_ROOT"/}" >&2
    git -C "$DEV_REPO_ROOT" submodule update --init --recursive \
      "${candidate#"$DEV_REPO_ROOT"/}" >&2 && return 0
  done
  return 1
}

if ! SCRIPT_HELPERS_DIR="$(dev_find_helpers)"; then
  dev_init_helpers || true
  if ! SCRIPT_HELPERS_DIR="$(dev_find_helpers)"; then
    cat >&2 <<'EOF'
[dev] script-helpers not found.

Expected it at scripts/script-helpers. Fix with:

  git submodule update --init --recursive

If this repo has never had the submodule:

  git submodule add -b production \
    https://github.com/nikolareljin/script-helpers.git scripts/script-helpers
EOF
    # Sourced normally, but exit covers the case where a caller runs it directly.
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
  fi
fi

export SCRIPT_HELPERS_DIR
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
