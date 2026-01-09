#!/usr/bin/env bash
# SCRIPT: ppa_upload.sh
# DESCRIPTION: Build a Debian source package and upload to Launchpad PPA.
# USAGE: ./ppa_upload.sh --ppa <ppa:owner/name> --key-id <gpg_key_id> [--series SERIES] [--repo PATH] [--prebuild COMMAND] [--build COMMAND] [--dry-run]
# EXAMPLE: ./ppa_upload.sh --ppa ppa:owner/name --key-id ABC123 --series jammy
# PARAMETERS:
#   --ppa <ppa:owner/name>   Launchpad PPA target (required).
#   --key-id <gpg_key_id>    GPG key ID or fingerprint (required).
#   --series <codename>      Optional distro codename to set with dch.
#   --repo <path>            Repo path (default: GITHUB_WORKSPACE or cwd).
#   --prebuild <command>     Command to run before build (default: "make man").
#   --build <command>        Command to build source package (default: debuild -S -sa).
#   --dry-run                Do not upload, just print the .changes file.
#   -h, --help               Show help.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help package_publish

usage() { display_help; }

ppa_target=""
key_id=""
series=""
repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
prebuild_cmd="make man"
build_cmd=""
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ppa) ppa_target="$2"; shift 2;;
    --key-id) key_id="$2"; shift 2;;
    --series) series="$2"; shift 2;;
    --repo) repo_dir="$2"; shift 2;;
    --prebuild) prebuild_cmd="$2"; shift 2;;
    --build) build_cmd="$2"; shift 2;;
    --dry-run) dry_run=true; shift;;
    -h|--help) usage; exit 0;;
    *) log_error "Unknown argument: $1"; usage; exit 2;;
  esac
done

if [[ -z "$ppa_target" ]] || [[ -z "$key_id" ]]; then
  log_error "PPA target and key id are required"
  usage
  exit 2
fi

pkg_build_source_package "$repo_dir" "$prebuild_cmd" "$build_cmd" "$series" "$key_id"
changes_file="$(pkg_find_changes_file "$repo_dir")"

if $dry_run; then
  log_info "Dry-run: would upload $changes_file to $ppa_target"
  exit 0
fi

pkg_upload_ppa "$ppa_target" "$changes_file"
