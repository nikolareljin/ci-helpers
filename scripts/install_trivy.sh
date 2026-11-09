#!/usr/bin/env bash
# SCRIPT: install_trivy.sh
# DESCRIPTION: Download the Trivy release pinned in scanner-pins.env, check the
#              archive against the sha256 pinned there, and unpack the binary
#              into a private directory. Optionally fetch the vulnerability
#              database into a cache directory beside it, so the scan that
#              follows can run with --skip-db-update --offline-scan.
#              No third-party action, no checksums file from the release.
# USAGE: bash scripts/install_trivy.sh [--download-db] [--dest DIR] [--pins FILE]
# PARAMETERS:
#   --download-db   Also run `trivy image --download-db-only` into the cache.
#   --dest DIR      Install under DIR (default: a new directory under
#                   RUNNER_TEMP, or mktemp -d).
#   --pins FILE     Pins file (default: scanner-pins.env beside scripts/).
#   -h, --help      Show this help message.
# OUTPUT: trivy_bin=<path> and cache_dir=<path>, on stdout and, when
#         GITHUB_OUTPUT is set, appended there.
# EXIT CODES:
#   0  Installed and verified.
#   1  Download, checksum or extraction failed; nothing is left executable.
#   2  Usage error, unsupported platform, or no pin for this platform.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="$script_dir/../scanner-pins.env"
dest=""
download_db=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --download-db) download_db=true; shift ;;
    --dest)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo "Error: --dest requires a value." >&2; exit 2; }
      dest="$2"; shift 2 ;;
    --pins)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo "Error: --pins requires a value." >&2; exit 2; }
      pins="$2"; shift 2 ;;
    -h|--help) grep '^#[^!]' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -r "$pins" ]] || { echo "::error::pins file not readable: $pins" >&2; exit 2; }

# KEY=value, first match; comments and blank lines are not keys.
pin() {
  awk -F= -v k="$1" '$1 == k { print $2; exit }' "$pins"
}

version="$(pin TRIVY_VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::TRIVY_VERSION in $pins is '$version', not X.Y.Z." >&2; exit 2; }

# uname to Trivy's release asset naming.
raw_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) asset_arch="64bit";  key_arch="64BIT" ;;
  aarch64|arm64) asset_arch="ARM64"; key_arch="ARM64" ;;
  *) echo "::error::Unsupported architecture '$arch'; Trivy is pinned for x86_64 and arm64." >&2; exit 2 ;;
esac
case "$raw_os" in
  linux)  asset_os="Linux"; key_os="LINUX" ;;
  darwin) asset_os="macOS"; key_os="MACOS" ;;
  *) echo "::error::Unsupported runner OS '$raw_os'; Trivy is pinned for Linux and macOS." >&2; exit 2 ;;
esac

archive="trivy_${version}_${asset_os}-${asset_arch}.tar.gz"
expected="$(pin "TRIVY_SHA256_${key_os}_${key_arch}" | tr '[:upper:]' '[:lower:]')"
if [[ ${#expected} -ne 64 || -n "$(printf '%s' "$expected" | tr -d '0-9a-f')" ]]; then
  echo "::error::No 64-hex sha256 pinned for $archive (TRIVY_SHA256_${key_os}_${key_arch} in $pins). Refusing to run an unverified binary." >&2
  exit 2
fi

# A private directory per run: fixed /tmp paths are shared by every job on a
# self-hosted runner, so one job could swap another's binary.
if [[ -z "$dest" ]]; then
  if [[ -n "${RUNNER_TEMP:-}" ]]; then
    dest="$(mktemp -d "${RUNNER_TEMP}/trivy.XXXXXX")"
  else
    dest="$(mktemp -d)"
  fi
fi
mkdir -p "$dest/bin" "$dest/cache"

url="https://github.com/aquasecurity/trivy/releases/download/v${version}/${archive}"
curl -fsSL "$url" -o "$dest/$archive"

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum < "$dest/$archive" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 < "$dest/$archive" | awk '{ print $1 }')"
else
  echo "::error::Neither sha256sum nor shasum is available to verify $archive." >&2
  exit 1
fi
if [[ "$actual" != "$expected" ]]; then
  rm -f "$dest/$archive"
  echo "::error::Checksum mismatch for $archive: expected $expected, got $actual." >&2
  exit 1
fi
echo "Verified $archive (sha256 $actual)"

tar -xzf "$dest/$archive" -C "$dest/bin" trivy
rm -f "$dest/$archive"
trivy_bin="$dest/bin/trivy"
chmod +x "$trivy_bin"
cache_dir="$dest/cache"

if [[ "$download_db" == true ]]; then
  # The one network step of a scan: the database comes from Aqua's registry
  # (ghcr.io, with Trivy's own mirror fallback) into this run's cache. The
  # scan itself then runs with --skip-db-update --offline-scan.
  "$trivy_bin" --cache-dir "$cache_dir" --quiet image --download-db-only
fi

printf 'trivy_bin=%s\ncache_dir=%s\n' "$trivy_bin" "$cache_dir"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'trivy_bin=%s\ncache_dir=%s\n' "$trivy_bin" "$cache_dir" >> "$GITHUB_OUTPUT"
fi
