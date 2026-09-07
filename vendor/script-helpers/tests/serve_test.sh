#!/usr/bin/env bash
# SCRIPT: serve_test.sh
# DESCRIPTION: Smoke tests for lib/serve.sh (serve_static_site).
# USAGE: ./tests/serve_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/serve_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0

note()  { echo "[serve_test] $*"; }
error() { echo "[serve_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import serve

# 1) serve_static_site is defined once helpers.sh is sourced and the module imported.
if declare -f serve_static_site >/dev/null 2>&1; then
  note "serve_static_site is defined after sourcing helpers.sh"
else
  error "serve_static_site is not defined after sourcing helpers.sh"
fi

# 2) serve_static_site returns 2 for a missing directory.
# Create a temp dir then remove it so the path is guaranteed not to exist
# (a hard-coded /nonexistent could accidentally exist under some sandboxes).
missing_dir="$(mktemp -d)"
rmdir "$missing_dir"
set +e
serve_static_site "$missing_dir" 8000 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 2 ]]; then
  note "serve_static_site on a missing directory returns 2"
else
  error "serve_static_site on a missing directory returned $rc, expected 2"
fi

# 3) serve_static_site returns 2 for a non-numeric port.
set +e
serve_static_site "$root_dir" not-a-port >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 2 ]]; then
  note "serve_static_site with a non-numeric port returns 2"
else
  error "serve_static_site with a non-numeric port returned $rc, expected 2"
fi

if (( failures == 0 )); then
  note "All serve.sh tests passed."
else
  note "Found $failures failing serve.sh assertion(s)."
  exit 1
fi
