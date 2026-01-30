#!/usr/bin/env bash
# SCRIPT: build_arch_artifacts.sh
# DESCRIPTION: Build Arch package via PKGBUILD and emit artifacts in the parent directory.
# USAGE: ./build_arch_artifacts.sh [--repo PATH] [--pkg-dir PATH] [--prebuild COMMAND] [--artifact-dir PATH]
# EXAMPLE: ./build_arch_artifacts.sh --repo .
# PARAMETERS:
#   --repo <path>         Repo path (default: GITHUB_WORKSPACE or cwd).
#   --pkg-dir <path>      PKGBUILD directory (default: packaging/arch).
#   --prebuild <command>  Command to run before build.
#   --artifact-dir <path> Output directory for packages (default: ..).
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
pkg_dir="packaging/arch"
prebuild_cmd=""
artifact_dir=".."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo_dir="$2"; shift 2;;
    --pkg-dir) pkg_dir="$2"; shift 2;;
    --prebuild) prebuild_cmd="$2"; shift 2;;
    --artifact-dir) artifact_dir="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) log_error "Unknown argument: $1"; usage; exit 2;;
  esac
done

if [[ "$pkg_dir" != /* ]]; then
  pkg_dir="$repo_dir/$pkg_dir"
fi

if [[ ! -f "$pkg_dir/PKGBUILD" ]]; then
  log_error "PKGBUILD not found: $pkg_dir/PKGBUILD"
  exit 1
fi

if [[ -n "$prebuild_cmd" ]]; then
  log_info "Running prebuild: $prebuild_cmd"
  (cd "$repo_dir" && bash -lc "$prebuild_cmd")
fi

(cd "$pkg_dir" && makepkg -s --noconfirm)

mkdir -p "$artifact_dir"
find "$pkg_dir" -maxdepth 1 -type f -name "*.pkg.tar.*" -exec cp -v {} "$artifact_dir" \;
