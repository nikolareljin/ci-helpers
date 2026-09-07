#!/usr/bin/env bash
# SCRIPT: svg_test.sh
# DESCRIPTION: Smoke tests for lib/svg.sh (svg_rasterize).
# USAGE: ./tests/svg_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/svg_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[svg_test] $*"; }
error() { echo "[svg_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import svg

# 1) functions defined after import
for fn in svg_rasterizer svg_rasterize svg_rasterize_sizes; do
  if declare -f "$fn" >/dev/null 2>&1; then
    note "$fn is defined"
  else
    error "$fn is NOT defined"
  fi
done

# 2) bad args return exactly 2
set +e
svg_rasterize >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 2 ]]; then
  note "missing args return 2"
else
  error "missing args returned $status (expected 2)"
fi

# 3) invalid sizes return exactly 2 (before any rasterizer is needed)
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/in.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#1D3A5F"/></svg>
EOF

for invalid_size in 0 -1 1.5 abc; do
  set +e
  svg_rasterize "$tmp/in.svg" "$tmp/out.png" "$invalid_size" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 2 ]]; then
    note "invalid size '$invalid_size' returns 2"
  else
    error "invalid size '$invalid_size' returned $status (expected 2)"
  fi
done

# 4) if a rasterizer is available, render a real PNG
if svg_rasterizer >/dev/null 2>&1; then
  if svg_rasterize "$tmp/in.svg" "$tmp/out.png" 64 >/dev/null 2>&1 && [[ -s "$tmp/out.png" ]]; then
    note "svg_rasterize produced a non-empty PNG"
  else
    error "svg_rasterize failed to produce a PNG"
  fi
else
  note "no rasterizer installed — skipping render assertion (not a failure)"
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
