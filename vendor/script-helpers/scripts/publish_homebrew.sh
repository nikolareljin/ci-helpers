#!/usr/bin/env bash
# SCRIPT: publish_homebrew.sh
# DESCRIPTION: Publish a Homebrew formula to a tap repository.
# USAGE: ./publish_homebrew.sh [--repo PATH] [--formula PATH] [--name NAME] [--tap-repo OWNER/REPO] [--tap-token TOKEN] [--tap-branch BRANCH] [--tap-dir DIR] [--commit-message MESSAGE]
# EXAMPLE: ./publish_homebrew.sh --formula packaging/brew/myapp.rb --tap-repo owner/homebrew-example
# PARAMETERS:
#   --repo <path>            Repo path (default: GITHUB_WORKSPACE or cwd).
#   --formula <path>         Formula path (default: packaging/brew/<name>.rb).
#   --name <name>            Formula name (default: inferred from formula path).
#   --tap-repo <owner/repo>  GitHub tap repository (default: HOMEBREW_TAP_REPO).
#   --tap-token <token>      GitHub token (default: HOMEBREW_TAP_TOKEN). Prefer
#                            the HOMEBREW_TAP_TOKEN env var: a command-line
#                            token is visible to other users in `ps`.
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

# The token must not reach an xtrace log. Tracing is paused from here -- the
# token is read, parsed and checked below -- until the auth header is built,
# then restored to whatever the caller had.
xtrace_was_on=0
case "$-" in *x*) xtrace_was_on=1;; esac
set +x

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
# Guarded: a subshell inherits an EXIT trap, and bash runs it there when the
# subshell is signalled -- so this could tear down the caller's stack, or
# delete a directory, while the run is still using it. ${BASHPID-$$} rather
# than $BASHPID alone: bash 3.2, which macOS ships, does not define BASHPID,
# and $$ is the top-level shell's pid in every subshell, so the comparison
# degrades to always-true there rather than to always-false.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp_dir"; fi' EXIT

# The token must not reach argv (visible in ps) or the tap clone's .git/config.
# The clone URL therefore carries no credential -- so origin in .git/config
# carries none either -- and the token travels as an HTTP auth header in git's
# environment config, the way actions/checkout passes it.
# git >= 2.31 reads that from the documented GIT_CONFIG_COUNT variables; older
# git only from GIT_CONFIG_PARAMETERS, the variable `git -c` itself uses.
#
# extraheader is multi-valued: a header the caller already configured (global
# gitconfig, GIT_CONFIG_COUNT or GIT_CONFIG_PARAMETERS, as actions/checkout
# leaves behind) would be sent as a second Authorization header, which GitHub
# rejects. An empty value resets the list, so the reset goes in first and the
# header straight after it. git reads GIT_CONFIG_PARAMETERS after the
# GIT_CONFIG_COUNT entries, so when the caller has set it the pair must go
# there to come last.
git_env_config_supported() {
  local v major minor
  v="$(git --version 2>/dev/null | awk '{print $3}')"
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  (( major > 2 || (major == 2 && minor >= 31) ))
}
auth_key="http.https://github.com/.extraheader"
auth_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$tap_token" | base64 | tr -d '\n')"
if git_env_config_supported && [[ -z "${GIT_CONFIG_PARAMETERS:-}" ]]; then
  cfg_idx="${GIT_CONFIG_COUNT:-0}"
  export "GIT_CONFIG_KEY_${cfg_idx}=${auth_key}"
  export "GIT_CONFIG_VALUE_${cfg_idx}="
  export "GIT_CONFIG_KEY_$((cfg_idx + 1))=${auth_key}"
  export "GIT_CONFIG_VALUE_$((cfg_idx + 1))=${auth_header}"
  export GIT_CONFIG_COUNT=$((cfg_idx + 2))
else
  export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:+${GIT_CONFIG_PARAMETERS} }'${auth_key}=' '${auth_key}=${auth_header}'"
fi
unset auth_header tap_token
if [[ "$xtrace_was_on" -eq 1 ]]; then set -x; fi

git clone "https://github.com/${tap_repo}.git" "$tmp_dir"

mkdir -p "$tmp_dir/$tap_dir"
cp "$formula_path" "$tmp_dir/$tap_dir/${formula_name}.rb"

cd "$tmp_dir"
git config user.name "ci-bot"
git config user.email "ci-bot@users.noreply.github.com"

# Stage first: a formula published for the first time is an untracked file,
# which a plain `git diff` never sees, so the tap looked "up to date" and the
# first publish silently never happened.
git add "$tap_dir/${formula_name}.rb"
if git diff --cached --quiet; then
  log_info "Homebrew tap already up to date."
  exit 0
fi

git commit -m "$commit_message"
git push origin "HEAD:${tap_branch}"
