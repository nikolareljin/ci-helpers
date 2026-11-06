#!/usr/bin/env bash
# docs_site.sh clean refuses a --venv that is not a virtualenv, and
# rust_release_build.sh refuses names that leave the artifact directory.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
check() {   # <description> <expected rc> <actual rc>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: exit $3, expected $2"; fail=1; fi
}

# A copy, so `clean` removes a ./site that is not this checkout's.
mkdir -p "$work/repo/scripts" "$work/repo/site"
cp "$root/scripts/docs_site.sh" "$work/repo/scripts/"
docs=("$work/repo/scripts/docs_site.sh")
export SCRIPT_HELPERS_DIR="$root/vendor/script-helpers"

mkdir -p "$work/precious"; touch "$work/precious/keep"
bash "${docs[@]}" clean --venv "$work/precious" >/dev/null 2>&1
check "clean refuses a directory with no pyvenv.cfg" 2 $?
[[ -f "$work/precious/keep" ]]; check "and leaves it in place" 0 $?
[[ -d "$work/repo/site" ]]; check "and leaves ./site in place" 0 $?

mkdir -p "$work/venv"; touch "$work/venv/pyvenv.cfg"
bash "${docs[@]}" clean --venv "$work/venv" >/dev/null 2>&1
check "clean removes a virtualenv" 0 $?
[[ ! -e "$work/venv" && ! -e "$work/repo/site" ]]; check "and ./site" 0 $?

bash "${docs[@]}" clean --venv "$work/absent" >/dev/null 2>&1
check "clean accepts a virtualenv that does not exist" 0 $?

mkdir -p "$work/mixed"; touch "$work/mixed/pyvenv.cfg" "$work/mixed/keep"
bash "${docs[@]}" clean --venv "$work/mixed" >/dev/null 2>&1
check "clean refuses a virtualenv made in a directory with other files" 2 $?
[[ -f "$work/mixed/keep" ]]; check "and keeps them" 0 $?

mkdir -p "$work/nocfg/lib"
bash "${docs[@]}" clean --venv "$work/nocfg" >/dev/null 2>&1
check "clean refuses venv-like directories with no pyvenv.cfg" 2 $?

mkdir -p "$work/empty"
bash "${docs[@]}" clean --venv "$work/empty" >/dev/null 2>&1
check "clean removes an empty directory" 0 $?

touch "$work/plain"
bash "${docs[@]}" clean --venv "$work/plain" >/dev/null 2>&1
check "clean refuses a file" 2 $?

mkdir -p "$work/real"; touch "$work/real/pyvenv.cfg"; mkdir -p "$work/real/bin" "$work/real/lib"
bash "${docs[@]}" clean --venv "$work/real" >/dev/null 2>&1
check "clean removes a full virtualenv" 0 $?
python3 -m venv --without-pip "$work/pyvenv" >/dev/null 2>&1
bash "${docs[@]}" clean --venv "$work/pyvenv" >/dev/null 2>&1
check "clean removes one python made" 0 $?

# A cargo stand-in, so a refused name is told from a failed build.
mkdir -p "$work/bin" "$work/rust"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/cargo"; chmod +x "$work/bin/cargo"
rust() { (cd "$work/rust" && PATH="$work/bin:$PATH" bash "$root/scripts/rust_release_build.sh" "$@" >/dev/null 2>&1); }

rust --bin-name ../evil --targets linux-gnu; check "--bin-name with a path is refused" 2 $?
rust --bin-name -evil --targets linux-gnu; check "--bin-name starting with - is refused" 2 $?
rust --bin-name a..b --targets linux-gnu; check "--bin-name with .. is refused" 2 $?
rust --bin-name tool --linux-gnu-aliases deb,../evil --targets linux-gnu; check "an alias with a path is refused" 2 $?

rust --bin-name tool --linux-gnu-aliases deb,-x --targets linux-gnu; check "an alias starting with - is refused" 2 $?
rust --bin-name tool --linux-gnu-aliases a..b --targets linux-gnu; check "an alias with .. is refused" 2 $?

mkdir -p "$work/rust/target/x86_64-unknown-linux-gnu/release"
touch "$work/rust/target/x86_64-unknown-linux-gnu/release/_tool"
rust --bin-name _tool --targets linux-gnu; check "a name Cargo allows with a leading _ builds" 0 $?
touch "$work/rust/target/x86_64-unknown-linux-gnu/release/my_tool+1.2"
rust --bin-name my_tool+1.2 --linux-gnu-aliases deb,yum --targets linux-gnu
check "a normal name and aliases build" 0 $?
[[ -f "$work/rust/artifacts/my_tool+1.2-linux" && -f "$work/rust/artifacts/my_tool+1.2-yum" ]]
check "and land in the artifact directory" 0 $?

exit "$fail"
