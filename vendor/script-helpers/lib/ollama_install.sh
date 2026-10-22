#!/usr/bin/env bash
# ollama_install: put Ollama itself on a machine, from a source that can be checked.
#
# Ollama's own one-line installer (`curl https://ollama.com/install.sh | sh`)
# runs whatever script the server returns at that moment, as root. This module
# installs the same thing a checkable way instead:
#   Linux   the official release archive of the version pinned in ci_defaults,
#           compared with the pinned SHA-256 before anything is unpacked
#   macOS   Homebrew (its bottles are checked by Homebrew), else the release
#           archive, checked the same way
#   Windows (Git Bash, MSYS, Cygwin) winget, which checks the installer against
#           its manifest, else the release zip, checked the same way and
#           unpacked; no setup program is run. ps/lib/ollama_install.ps1 does
#           the same from PowerShell.
#   other   nothing is downloaded; the message names the official installer
#
# It installs the program only. Running it as a service (the systemd unit the
# one-line installer writes, or `brew services start ollama`) is left to the
# machine's owner, and said in the message.
#
# Expected imports by caller (via shlib_import): logging. ci_defaults is sourced
# here when the caller has not imported it.
#
# Return codes, used by every function in this module:
#   0  installed, or already there at the pinned version or newer
#   1  the download failed, or it does not match the pinned SHA-256
#   3  a required tool is missing, or the platform has no checkable source

# Always sourced: ci_defaults only fills variables that are unset or empty, so a
# caller's version or checksum overrides are kept and the rest stay pinned.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/ci_defaults.sh"

# Usage: ollama_install_asset; prints the release asset name for this machine
# (ollama-linux-amd64.tar.zst, ollama-linux-arm64.tar.zst, ollama-darwin.tgz).
# Returns 3 on a platform with no archive this module installs.
# Returns: 0 printed; 3 unsupported platform.
# Output: stdout the asset name.
ollama_install_asset() {
  case "$(uname -s)" in
    Linux)
      case "$(uname -m)" in
        x86_64|amd64) printf '%s\n' "ollama-linux-amd64.tar.zst" ;;
        aarch64|arm64) printf '%s\n' "ollama-linux-arm64.tar.zst" ;;
        *) return 3 ;;
      esac
      ;;
    Darwin) printf '%s\n' "ollama-darwin.tgz" ;;
    MINGW*|MSYS*|CYGWIN*)
      case "$(uname -m)" in
        x86_64|amd64) printf '%s\n' "ollama-windows-amd64.zip" ;;
        aarch64|arm64) printf '%s\n' "ollama-windows-arm64.zip" ;;
        *) return 3 ;;
      esac
      ;;
    *) return 3 ;;
  esac
}

# Usage: ollama_install_expected_sha256 <asset>; prints the pinned SHA-256 of
# that release asset. Returns 3 for an asset with no pin.
# Returns: 0 printed; 3 no pin for that asset.
# Output: stdout the pinned hash (may be empty when the pin variable is unset).
ollama_install_expected_sha256() {
  case "${1:-}" in
    ollama-linux-amd64.tar.zst) printf '%s\n' "$CI_DEFAULT_OLLAMA_SHA256_LINUX_AMD64" ;;
    ollama-linux-arm64.tar.zst) printf '%s\n' "$CI_DEFAULT_OLLAMA_SHA256_LINUX_ARM64" ;;
    ollama-darwin.tgz) printf '%s\n' "$CI_DEFAULT_OLLAMA_SHA256_DARWIN" ;;
    ollama-windows-amd64.zip) printf '%s\n' "$CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64" ;;
    ollama-windows-arm64.zip) printf '%s\n' "$CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64" ;;
    *) return 3 ;;
  esac
}

# Usage: ollama_install_sha256 <file>; prints its SHA-256, with shasum,
# sha256sum or openssl (a minimal Linux may have only sha256sum). Returns 3
# when none is there.
# Returns: 0 printed; 3 no hashing tool.
# Output: stdout the hex digest.
ollama_install_sha256() {
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

# Usage: ollama_installed_version [binary]; prints the version of that ollama
# binary, or of the one on PATH (0.40.0). Prints nothing and returns 1 when
# there is none.
#
# `ollama --version` asks a running server first and prints the SERVER's
# version ("ollama version is 0.34.4"), with the binary's own only as "client
# version is 0.40.0" when the two differ. So it is asked with OLLAMA_HOST at a
# port nothing listens on, and a "client version" line wins over any other.
# shellcheck disable=SC2120  # callers in other files pass a binary
# Returns: 0 printed; 1 no binary or no version found.
# Output: stdout X.Y.Z; stderr nothing.
ollama_installed_version() {
  local bin="${1:-ollama}" out client
  command -v "$bin" >/dev/null 2>&1 || return 1
  out="$(OLLAMA_HOST=127.0.0.1:9 "$bin" --version 2>&1)" || true
  client="$(printf '%s\n' "$out" | sed -n 's/.*client version is \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | sed -n 1p)" || true
  if [[ -z "$client" ]]; then
    client="$(printf '%s\n' "$out" | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+' | sed -n 1p)" || true
  fi
  [[ -n "$client" ]] || return 1
  printf '%s\n' "$client"
}

# Usage: _ollama_install_at_least <have> <want>; 0 when have >= want (X.Y.Z).
_ollama_install_at_least() {
  local IFS=.
  local -a h w
  read -r -a h <<<"${1:-0.0.0}"
  read -r -a w <<<"${2:-0.0.0}"
  local i
  for i in 0 1 2; do
    [[ "${h[$i]:-0}" =~ ^[0-9]+$ ]] || return 1
    [[ "${w[$i]:-0}" =~ ^[0-9]+$ ]] || return 1
    if (( 10#${h[$i]:-0} > 10#${w[$i]:-0} )); then return 0; fi
    if (( 10#${h[$i]:-0} < 10#${w[$i]:-0} )); then return 1; fi
  done
  return 0
}

# Usage: _ollama_install_report_after <pinned>; after Homebrew or winget, says
# which version is on PATH now. Their catalogs may be behind the pin; that is
# said, not an error.
_ollama_install_report_after() {
  local now
  if now="$(ollama_installed_version)"; then
    if _ollama_install_at_least "$now" "${1:-0.0.0}"; then
      log_info "Ollama $now is installed."
    else
      log_warn "Ollama $now is installed; the pinned version is ${1:-}. The package manager has nothing newer yet."
    fi
  fi
  return 0
}

# Usage: ollama_install [--prefix DIR] [--force]
# Installs the pinned Ollama (CI_DEFAULT_OLLAMA_VERSION) unless one at that
# version or newer is on PATH already (--force installs anyway). An older one
# is upgraded: Homebrew and winget upgrade theirs, the archive replaces it.
#   --prefix DIR  where bin/ollama goes. Default /usr/local, which needs root:
#                 the unpack runs through sudo when this shell is not root. A
#                 prefix under the home directory needs no root; its bin must
#                 be on PATH.
# On macOS with Homebrew, and no --prefix: `brew install ollama`, or `brew
# upgrade ollama` for Homebrew's own older one. A --prefix means the archive.
# Env: OLLAMA_RELEASE_BASE_URL (default
#   https://github.com/ollama/ollama/releases/download), for a mirror; the
#   archive is still checked against the pinned SHA-256.
# Returns as the module says. A mismatch deletes the download and unpacks
# nothing.
# Returns: 0 installed or already current; 1 download, checksum, unpack, install or package-manager failure; 3 bad option, missing tool or unsupported platform.
# Output: stderr log lines; download and package-manager output.
ollama_install() {
  local prefix="/usr/local" prefix_given=0 force=0 asset want got have tmpdir url sudo=""
  local base="${OLLAMA_RELEASE_BASE_URL:-https://github.com/ollama/ollama/releases/download}"
  local version="$CI_DEFAULT_OLLAMA_VERSION"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix) prefix="${2:-}"; prefix_given=1; [[ -n "$prefix" ]] || { log_error "ollama_install: --prefix needs a directory"; return 3; }; shift 2 ;;
      --force) force=1; shift ;;
      *) log_error "ollama_install: unknown option: $1"; return 3 ;;
    esac
  done

  # The prefix is written into a launcher script (macOS), so it must be
  # absolute (a relative one would be read from wherever the launcher is
  # started) and hold nothing a shell reads as code.
  case "$prefix" in
    /*) ;;
    *) prefix="$(pwd -P)/${prefix#./}" ;;
  esac
  case "$prefix" in
    *[\"\$\`\\]*|*$'\n'*|*$'\r'*)
      log_error "ollama_install: --prefix may not contain a quote, \$, a backquote, a backslash or a line break"
      return 3
      ;;
  esac

  if have="$(ollama_installed_version)" && [[ "$force" -eq 0 ]] && _ollama_install_at_least "$have" "$version"; then
    log_info "Ollama $have is installed (pinned: $version); nothing to do."
    return 0
  fi

  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      [[ "$prefix_given" -eq 1 ]] || prefix="${LOCALAPPDATA:-$HOME/AppData/Local}/Programs/Ollama"
      if command -v winget >/dev/null 2>&1 && [[ "$prefix_given" -eq 0 ]]; then
        # An older Ollama is upgraded: `winget install` stops at one that is
        # there. When winget has nothing newer, the pinned zip goes to the same
        # place Ollama's own installer uses.
        local verb=install
        [[ -z "$have" ]] || verb=upgrade
        log_info "Ollama with winget ($verb)."
        if winget "$verb" --id Ollama.Ollama -e --silent --accept-package-agreements --accept-source-agreements; then
          _ollama_install_report_after "$version"
          return 0
        fi
        log_warn "winget $verb did not succeed; using the release zip."
      fi
      ;;
  esac

  if [[ "$(uname -s)" == "Darwin" && "$prefix_given" -eq 0 ]] && command -v brew >/dev/null 2>&1; then
    # `brew install` does nothing for a formula that is there: an older one is
    # upgraded. An Ollama from elsewhere (the app) is not Homebrew's to upgrade;
    # the formula is installed beside it.
    if brew list --formula ollama >/dev/null 2>&1; then
      log_info "Upgrading Ollama with Homebrew."
      brew upgrade ollama || { log_error "ollama_install: brew upgrade ollama failed"; return 1; }
    else
      log_info "Installing Ollama with Homebrew."
      brew install ollama || { log_error "ollama_install: brew install ollama failed"; return 1; }
    fi
    _ollama_install_report_after "$version"
    log_info "Start it with: brew services start ollama (or: ollama serve). A running Ollama keeps its version until it is restarted."
    return 0
  fi

  if ! asset="$(ollama_install_asset)"; then
    log_error "ollama_install: no checkable Ollama archive for $(uname -s) $(uname -m). See https://ollama.com/download."
    return 3
  fi
  want="$(ollama_install_expected_sha256 "$asset")" || return 3
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { log_error "ollama_install: no pinned SHA-256 for $asset (CI_DEFAULT_OLLAMA_SHA256_*)"; return 3; }
  case "$asset" in
    *.zip) command -v unzip >/dev/null 2>&1 || { log_error "ollama_install: unzip is needed to unpack $asset"; return 3; } ;;
    *.tar.zst) command -v zstd >/dev/null 2>&1 || { log_error "ollama_install: zstd is needed to unpack $asset (apt install zstd, dnf install zstd)"; return 3; } ;;
  esac
  command -v curl >/dev/null 2>&1 || { log_error "ollama_install: curl is needed to download it"; return 3; }

  # Whether the unpack needs root: the nearest directory of the prefix that
  # exists decides, since everything below it is created.
  local existing="$prefix" up
  while [[ ! -d "$existing" ]]; do
    up="${existing%/*}"
    # No slash left, or none but the leading one: the current directory or /.
    [[ "$up" != "$existing" ]] || up="."
    [[ -n "$up" ]] || up="/"
    existing="$up"
  done
  if [[ "$asset" != *.zip && ! -w "$existing" ]] && [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || { log_error "ollama_install: $prefix is not writable and sudo is not there; use --prefix \"\$HOME/.local\""; return 3; }
    sudo="sudo"
  fi

  tmpdir="$(mktemp -d)" || return 1
  url="${base%/}/v${version}/${asset}"
  log_info "Downloading Ollama $version ($asset)."
  if ! curl -fSL --progress-bar -o "$tmpdir/$asset" "$url"; then
    rm -rf "$tmpdir"
    log_error "ollama_install: download failed: $url"
    return 1
  fi
  if ! got="$(ollama_install_sha256 "$tmpdir/$asset")"; then
    rm -rf "$tmpdir"
    log_error "ollama_install: shasum, sha256sum or openssl is needed to check it"
    return 3
  fi
  if [[ "$got" != "$want" ]]; then
    rm -rf "$tmpdir"
    log_error "ollama_install: $asset $version does not match the pinned SHA-256 (got $got, want $want); nothing was installed. A changed CI_DEFAULT_OLLAMA_VERSION needs its CI_DEFAULT_OLLAMA_SHA256_* values too."
    return 1
  fi

  # Unpack into a staging directory first: a damaged archive or a full disk
  # must fail before anything installed is touched.
  mkdir -p "$tmpdir/stage" || { rm -rf "$tmpdir"; return 1; }
  case "$asset" in
    *.tar.zst)
      # bin/ollama and lib/ollama/, as the release lays them out.
      zstd -dc "$tmpdir/$asset" | tar -x -C "$tmpdir/stage" -f - || { rm -rf "$tmpdir"; log_error "ollama_install: unpacking $asset failed"; return 1; }
      [[ -x "$tmpdir/stage/bin/ollama" ]] || { rm -rf "$tmpdir"; log_error "ollama_install: $asset has no bin/ollama"; return 1; }
      ;;
    *.zip)
      # ollama.exe and lib\ollama\, as the release lays them out.
      unzip -q -o "$tmpdir/$asset" -d "$tmpdir/stage" || { rm -rf "$tmpdir"; log_error "ollama_install: unpacking $asset failed"; return 1; }
      [[ -f "$tmpdir/stage/ollama.exe" ]] || { rm -rf "$tmpdir"; log_error "ollama_install: $asset has no ollama.exe"; return 1; }
      ;;
    *.tgz)
      # The macOS archive is flat: ollama, llama-server and the libraries it
      # loads from beside itself. All of it goes to lib/ollama; bin/ollama
      # starts it from there, so it finds them.
      mkdir -p "$tmpdir/flat" && tar -x -z -C "$tmpdir/flat" -f "$tmpdir/$asset" || { rm -rf "$tmpdir"; log_error "ollama_install: unpacking $asset failed"; return 1; }
      [[ -x "$tmpdir/flat/ollama" ]] || { rm -rf "$tmpdir"; log_error "ollama_install: $asset has no ollama at its top"; return 1; }
      mkdir -p "$tmpdir/stage/bin" "$tmpdir/stage/lib/ollama" && cp -R "$tmpdir/flat/." "$tmpdir/stage/lib/ollama/" || { rm -rf "$tmpdir"; return 1; }
      printf '#!/bin/sh\nexec "%s/lib/ollama/ollama" "$@"\n' "$prefix" >"$tmpdir/stage/bin/ollama" && chmod 0755 "$tmpdir/stage/bin/ollama"
      ;;
  esac

  # Then replace. The old lib/ollama goes first: Ollama loads every library in
  # it, and the previous version's must not stay beside the new ones. Nothing
  # else in the prefix is touched.
  # A program that is running (the service's bin/ollama) cannot be written
  # over ("Text file busy"); it can be removed and replaced, and the running
  # one keeps its copy until restarted.
  local f
  for f in "$tmpdir"/stage/bin/*; do
    [[ -e "$f" ]] || continue
    [[ ! -e "$prefix/bin/${f##*/}" ]] || $sudo rm -f "$prefix/bin/${f##*/}" || { rm -rf "$tmpdir"; log_error "ollama_install: could not replace $prefix/bin/${f##*/}"; return 1; }
  done
  if ! $sudo mkdir -p "$prefix" || { [[ -d "$prefix/lib/ollama" ]] && ! $sudo rm -rf "$prefix/lib/ollama"; } \
    || ! $sudo cp -R "$tmpdir/stage/." "$prefix/"; then
    rm -rf "$tmpdir"; log_error "ollama_install: installing into $prefix failed"; return 1
  fi
  if [[ "$asset" == *.zip ]]; then
    rm -rf "$tmpdir"
    log_info "Ollama $version installed in $prefix. Add it to PATH, then run: ollama serve."
    return 0
  fi
  rm -rf "$tmpdir"
  log_info "Ollama $version installed at $prefix/bin/ollama."
  if [[ -n "$have" ]]; then
    log_info "Ollama $have was installed before: a running Ollama keeps that version until it is restarted (sudo systemctl restart ollama, where it is a service)."
  fi
  log_info "Start it with: ollama serve. To run it as a service, see https://github.com/ollama/ollama/blob/main/docs/linux.md."
  return 0
}
