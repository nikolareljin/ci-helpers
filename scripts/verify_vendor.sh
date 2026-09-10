#!/usr/bin/env bash
# SCRIPT: verify_vendor.sh
# DESCRIPTION: Verify vendor/script-helpers is usable, current, and free of upstream CI config.
# USAGE: ./scripts/verify_vendor.sh [--offline] [-h|--help]
# PARAMETERS:
#   --offline   Skip the upstream currency check (no network / no gh).
#   -h, --help  Show this help message.
# EXIT_CODES:
#   0  Vendored copy is usable and current.
#   1  A check failed. The failing check is named on stderr.
#   2  Bad arguments.
#
# NOTES:
#   Vendoring is only safe if something proves the copy still works. Syncing is
#   a file copy: it cannot tell you that a module this repository imports went
#   away upstream, or that an excluded path crept back in. This is that proof,
#   and it runs on every pull request.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendor/script-helpers"
SHA_LOCK="$ROOT_DIR/vendor/.script-helpers-sha"
REF_LOCK="$ROOT_DIR/vendor/.script-helpers-ref"
UPSTREAM_REPO="nikolareljin/script-helpers"

# Paths that must never appear in the vendored tree. Keep in step with
# VENDOR_EXCLUDES in sync_script_helpers.sh.
FORBIDDEN_PATHS=(".git" ".github")

OFFLINE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline) OFFLINE=true; shift ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

cd "$ROOT_DIR"
failures=0
ok()   { echo "[verify-vendor] $*"; }
bad()  { echo "[verify-vendor][ERROR] $*" >&2; failures=$((failures+1)); }

# 1) Structure -----------------------------------------------------------------
[[ -f "$VENDOR_DIR/helpers.sh" ]] \
  && ok "helpers.sh present" \
  || bad "vendor/script-helpers/helpers.sh is missing"

for lock in "$SHA_LOCK" "$REF_LOCK"; do
  if [[ -s "$lock" ]]; then
    ok "$(basename "$lock") = $(tr -d '[:space:]' < "$lock")"
  else
    bad "$(basename "$lock") is missing or empty"
  fi
done

# 2) Exclusions ----------------------------------------------------------------
# A vendored copy of upstream's CI cannot run from here, but it does reference
# this repository's reusable workflows, which reads as a second definition of
# our own CI.
for forbidden in "${FORBIDDEN_PATHS[@]}"; do
  if [[ -e "$VENDOR_DIR/$forbidden" ]]; then
    bad "vendor/script-helpers/$forbidden exists and must not be vendored"
  else
    ok "no vendored $forbidden"
  fi
done

if grep -rq "$UPSTREAM_REPO/../ci-helpers" "$VENDOR_DIR" 2>/dev/null \
   || grep -rq "nikolareljin/ci-helpers" "$VENDOR_DIR" 2>/dev/null; then
  bad "vendored tree references nikolareljin/ci-helpers (circular)"
  grep -rn "nikolareljin/ci-helpers" "$VENDOR_DIR" 2>/dev/null | head -5 >&2
else
  ok "vendored tree does not reference ci-helpers"
fi

# 3) Every module this repository imports must exist and load ------------------
# Derived from the scripts rather than hard-coded, so adding an import to a
# script here is enough to extend the check.
# This script's own shlib_import is a variable expansion, not a literal module
# list, so exclude it or it lands in the set as a bogus module name.
mapfile -t modules < <(
  grep -h '^\s*shlib_import ' scripts/*.sh 2>/dev/null \
    | grep -v 'modules\[@\]' \
    | sed 's/^\s*shlib_import //' | tr ' ' '\n' \
    | grep -E '^[a-z_][a-z0-9_]*$' | sort -u
)
if [[ ${#modules[@]} -eq 0 ]]; then
  bad "found no shlib_import lines in scripts/ - the check would pass vacuously"
else
  ok "modules required by scripts/: ${modules[*]}"
  for m in "${modules[@]}"; do
    [[ -f "$VENDOR_DIR/lib/$m.sh" ]] || bad "lib/$m.sh is imported but not vendored"
  done
  # Import them the way a real caller does, in one shell.
  if ( set -euo pipefail
       # shellcheck source=/dev/null
       source "$VENDOR_DIR/helpers.sh"
       shlib_import "${modules[@]}"
       declare -F log_info >/dev/null ) >/dev/null 2>&1; then
    ok "all required modules import cleanly"
  else
    bad "importing the required modules failed"
  fi
fi

# 4) The scripts that depend on the vendored copy must still run ---------------
# --help exercises the source + import path without side effects.
for script in scripts/*.sh; do
  grep -q 'vendor/script-helpers\|SCRIPT_HELPERS_DIR' "$script" 2>/dev/null || continue
  [[ "$script" == "scripts/verify_vendor.sh" ]] && continue
  if bash "$script" --help >/dev/null 2>&1; then
    ok "$(basename "$script") --help runs"
  else
    bad "$(basename "$script") --help failed against the vendored copy"
  fi
done

# 5) Currency ------------------------------------------------------------------
if [[ "$OFFLINE" == "true" ]]; then
  ok "skipping the upstream currency check (--offline)"
elif ! command -v gh >/dev/null 2>&1; then
  ok "gh not available; skipping the upstream currency check"
else
  pinned="$(tr -d '[:space:]' < "$SHA_LOCK" 2>/dev/null || true)"
  ref="$(tr -d '[:space:]' < "$REF_LOCK" 2>/dev/null || true)"
  if [[ "$ref" == "latest" ]]; then
    # Same pipeline as security-weekly's vendor-drift and sync_script_helpers.sh:
    # strip a leading v and sort numerically. `sort -V` alone puts every
    # v-prefixed tag after every bare one, so an old v0.2.0 won as "newest"
    # over 0.26.0 and this check refused a correct re-vendor.
    ref="$(gh api "repos/$UPSTREAM_REPO/tags" --jq '.[].name' 2>/dev/null \
           | { grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true; } \
           | awk '{ k=$0; gsub(/^v/,"",k); n=split(k,a,"."); printf "%010d%010d%010d %s\n",a[1],a[2],a[3],$0 }' \
           | sort -k1,1 | awk '{print $2}' | tail -n1 || true)"
  fi
  upstream="$(gh api "repos/$UPSTREAM_REPO/commits/$ref" --jq '.sha' 2>/dev/null || true)"
  if [[ -z "$upstream" ]]; then
    ok "could not resolve upstream ref '$ref'; skipping currency check"
  elif [[ "$pinned" == "$upstream" ]]; then
    ok "vendored copy is current with $ref ($upstream)"
  else
    bad "vendored copy is behind $ref: have $pinned, upstream $upstream - run scripts/sync_script_helpers.sh"
  fi
fi

if [[ $failures -gt 0 ]]; then
  echo "[verify-vendor] FAILED ($failures)" >&2
  exit 1
fi
echo "[verify-vendor] vendored script-helpers is usable and current"
