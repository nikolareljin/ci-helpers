#!/usr/bin/env bash
# SCRIPT: build_brew_tarball.sh
# DESCRIPTION: Build a Homebrew tarball for a repo.
# USAGE: ./build_brew_tarball.sh --name <name> [--repo PATH] [--version-file FILE] [--dist-dir DIR] [--exclude PATTERN]
# EXAMPLE: ./build_brew_tarball.sh --name isoforge --repo . --exclude dist --exclude .git
# PARAMETERS:
#   --name <name>         Package name (required).
#   --repo <path>         Repo path (default: GITHUB_WORKSPACE or cwd).
#   --version-file <file> Version file (default: VERSION in repo).
#   --dist-dir <dir>      Output directory (default: repo/dist).
#   --exclude <pattern>   Exclude path (repeatable).
#   -h, --help            Show help.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { display_help; }

repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
name=""
version_file=""
dist_dir=""
excludes=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) name="$2"; shift 2;;
    --repo) repo_dir="$2"; shift 2;;
    --version-file) version_file="$2"; shift 2;;
    --dist-dir) dist_dir="$2"; shift 2;;
    --exclude) excludes+=("$2"); shift 2;;
    -h|--help) usage; exit 0;;
    *) log_error "Unknown argument: $1"; usage; exit 2;;
  esac
done

if [[ -z "$name" ]]; then
  log_error "--name is required"
  exit 2
fi

if [[ -z "$version_file" ]]; then
  version_file="$repo_dir/VERSION"
fi
if [[ ! -f "$version_file" ]]; then
  log_error "Version file not found: $version_file"
  exit 2
fi

version="$(cat "$version_file")"
if [[ -z "$dist_dir" ]]; then
  dist_dir="$repo_dir/dist"
fi
mkdir -p "$dist_dir"

tmp_dir="$(mktemp -d)"
pkg_dir="$tmp_dir/$name-$version"
mkdir -p "$pkg_dir"

rsync_args=( -a )
for ex in "${excludes[@]}"; do
  rsync_args+=( --exclude "$ex" )
done

rsync "${rsync_args[@]}" "$repo_dir/" "$pkg_dir/"

tarball="$dist_dir/$name-$version.tar.gz"
tar -czf "$tarball" -C "$tmp_dir" "$name-$version"
rm -rf "$tmp_dir"

log_info "Built Homebrew tarball: $tarball"
