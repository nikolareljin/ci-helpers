#!/usr/bin/env bash
# SCRIPT: install_dependency_check.sh
# DESCRIPTION: Download the dependency-check CLI release pinned in
#              scanner-pins.env, check the zip against the sha256 pinned
#              there, unpack it, and fetch the NVD data into a directory of
#              its own (--updateonly). The API key is read from NVD_API_KEY
#              and written to a mode 600 properties file, never to an
#              argument. No caller code runs: the CLI is pointed at no
#              project. A file over 60 MiB is stored as <name>.split-NNN
#              parts (publication-check's limit is 64 MiB per file).
# USAGE: NVD_API_KEY=... bash scripts/install_dependency_check.sh --data DIR [--pins FILE]
# PARAMETERS:
#   --data DIR   Directory for the NVD data (created; must not exist yet).
#   --pins FILE  Pins file (default: scanner-pins.env beside scripts/).
#   -h, --help   Show this help message.
# ENVIRONMENT:
#   NVD_API_KEY      Required. The NVD API key.
#   DC_DOWNLOAD_URL  Test hook: download from this URL instead of GitHub.
# EXIT CODES:
#   0  Data fetched.
#   1  Download, checksum, extraction or update failed.
#   2  Usage error or no pin.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="$script_dir/../scanner-pins.env"
data=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo "Error: --data requires a value." >&2; exit 2; }
      data="$2"; shift 2 ;;
    --pins)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo "Error: --pins requires a value." >&2; exit 2; }
      pins="$2"; shift 2 ;;
    -h|--help) grep '^#[^!]' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$data" ]] || { echo "::error::--data is required." >&2; exit 2; }
# An absolute path of plain characters, no .. component: it reaches the CLI's argv.
if [[ ! "$data" =~ ^/[A-Za-z0-9._/-]+$ || "/$data/" == */../* ]]; then
  echo "::error::--data '$data' is not an absolute path of letters, digits, '.', '_', '-' and '/'." >&2; exit 2
fi
[[ ! -e "$data" && ! -L "$data" ]] || { echo "::error::$data already exists." >&2; exit 2; }
[[ -n "${NVD_API_KEY:-}" ]] || { echo "::error::NVD_API_KEY is empty; dependency-check cannot update the NVD data without it." >&2; exit 2; }
[[ -r "$pins" ]] || { echo "::error::pins file not readable: $pins" >&2; exit 2; }

pin() { awk -F= -v k="$1" '$1 == k { print $2; exit }' "$pins"; }

version="$(pin DEPENDENCY_CHECK_VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::DEPENDENCY_CHECK_VERSION in $pins is '$version', not X.Y.Z." >&2; exit 2; }
expected="$(pin DEPENDENCY_CHECK_SHA256 | tr '[:upper:]' '[:lower:]')"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo "::error::No 64-hex DEPENDENCY_CHECK_SHA256 in $pins. Refusing to run an unverified CLI." >&2; exit 2; }

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dependency-check.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
zip="dependency-check-${version}-release.zip"
url="${DC_DOWNLOAD_URL:-https://github.com/dependency-check/DependencyCheck/releases/download/v${version}/${zip}}"
curl -fsSL "$url" -o "$work/$zip"

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum < "$work/$zip" | awk '{ print $1 }')"
else
  actual="$(shasum -a 256 < "$work/$zip" | awk '{ print $1 }')"
fi
if [[ "$actual" != "$expected" ]]; then
  echo "::error::Checksum mismatch for $zip: expected $expected, got $actual." >&2
  exit 1
fi
echo "Verified $zip (sha256 $actual)"

unzip -q "$work/$zip" -d "$work/cli"
cli="$work/cli/dependency-check/bin/dependency-check.sh"
[[ -f "$cli" && ! -L "$cli" ]] || { echo "::error::$zip holds no dependency-check/bin/dependency-check.sh." >&2; exit 1; }

props="$work/nvd.properties"
( umask 077; printf 'nvd.api.key=%s\n' "$NVD_API_KEY" > "$props" )
mkdir -p "$data"
chmod u+x "$cli"
"$cli" --updateonly --data "${data}" --propertyfile "$props" --disableOssIndex
# publication-check refuses a file over 64 MiB and the database is several
# hundred, so a large file leaves as <name>.split-NNN parts of 60 MiB; the
# scan job joins them after checking the manifest.
shopt -s globstar nullglob dotglob
for big in "$data"/**/*; do
  [[ -f "$big" && ! -L "$big" ]] || continue
  (( $(stat -c %s -- "$big") > 62914560 )) || continue
  [[ ! -e "${big}.split-000" ]] || { echo "::error::${big}.split-000 already exists." >&2; exit 1; }
  split -b 60M -d -a 3 -- "$big" "${big}.split-"
  rm -f -- "$big"
done
shopt -u globstar nullglob dotglob
echo "NVD data for dependency-check ${version} in $data"
