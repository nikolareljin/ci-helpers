#!/usr/bin/env bash
# SCRIPT: cloudflare_stage.sh
# DESCRIPTION: Copy what cloudflare-deploy.yml's deploy job uploads out of
#              the caller's working directory into OUT, which already holds
#              bundle/ (wrangler's dry-run output) for the Workers lane.
#              Workers: the deploy config to tree/<config> and the assets
#              directory to tree/<assets>. Pages: the directory to site/.
#              Only regular files that resolve under the working directory
#              are copied; a symlink, a special file or a name with a line
#              break is refused. Then large files are split
#              (artifact_parts.sh) and the sha256 manifest is printed.
# USAGE: bash scripts/cloudflare_stage.sh workers WORKDIR OUT CONFIG [ASSETS]
#        bash scripts/cloudflare_stage.sh pages WORKDIR OUT PAGES_DIR
#        Paths after OUT are relative to WORKDIR.
# OUTPUT: the manifest, `sha256sum` lines with ./<path>, on stdout.
# EXIT CODES: 0 staged, 1 a refusal, 2 a usage error.
# ----------------------------------------------------
set -euo pipefail
export LC_ALL=C
fail() { echo "::error::$*" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

lane="${1:-}"
case "$lane:$#" in workers:4|workers:5|pages:4) ;; *) echo "usage: see the header of $0" >&2; exit 2 ;; esac
work="$2" out="$3"
[[ -d "$work" && ! -L "$work" ]] || fail "the working directory is not a directory."
[[ -d "$out" && ! -L "$out" ]] || fail "$out is not a directory."
top="$(realpath -e -- "$work")"

relok() {
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.@+-]*(/[A-Za-z0-9_][A-Za-z0-9_.@+-]*)*$ ]] || fail "'$1' is not a plain relative path."
  [[ ! "/$1/" =~ /\.\.?/ ]] || fail "'$1' has a . or .. component."
}

stage_file() {  # stage_file <path under work> <dest path under out>
  local src="$top/$1" real
  [[ -f "$src" && ! -L "$src" ]] || fail "'$1' is not a regular file (symlinks are refused)."
  real="$(realpath -e -- "$src")"
  [[ "$real" == "$top"/* ]] || fail "'$1' resolves outside the working directory."
  mkdir -p -- "$(dirname -- "$out/$2")"
  cp -P -- "$src" "$out/$2"
}

stage_dir() {  # stage_dir <dir under work> <dest dir under out>
  local src="$top/$1" real f rel
  [[ -d "$src" && ! -L "$src" ]] || fail "'$1' is not a directory (symlinks are refused)."
  real="$(realpath -e -- "$src")"
  [[ "$real" == "$top/$1" ]] || fail "'$1' resolves outside the working directory."
  if [[ -n "$(find "$src" -mindepth 1 ! -type f ! -type d -print -quit)" ]]; then
    fail "'$1' holds a symlink or special file."
  fi
  if [[ -n "$(find "$src" -name "$(printf '*\n*')" -print -quit)" ]]; then
    fail "'$1' holds a file name with a line break."
  fi
  mkdir -p -- "$out/$2"
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    stage_file "$1/$rel" "$2/$rel"
  done < <(find "$src" -type f -print0)
}

if [[ "$lane" == workers ]]; then
  relok "$4"
  stage_file "$4" "tree/$4"
  if [[ -n "${5:-}" ]]; then
    relok "$5"
    stage_dir "$5" "tree/$5"
  fi
  [[ -d "$out/bundle" && ! -L "$out/bundle" ]] || fail "no bundle/ from the dry run."
else
  relok "$4"
  stage_dir "$4" site
fi

bash "$here/artifact_parts.sh" split "$out"
if [[ -n "$(find "$out" -mindepth 1 ! -type f ! -type d -print -quit)" ]]; then
  fail "the staged tree holds a symlink or special file."
fi
if [[ -n "$(find "$out" -name "$(printf '*\n*')" -print -quit)" ]]; then
  fail "a staged file name holds a line break."
fi
(cd "$out" && find . -type f | sort | while IFS= read -r f; do sha256sum -- "$f"; done)
