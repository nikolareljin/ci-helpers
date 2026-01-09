#!/usr/bin/env bash
# package_publish.sh - Helpers for Debian package builds and PPA publishing.

_pkg_log_info() {
  if declare -F log_info >/dev/null 2>&1; then
    log_info "$*"
  else
    echo "[INFO] $*" >&2
  fi
}

_pkg_log_error() {
  if declare -F log_error >/dev/null 2>&1; then
    log_error "$*"
  else
    echo "[ERROR] $*" >&2
  fi
}

# Usage: pkg_require_cmds <cmd> [cmd...]
pkg_require_cmds() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      _pkg_log_error "Missing required command: $cmd"
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    return 2
  fi
  return 0
}

# Usage: pkg_run_prebuild <command>
pkg_run_prebuild() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then
    _pkg_log_info "Running prebuild: $cmd"
    bash -lc "$cmd"
  fi
}

# Usage: pkg_set_series <series>
pkg_set_series() {
  local series="${1:-}"
  if [[ -n "$series" ]]; then
    pkg_require_cmds dch || return 2
    dch --distribution "$series" --no-auto-nmu "Automated PPA build"
  fi
}

# Usage: pkg_build_deb_artifacts <repo_dir> <prebuild_cmd> <build_cmd>
pkg_build_deb_artifacts() {
  local repo_dir="$1" prebuild_cmd="$2" build_cmd="$3"
  cd "$repo_dir"
  pkg_run_prebuild "$prebuild_cmd"
  if [[ -n "$build_cmd" ]]; then
    _pkg_log_info "Running build: $build_cmd"
    bash -lc "$build_cmd"
  else
    pkg_require_cmds dpkg-buildpackage || return 2
    dpkg-buildpackage -us -uc
  fi
}

# Usage: pkg_build_source_package <repo_dir> <prebuild_cmd> <build_cmd> <series> <key_id>
pkg_build_source_package() {
  local repo_dir="$1" prebuild_cmd="$2" build_cmd="$3" series="$4" key_id="$5"
  if [[ -z "$build_cmd" ]] && [[ -z "${PPA_GPG_PASSPHRASE:-}" ]]; then
    _pkg_log_error "PPA_GPG_PASSPHRASE is required for signing"
    return 2
  fi
  pkg_require_cmds debuild gpg || return 2
  cd "$repo_dir"
  pkg_run_prebuild "$prebuild_cmd"
  pkg_set_series "$series"
  if [[ -n "$build_cmd" ]]; then
    _pkg_log_info "Running build: $build_cmd"
    bash -lc "$build_cmd"
  else
    debuild -S -sa -k"$key_id" -p"gpg --batch --pinentry-mode loopback --passphrase ${PPA_GPG_PASSPHRASE}"
  fi
}

# Usage: pkg_find_changes_file <repo_dir>
pkg_find_changes_file() {
  local repo_dir="$1"
  local changes_file
  changes_file="$(ls "$repo_dir"/../*.changes | head -n 1 || true)"
  if [[ -z "$changes_file" ]]; then
    _pkg_log_error "No .changes file found."
    return 1
  fi
  echo "$changes_file"
}

# Usage: pkg_upload_ppa <ppa_target> <changes_file>
pkg_upload_ppa() {
  local ppa_target="$1" changes_file="$2"
  pkg_require_cmds dput || return 2
  dput "$ppa_target" "$changes_file"
}
