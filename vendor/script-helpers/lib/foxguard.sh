#!/usr/bin/env bash
# foxguard: the pinned static-analysis scanner that scripts/ci_security.sh runs.
#
# `npx foxguard` fetches whatever version is latest. This module installs one
# version, pinned in ci_defaults together with the SHA-256 of each release
# binary, and refuses a cached binary that does not match the pin. A foxguard
# on PATH is used when it reports the pinned version or a newer one
# (lib/scanner.sh); an older one is passed over.
#
# Expected imports by caller (via shlib_import): logging. ci_defaults,
# scanner and fetch are sourced here.
#
# Return codes, used by every function in this module:
#   0  success
#   1  the operation failed (download, checksum mismatch)
#   3  the pinned version is not installed, a required tool is missing, or the
#      platform has no binary

# Always sourced: ci_defaults only fills variables that are unset or empty, so a
# caller's version or checksum overrides are kept and the rest stay pinned.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/ci_defaults.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/scanner.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/fetch.sh"

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

# Usage: foxguard_is_pinned <file>
# foxguard_is_pinned <file>; true when the file's SHA-256 is the one pinned for
# this machine's release asset. A file that cannot be hashed is not the pin.
# Returns: 0 it is the pinned binary; 1 it is not; 3 no release binary for this platform, or no SHA-256 tool.
# Output: nothing.
foxguard_is_pinned() {
  local asset want got
  asset="$(foxguard_asset)" || return 3
  want="$(foxguard_expected_sha256 "$asset")" || return 3
  got="$(foxguard_sha256 "$1" 2>/dev/null)" || return 3
  [[ -n "$want" && "$got" == "$want" ]]
}

# Usage: foxguard_path_bin
# foxguard_path_bin; the foxguard on PATH, when `foxguard --version` reports
# the pinned version or a newer one.
# Returns: 0 found; 3 none on PATH, an older one, or one with no X.Y.Z version.
# Output: stdout the binary path.
foxguard_path_bin() {
  scanner_path_bin foxguard
}

# Usage: foxguard_bin
# foxguard_bin; the foxguard to run: the pinned binary in the cache when its
# SHA-256 matches the pin, else one on PATH that reports the pinned version or
# a newer one (foxguard_version_warning has the warning for a newer breaking
# series). A cached binary of another version is never used, nor an older
# foxguard on PATH. foxguard_missing_reason says why there is none.
# Returns: 0 found; 3 no pinned foxguard in the cache and no usable one on PATH.
# Output: stdout the binary path.
foxguard_bin() {
  local cached
  cached="$(foxguard_cache_path)"
  if [[ -x "$cached" ]] && foxguard_is_pinned "$cached"; then
    printf '%s\n' "$cached"
  else
    foxguard_path_bin
  fi
}

# Usage: foxguard_missing_reason
# foxguard_missing_reason; one line saying why foxguard_bin finds none: a
# cached binary that does not match the pin or cannot be checked, a foxguard on
# PATH that is older than the pin or reports no usable version, or none at all.
# Returns: always 0.
# Output: stdout the reason, without a trailing full stop.
foxguard_missing_reason() {
  local cached path_why why="" rc=0
  cached="$(foxguard_cache_path)"
  if [[ -x "$cached" ]]; then
    foxguard_is_pinned "$cached" || rc=$?
    case "$rc" in
      1) why="$cached does not match the pinned SHA-256 of foxguard $CI_DEFAULT_FOXGUARD_VERSION" ;;
      3) why="$cached cannot be checked against the pinned SHA-256 (shasum, sha256sum or openssl is needed)" ;;
    esac
  fi
  if path_why="$(scanner_path_reason foxguard)"; then
    why="${why:+$why; }$path_why"
  fi
  printf '%s\n' "${why:-foxguard is not installed}"
}

# Usage: foxguard_version_warning [<bin>]
# foxguard_version_warning [<bin>]; the warning for running <bin> (default:
# foxguard_bin) when it is a foxguard on PATH in a newer breaking series than
# the pin (another major, or another minor of 0.x).
# Returns: always 0.
# Output: stdout one line, or nothing.
foxguard_version_warning() {
  local bin="${1:-}"
  [[ -n "$bin" ]] || bin="$(foxguard_bin)" || return 0
  scanner_version_warning foxguard "$bin"
}

# Usage: foxguard_resolve
# foxguard_resolve; foxguard_bin, and when the foxguard on PATH is older than
# the pin, the pinned release is installed into the cache first (not in CI, nor
# with SCRIPT_HELPERS_NO_AUTO_INSTALL=1) and used. See scanner_resolve.
# Returns: 0 found; 3 none, and none could be installed.
# Output: stdout the binary path; stderr the upgrade message, install progress and the warning.
foxguard_resolve() {
  scanner_resolve foxguard
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
  local asset want got dest tmp url rc
  asset="$(foxguard_asset)" || { log_error "foxguard: no release binary for $(uname -s) $(uname -m)"; return 3; }
  want="$(foxguard_expected_sha256 "$asset")" || return 3
  dest="$(foxguard_cache_path)"
  url="https://github.com/0sec-labs/foxguard/releases/download/v${CI_DEFAULT_FOXGUARD_VERSION}/${asset}"
  mkdir -p "$(dirname "$dest")" || return 1
  tmp="$(mktemp "$(dirname "$dest")/.download.XXXXXX")" || return 1
  trap_stack_push "$tmp"
  fetch_to_file foxguard "$url" "$tmp" || { rc=$?; trap_stack_pop; return "$rc"; }
  got="$(foxguard_sha256 "$tmp")" || { trap_stack_pop; log_error "foxguard: shasum, sha256sum or openssl is needed to check it"; return 3; }
  if [[ "$got" != "$want" ]]; then
    trap_stack_pop
    log_error "foxguard: $asset $CI_DEFAULT_FOXGUARD_VERSION does not match the pinned SHA-256 (got $got, want $want); not installed. A changed CI_DEFAULT_FOXGUARD_VERSION needs its CI_DEFAULT_FOXGUARD_SHA256_* values too."
    return 1
  fi
  chmod +x "$tmp" && mv -f -- "$tmp" "$dest" || { trap_stack_pop; return 1; }
  trap_stack_pop
  log_info "foxguard $CI_DEFAULT_FOXGUARD_VERSION installed at $dest"
}
