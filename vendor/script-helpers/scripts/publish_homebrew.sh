#!/usr/bin/env bash
# SCRIPT: publish_homebrew.sh
# DESCRIPTION: Publish a Homebrew formula to a tap repository.
# USAGE: ./publish_homebrew.sh [--repo PATH] [--formula PATH] [--name NAME] [--tap-repo OWNER/REPO] [--tap-token TOKEN] [--tap-branch BRANCH] [--tap-dir DIR] [--commit-message MESSAGE]
# EXAMPLE: ./publish_homebrew.sh --formula packaging/brew/myapp.rb --tap-repo owner/homebrew-tap
# PARAMETERS:
#   --repo <path>            Repo path (default: GITHUB_WORKSPACE or cwd).
#   --formula <path>         Formula path (default: packaging/brew/<name>.rb).
#   --name <name>            Formula name (default: inferred from formula path).
#   --tap-repo <owner/repo>  GitHub tap repository (default: HOMEBREW_TAP_REPO).
#   --tap-token <token>      GitHub token (default: HOMEBREW_TAP_TOKEN).
#   --tap-branch <branch>    Tap branch (default: HOMEBREW_TAP_BRANCH or main).
#   --tap-dir <dir>          Destination directory in tap (default: Formula).
#   --commit-message <msg>   Commit message (default: "Update <name> formula").
#   -h, --help               Show help.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { display_help; }

repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
formula_path=""
formula_name=""
tap_repo="${HOMEBREW_TAP_REPO:-}"
tap_token="${HOMEBREW_TAP_TOKEN:-}"
tap_branch="${HOMEBREW_TAP_BRANCH:-main}"
tap_dir="Formula"
commit_message=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo_dir="$2"; shift 2;;
    --formula) formula_path="$2"; shift 2;;
    --name) formula_name="$2"; shift 2;;
    --tap-repo) tap_repo="$2"; shift 2;;
    --tap-token) tap_token="$2"; shift 2;;
    --tap-branch) tap_branch="$2"; shift 2;;
    --tap-dir) tap_dir="$2"; shift 2;;
    --commit-message) commit_message="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) log_error "Unknown argument: $1"; usage; exit 2;;
  esac
done

if [[ -z "$formula_path" ]]; then
  if [[ -n "$formula_name" ]]; then
    if [[ -f "$repo_dir/packaging/brew/${formula_name}.rb" ]]; then
      formula_path="$repo_dir/packaging/brew/${formula_name}.rb"
    else
      formula_path="$repo_dir/packaging/homebrew/${formula_name}.rb"
    fi
  else
    formula_path="$(find "$repo_dir/packaging/brew" -maxdepth 1 -type f -name '*.rb' 2>/dev/null | head -n 1 || true)"
    if [[ -z "$formula_path" ]]; then
      formula_path="$(find "$repo_dir/packaging/homebrew" -maxdepth 1 -type f -name '*.rb' 2>/dev/null | head -n 1 || true)"
    fi
  fi
fi

if [[ -z "$formula_name" && -n "$formula_path" ]]; then
  formula_name="$(basename "$formula_path" .rb)"
fi

if [[ -z "$formula_path" || ! -f "$formula_path" ]]; then
  log_error "Formula not found: $formula_path"
  exit 2
fi

if [[ -z "$tap_repo" || -z "$tap_token" ]]; then
  log_warn "Homebrew publish skipped (HOMEBREW_TAP_REPO or HOMEBREW_TAP_TOKEN not set)."
  exit 0
fi

if [[ -z "$commit_message" ]]; then
  commit_message="Update ${formula_name:-formula} formula"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

set +x
git clone "https://x-access-token:${tap_token}@github.com/${tap_repo}.git" "$tmp_dir"
set -x

mkdir -p "$tmp_dir/$tap_dir"
cp "$formula_path" "$tmp_dir/$tap_dir/${formula_name}.rb"

cd "$tmp_dir"
git config user.name "ci-bot"
git config user.email "ci-bot@users.noreply.github.com"

if git diff --quiet; then
  log_info "Homebrew tap already up to date."
  exit 0
fi

git add "$tap_dir/${formula_name}.rb"
git commit -m "$commit_message"
git push origin "HEAD:${tap_branch}"
