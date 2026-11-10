#!/usr/bin/env bash
# SCRIPT: setup_pnpm.sh
# DESCRIPTION: Put pnpm on PATH through corepack, which ships with Node, so a
#              workflow runs no third-party action for it. The version is
#              resolved in this order: PNPM_VERSION; else the root
#              package.json's devEngines.packageManager (name pnpm); else its
#              packageManager "pnpm@<version>[+<hash>]"; else refuse.
#              PNPM_VERSION that disagrees with packageManager is refused. A
#              packageManager hash goes to corepack as written, and corepack
#              refuses a download that does not match it.
# USAGE: PNPM_VERSION=<spec> bash scripts/setup_pnpm.sh
# ENVIRONMENT:
#   PNPM_VERSION       Version, range or dist-tag (`latest`); empty reads package.json.
#   PACKAGE_JSON_FILE  package.json to read, relative to GITHUB_WORKSPACE
#                      (default: package.json). A missing file is not an error.
#   GITHUB_WORKSPACE   The caller's checkout (default: the working directory).
#   RUNNER_TEMP        Where the pnpm shims are written (default: mktemp -d).
#   GITHUB_PATH, GITHUB_ENV, GITHUB_OUTPUT  Written when set.
# OUTPUT: pnpm_spec=<what corepack prepared>, pnpm_bin=<shim directory>, on
#         stdout and, when GITHUB_OUTPUT is set, appended there.
# EXIT CODES:
#   0  pnpm is on PATH at the resolved version.
#   1  corepack could not prepare it (download, hash mismatch, unknown version).
#   2  No version anywhere, two versions that disagree, no corepack or no node.
# ----------------------------------------------------
set -euo pipefail

version="${PNPM_VERSION:-}"
package_json="${PACKAGE_JSON_FILE:-package.json}"
workspace="${GITHUB_WORKSPACE:-$PWD}"

command -v node >/dev/null 2>&1 || { echo "::error::node is not on PATH; corepack needs it." >&2; exit 2; }
if ! command -v corepack >/dev/null 2>&1; then
  echo "::error::corepack is not on PATH. Node 16.9 to 24 ship it; Node 25 dropped it. Put a Node that ships corepack on PATH before this step, or install corepack." >&2
  exit 2
fi

# The two fields the action read, from the caller's root package.json. Not a
# jq dependency: node is here by the check above.
manager=""
dev_engines=""
if [[ -f "$workspace/$package_json" ]]; then
  fields="$(node -e '
const fs = require("fs");
const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const pm = typeof m.packageManager === "string" ? m.packageManager : "";
const de = m.devEngines && m.devEngines.packageManager;
const dev = de && de.name === "pnpm" && typeof de.version === "string" ? de.version : "";
process.stdout.write(pm + "\n" + dev + "\n");
' "$workspace/$package_json")"
  manager="$(printf '%s\n' "$fields" | sed -n 1p)"
  dev_engines="$(printf '%s\n' "$fields" | sed -n 2p)"
fi

# packageManager is `pnpm@<version>[+<hash>]`; the version alone for the
# comparison, the whole field for corepack so the hash is checked.
manager_version=""
case "$manager" in
  pnpm@*) manager_version="${manager#pnpm@}"; manager_version="${manager_version%%+*}" ;;
esac

if [[ -n "$version" ]]; then
  if [[ -n "$manager_version" && "$manager_version" != "$version" ]]; then
    echo "::error::Multiple versions of pnpm specified: '$version' in the workflow's pnpm_version and '$manager' in $package_json's packageManager. Remove one." >&2
    exit 2
  fi
  if [[ -n "$manager_version" ]]; then
    spec="$manager"
  else
    spec="pnpm@$version"
  fi
elif [[ -n "$dev_engines" ]]; then
  spec="pnpm@$dev_engines"
elif [[ -n "$manager_version" ]]; then
  spec="$manager"
else
  echo "::error::No pnpm version is specified. Set pnpm_version in the workflow, or packageManager or devEngines.packageManager in $package_json." >&2
  exit 2
fi

# Shims in a directory of this run's own, so no system directory is written.
if [[ -n "${RUNNER_TEMP:-}" ]]; then
  bin="$(mktemp -d "${RUNNER_TEMP}/pnpm-bin.XXXXXX")"
else
  bin="$(mktemp -d)"
fi

# No download prompt, and no refusal when the package.json names another
# manager: the workflow asked for pnpm, as it did with the action.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export COREPACK_ENABLE_STRICT=0

corepack enable --install-directory "$bin" pnpm
PATH="$bin:$PATH"
export PATH
echo "Preparing $spec with corepack $(corepack --version)"
corepack prepare "$spec" --activate

installed="$(pnpm --version)"
want="${spec#pnpm@}"; want="${want%%+*}"
if [[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].*)?$ && "$installed" != "$want" ]]; then
  echo "::error::corepack prepared $spec but pnpm --version says $installed." >&2
  exit 1
fi
echo "pnpm $installed is on PATH"

bin_path="$bin"
if command -v cygpath >/dev/null 2>&1; then
  bin_path="$(cygpath -w "$bin")"
fi
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$bin_path" >> "$GITHUB_PATH"
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'COREPACK_ENABLE_DOWNLOAD_PROMPT=0\nCOREPACK_ENABLE_STRICT=0\n' >> "$GITHUB_ENV"
fi
printf 'pnpm_spec=%s\npnpm_bin=%s\n' "$spec" "$bin_path"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'pnpm_spec=%s\npnpm_bin=%s\n' "$spec" "$bin_path" >> "$GITHUB_OUTPUT"
fi
