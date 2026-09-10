#!/usr/bin/env bash
# SCRIPT: changelog_test.sh
# DESCRIPTION: Smoke tests for lib/changelog.sh (header check, extract, new section).
# USAGE: ./tests/changelog_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/changelog_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[changelog_test] $*"; }
error() { echo "[changelog_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import changelog

# 1) functions defined after import
for fn in changelog_check_header changelog_extract changelog_new_section; do
  if declare -f "$fn" >/dev/null 2>&1; then
    note "$fn is defined"
  else
    error "$fn is NOT defined"
  fi
done

# 2) bad args return exactly 2
set +e
changelog_check_header >/dev/null 2>&1;  [[ $? -eq 2 ]] || error "changelog_check_header with no args did not return 2"
changelog_extract >/dev/null 2>&1;       [[ $? -eq 2 ]] || error "changelog_extract with no args did not return 2"
changelog_new_section >/dev/null 2>&1;   [[ $? -eq 2 ]] || error "changelog_new_section with no args did not return 2"
set -e
note "bad arguments return 2"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 3) the canonical header passes and yields the version
cat > "$tmp/good.md" <<'EOF'
# Changelog

## [Unreleased]

## 2026-06-01 — v1.2.3

### Added

- The first thing.

## 2026-05-01 — v1.2.2

### Fixed

- Something old.
EOF
got="$(changelog_check_header "$tmp/good.md" 2>/dev/null)"
[[ "$got" == "1.2.3" ]] || error "check_header on a conforming file gave '$got' (expected 1.2.3)"
note "the canonical header passes and the Unreleased section is skipped"

# 4) the near-miss shapes are rejected — this is the whole point of the module
cat > "$tmp/keepachangelog.md" <<'EOF'
# Changelog

## [1.2.3] - 2026-06-01

- Added: something.
EOF
set +e
changelog_check_header "$tmp/keepachangelog.md" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || error "the keep-a-changelog header returned $status (expected 1)"

cat > "$tmp/hyphen.md" <<'EOF'
# Changelog

## 2026-06-01 - v1.2.3

- Added: something.
EOF
set +e
changelog_check_header "$tmp/hyphen.md" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || error "an ASCII hyphen in place of the em-dash returned $status (expected 1)"
note "non-conforming headers are rejected"

# 5) extract returns the body without the header, and fails on a missing version
body="$(changelog_extract "$tmp/good.md" 1.2.3 2>/dev/null)"
grep -q "The first thing." <<<"$body" || error "extract did not return the section body"
grep -q "Something old."   <<<"$body" && error "extract leaked the next section"
grep -q "^## "             <<<"$body" && error "extract included the header line"
set +e
changelog_extract "$tmp/good.md" 9.9.9 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || error "extract of a missing version returned $status (expected 1)"
note "extract returns just the requested section"

# 6) new_section inserts above the newest release and is idempotent
changelog_new_section "$tmp/good.md" 1.3.0 --date 2026-07-31 >/dev/null 2>&1 \
  || error "changelog_new_section failed"
head -n 5 "$tmp/good.md" | grep -q '^## 2026-07-31 — v1.3.0' \
  || error "the new section was not inserted near the top"
grep -q '^## \[Unreleased\]' "$tmp/good.md" \
  || error "the Unreleased placeholder was lost"
grep -q 'The first thing.' "$tmp/good.md" \
  || error "existing content was lost"

# cksum, not md5sum (GNU-only) or shasum (a perl script, absent on
# musl): this only needs to notice a change, and cksum is POSIX.
before="$(cksum < "$tmp/good.md")"
changelog_new_section "$tmp/good.md" 1.3.0 --date 2026-07-31 >/dev/null 2>&1
after="$(cksum < "$tmp/good.md")"
[[ "$before" == "$after" ]] || error "a second call for the same version changed the file"
note "new_section inserts correctly and is idempotent"

# 7) it creates the file when there is none
changelog_new_section "$tmp/fresh.md" 0.1.0 --date 2026-07-31 >/dev/null 2>&1 \
  || error "changelog_new_section did not create a missing file"
grep -q '^## 2026-07-31 — v0.1.0' "$tmp/fresh.md" \
  || error "the created file has no release section"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
