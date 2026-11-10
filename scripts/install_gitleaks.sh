#!/usr/bin/env bash
# SCRIPT: install_gitleaks.sh
# DESCRIPTION: Download the gitleaks release archive for this runner, check it
#              against the sha256 pinned in scanner-pins.env (or the one given
#              for another version), and unpack the binary into a private
#              directory. Never a checksums file from the release: a replaced
#              release would bring its own.
#              Shared by the gitleaks-scan and gitleaks-diff actions, so the
#              pin table lives in one place.
# USAGE: GITLEAKS_VERSION=v8.30.1 [GITLEAKS_SHA256=<hex>] bash scripts/install_gitleaks.sh
# PARAMETERS:
#   GITLEAKS_VERSION  Release tag, with or without the leading "v".
#   GITLEAKS_SHA256   Digest of the archive for this runner. Required for a
#                     version other than the pinned one; for the pinned
#                     version it may only repeat the pinned digest.
#   RUNNER_TEMP       Where the private install directory is created.
#   GITHUB_OUTPUT     When set, gl_bin=<path> is appended there.
# EXIT CODES:
#   0  Installed and verified.
#   1  Unsupported platform, missing or malformed digest, checksum mismatch
#      or failed download; nothing is left executable.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="$script_dir/../scanner-pins.env"
pin() { awk -F= -v k="$1" '$1 == k { print $2; exit }' "$pins"; }

# Normalize: strip any leading "v" then re-add it so both "v8.30.1"
# and "8.30.1" produce the correct release URL.
ver="${GITLEAKS_VERSION#v}"
tag="v${ver}"

# Map uname output to gitleaks release asset naming
raw_os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "${arch}" in x86_64) arch="x64" ;; aarch64|arm64) arch="arm64" ;; esac

case "${raw_os}" in
  linux)                os="linux"   ; ext="tar.gz" ;;
  darwin)               os="darwin"  ; ext="tar.gz" ;;
  mingw*|msys*|cygwin*) os="windows" ; ext="zip"    ;;
  *)
    echo "::error::Unsupported runner OS '${raw_os}'. gitleaks supports linux, darwin, and windows." >&2
    exit 1
    ;;
esac

archive="gitleaks_${ver}_${os}_${arch}.${ext}"
# A private directory per run: fixed /tmp paths are shared by every job
# on a self-hosted runner, so one job could swap another's binary.
if [ -n "${RUNNER_TEMP:-}" ]; then
  work=$(mktemp -d "${RUNNER_TEMP}/gitleaks.XXXXXX")
else
  work=$(mktemp -d)
fi

# Direct download from GitHub Releases: no API auth needed for public repos.
# Using curl avoids the 401 that gh-cli triggers when github.token is scoped
# to a different repo than the one being downloaded from.
base_url="https://github.com/gitleaks/gitleaks/releases/download/${tag}"
curl -fsSL "${base_url}/${archive}" -o "${work}/${archive}"

# Verify against a digest held in this repository, never one fetched
# beside the archive: a replaced release would bring its own checksums.
# scanner-pins.env holds the digests of one version, for each runner.
pinned=""
if [ "${ver}" = "$(pin GITLEAKS_VERSION)" ]; then
  pinned="$(pin "GITLEAKS_SHA256_$(printf '%s_%s' "${os}" "${arch}" | tr '[:lower:]' '[:upper:]')")"
fi
# First field only, lower-cased: a pasted checksums.txt line
# ("<hash>  <file>") or an upper-case digest still works.
expected="$(printf '%s' "${GITLEAKS_SHA256:-${pinned}}" | awk 'NR == 1 { print tolower($1) }')"
if [ -z "${expected}" ]; then
  echo "::error::No pinned sha256 for ${archive}; pass gitleaks_sha256 (its digest in that release's checksums.txt, checked against a second source). Refusing to run an unverified binary." >&2
  exit 1
fi
if [ "${#expected}" -ne 64 ] || [ -n "$(printf '%s' "${expected}" | tr -d '0-9a-f')" ]; then
  echo "::error::gitleaks_sha256 must be 64 hex characters, got '${expected}'." >&2
  exit 1
fi
# A pinned version keeps its pin: the input may repeat it, never replace it.
if [ -n "${pinned}" ] && [ "${expected}" != "${pinned}" ]; then
  echo "::error::gitleaks_sha256 differs from the digest pinned for ${archive}; leave it empty or pass the pinned digest." >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  # From stdin: given a path with a backslash (a Windows RUNNER_TEMP),
  # Git Bash's sha256sum prefixes the hash with "\".
  actual=$(sha256sum < "${work}/${archive}" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 < "${work}/${archive}" | awk '{ print $1 }')
else
  echo "::error::Neither sha256sum nor shasum is available to verify ${archive}." >&2
  exit 1
fi
if [ "${actual}" != "${expected}" ]; then
  echo "::error::Checksum mismatch for ${archive}: expected ${expected}, got ${actual}." >&2
  exit 1
fi
echo "Verified ${archive} (sha256 ${actual})"

if [ "${ext}" = "zip" ]; then
  unzip -q "${work}/${archive}" -d "${work}/bin"
  GL_BIN="${work}/bin/gitleaks.exe"
else
  mkdir -p "${work}/bin"
  tar -xzf "${work}/${archive}" -C "${work}/bin" gitleaks
  GL_BIN="${work}/bin/gitleaks"
  chmod +x "${GL_BIN}"
fi
# An output, not GITHUB_ENV, which would also reach every later step
# of the caller's job.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "gl_bin=${GL_BIN}" >> "${GITHUB_OUTPUT}"
fi
