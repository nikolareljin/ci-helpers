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
for fn in changelog_check_header changelog_extract changelog_has_entries changelog_new_section; do
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

# 5b) a version is matched whole, not as a substring of another version. This
# was `index(line, want) > 0`, so asking for 0.2.0 returned the body of a
# v10.2.0 section -- the release notes for one version being another's.
cat > "$tmp/collide.md" <<'MD'
# Changelog

## 2026-09-10 — v10.2.0

- ten point two.

## 2026-01-01 — v0.2.0

- zero point two.
MD
body="$(changelog_extract "$tmp/collide.md" 0.2.0 2>/dev/null)"
grep -q "zero point two." <<<"$body" || error "0.2.0 did not select its own section"
grep -q "ten point two."  <<<"$body" && error "0.2.0 matched the v10.2.0 section"
body="$(changelog_extract "$tmp/collide.md" 10.2.0 2>/dev/null)"
grep -q "ten point two." <<<"$body" || error "10.2.0 did not select its own section"
# The dots are literal, not regex wildcards.
set +e
changelog_extract "$tmp/collide.md" 0X2Y0 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || error "0X2Y0 matched a section, so the dots are being read as wildcards"
note "a version matches whole, with literal dots"

# 5c) a pre-release is a different version. With `-` counted as a boundary,
# asking for 0.2.0 returned the v0.2.0-rc.1 section, so a final release with no
# section of its own passed the gate and shipped the rc's notes.
cat > "$tmp/rc.md" <<'MD'
# Changelog

## 2026-09-01 — v0.2.0-rc.1

- the release candidate.

## 2026-01-01 — v0.1.0

- the old one.
MD
set +e
body="$(changelog_extract "$tmp/rc.md" 0.2.0 2>/dev/null)"
status=$?
set -e
[[ "$status" -eq 1 ]] || error "0.2.0 found a section in a file that only has v0.2.0-rc.1 (returned $status)"
grep -q "the release candidate." <<<"$body" && error "0.2.0 returned the v0.2.0-rc.1 body"
body="$(changelog_extract "$tmp/rc.md" 0.2.0-rc.1 2>/dev/null)"
grep -q "the release candidate." <<<"$body" || error "0.2.0-rc.1 did not select its own section"
note "a pre-release section does not stand in for the final version"

# 5d) every header shape the function documents, including a bare version --
# the one shape whose leading boundary is the start of the line.
cat > "$tmp/shapes.md" <<'MD'
# Changelog

## 3.0.0

- bare.

## [2.0.0] - 2026-02-02

- bracketed.

## 1.0.0+build.7

- build metadata.
MD
grep -q "bare."       <<<"$(changelog_extract "$tmp/shapes.md" 3.0.0 2>/dev/null)"  || error "a bare '## 3.0.0' header was not found"
grep -q "bracketed."  <<<"$(changelog_extract "$tmp/shapes.md" v2.0.0 2>/dev/null)" || error "a '## [2.0.0] - date' header was not found"
grep -q "build metadata." <<<"$(changelog_extract "$tmp/shapes.md" 1.0.0+build.7 2>/dev/null)" \
  || error "a version with + build metadata did not match its own header"
set +e
changelog_extract "$tmp/shapes.md" 1.0.0+build7 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || error "1.0.0+build7 matched 1.0.0+build.7, so the dot is still a wildcard"
note "bare, bracketed and build-metadata headers all match"

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

# 6b) its "already there" check uses the same whole-version rule. It was a
# substring match, so a v10.2.0 section made 0.2.0 look present: it logged
# "already has a section", returned 0, and wrote nothing.
cp "$tmp/collide.md" "$tmp/collide_new.md"
sed -i.bak '/v0\.2\.0$/,$d' "$tmp/collide_new.md" && rm -f "$tmp/collide_new.md.bak"
changelog_new_section "$tmp/collide_new.md" 0.2.0 --date 2026-09-12 >/dev/null 2>&1 \
  || error "changelog_new_section failed beside a v10.2.0 section"
grep -q '^## 2026-09-12 — v0.2.0$' "$tmp/collide_new.md" \
  || error "new_section treated 0.2.0 as present because v10.2.0 exists"
note "new_section is not fooled by a version it is a substring of"

# 6c) a section existing is not a section saying something. new_section's
# template is a header over empty headings; that must not count as release notes.
printf '# Changelog\n\n' > "$tmp/fresh_template.md"
changelog_new_section "$tmp/fresh_template.md" 0.9.0 --date 2026-09-13 >/dev/null 2>&1
template="$(changelog_extract "$tmp/fresh_template.md" 0.9.0)"
changelog_has_entries "$template" && error "changelog_has_entries accepted the empty new_section template"
changelog_has_entries ""          && error "changelog_has_entries accepted an empty body"
changelog_has_entries $'### Added\r\n\r\n###\r\n' && error "changelog_has_entries accepted CRLF headings"
changelog_has_entries $'### Added\n- A real entry.' || error "changelog_has_entries rejected a real entry"
changelog_has_entries 'Prose with no heading.'      || error "changelog_has_entries rejected plain prose"
changelog_has_entries '- #42 fixed'                  || error "changelog_has_entries took a bullet mentioning #42 for a heading"
note "has_entries tells a written section from an empty template"

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
