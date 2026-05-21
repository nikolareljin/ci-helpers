#!/usr/bin/env bash
# SCRIPT: build_rpm_artifacts.sh
# DESCRIPTION: Build RPM packages and emit artifacts in the parent directory.
# USAGE: ./build_rpm_artifacts.sh [--repo PATH] [--spec PATH] [--prebuild COMMAND] [--artifact-dir PATH]
# EXAMPLE: ./build_rpm_artifacts.sh --repo .
# PARAMETERS:
#   --repo <path>        Repo path (default: GITHUB_WORKSPACE or cwd).
#   --spec <path>        Spec file path (default: packaging/rpm/<app>.spec).
#   --prebuild <command> Command to run before build.
#   --artifact-dir <path> Output directory for built RPMs (default: ..).
#   -h, --help           Show help.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help packaging

usage() { display_help; }

repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
spec_path=""
prebuild_cmd=""
artifact_dir=".."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo_dir="$2"; shift 2;;
    --spec) spec_path="$2"; shift 2;;
    --prebuild) prebuild_cmd="$2"; shift 2;;
    --artifact-dir) artifact_dir="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) log_error "Unknown argument: $1"; usage; exit 2;;
  esac
done

config_path="$repo_dir/packaging/packaging.env"
if [[ -f "$config_path" ]]; then
  pkg_load_metadata "$config_path"
fi

if [[ -z "$spec_path" ]]; then
  if [[ -n "${APP_NAME:-}" ]]; then
    spec_path="$repo_dir/packaging/rpm/${APP_NAME}.spec"
  else
    spec_path="$(find "$repo_dir/packaging/rpm" -maxdepth 1 -type f -name '*.spec' 2>/dev/null | head -n 1 || true)"
  fi
fi

if [[ -z "$spec_path" || ! -f "$spec_path" ]]; then
  log_error "Spec file not found (use --spec): $spec_path"
  exit 1
fi

if [[ -z "${APP_NAME:-}" ]]; then
  APP_NAME="$(awk -F: '/^Name:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' "$spec_path")"
fi

if [[ -z "${APP_VERSION:-}" ]]; then
  APP_VERSION="$(awk -F: '/^Version:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' "$spec_path")"
fi

if [[ -z "${APP_VERSION:-}" ]]; then
  APP_VERSION="$(pkg_guess_version "$repo_dir")"
fi

APP_NAME="${APP_NAME:-app}"

if [[ -n "$prebuild_cmd" ]]; then
  log_info "Running prebuild: $prebuild_cmd"
  (cd "$repo_dir" && bash -lc "$prebuild_cmd")
fi

build_root="$repo_dir/packaging/rpm/build"
mkdir -p "$build_root"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

source_tar="${APP_NAME:-app}-${APP_VERSION}.tar.gz"
source_path="$build_root/SOURCES/$source_tar"

if command -v git >/dev/null 2>&1 && git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 && [[ -z "$prebuild_cmd" ]]; then
  git -C "$repo_dir" archive --format=tar.gz --prefix="${APP_NAME:-app}-${APP_VERSION}/" -o "$source_path" HEAD
else
  tar -C "$repo_dir" -czf "$source_path" \
    --exclude=".git" \
    --transform "s,^,${APP_NAME:-app}-${APP_VERSION}/," \
    .
fi

cp "$spec_path" "$build_root/SPECS/"

rpmbuild -ba "$build_root/SPECS/$(basename "$spec_path")" \
  --define "_topdir $build_root" \
  --define "_sourcedir $build_root/SOURCES"

mkdir -p "$artifact_dir"
find "$build_root/RPMS" -type f -name "*.rpm" -exec cp -v {} "$artifact_dir" \;
