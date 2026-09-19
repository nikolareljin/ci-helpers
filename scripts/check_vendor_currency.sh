#!/usr/bin/env bash
# SCRIPT: check_vendor_currency.sh
# DESCRIPTION: Say when script-helpers has released something newer than the vendored copy, and offer to take it.
# USAGE: ./scripts/check_vendor_currency.sh [--offer] [--strict] [--quiet] [--force] [--max-age-hours <n>] [--repo-url <url>]
# PARAMETERS:
#   --offer              Ask whether to re-vendor, and do it on yes. Requires a terminal.
#   --strict             Exit 1 when the vendored copy is behind (default: report and exit 0).
#   --quiet              Say nothing when the copy is current.
#   --force              Ignore the throttle and check now.
#   --max-age-hours <n>  Skip if already checked within this many hours (default: 24).
#   --repo-url <url>     Upstream to query. Defaults to SCRIPT_HELPERS_REPO_URL or the public URL.
#   -h, --help           Show this help message.
# EXIT_CODES:
#   0  Current, or behind and not --strict, or the check did not run (CI, throttled, offline).
#   1  Behind, and --strict was given.
#   2  Bad arguments.
# ----------------------------------------------------
#
# Why this is a developer-time tool and not a CI check.
#
# vendor-check.yml deliberately does NOT test currency, and its header says why:
# an upstream release would otherwise turn every open pull request red for a
# reason unrelated to the change under review. That reasoning still holds, so
# this never runs in CI -- it exits early when $CI is set -- and it never fails
# a commit or a push by default.
#
# What it answers is the question nothing else does. security-weekly.yml's
# vendor-drift job catches a vendored tree that no longer matches its own
# recorded pin. While that pin is an explicit tag, nothing says "upstream has
# moved on since you pinned it". Re-vendoring stays a decision; this is what
# puts the decision in front of someone.
#
# `production` is the signal rather than the newest tag, because that is the ref
# consumers follow. A release candidate is never offered: the tag pattern below
# accepts X.Y.Z only, so a -rcN upstream is invisible here by construction.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}/vendor/script-helpers}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { display_help; }

REPO_URL="${SCRIPT_HELPERS_REPO_URL:-https://github.com/nikolareljin/script-helpers.git}"
OFFER=false
STRICT=false
QUIET=false
FORCE=false
MAX_AGE_HOURS=24

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --offer) OFFER=true; shift ;;
    --strict) STRICT=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --force) FORCE=true; shift ;;
    --max-age-hours)
      [[ $# -ge 2 ]] || { echo "Option $1 requires a value." >&2; exit 2; }
      MAX_AGE_HOURS="$2"; shift 2 ;;
    --repo-url)
      [[ $# -ge 2 ]] || { echo "Option $1 requires a value." >&2; exit 2; }
      REPO_URL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Never in CI. See the header.
if [[ -n "${CI:-}" ]]; then
  exit 0
fi

ref_file="$ROOT_DIR/vendor/.script-helpers-ref"
sha_file="$ROOT_DIR/vendor/.script-helpers-sha"
[[ -f "$ref_file" && -f "$sha_file" ]] || exit 0

pinned_ref="$(tr -d ' \t\n\r' < "$ref_file")"
pinned_sha="$(tr -d ' \t\n\r' < "$sha_file")"

# Throttle. A network round trip on every commit is a tax nobody agreed to.
# The stamp lives in .git/, which is never committed and never shared.
stamp="$ROOT_DIR/.git/.script-helpers-currency-checked"
if [[ "$FORCE" != true && -f "$stamp" ]]; then
  now="$(date +%s)"
  then_ts="$(tr -d ' \t\n\r' < "$stamp" 2>/dev/null || echo 0)"
  case "$then_ts" in (*[!0-9]*|"") then_ts=0 ;; esac
  if [[ $(( (now - then_ts) / 3600 )) -lt $MAX_AGE_HOURS ]]; then
    exit 0
  fi
fi

# Offline, or upstream unreachable, is not a failure: this is a courtesy.
if ! remote_out="$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null)"; then
  exit 0
fi
if ! prod_out="$(git ls-remote "$REPO_URL" 'refs/tags/production' 'refs/heads/production' 2>/dev/null)"; then
  prod_out=""
fi
date +%s > "$stamp" 2>/dev/null || true

# X.Y.Z only. A candidate is never offered.
sorted_tags="$(
  printf '%s\n' "$remote_out" \
    | awk '{print $2}' \
    | sed 's|refs/tags/||' \
    | { grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true; } \
    | awk '{ k=$0; gsub(/^v/,"",k); n=split(k,a,"."); printf "%010d%010d%010d %s\n",a[1],a[2],a[3],$0 }' \
    | sort -k1,1 \
    | awk '{print $2}'
)"
latest_tag="$(printf '%s\n' "$sorted_tags" | tail -1)"
[[ -n "$latest_tag" ]] || exit 0

# Which tag does production name? That is what consumers actually follow.
prod_sha="$(printf '%s\n' "$prod_out" | awk '$2 == "refs/tags/production" {print $1; exit}')"
[[ -n "$prod_sha" ]] || prod_sha="$(printf '%s\n' "$prod_out" | awk '$2 == "refs/heads/production" {print $1; exit}')"
prod_tag=""
if [[ -n "$prod_sha" ]]; then
  prod_tag="$(printf '%s\n' "$remote_out" | awk -v s="$prod_sha" '$1 == s {print $2}' | sed 's|refs/tags/||' \
    | { grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true; } | tail -1)"
fi

# Compare against production when it names a release, and against the newest
# tag otherwise -- a production ref that has not been cut yet should not read
# as "you are up to date".
target="${prod_tag:-$latest_tag}"

if [[ "$pinned_ref" == "$target" ]]; then
  [[ "$QUIET" == true ]] || log_info "vendor/script-helpers is current at ${pinned_ref}."
  exit 0
fi

if ! "$ROOT_DIR/scripts/semver_compare.sh" "${pinned_ref#v}" "${target#v}" >/dev/null 2>&1; then
  : # comparison is advisory; fall through to the report either way
fi
newer="$(printf '%s\n' "$sorted_tags" | awk -v p="$pinned_ref" 'found {print} $0 == p {found=1}')"
count="$(printf '%s\n' "$newer" | { grep -c . || true; })"

# A pin ahead of upstream's production means someone vendored a newer tag on
# purpose. Say so rather than inventing an update.
if [[ -z "$newer" && "$pinned_ref" != "$target" ]]; then
  [[ "$QUIET" == true ]] || log_warn "vendor/script-helpers is pinned to ${pinned_ref}, which is not behind ${target}. Nothing to offer."
  exit 0
fi

{
  echo
  echo "  script-helpers has moved on."
  echo
  echo "    vendored here   ${pinned_ref}  (${pinned_sha:0:8})"
  if [[ -n "$prod_tag" ]]; then
    echo "    production      ${prod_tag}"
  else
    echo "    production      <not a release tag>"
  fi
  echo "    newest release  ${latest_tag}"
  echo "    releases since  ${count}$( [[ -n "$newer" ]] && printf ' (%s)' "$(printf '%s\n' "$newer" | tr '\n' ' ' | sed 's/ $//')" )"
  echo
  echo "  Re-vendoring is a decision, not a chore: the copy is only safe while"
  echo "  scripts/verify_vendor.sh still passes against it."
  echo
  echo "    ./scripts/sync_script_helpers.sh --ref ${target}"
  echo "    ./scripts/verify_vendor.sh"
  echo
} >&2

if [[ "$OFFER" == true ]]; then
  if [[ ! -t 0 ]]; then
    log_warn "--offer needs a terminal; not prompting."
  else
    printf '  Re-vendor to %s now? [y/N] ' "$target" >&2
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|YES)
        "$ROOT_DIR/scripts/sync_script_helpers.sh" --ref "$target"
        "$ROOT_DIR/scripts/verify_vendor.sh"
        log_info "Re-vendored to ${target}. Review the diff under vendor/ before committing."
        exit 0
        ;;
      *) log_info "Left at ${pinned_ref}." ;;
    esac
  fi
fi

[[ "$STRICT" == true ]] && exit 1
exit 0
