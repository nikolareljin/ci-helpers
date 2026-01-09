#!/usr/bin/env bash
# SCRIPT: build_deb_artifacts.sh
# DESCRIPTION: Build Debian packages and emit artifacts in the parent directory.
# USAGE: ./build_deb_artifacts.sh [--repo PATH] [--prebuild COMMAND] [--build COMMAND]
# EXAMPLE: ./build_deb_artifacts.sh --repo . --prebuild "make man"
# PARAMETERS:
#   --repo <path>        Repo path (default: GITHUB_WORKSPACE or cwd).
#   --prebuild <command> Command to run before build (default: "make man").
#   --build <command>    Build command override (default: dpkg-buildpackage -us -uc).
#   -h, --help           Show help.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help package_publish

usage() { display_help; }

repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
prebuild_cmd="make man"
build_cmd=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo_dir="$2"; shift 2;;
    --prebuild) prebuild_cmd="$2"; shift 2;;
    --build) build_cmd="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) log_error "Unknown argument: $1"; usage; exit 2;;
  esac
done

pkg_build_deb_artifacts "$repo_dir" "$prebuild_cmd" "$build_cmd"
