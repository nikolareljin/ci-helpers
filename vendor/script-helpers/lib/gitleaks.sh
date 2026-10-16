#!/usr/bin/env bash
# gitleaks: the pinned secret scanner, installed on a host that has none.
#
# The release archive for this machine is downloaded, checked against the
# SHA-256 pinned in ci_defaults, and unpacked into the cache. An archive that
# does not match the pin is deleted, never unpacked.
#
# Expected imports by caller (via shlib_import): logging, foxguard (for
# foxguard_sha256). ci_defaults is sourced here when the caller has not.
#
# Return codes: 0 success; 1 the operation failed (download, checksum, unpack);
# 3 not installed, a required tool is missing, or the platform has no binary.

if [[ -z "${CI_DEFAULT_GITLEAKS_SHA256_LINUX_X64:-}" ]]; then
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/ci_defaults.sh"
fi

# gitleaks_asset; the release archive for this machine, e.g.
# gitleaks_8.30.1_linux_x64.tar.gz, or ..._windows_x64.zip under Git Bash.
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

# gitleaks_expected_sha256 <asset>; the pinned SHA-256 of that archive.
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

# gitleaks_cache_path; where gitleaks_install puts the binary.
gitleaks_cache_path() {
  local name=gitleaks
  case "$(gitleaks_asset 2>/dev/null)" in *.zip) name=gitleaks.exe ;; esac
  printf '%s/script-helpers/gitleaks/%s/%s\n' \
    "${XDG_CACHE_HOME:-$HOME/.cache}" "$CI_DEFAULT_GITLEAKS_VERSION" "$name"
}

# gitleaks_bin; one on PATH, else the pinned binary in the cache. Returns 3 when
# there is neither.
gitleaks_bin() {
  local cached
  if command -v gitleaks >/dev/null 2>&1; then
    command -v gitleaks; return 0
  fi
  cached="$(gitleaks_cache_path)"
  [[ -x "$cached" ]] && { printf '%s\n' "$cached"; return 0; }
  return 3
}

# gitleaks_install; download, verify and unpack the pinned release for this
# machine into gitleaks_cache_path.
gitleaks_install() {
  local asset want got dest dir tmp url
  asset="$(gitleaks_asset)" || { log_error "gitleaks: no release binary for $(uname -s) $(uname -m)"; return 3; }
  want="$(gitleaks_expected_sha256 "$asset")" || return 3
  dest="$(gitleaks_cache_path)"; dir="$(dirname "$dest")"
  url="https://github.com/gitleaks/gitleaks/releases/download/${CI_DEFAULT_GITLEAKS_VERSION}/${asset}"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp -d "$dir/.download.XXXXXX")" || return 1
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --max-time 300 -o "$tmp/$asset" "$url" || { rm -rf "$tmp"; log_error "gitleaks: download failed: $url"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -O "$tmp/$asset" "$url" || { rm -rf "$tmp"; log_error "gitleaks: download failed: $url"; return 1; }
  else
    rm -rf "$tmp"; log_error "gitleaks: curl or wget is needed to download it"; return 3
  fi
  got="$(foxguard_sha256 "$tmp/$asset")" || { rm -rf "$tmp"; log_error "gitleaks: shasum, sha256sum or openssl is needed to check it"; return 3; }
  if [[ "$got" != "$want" ]]; then
    rm -rf "$tmp"
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
  esac || { rm -rf "$tmp"; log_error "gitleaks: could not unpack $asset"; return 1; }
  chmod +x "$tmp/$(basename "$dest")" && mv -f "$tmp/$(basename "$dest")" "$dest" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  log_info "gitleaks $CI_DEFAULT_GITLEAKS_VERSION installed at $dest"
}
