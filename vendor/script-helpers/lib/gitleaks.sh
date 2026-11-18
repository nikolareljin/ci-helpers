#!/usr/bin/env bash
# gitleaks: the pinned secret scanner, installed on a host that has none or
# an older one.
#
# A gitleaks on PATH is used when it reports the pinned version or a newer one
# (lib/scanner.sh); an older one is passed over for the pinned release in the
# cache.
#
# The release archive for this machine is downloaded, checked against the
# SHA-256 pinned in ci_defaults, and unpacked into the cache. An archive that
# does not match the pin is deleted, never unpacked.
#
# Expected imports by caller (via shlib_import): logging, foxguard (for
# foxguard_sha256); the lookups (gitleaks_bin, gitleaks_missing_reason) need
# neither. ci_defaults and scanner are sourced here.
#
# Return codes: 0 success; 1 the operation failed (download, checksum, unpack);
# 3 not installed, a required tool is missing, or the platform has no binary.

# Always sourced: ci_defaults only fills variables that are unset or empty, so a
# caller's version or checksum overrides are kept and the rest stay pinned.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/ci_defaults.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/scanner.sh"

# Usage: gitleaks_asset
# gitleaks_asset; the release archive for this machine, e.g.
# gitleaks_8.30.1_linux_x64.tar.gz, or ..._windows_x64.zip under Git Bash.
# Returns: 0 known platform; 3 no release binary for this OS or CPU.
# Output: stdout the archive name.
gitleaks_asset() {
  local os arch ext=tar.gz v="${CI_DEFAULT_GITLEAKS_VERSION#v}"
  case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=darwin ;;
    MINGW*|MSYS*|CYGWIN*) os=windows; ext=zip ;;
    *) return 3 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) return 3 ;;
  esac
  [[ "$os" == "windows" && "$arch" != "x64" ]] && return 3
  printf 'gitleaks_%s_%s_%s.%s\n' "$v" "$os" "$arch" "$ext"
}

# Usage: gitleaks_expected_sha256 <asset>
# gitleaks_expected_sha256 <asset>; the pinned SHA-256 of that archive.
# Returns: 0 known asset; 3 unknown asset.
# Output: stdout the pinned SHA-256.
gitleaks_expected_sha256() {
  case "$1" in
    *_linux_x64.tar.gz)    printf '%s\n' "$CI_DEFAULT_GITLEAKS_SHA256_LINUX_X64" ;;
    *_linux_arm64.tar.gz)  printf '%s\n' "$CI_DEFAULT_GITLEAKS_SHA256_LINUX_ARM64" ;;
    *_darwin_x64.tar.gz)   printf '%s\n' "$CI_DEFAULT_GITLEAKS_SHA256_DARWIN_X64" ;;
    *_darwin_arm64.tar.gz) printf '%s\n' "$CI_DEFAULT_GITLEAKS_SHA256_DARWIN_ARM64" ;;
    *_windows_x64.zip)     printf '%s\n' "$CI_DEFAULT_GITLEAKS_SHA256_WINDOWS_X64" ;;
    *) return 3 ;;
  esac
}

# Usage: gitleaks_cache_path
# gitleaks_cache_path; where gitleaks_install puts the binary.
# Returns: always 0.
# Output: stdout the cache path of the binary.
gitleaks_cache_path() {
  local name=gitleaks
  case "$(gitleaks_asset 2>/dev/null)" in *.zip) name=gitleaks.exe ;; esac
  printf '%s/script-helpers/gitleaks/%s/%s\n' \
    "${XDG_CACHE_HOME:-${HOME:-}/.cache}" "$CI_DEFAULT_GITLEAKS_VERSION" "$name"
}

# Usage: gitleaks_bin
# gitleaks_bin; the gitleaks to run. In this order: one on PATH that reports
# the pinned version or a newer one of the same major; the pinned binary in the
# cache; one on PATH of a newer major (gitleaks_version_warning has the
# warning for it). An older gitleaks on PATH, or one whose version is not
# [v]X.Y.Z, is never used. gitleaks_missing_reason says why there is none.
# Returns: 0 found; 3 no usable gitleaks on PATH and none in the cache.
# Output: stdout the binary path.
gitleaks_bin() {
  local cached="" found="" c dir
  # Either name in the pinned version's directory: gitleaks_install writes
  # gitleaks.exe under Git Bash, and uname is not trusted to say which it was.
  dir="$(dirname "$(gitleaks_cache_path)")"
  for c in gitleaks gitleaks.exe; do
    [[ -x "$dir/$c" ]] && { cached="$dir/$c"; break; }
  done
  if found="$(scanner_path_bin gitleaks)"; then
    if [[ -z "$cached" ]] || ! scanner_path_breaking gitleaks; then
      printf '%s\n' "$found"; return 0
    fi
  fi
  [[ -n "$cached" ]] && { printf '%s\n' "$cached"; return 0; }
  return 3
}

# Usage: gitleaks_missing_reason
# gitleaks_missing_reason; one line saying why gitleaks_bin finds none: the
# gitleaks on PATH is older than the pin or reports no usable version, or there
# is none at all.
# Returns: always 0.
# Output: stdout the reason, without a trailing full stop.
gitleaks_missing_reason() {
  scanner_path_reason gitleaks || printf 'gitleaks is not installed\n'
}

# Usage: gitleaks_version_warning [<bin>]
# gitleaks_version_warning [<bin>]; the warning for running <bin> (default:
# gitleaks_bin) when it is a gitleaks on PATH of a newer major than the pin.
# Returns: always 0.
# Output: stdout one line, or nothing.
gitleaks_version_warning() {
  local bin="${1:-}"
  [[ -n "$bin" ]] || bin="$(gitleaks_bin)" || return 0
  scanner_version_warning gitleaks "$bin"
}

# Usage: gitleaks_resolve
# gitleaks_resolve; gitleaks_bin, and when the gitleaks on PATH is older than
# the pin, the pinned release is installed into the cache first (not in CI, nor
# with SCRIPT_HELPERS_NO_AUTO_INSTALL=1) and used. See scanner_resolve.
# Returns: 0 found; 3 none, and none could be installed.
# Output: stdout the binary path; stderr the upgrade message, install progress and the newer-major warning.
gitleaks_resolve() {
  scanner_resolve gitleaks
}

# Usage: gitleaks_install
# gitleaks_install; download, verify and unpack the pinned release for this
# machine into gitleaks_cache_path.
# Returns: 0 installed; 1 mkdir, mktemp, download, checksum, unpack or move failed; 3 no binary for this platform, or curl/wget or a SHA-256 tool is missing.
# Output: stdout nothing; stderr progress and errors.
gitleaks_install() {
  local asset want got dest dir tmp url
  asset="$(gitleaks_asset)" || { log_error "gitleaks: no release binary for $(uname -s) $(uname -m)"; return 3; }
  want="$(gitleaks_expected_sha256 "$asset")" || return 3
  dest="$(gitleaks_cache_path)"; dir="$(dirname "$dest")"
  url="https://github.com/gitleaks/gitleaks/releases/download/${CI_DEFAULT_GITLEAKS_VERSION}/${asset}"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp -d "$dir/.download.XXXXXX")" || return 1
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --max-time 300 -o "$tmp/$asset" "$url" || { rm -rf -- "$tmp"; log_error "gitleaks: download failed: $url"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -O "$tmp/$asset" "$url" || { rm -rf -- "$tmp"; log_error "gitleaks: download failed: $url"; return 1; }
  else
    rm -rf -- "$tmp"; log_error "gitleaks: curl or wget is needed to download it"; return 3
  fi
  got="$(foxguard_sha256 "$tmp/$asset")" || { rm -rf -- "$tmp"; log_error "gitleaks: shasum, sha256sum or openssl is needed to check it"; return 3; }
  if [[ "$got" != "$want" ]]; then
    rm -rf -- "$tmp"
    log_error "gitleaks: $asset does not match the pinned SHA-256 (got $got, want $want); not installed."
    return 1
  fi
  case "$asset" in
    *.zip)
      # Git Bash has no unzip by default; Windows always has PowerShell.
      if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$tmp/$asset" gitleaks.exe -d "$tmp"
      else
        powershell.exe -NoProfile -Command "Expand-Archive -Force -Path '$(cygpath -w "$tmp/$asset")' -DestinationPath '$(cygpath -w "$tmp")'"
      fi ;;
    *) tar -xzf "$tmp/$asset" -C "$tmp" gitleaks ;;
  esac || { rm -rf -- "$tmp"; log_error "gitleaks: could not unpack $asset"; return 1; }
  chmod +x "$tmp/$(basename "$dest")" && mv -f -- "$tmp/$(basename "$dest")" "$dest" || { rm -rf -- "$tmp"; return 1; }
  rm -rf -- "$tmp"
  log_info "gitleaks $CI_DEFAULT_GITLEAKS_VERSION installed at $dest"
}
