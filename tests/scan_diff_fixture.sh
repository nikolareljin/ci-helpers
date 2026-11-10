#!/usr/bin/env bash
# SCRIPT: scan_diff_fixture.sh
# DESCRIPTION: Build the repositories the diff-scan self-tests run against.
#              Everything is generated when this runs: the keys come from
#              openssl, so no real-looking secret is committed to this tree
#              and none is on anyone's list of known example values.
#              `src` holds `main` (a clean README, two command injections,
#              one under vendor/, and one private key, all old) and one
#              branch per case; each branch is also cloned into <dir>/<branch>, where `main` is only
#              `origin/main`, as in a caller's checkout.
# USAGE: bash tests/scan_diff_fixture.sh <dir>
# PARAMETERS:
#   <dir>  Empty or absent directory to build in.
# BRANCHES:
#   clean          adds a clean file: both diffs pass, both full scans fail
#   new-secret     adds a key: gitleaks-diff fails, foxguard-diff passes
#   new-shell      adds shell=True: foxguard-diff fails, gitleaks-diff passes
#   moved          moves the old command injection down: foxguard-diff passes
#   added-removed  adds a key then removes it: gitleaks-diff fails
#   both           adds a key and shell=True: both diffs fail
#   head-config    adds configs that would silence both, plus both findings:
#                  both diffs fail (the configs are read from the base)
#   renamed        moves both old files to new paths: both diffs pass
#   renamed-new    renames old.py and adds shell=True to it: foxguard-diff fails
#   deleted        deletes old.py, leaving no file foxguard reads: it passes
#   ignored        adds shell=True in a file its own .gitignore names:
#                  foxguard-diff fails (foxguard would skip the file)
#   ignored-dot    the same with .ignore: foxguard-diff fails
#   hidden-new     adds shell=True under a dot directory: foxguard-diff
#                  fails (foxguard's walk skips hidden paths)
#   hidden-moved   moves old.py under a dot directory: foxguard-diff passes
#   noise-new      adds shell=True in vendor/x.py and build/y.py:
#                  foxguard-diff fails (foxguard's walk skips those paths)
#   minified-new   adds a command injection in a.min.js: foxguard-diff fails
#                  (foxguard skips that name even when it is named)
#   noise-moved    moves old.py into vendor/ and edits an old vendored file:
#                  foxguard-diff passes (the old findings stay old)
#   too-large      adds a parseable file over foxguard's 1 MiB limit:
#                  foxguard-diff fails (a file it would skip is refused)
#   head-ignore    adds a key and a .gitleaksignore naming that key's
#                  fingerprint: gitleaks-diff fails (gitleaks reads the tree's
#                  ignore list, so one that differs from the base's is refused)
# EXIT CODES:
#   0  Built.
#   1  git or openssl failed.
#   2  Usage error.
# ----------------------------------------------------
set -euo pipefail
umask 077

dir="${1:-}"
[[ -n "$dir" ]] || { echo "usage: $0 <dir>" >&2; exit 2; }
if [[ -e "$dir" && -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
  echo "$dir is not empty" >&2; exit 2
fi
mkdir -p "$dir"
dir="$(cd "$dir" && pwd -P)"
src="$dir/src"

# Identity for the fixture commits only; the caller's git config is not read.
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

g() { git -C "$src" "$@"; }
injection() { printf 'import subprocess\nimport sys\n\nsubprocess.run(sys.argv[1], shell=True)\n' > "$src/$1"; }
key() { openssl genrsa -out "$src/$1" 2048 2>/dev/null; }
branch() { g checkout -q main; g checkout -q -b "$1"; }

git init -q -b main "$src"
echo "# fixture" > "$src/README.md"
injection old.py
mkdir -p "$src/vendor"
injection vendor/lib.py
key old_key.pem
g add -A; g commit -q -m "base: one old finding of each kind"

branch clean
echo "x = 1" > "$src/clean.py"
g add -A; g commit -q -m "a clean file"

branch new-secret
key new_key.pem
g add -A; g commit -q -m "a new key"

branch new-shell
injection handler.py
g add -A; g commit -q -m "a new command injection"

branch moved
printf '# header\n# more\n\nimport subprocess\nimport sys\n\nsubprocess.run(sys.argv[1], shell=True)\n' > "$src/old.py"
g add -A; g commit -q -m "the old finding moves down three lines"

branch added-removed
key temp_key.pem
g add -A; g commit -q -m "a key, briefly"
g rm -q temp_key.pem
g commit -q -m "the key removed again"

branch both
key new_key.pem
injection handler.py
g add -A; g commit -q -m "a new key and a new command injection"

branch head-config
printf '[allowlist]\npaths = [".*"]\n' > "$src/.gitleaks.toml"
printf 'scan:\n  ignore_rules:\n    - id: py/no-command-injection\n' > "$src/.foxguard.yml"
key new_key.pem
injection handler.py
g add -A; g commit -q -m "configs that would silence both, and both"

branch head-ignore
key new_key.pem
g add -A; g commit -q -m "a new key"
# gitleaks git-mode fingerprint: <commit>:<path>:<rule>:<line>
printf '%s:new_key.pem:private-key:1\n' "$(g rev-parse HEAD)" > "$src/.gitleaksignore"
g add -A; g commit -q -m "an ignore list naming that key"

branch renamed
g mv old.py lib_old.py
g mv old_key.pem keys_old.pem
g commit -q -m "both old files renamed"

branch renamed-new
g mv old.py lib_old.py
printf 'subprocess.call(sys.argv[2], shell=True)\n' >> "$src/lib_old.py"
g add -A; g commit -q -m "old.py renamed, with a new command injection"

branch deleted
g rm -q old.py
g commit -q -m "the only file foxguard reads, deleted"

branch ignored
injection hidden.py
echo hidden.py > "$src/.gitignore"
g add -A -f; g commit -q -m "a new command injection its .gitignore names"

branch ignored-dot
injection hidden.py
printf 'hidden.py\n' > "$src/.ignore"
g add -A -f; g commit -q -m "a new command injection its .ignore names"

branch hidden-new
mkdir -p "$src/.tools"
injection .tools/run.py
g add -A; g commit -q -m "a new command injection under a dot directory"

branch hidden-moved
mkdir -p "$src/.tools"
g mv old.py .tools/old.py
g commit -q -m "old.py moved under a dot directory"

branch noise-new
mkdir -p "$src/vendor" "$src/build"
injection vendor/x.py
injection build/y.py
g add -A; g commit -q -m "new command injections where foxguard's walk does not look"

branch minified-new
printf 'const cp = require("child_process");\ncp.exec(process.argv[2]);\n' > "$src/a.min.js"
g add -A; g commit -q -m "a new command injection in a file name foxguard skips"

branch noise-moved
mkdir -p "$src/vendor"
g mv old.py vendor/old.py
printf '# edited\n' >> "$src/vendor/lib.py"
g add -A; g commit -q -m "old.py moved into vendor/, an old vendored file edited"

branch too-large
{ printf 'x = 1\n'; head -c 1048576 /dev/zero | tr '\0' '#'; printf '\n'; } > "$src/big.py"
g add -A; g commit -q -m "a file over foxguard's size limit"

g checkout -q main
for b in noise-new minified-new noise-moved too-large hidden-new hidden-moved renamed renamed-new deleted ignored ignored-dot clean new-secret new-shell moved added-removed both head-config head-ignore; do
  git clone -q --branch "$b" "$src" "$dir/$b"
done
echo "scan-diff fixture at $dir"
