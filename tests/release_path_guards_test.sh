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

mkdir -p "$work/hidden"; touch "$work/hidden/pyvenv.cfg" "$work/hidden/.keep"
bash "${docs[@]}" clean --venv "$work/hidden" >/dev/null 2>&1
check "clean refuses a hidden file beside pyvenv.cfg" 2 $?

mkdir -p "$work/nog"; touch "$work/nog/keep"
env SHELLOPTS=noglob bash "${docs[@]}" clean --venv "$work/nog" >/dev/null 2>&1
check "inherited noglob does not read as empty" 2 $?
[[ -f "$work/nog/keep" ]]; check "and keeps the files" 0 $?

mkdir -p "$work/dot"; touch "$work/dot/pyvenv.cfg"
mkdir -p "$work/repo/site"
bash "${docs[@]}" clean --venv "$work/dot/." >/dev/null 2>&1
check "a final . is refused" 2 $?
[[ -d "$work/repo/site" ]]; check "before ./site goes" 0 $?

ln -s "$work/gone" "$work/dangling"
bash "${docs[@]}" clean --venv "$work/dangling" >/dev/null 2>&1
check "a dangling link is removed" 0 $?
[[ ! -L "$work/dangling" ]]; check "the link is gone" 0 $?

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
if python3 -m venv --without-pip "$work/pyvenv" >/dev/null 2>&1; then
  bash "${docs[@]}" clean --venv "$work/pyvenv" >/dev/null 2>&1
  check "clean removes one python made" 0 $?
  [[ ! -e "$work/pyvenv" ]]; check "and it is gone" 0 $?
else
  echo "skip clean of a real virtualenv: python3 -m venv failed"
fi

# Layout `uv venv` and `virtualenv` write.
mkdir -p "$work/uv/bin" "$work/uv/lib"; touch "$work/uv/pyvenv.cfg" "$work/uv/CACHEDIR.TAG" "$work/uv/.gitignore" "$work/uv/.lock"
bash "${docs[@]}" clean --venv "$work/uv" >/dev/null 2>&1
check "clean removes a uv or virtualenv layout" 0 $?

# DOCS_VENV has no dash check of its own; find once read this as a predicate
# and reported it empty.
mkdir -p "$work/repo/-foo"; touch "$work/repo/-foo/precious"
(cd "$work/repo" && DOCS_VENV=-foo bash scripts/docs_site.sh clean >/dev/null 2>&1)
check "DOCS_VENV with a leading dash is refused" 2 $?
[[ -f "$work/repo/-foo/precious" ]]; check "and keeps its files" 0 $?

if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$work/repo/site" "$work/locked"; touch "$work/locked/keep"; chmod 000 "$work/locked"
  bash "${docs[@]}" clean --venv "$work/locked" >/dev/null 2>&1
  check "a directory it cannot list is refused" 2 $?
  [[ -d "$work/repo/site" ]]; check "and ./site stays" 0 $?
  chmod 700 "$work/locked"
fi

mkdir -p "$work/target/bin"; touch "$work/target/pyvenv.cfg"; ln -s "$work/target" "$work/link"
bash "${docs[@]}" clean --venv "$work/link/" >/dev/null 2>&1
check "a link with a trailing slash is accepted" 0 $?
[[ ! -e "$work/link" && -f "$work/target/pyvenv.cfg" ]]; check "only the link goes" 0 $?

# A cargo stand-in, so a refused name is told from a failed build.
mkdir -p "$work/bin" "$work/rust"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/cargo"; chmod +x "$work/bin/cargo"
rust() { (cd "$work/rust" && PATH="$work/bin:$PATH" bash "$root/scripts/rust_release_build.sh" "$@" >/dev/null 2>&1); }

rust --bin-name ../evil --targets linux-gnu; check "--bin-name with a path is refused" 2 $?
rust --bin-name -evil --targets linux-gnu; check "--bin-name starting with - is refused" 2 $?
rust --bin-name "$(printf 'tool\303\251')" --targets linux-gnu; check "--bin-name outside ASCII is refused" 2 $?
rust --bin-name; check "--bin-name with no value exits 2" 2 $?
rust --bin-name tool --linux-gnu-aliases "$(printf 'deb\n../evil')" --targets linux-gnu; check "aliases over two lines are refused" 2 $?
for loc in $(locale -a 2>/dev/null | grep -i -E '^(en_[A-Z]{2}|el_GR)\.utf-?8$' | head -1); do
  (export LC_ALL="$loc"; rust --bin-name "$(printf 'tool\303\251')" --targets linux-gnu); check "and under $loc" 2 $?
done
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
