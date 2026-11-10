#!/usr/bin/env bash
# SCRIPT: setup_ruby_test.sh
# DESCRIPTION: scripts/setup_ruby.sh picks a Ruby from the runner's tool
#              cache the way ruby/setup-ruby did (X, X.Y and X.Y.Z, newest
#              match, the runner's architecture directory), writes PATH and
#              the outputs, names the cached versions when none matches, and
#              downloads nothing. The cache is a directory of stub rubies.
#              Runs under bash 3.2 (macOS runners).
# USAGE: bash tests/setup_ruby_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/setup_ruby.sh"
pins="$root/toolchain-pins.env"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# The shipped pins file names a fastlane release.
fastlane="$(awk -F= '$1 == "FASTLANE_VERSION" { print $2 }' "$pins")"
[[ "$fastlane" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL FASTLANE_VERSION is '$fastlane'"; fail=1; }

# cached <version> <arch> [reported]: a Ruby that reports its version.
cached() {
  local dir="$work/cache/Ruby/$1/$2/bin"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nprintf %%s "%s"\n' "${3:-$1}" > "$dir/ruby"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bundle"
  chmod +x "$dir/ruby" "$dir/bundle"
}
cached 3.2.6 x64
cached 3.3.5 x64
cached 3.4.1 x64
cached 3.3.5 arm64
# A directory with no bin/ruby is a partial install, never chosen.
mkdir -p "$work/cache/Ruby/3.4.9/x64"
# Not a version: ignored.
mkdir -p "$work/cache/Ruby/latest/x64/bin"

# run <name> <expected rc> <RUBY_VERSION> [RUNNER_ARCH] [cache dir]
run() {
  local name="$1" want="$2" version="$3" arch="${4:-X64}" cache="${5-$work/cache}" rc=0
  rm -rf "${work:?}/gh"; mkdir -p "$work/gh"
  RUBY_VERSION="$version" RUNNER_ARCH="$arch" RUNNER_TOOL_CACHE="$cache" \
    TOOLCHAIN_PINS="${TEST_PINS:-$pins}" \
    GITHUB_PATH="$work/gh/path" GITHUB_OUTPUT="$work/gh/out" \
    bash "$script" > "$work/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 1
  fi
  return 0
}
says() {
  grep -qF -- "$1" "$work/out" || { echo "FAIL $name: no '$1' in output:"; cat "$work/out"; fail=1; }
}
# chose <version> <arch>: the outputs and GITHUB_PATH name this Ruby.
chose() {
  local bin="$work/cache/Ruby/$1/$2/bin"
  grep -q "^ruby_version=$1$" "$work/gh/out" || { echo "FAIL $name: ruby_version output is not $1:"; cat "$work/gh/out"; fail=1; }
  grep -q "^ruby_bin=$bin$" "$work/gh/out" || { echo "FAIL $name: ruby_bin output is not $bin:"; cat "$work/gh/out"; fail=1; }
  grep -qxF "$bin" "$work/gh/path" || { echo "FAIL $name: $bin not appended to GITHUB_PATH"; fail=1; }
}

name="X.Y picks the newest X.Y.Z"
run "$name" 0 3.4 && chose 3.4.1 x64 && says "ruby 3.4.1 from"
grep -q "^fastlane_version=$fastlane$" "$work/gh/out" || { echo "FAIL $name: no fastlane_version output"; fail=1; }

name="X picks the newest X.Y.Z"
run "$name" 0 3 && chose 3.4.1 x64

name="X.Y.Z picks that release only"
run "$name" 0 3.2.6 && chose 3.2.6 x64

name="an X.Y.Z the cache does not hold names the cached versions"
run "$name" 1 3.2.7 && says "No Ruby 3.2.7 in the runner's tool cache for x64. Available: 3.2.6 3.3.5 3.4.1."

name="an X.Y the cache does not hold names the cached versions"
run "$name" 1 3.1 && says "Available: 3.2.6 3.3.5 3.4.1"

name="a partial install is not chosen"
run "$name" 1 3.4.9 && says "No Ruby 3.4.9"

name="the runner's architecture picks its own directory"
run "$name" 0 3.3 ARM64 && chose 3.3.5 arm64

name="a version cached for another architecture only is not found"
run "$name" 1 3.4 ARM64 && says "for arm64. Available: 3.3.5."

name="an architecture with no directory name"
run "$name" 2 3.4 s390x && says "has no tool cache directory name"

name="versions sort numerically, not as text"
cached 3.4.10 x64
run "$name" 0 3.4 && chose 3.4.10 x64
run "$name" 0 3 && chose 3.4.10 x64

name="a ruby that reports another version is refused"
cached 3.5.0 x64 3.5.1
run "$name" 1 3.5 && says "reports '3.5.1', not 3.5.0"

name="an empty cache"
mkdir -p "$work/empty"
run "$name" 1 3.4 X64 "$work/empty" && says "No Ruby in the runner's tool cache"

name="no RUNNER_TOOL_CACHE"
run "$name" 2 3.4 X64 "" && says "RUNNER_TOOL_CACHE is empty"

name="no version"
run "$name" 2 "" && says "RUBY_VERSION is empty"

name="a version that is not X, X.Y or X.Y.Z"
run "$name" 2 latest && says "is not X, X.Y or X.Y.Z"
run "$name" 2 3.4.1.2 && says "is not X, X.Y or X.Y.Z"
run "$name" 2 "3.4; rm -rf /" && says "is not X, X.Y or X.Y.Z"

name="a pins file without a fastlane version"
printf 'RUSTUP_VERSION=1.0.0\n' > "$work/pins.env"
TEST_PINS="$work/pins.env" run "$name" 2 3.4 && says "FASTLANE_VERSION in $work/pins.env is ''"

name="nothing is downloaded"
if grep -qE 'curl|wget|gem install|git clone' "$script"; then
  echo "FAIL $name: the script names a download tool"; fail=1
fi

[[ "$fail" = 0 ]] && echo "ok: setup_ruby picks the cached Ruby the action would, names the cached versions when none matches, and downloads nothing"
exit "$fail"
