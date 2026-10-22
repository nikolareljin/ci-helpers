#!/usr/bin/env bash
# foxguard: the pinned static-analysis scanner that scripts/ci_security.sh runs.
#
# `npx foxguard` fetches whatever version is latest. This module runs one
# version, pinned in ci_defaults together with the SHA-256 of each release
# binary, so a scan gives the same answer on every machine and a binary that
# does not match the pin is refused instead of run.
#
# Expected imports by caller (via shlib_import): logging. ci_defaults is sourced
# here when the caller has not imported it.
#
# Return codes, used by every function in this module:
#   0  success
#   1  the operation failed (download, checksum mismatch)
#   3  not installed, a required tool is missing, or the platform has no binary

# Always sourced: ci_defaults only fills variables that are unset or empty, so a
# caller's version or checksum overrides are kept and the rest stay pinned.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/ci_defaults.sh"

# The file names foxguard reads its configuration from, in each directory from
# the scan path upward. Measured on 0.14.1: all four are read.
FOXGUARD_CONFIG_NAMES=".foxguard.yml .foxguard.yaml foxguard.yml foxguard.yaml"

# Usage: foxguard_asset
# foxguard_asset; the release asset name for this machine, e.g.
# foxguard-linux-x86_64, or foxguard-windows-x86_64.exe under Git Bash, MSYS or
# Cygwin. Returns 3 on a platform with no release binary.
# Returns: 0 known platform; 3 no release binary for this OS or CPU.
# Output: stdout the asset name.
foxguard_asset() {
  local os arch ext=""
  case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=macos ;;
    MINGW*|MSYS*|CYGWIN*) os=windows; ext=".exe" ;;
    *) return 3 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) return 3 ;;
  esac
  [[ "$os" == "windows" && "$arch" != "x86_64" ]] && return 3
  printf 'foxguard-%s-%s%s\n' "$os" "$arch" "$ext"
}

# Usage: foxguard_config_in <dir>
# foxguard_config_in <dir>; print the foxguard config file in that directory, if
# there is one (see FOXGUARD_CONFIG_NAMES). Returns 1 when there is none.
# Returns: 0 a config file exists; 1 none.
# Output: stdout the config path.
foxguard_config_in() {
  local name
  for name in $FOXGUARD_CONFIG_NAMES; do
    [[ -f "$1/$name" ]] && { printf '%s/%s\n' "$1" "$name"; return 0; }
  done
  return 1
}

# Usage: foxguard_expected_sha256 <asset>
# foxguard_expected_sha256 <asset>; the pinned SHA-256 of that release asset.
# Returns: 0 known asset; 3 unknown asset.
# Output: stdout the pinned SHA-256.
foxguard_expected_sha256() {
  case "$1" in
    foxguard-linux-x86_64)  printf '%s\n' "$CI_DEFAULT_FOXGUARD_SHA256_LINUX_X86_64" ;;
    foxguard-linux-aarch64) printf '%s\n' "$CI_DEFAULT_FOXGUARD_SHA256_LINUX_AARCH64" ;;
    foxguard-macos-x86_64)  printf '%s\n' "$CI_DEFAULT_FOXGUARD_SHA256_MACOS_X86_64" ;;
    foxguard-macos-aarch64) printf '%s\n' "$CI_DEFAULT_FOXGUARD_SHA256_MACOS_AARCH64" ;;
    foxguard-windows-x86_64.exe) printf '%s\n' "$CI_DEFAULT_FOXGUARD_SHA256_WINDOWS_X86_64" ;;
    *) return 3 ;;
  esac
}

# Usage: foxguard_cache_path
# foxguard_cache_path; where --install-foxguard puts the pinned binary
# (foxguard.exe on Windows, which runs nothing without the extension).
# Returns: always 0.
# Output: stdout the cache path of the binary.
foxguard_cache_path() {
  local name=foxguard
  case "$(foxguard_asset 2>/dev/null)" in *.exe) name=foxguard.exe ;; esac
  printf '%s/script-helpers/foxguard/%s/%s\n' \
    "${XDG_CACHE_HOME:-$HOME/.cache}" "$CI_DEFAULT_FOXGUARD_VERSION" "$name"
}

# Usage: foxguard_bin
# foxguard_bin; the foxguard to run: the pinned binary in the cache, else one on
# PATH. Returns 3 when there is neither.
# Returns: 0 found; 3 not in the cache and not on PATH.
# Output: stdout the binary path.
foxguard_bin() {
  local cached
  cached="$(foxguard_cache_path)"
  if [[ -x "$cached" ]]; then
    printf '%s\n' "$cached"
  elif command -v foxguard >/dev/null 2>&1; then
    command -v foxguard
  else
    return 3
  fi
}

# Usage: foxguard_sha256 <file>
# foxguard_sha256 <file>; its SHA-256, with shasum, sha256sum or openssl.
# shasum and openssl are on macOS; a minimal Linux (Alpine, slim images) may
# have only coreutils' or busybox's sha256sum.
# Returns: 3 no shasum, sha256sum or openssl; otherwise the exit code of the awk pipeline (0, also for an unreadable file).
# Output: stdout the hex digest; stderr the hash tool's error for an unreadable file.
foxguard_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    return 3
  fi
}

# Usage: foxguard_install
# foxguard_install; download the pinned release binary for this machine, check
# it against the pinned SHA-256, and put it at foxguard_cache_path. A mismatch
# deletes the download and returns 1.
# Returns: 0 installed; 1 mkdir, mktemp, download, checksum or move failed; 3 no binary for this platform, or curl/wget or a SHA-256 tool is missing.
# Output: stdout nothing; stderr progress and errors.
foxguard_install() {
  local asset want got dest tmp url
  asset="$(foxguard_asset)" || { log_error "foxguard: no release binary for $(uname -s) $(uname -m)"; return 3; }
  want="$(foxguard_expected_sha256 "$asset")" || return 3
  dest="$(foxguard_cache_path)"
  url="https://github.com/0sec-labs/foxguard/releases/download/v${CI_DEFAULT_FOXGUARD_VERSION}/${asset}"
  mkdir -p "$(dirname "$dest")" || return 1
  tmp="$(mktemp "$(dirname "$dest")/.download.XXXXXX")" || return 1
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --max-time 300 -o "$tmp" "$url" || { rm -f "$tmp"; log_error "foxguard: download failed: $url"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -O "$tmp" "$url" || { rm -f "$tmp"; log_error "foxguard: download failed: $url"; return 1; }
  else
    rm -f "$tmp"; log_error "foxguard: curl or wget is needed to download it"; return 3
  fi
  got="$(foxguard_sha256 "$tmp")" || { rm -f "$tmp"; log_error "foxguard: shasum, sha256sum or openssl is needed to check it"; return 3; }
  if [[ "$got" != "$want" ]]; then
    rm -f "$tmp"
    log_error "foxguard: $asset $CI_DEFAULT_FOXGUARD_VERSION does not match the pinned SHA-256 (got $got, want $want); not installed. A changed CI_DEFAULT_FOXGUARD_VERSION needs its CI_DEFAULT_FOXGUARD_SHA256_* values too."
    return 1
  fi
  chmod +x "$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  log_info "foxguard $CI_DEFAULT_FOXGUARD_VERSION installed at $dest"
}
