#!/usr/bin/env bash
# SCRIPT: install_foxguard.sh
# DESCRIPTION: Download the foxguard release binary for this runner, check it
#              against the sha256 pinned in scanner-pins.env (or the one given
#              for another version), and make it executable in a private
#              directory. Never a checksums file from the release: a replaced
#              release would bring its own.
#              Shared by the foxguard-scan and foxguard-diff actions, so the
#              pin table lives in one place.
# USAGE: FOXGUARD_VERSION=v0.14.1 [FOXGUARD_SHA256=<hex>] bash scripts/install_foxguard.sh
# PARAMETERS:
#   FOXGUARD_VERSION  Release tag, with or without the leading "v".
#   FOXGUARD_SHA256   Digest of the binary for this runner. Required for a
#                     version other than the pinned one; for the pinned
#                     version it may only repeat the pinned digest.
#   RUNNER_TEMP       Where the private install directory is created.
#   GITHUB_OUTPUT     When set, fg_bin=<path> is appended there.
# EXIT CODES:
#   0  Installed and verified.
#   1  Unsupported platform, missing or malformed digest, checksum mismatch
#      or failed download; nothing is left executable.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="$script_dir/../scanner-pins.env"
pin() { awk -F= -v k="$1" '$1 == k { print $2; exit }' "$pins"; }

# Normalize: strip any leading "v" then re-add it so both "v0.14.1"
# and "0.14.1" produce the correct release URL.
ver="${FOXGUARD_VERSION#v}"
tag="v${ver}"

# Map uname output to foxguard release asset naming. The release
# ships bare binaries, one per platform, no archive.
raw_os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "${arch}" in x86_64|amd64) arch="x86_64" ;; aarch64|arm64) arch="aarch64" ;; esac

case "${raw_os}" in
  linux)                os="linux"   ; ext="" ;;
  darwin)               os="macos"   ; ext="" ;;
  mingw*|msys*|cygwin*) os="windows" ; ext=".exe" ;;
  *)
    echo "::error::Unsupported runner OS '${raw_os}'. foxguard supports linux, darwin, and windows." >&2
    exit 1
    ;;
esac
if [ "${os}" = "windows" ] && [ "${arch}" != "x86_64" ]; then
  echo "::error::foxguard ${tag} publishes no windows ${arch} binary." >&2
  exit 1
fi

asset="foxguard-${os}-${arch}${ext}"
# A private directory per run: fixed /tmp paths are shared by every job
# on a self-hosted runner, so one job could swap another's binary.
if [ -n "${RUNNER_TEMP:-}" ]; then
  work=$(mktemp -d "${RUNNER_TEMP}/foxguard.XXXXXX")
else
  work=$(mktemp -d)
fi

# Direct download from GitHub Releases: no API auth needed for public repos.
base_url="https://github.com/0sec-labs/foxguard/releases/download/${tag}"
curl -fsSL "${base_url}/${asset}" -o "${work}/${asset}"

# Verify against a digest held in this repository, never one fetched
# beside the binary: a replaced release would bring its own checksums.
# scanner-pins.env holds the digests of one version, for each runner.
pinned=""
if [ "${ver}" = "$(pin FOXGUARD_VERSION)" ]; then
  pinned="$(pin "FOXGUARD_SHA256_$(printf '%s_%s' "${os}" "${arch}" | tr '[:lower:]' '[:upper:]')")"
fi
# First field only, lower-cased: a pasted checksums.txt line
# ("<hash>  <file>") or an upper-case digest still works.
expected="$(printf '%s' "${FOXGUARD_SHA256:-${pinned}}" | awk 'NR == 1 { print tolower($1) }')"
if [ -z "${expected}" ]; then
  echo "::error::No pinned sha256 for ${tag} ${asset}; pass foxguard_sha256 (its digest in that release's checksums.txt, checked against a second source). Refusing to run an unverified binary." >&2
  exit 1
fi
if [ "${#expected}" -ne 64 ] || [ -n "$(printf '%s' "${expected}" | tr -d '0-9a-f')" ]; then
  echo "::error::foxguard_sha256 must be 64 hex characters, got '${expected}'." >&2
  exit 1
fi
# A pinned version keeps its pin: the input may repeat it, never replace it.
if [ -n "${pinned}" ] && [ "${expected}" != "${pinned}" ]; then
  echo "::error::foxguard_sha256 differs from the digest pinned for ${tag} ${asset}; leave it empty or pass the pinned digest." >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  # From stdin: given a path with a backslash (a Windows RUNNER_TEMP),
  # Git Bash's sha256sum prefixes the hash with "\".
  actual=$(sha256sum < "${work}/${asset}" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 < "${work}/${asset}" | awk '{ print $1 }')
else
  echo "::error::Neither sha256sum nor shasum is available to verify ${asset}." >&2
  exit 1
fi
if [ "${actual}" != "${expected}" ]; then
  echo "::error::Checksum mismatch for ${asset}: expected ${expected}, got ${actual}." >&2
  exit 1
fi
echo "Verified ${asset} (sha256 ${actual})"

mkdir -p "${work}/bin"
FG_BIN="${work}/bin/foxguard${ext}"
mv "${work}/${asset}" "${FG_BIN}"
chmod +x "${FG_BIN}"
# An output, not GITHUB_ENV, which would also reach every later step
# of the caller's job.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "fg_bin=${FG_BIN}" >> "${GITHUB_OUTPUT}"
fi
