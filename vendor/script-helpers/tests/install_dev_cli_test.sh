#!/usr/bin/env bash
# SCRIPT: install_dev_cli_test.sh
# DESCRIPTION: Smoke tests for scripts/install_dev_cli.sh shim backup behaviour.
# USAGE: ./tests/install_dev_cli_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/install_dev_cli_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[install_dev_cli_test] $*"; }
error() { echo "[install_dev_cli_test][ERROR] $*" >&2; failures=$((failures+1)); }

ORIGINAL='echo "original script"'

# A shim is recognised the same way the installer recognises its own: by the
# `# Compatibility shim. Use ./dev ...` marker its re-run guard greps for. The
# body must also delegate to ./dev, which is what resolves a usable bash --
# asserting on scripts/cli.sh instead would pass while the shim bypassed that
# resolver in every consuming repo.
is_shim() {
  local f="$1"
  grep -q '^# Compatibility shim\. Use \./dev ' "$f" 2>/dev/null &&
    grep -q '/dev" ' "$f" 2>/dev/null
}

# A throwaway git repo with one root script to shim.
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q .
  printf '#!/usr/bin/env bash\n%s\n' "$ORIGINAL" > "$dir/start"
  chmod +x "$dir/start"
}

# Run the installer and fail the test if it exits non-zero. Discarding the
# status would let a hard error pass unnoticed whenever the file assertions
# happened to hold anyway.
run_installer() {
  local label="$1"; shift
  local rc=0
  bash scripts/install_dev_cli.sh "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    note "$label: installer exited 0"
  else
    error "$label: installer exited $rc"
  fi
}

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

# 1) First install backs the original up and leaves a shim behind.
repo="$tmp_root/once"
make_repo "$repo"
run_installer "first install" --repo "$repo" --shims start

if grep -q "$ORIGINAL" "$repo/start.pre-dev-cli" 2>/dev/null; then
  note "first run backs the original up to start.pre-dev-cli"
else
  error "first run did not preserve the original in start.pre-dev-cli"
fi
if is_shim "$repo/start"; then
  note "first run installs the shim"
else
  error "first run did not install the shim"
fi

# 2) Re-running must not overwrite that backup with the shim it just wrote.
#    Regression: `mv "$dest" "$dest.pre-dev-cli"` ran unconditionally, so a
#    second install replaced the only copy of the caller's script.
run_installer "re-install" --repo "$repo" --shims start

if grep -q "$ORIGINAL" "$repo/start.pre-dev-cli" 2>/dev/null; then
  note "second run preserves the original backup"
else
  error "second run destroyed the original backup (it now holds the shim)"
fi
if is_shim "$repo/start"; then
  note "second run leaves the shim in place"
else
  error "second run did not leave a shim at start"
fi

# 3) A pre-existing .pre-dev-cli next to a file we did not write must not be
#    treated as our own shim. Deleting $dest there would destroy a real script
#    while its backup slot is already occupied -- nothing may be touched.
guard="$tmp_root/guard"
make_repo "$guard"
printf '#!/usr/bin/env bash\necho "unrelated pre-existing backup"\n' > "$guard/start.pre-dev-cli"
run_installer "foreign backup" --repo "$guard" --shims start

if grep -q "$ORIGINAL" "$guard/start" 2>/dev/null; then
  note "a real script is left intact when a foreign .pre-dev-cli exists"
else
  error "the real script at start was destroyed when a foreign .pre-dev-cli existed"
fi
if grep -q 'unrelated pre-existing backup' "$guard/start.pre-dev-cli" 2>/dev/null; then
  note "the foreign .pre-dev-cli is left intact"
else
  error "the foreign .pre-dev-cli was overwritten"
fi

# 4) --dry-run must not touch anything.
dry="$tmp_root/dry"
make_repo "$dry"
run_installer "dry run" --repo "$dry" --shims start --dry-run

if [[ ! -e "$dry/start.pre-dev-cli" ]] && grep -q "$ORIGINAL" "$dry/start"; then
  note "--dry-run leaves the tree untouched"
else
  error "--dry-run modified the tree"
fi

# 5) A shim named after the entry point, or written as a path, is refused --
#    and refused before anything is touched. `--shims dev` used to move the real
#    ./dev to dev.pre-dev-cli and replace it with a shim that ran `./dev dev`:
#    an exec loop, with the entry point already moved aside. A bad name found
#    halfway through the list would leave the earlier shims installed, so the
#    whole list is checked first: `start` here must not be shimmed either.
loop="$tmp_root/loop"
make_repo "$loop"
rc=0; bash scripts/install_dev_cli.sh --repo "$loop" --shims start,dev >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 ]]; then
  note "--shims dev: refused with exit 2"
else
  error "--shims dev: expected exit 2, got $rc"
fi
if [[ -e "$loop/dev" ]] && ! is_shim "$loop/dev"; then
  note "--shims dev: ./dev is not a shim"
elif [[ ! -e "$loop/dev" ]]; then
  # The refusal came before the template was installed at all: also fine.
  note "--shims dev: ./dev was not written"
else
  error "--shims dev: ./dev was replaced by a shim that would exec itself"
fi
[[ ! -e "$loop/dev.pre-dev-cli" ]] \
  && note "--shims dev: the entry point was not moved aside" \
  || error "--shims dev: ./dev was moved to dev.pre-dev-cli"
if grep -q "$ORIGINAL" "$loop/start" && [[ ! -e "$loop/start.pre-dev-cli" ]]; then
  note "--shims dev: the list was refused whole -- start was not shimmed"
else
  error "--shims dev: start was shimmed before the bad name was found"
fi

rc=0; bash scripts/install_dev_cli.sh --repo "$loop" --shims ../escape >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] \
  && note "--shims ../escape: a path is refused with exit 2" \
  || error "--shims ../escape: expected exit 2, got $rc"
[[ ! -e "$tmp_root/escape" ]] \
  && note "--shims ../escape: nothing written outside the repository" \
  || error "--shims ../escape: wrote a file outside the repository"

# 6) A refused list must leave the repository untouched -- including the entry
#    point. Validation used to run after dev, scripts/cli.sh and
#    scripts/_bootstrap.sh had been written, so exit 2 still modified the tree.
pristine="$tmp_root/pristine"
make_repo "$pristine"
rc=0; bash scripts/install_dev_cli.sh --repo "$pristine" --shims dev >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 && ! -e "$pristine/dev" && ! -e "$pristine/scripts/cli.sh" && ! -e "$pristine/scripts/_bootstrap.sh" ]]; then
  note "refused list: nothing was written, not even the entry point"
else
  error "refused list: exit $rc, and the tree was modified before the refusal (dev=$([[ -e $pristine/dev ]] && echo yes || echo no) cli.sh=$([[ -e $pristine/scripts/cli.sh ]] && echo yes || echo no))"
fi

# 7) A shim name that is a symlink -- dangling here -- must not be written
#    through. `-e` is false for a dangling link, so the old code fell to the
#    write, which followed the link and created the shim outside the repository.
sym="$tmp_root/sym"
make_repo "$sym"
mkdir -p "$tmp_root/outside"
rm -f "$sym/start"                      # make_repo seeded a real one
ln -s "$tmp_root/outside/missing" "$sym/start"
rc=0; bash scripts/install_dev_cli.sh --repo "$sym" --shims start >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] \
  && note "symlink shim: refused with exit 2" \
  || error "symlink shim: expected exit 2, got $rc"
[[ ! -e "$tmp_root/outside/missing" ]] \
  && note "symlink shim: nothing was written through the link" \
  || error "symlink shim: the shim was written outside the repository via the link"
[[ -L "$sym/start" ]] \
  && note "symlink shim: the link itself is left in place" \
  || error "symlink shim: the link was replaced or removed"

# 8) Three more names the pre-write pass must refuse whole, so that `start`,
#    listed first, is never shimmed: the reserved backup suffix, an existing
#    directory (.git here -- which the old code moved to .git.pre-dev-cli and
#    replaced with a file), and a symlink later in the list.
for bad in start.pre-dev-cli .git; do
  r="$tmp_root/bad_$RANDOM"
  make_repo "$r"
  rc=0; bash scripts/install_dev_cli.sh --repo "$r" --shims "start,$bad" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 2 && ! -e "$r/dev" && ! -e "$r/start.pre-dev-cli" && -d "$r/.git" && ! -e "$r/.git.pre-dev-cli" ]] && grep -q "$ORIGINAL" "$r/start"; then
    note "--shims start,$bad: refused with exit 2 and nothing touched"
  else
    error "--shims start,$bad: exit $rc; dev=$([[ -e $r/dev ]] && echo yes || echo no) start-backup=$([[ -e $r/start.pre-dev-cli ]] && echo yes || echo no) .git-dir=$([[ -d $r/.git ]] && echo yes || echo no)"
  fi
done
r="$tmp_root/badlink"
make_repo "$r"
ln -s "$tmp_root/outside/missing2" "$r/link"
rc=0; bash scripts/install_dev_cli.sh --repo "$r" --shims start,link >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 && ! -e "$r/dev" && ! -e "$r/start.pre-dev-cli" && ! -e "$tmp_root/outside/missing2" ]] && grep -q "$ORIGINAL" "$r/start"; then
  note "--shims start,link: a symlink later in the list is refused before start is touched"
else
  error "--shims start,link: exit $rc; dev=$([[ -e $r/dev ]] && echo yes || echo no) start-backup=$([[ -e $r/start.pre-dev-cli ]] && echo yes || echo no) escaped=$([[ -e $tmp_root/outside/missing2 ]] && echo yes || echo no)"
fi

# 9) The entry point's own destinations get the same guard. A dangling symlink
#    at ./dev is neither -f nor -e, so install_file reached cp, which followed
#    it and wrote the template outside the repository.
core="$tmp_root/core"
make_repo "$core"
ln -s "$tmp_root/outside/dev-escape" "$core/dev"
rc=0; bash scripts/install_dev_cli.sh --repo "$core" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] \
  && note "dangling symlink at ./dev: refused with exit 2" \
  || error "dangling symlink at ./dev: expected exit 2, got $rc"
[[ ! -e "$tmp_root/outside/dev-escape" ]] \
  && note "dangling symlink at ./dev: nothing was written through it" \
  || error "dangling symlink at ./dev: the template was written outside the repository via the link"
[[ ! -e "$core/scripts/cli.sh" ]] \
  && note "dangling symlink at ./dev: refused before any core file was written" \
  || error "dangling symlink at ./dev: scripts/cli.sh was written before the refusal"

if [[ $failures -gt 0 ]]; then
  echo "[install_dev_cli_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[install_dev_cli_test] all checks passed"
