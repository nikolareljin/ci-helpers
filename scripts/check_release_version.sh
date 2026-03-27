#!/usr/bin/env bash
# SCRIPT: check_release_version.sh
# DESCRIPTION: Ensure VERSION matches release/[v]X.Y.Z[-rcN] or release/[v]X.Y.Z[-rc.N] branch names.
# USAGE: ./check_release_version.sh [--branch <branch>] [--repo <path>] [--version-file <path>] [--print-version]
# EXAMPLE: ./check_release_version.sh --branch release/1.2.3-rc.1 --repo .
# PARAMETERS:
#   --branch <branch>      Release branch to validate (default: current branch if detectable).
#   --repo <path>          Repository path or subdirectory inside the repo (default: GITHUB_WORKSPACE or cwd).
#   --version-file <path>  Path to VERSION file (default: <repo-root>/VERSION).
#   --print-version        Print the inferred release version to stdout.
#   -h, --help             Show this help message.
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

branch=""
repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
version_file=""
print_version=false
release_branch_pattern='^release\/v?([0-9]+\.[0-9]+\.[0-9]+(-rc\.?[0-9]+)?)$'

require_arg_value() {
  local option="$1"
  local value="${2-}"

  if [[ -z "$value" || "$value" == --* ]]; then
    log_error_safe "Missing value for $option"
    usage
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      require_arg_value "$1" "${2-}"
      branch="$2"
      shift 2
      ;;
    --repo)
      require_arg_value "$1" "${2-}"
      repo_dir="$2"
      shift 2
      ;;
    --version-file)
      require_arg_value "$1" "${2-}"
      version_file="$2"
      shift 2
      ;;
    --print-version) print_version=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error_safe "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

if repo_root="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)"; then
  repo_dir="$repo_root"
fi

if [[ -z "$branch" ]]; then
  branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
fi
if [[ -z "$branch" ]]; then
  branch="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
fi
if [[ -z "$branch" ]]; then
  log_info_safe "Skipping VERSION check: branch not provided and could not be determined (possibly detached HEAD)"
  exit 0
fi

if [[ ! "$branch" =~ $release_branch_pattern ]]; then
  log_info_safe "Skipping VERSION check: '$branch' is not a release branch"
  exit 0
fi

expected_version="${BASH_REMATCH[1]}"
if [[ -z "$version_file" ]]; then
  version_file="$repo_dir/VERSION"
fi
if [[ ! -f "$version_file" ]]; then
  log_error_safe "VERSION file not found at $version_file"
  exit 1
fi

IFS= read -r actual_version < "$version_file" || actual_version=""
actual_version="${actual_version//$'\r'/}"
actual_version="$(printf '%s' "$actual_version" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ "$actual_version" != "$expected_version" ]]; then
  log_error_safe "VERSION mismatch for $branch: expected '$expected_version', found '$actual_version'"
  exit 1
fi

log_info_safe "VERSION matches release branch $branch -> $expected_version"
if $print_version; then
  echo "$expected_version"
fi
