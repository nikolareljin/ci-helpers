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

if [[ $failures -gt 0 ]]; then
  echo "[install_dev_cli_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[install_dev_cli_test] all checks passed"
