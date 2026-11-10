#!/usr/bin/env bash
# SCRIPT: setup_ruby.sh
# DESCRIPTION: Put a Ruby from the runner's tool cache on PATH, so a workflow
#              runs no third-party action for it. The version is matched the
#              way ruby/setup-ruby matched it: `3` picks the newest 3.y.z,
#              `3.4` the newest 3.4.z, `3.4.12` that release only. Nothing is
#              downloaded: a version the cache does not hold fails with the
#              versions it does. The fastlane gem version pinned in
#              toolchain-pins.env is written as an output for the step that
#              installs fastlane without a Gemfile.
# USAGE: RUBY_VERSION=<version> bash scripts/setup_ruby.sh
# ENVIRONMENT:
#   RUBY_VERSION       X, X.Y or X.Y.Z, optionally ruby-prefixed. Empty or
#                      `default` reads .ruby-version, .tool-versions or
#                      mise.toml in the current directory, as setup-ruby did;
#                      those file names are accepted as the value too.
#   RUNNER_TOOL_CACHE  The tool cache root (GitHub-hosted runners set it).
#   RUNNER_ARCH        X64 or ARM64 (set by the runner); else from uname -m.
#   TOOLCHAIN_PINS     Pins file (default: toolchain-pins.env beside scripts/).
#   GITHUB_PATH, GITHUB_OUTPUT  Written when set.
# OUTPUT: ruby_version=<the X.Y.Z chosen>, ruby_bin=<its bin directory>,
#         fastlane_version=<FASTLANE_VERSION from the pins file>, on stdout
#         and, when GITHUB_OUTPUT is set, appended there.
# EXIT CODES:
#   0  ruby is on PATH at the chosen version.
#   1  No cached Ruby matches, or the chosen one does not run.
#   2  Usage error: no version, a version not of the form X[.Y[.Z]], no tool
#      cache, an architecture this script does not map, no fastlane pin.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="${TOOLCHAIN_PINS:-$script_dir/../toolchain-pins.env}"
want="${RUBY_VERSION:-}"
cache="${RUNNER_TOOL_CACHE:-}"

# As ruby/setup-ruby did: empty or `default` reads .ruby-version, then
# .tool-versions, then mise.toml, in the current directory; those names are
# also accepted as the version; a `ruby-` prefix is dropped.
source_file=""
if [[ -z "$want" || "$want" == "default" ]]; then
  for f in .ruby-version .tool-versions mise.toml; do
    if [[ -f "$f" ]]; then want="$f"; break; fi
  done
  [[ -n "$want" && "$want" != "default" ]] || { echo "::error::RUBY_VERSION is empty and no .ruby-version, .tool-versions or mise.toml is in $(pwd); name a version such as 3.4 or 3.4.12." >&2; exit 2; }
fi
case "$want" in
  .ruby-version) source_file="$want"; want="$(head -n 1 "$want" | tr -d '[:space:]')" ;;
  .tool-versions) source_file="$want"; want="$(awk '$1 == "ruby" { print $2; exit }' "$want")" ;;
  mise.toml) source_file="$want"; want="$(sed -n 's/^[[:space:]]*ruby[[:space:]]*=[[:space:]]*["'"'"']\([^"'"'"']*\)["'"'"'].*/\1/p' "$want" | head -n 1)" ;;
esac
want="${want#ruby-}"
from="${source_file:+ (from $source_file)}"
[[ -n "$want" ]] || { echo "::error::RUBY_VERSION is empty$from; name a version such as 3.4 or 3.4.12." >&2; exit 2; }
[[ "$want" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "::error::RUBY_VERSION '$want'$from is not X, X.Y or X.Y.Z; only CRuby from the tool cache is supported." >&2; exit 2; }
[[ -z "$source_file" ]] || echo "Using Ruby $want from $source_file"
[[ -n "$cache" ]] || { echo "::error::RUNNER_TOOL_CACHE is empty; this script reads Ruby from the runner's tool cache and downloads nothing." >&2; exit 2; }
# Windows runners name it C:\hostedtoolcache\windows; a backslash is a glob
# escape, so Git Bash gets the /c/... form.
if command -v cygpath >/dev/null 2>&1; then
  cache="$(cygpath -u "$cache")"
fi

# The architecture directory under Ruby/<version>/, as the runner names it.
case "${RUNNER_ARCH:-$(uname -m)}" in
  X64|x86_64|amd64) arch=x64 ;;
  ARM64|aarch64|arm64) arch=arm64 ;;
  *) echo "::error::Architecture '${RUNNER_ARCH:-$(uname -m)}' has no tool cache directory name here; expected X64 or ARM64." >&2; exit 2 ;;
esac

# KEY=value, first match; comments and blank lines are not keys.
pin() {
  awk -F= -v k="$1" '$1 == k { print $2; exit }' "$pins"
}
[[ -f "$pins" ]] || { echo "::error::Pins file $pins is missing." >&2; exit 2; }
fastlane_version="$(pin FASTLANE_VERSION)"
[[ "$fastlane_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::FASTLANE_VERSION in $pins is '$fastlane_version', not X.Y.Z." >&2; exit 2; }

# Every X.Y.Z the cache holds for this architecture, newest last. A directory
# without bin/ruby (bin/ruby.exe on Windows) is a partial install and does
# not count.
available=""
if [[ -d "$cache/Ruby" ]]; then
  for dir in "$cache"/Ruby/*/; do
    v="$(basename "$dir")"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    [[ -x "$dir$arch/bin/ruby" || -x "$dir$arch/bin/ruby.exe" ]] || continue
    available="$available$v"$'\n'
  done
fi
available="$(printf '%s' "$available" | sort -t. -k1,1n -k2,2n -k3,3n)"

# The newest version equal to the request or under it: `3.4` is `3.4.*`.
chosen=""
case "$want" in
  *.*.*) pattern="$want" ;;
  *)     pattern="$want.*" ;;
esac
while IFS= read -r v; do
  [[ -n "$v" ]] || continue
  # shellcheck disable=SC2254  # the pattern is the version prefix on purpose
  case "$v" in
    $pattern) chosen="$v" ;;
  esac
done <<EOF
$available
EOF

if [[ -z "$chosen" ]]; then
  if [[ -n "$available" ]]; then
    have="$(printf '%s' "$available" | tr '\n' ' ')"
    echo "::error::No Ruby $want in the runner's tool cache for $arch. Available: ${have% }. Set ruby_version to one of these; this workflow downloads no Ruby." >&2
  else
    echo "::error::No Ruby in the runner's tool cache at $cache/Ruby for $arch. Set ruby_version to a version the runner image ships; this workflow downloads no Ruby." >&2
  fi
  exit 1
fi

bin="$cache/Ruby/$chosen/$arch/bin"
PATH="$bin:$PATH"
export PATH
reported="$("$bin/ruby" -e 'print RUBY_VERSION' 2>/dev/null || true)"
if [[ "$reported" != "$chosen" ]]; then
  echo "::error::$bin/ruby reports '$reported', not $chosen." >&2
  exit 1
fi
[[ -e "$bin/bundle" || -e "$bin/bundle.bat" ]] || { echo "::error::$bin holds no bundle; the cached Ruby $chosen is incomplete." >&2; exit 1; }
echo "ruby $chosen from $bin is on PATH"

bin_path="$bin"
if command -v cygpath >/dev/null 2>&1; then
  bin_path="$(cygpath -w "$bin")"
fi
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$bin_path" >> "$GITHUB_PATH"
fi
printf 'ruby_version=%s\nruby_bin=%s\nfastlane_version=%s\n' "$chosen" "$bin_path" "$fastlane_version"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'ruby_version=%s\nruby_bin=%s\nfastlane_version=%s\n' "$chosen" "$bin_path" "$fastlane_version" >> "$GITHUB_OUTPUT"
fi
