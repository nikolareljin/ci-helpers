#!/usr/bin/env bash
# SCRIPT: release_notes_test.sh
# DESCRIPTION: Tests for scripts/release_notes.sh and scripts/check_changelog_section.sh.
# USAGE: ./tests/release_notes_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/release_notes_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[release_notes_test] $*"; }
error() { echo "[release_notes_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

notes="$root_dir/scripts/release_notes.sh"
gate="$root_dir/scripts/check_changelog_section.sh"

# Same shape as git_branches_test.sh: identity per invocation with -c, so the
# fixture never writes a user into any config.
git_t() { git -c user.name='script-helpers tests' -c user.email='tests@localhost' "$@"; }

# A repository with two releases. 0.1.0 is tagged at the first commit, then two
# more commits land, then 0.2.0 is tagged at the tip -- which is the state the
# release workflows actually run in, and the state the old generator got wrong.
build_repo() {
  local dir="$1"
  mkdir -p "$dir"
  ( cd "$dir"
    git init --quiet -b main .
    echo one > a.txt; git_t add a.txt; git_t commit --quiet -m "feat: the first thing"
    git_t tag 0.1.0
    echo two > b.txt; git_t add b.txt; git_t commit --quiet -m "fix: the second thing"
    echo three > c.txt; git_t add c.txt; git_t commit --quiet -m "fix: the third thing"
    git_t tag 0.2.0
  )
}

# ---------------------------------------------------------------------------
# 1) The regression. HEAD carries the tag being released, so
#    `git describe --tags --abbrev=0` returns that tag and the range is empty.
#    The notes must still be the commits since the PREVIOUS tag.
# ---------------------------------------------------------------------------
build_repo "$tmp/r1"
out="$("$notes" --version 0.2.0 --repo "$tmp/r1" 2>/dev/null)"

grep -q "the second thing" <<<"$out" || error "notes lost a commit from the range (0.1.0..0.2.0)"
grep -q "the third thing"  <<<"$out" || error "notes lost the tip commit"
grep -q "the first thing"  <<<"$out" && error "notes reached back past the previous tag"
grep -qi "No changes"      <<<"$out" && error "notes fell through to the placeholder on a range with commits"
note "a tag on HEAD still yields the previous tag's range"

# The same call must not be fooled when asked before the tag exists either.
( cd "$tmp/r1" && git_t tag -d 0.2.0 >/dev/null )
out="$("$notes" --version 0.2.0 --repo "$tmp/r1" 2>/dev/null)"
grep -q "the third thing" <<<"$out" || error "notes are wrong when the tag does not exist yet"
note "notes are the same before the tag is created"
( cd "$tmp/r1" && git_t tag 0.2.0 )

# ---------------------------------------------------------------------------
# 2) A CHANGELOG section wins over the commit range.
# ---------------------------------------------------------------------------
cat > "$tmp/r1/CHANGELOG.md" <<'EOF'
# Changelog

## 2026-09-12 — v0.2.0

### Added
- Something a person wrote.

## 2026-01-01 — v0.1.0

- The older one.
EOF
out="$("$notes" --version 0.2.0 --repo "$tmp/r1" 2>/dev/null)"
grep -q "Something a person wrote." <<<"$out" || error "the CHANGELOG section was not preferred"
grep -q "the third thing"           <<<"$out" && error "the commit range leaked in alongside the changelog"
grep -q "The older one."            <<<"$out" && error "the next section leaked in"
note "a CHANGELOG section is preferred over the commit range"

# ...and a version the changelog does not mention still falls back to commits,
# rather than reporting the wrong section or nothing at all.
out="$("$notes" --version 0.3.0 --tag 0.2.0 --repo "$tmp/r1" 2>/dev/null)"
grep -q "the third thing" <<<"$out" || error "a version absent from the CHANGELOG did not fall back to commits"
note "a version absent from the CHANGELOG falls back to the range"

# ---------------------------------------------------------------------------
# 3) Prefix collision. Asking for 0.2.0 must not match a v10.2.0 header.
#    This is why changelog_extract matches on boundaries rather than substrings.
# ---------------------------------------------------------------------------
cat > "$tmp/r1/COLLIDE.md" <<'EOF'
# Changelog

## 2026-09-10 — v10.2.0

- ten point two.

## 2026-01-01 — v0.2.0

- zero point two.
EOF
out="$("$notes" --version 0.2.0 --changelog "$tmp/r1/COLLIDE.md" --repo "$tmp/r1" 2>/dev/null)"
grep -q "zero point two." <<<"$out" || error "0.2.0 did not select its own section"
grep -q "ten point two."  <<<"$out" && error "0.2.0 matched the v10.2.0 section"
out="$("$notes" --version 10.2.0 --changelog "$tmp/r1/COLLIDE.md" --repo "$tmp/r1" 2>/dev/null)"
grep -q "ten point two." <<<"$out" || error "10.2.0 did not select its own section"
note "a version matches its own section, not one it is a substring of"

# ---------------------------------------------------------------------------
# 4) A first release has no previous tag: every commit, and no placeholder.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/r2"
( cd "$tmp/r2"
  git init --quiet -b main .
  echo one > a.txt; git_t add a.txt; git_t commit --quiet -m "feat: the only thing"
  git_t tag 0.1.0
)
out="$("$notes" --version 0.1.0 --repo "$tmp/r2" 2>/dev/null)"
grep -q "the only thing" <<<"$out" || error "a first release did not list its commits"
grep -qi "No changes"    <<<"$out" && error "a first release produced the placeholder"
note "a first release lists every commit"

# ---------------------------------------------------------------------------
# 5) When there genuinely is nothing, say what was looked at. The old
#    `* No changes listed.` could not be told apart from a broken range.
# ---------------------------------------------------------------------------
( cd "$tmp/r2" && git_t tag 0.2.0 )   # a second tag on the same commit
out="$("$notes" --version 0.2.0 --repo "$tmp/r2" 2>/dev/null)"
grep -q "0.2.0" <<<"$out" || error "an empty result did not name the version"
grep -qi "looked at" <<<"$out" || error "an empty result did not say what it looked at"
[[ "$out" == "* No changes listed." ]] && error "the bare placeholder came back"
note "an empty result says which version and which source"

# ---------------------------------------------------------------------------
# 6) --output writes the body to a file, so notes reach actions by body_path
#    rather than through an interpolated string.
# ---------------------------------------------------------------------------
"$notes" --version 0.2.0 --repo "$tmp/r1" --output "$tmp/body.md" >/dev/null 2>&1
[[ -s "$tmp/body.md" ]] || error "--output wrote nothing"
grep -q "Something a person wrote." "$tmp/body.md" || error "--output wrote the wrong body"
note "--output writes the body to a file"

# ---------------------------------------------------------------------------
# 7) The gate: missing section fails, present section passes, and it is a no-op
#    away from a release branch.
# ---------------------------------------------------------------------------
"$gate" --version 0.2.0 --changelog "$tmp/r1/CHANGELOG.md" --repo "$tmp/r1" >/dev/null 2>&1 \
  || error "the gate rejected a version that has a section"
"$gate" --branch feat/something --repo "$tmp/r1" >/dev/null 2>&1 \
  || error "the gate did not skip a non-release branch"
set +e
"$gate" --version 9.9.9 --changelog "$tmp/r1/CHANGELOG.md" --repo "$tmp/r1" >/dev/null 2>&1
status=$?
"$gate" --version 0.2.0 --changelog "$tmp/r1/ABSENT.md" --repo "$tmp/r1" >/dev/null 2>&1
status_absent=$?
set -e
[[ "$status" -eq 1 ]] || error "the gate accepted a version with no section (returned $status)"
[[ "$status_absent" -eq 1 ]] || error "the gate accepted a missing CHANGELOG (returned $status_absent)"
note "the gate fails on a missing section and skips off a release branch"

# ---------------------------------------------------------------------------
# 8) Bad arguments are refused rather than assumed.
# ---------------------------------------------------------------------------
set +e
"$notes" >/dev/null 2>&1;                              no_version=$?
"$notes" --version 1.0.0 --repo /nope >/dev/null 2>&1; bad_repo=$?
"$notes" --bogus >/dev/null 2>&1;                      bad_flag=$?
set -e
[[ "$no_version" -eq 2 ]] || error "no --version returned $no_version (expected 2)"
[[ "$bad_repo"   -eq 2 ]] || error "a missing --repo returned $bad_repo (expected 2)"
[[ "$bad_flag"   -eq 2 ]] || error "an unknown flag returned $bad_flag (expected 2)"
note "bad arguments return 2"

# An option with no value, or a version that is not one, is also a bad argument.
# `shift 2` on a lone `--version` used to exit 1 under set -e, with no message.
set +e
"$notes" --version >/dev/null 2>&1;                          notes_novalue=$?
"$notes" --version 'not-a-version' --repo "$tmp/r1" >/dev/null 2>&1; notes_badver=$?
"$gate" --changelog >/dev/null 2>&1;                         gate_novalue=$?
"$gate" --version '1.2' --repo "$tmp/r1" >/dev/null 2>&1;    gate_badver=$?
msg="$("$notes" --version 2>&1 >/dev/null)"
set -e
[[ "$notes_novalue" -eq 2 ]] || error "release_notes --version with no value returned $notes_novalue (expected 2)"
[[ "$notes_badver"  -eq 2 ]] || error "release_notes accepted 'not-a-version' (returned $notes_badver)"
[[ "$gate_novalue"  -eq 2 ]] || error "check_changelog_section --changelog with no value returned $gate_novalue (expected 2)"
[[ "$gate_badver"   -eq 2 ]] || error "check_changelog_section accepted '1.2' (returned $gate_badver)"
grep -q -- "--version" <<<"$msg" || error "a missing option value was refused without naming the option"
note "a missing option value or a malformed version returns 2"

# ---------------------------------------------------------------------------
# 9) Floating tags are not releases. This repository moves `production` to each
#    release commit; describe used to return it as the "previous" tag, and the
#    range production..0.2.0 was empty.
# ---------------------------------------------------------------------------
build_repo "$tmp/r3"
( cd "$tmp/r3" && git_t tag production && git_t tag latest )
out="$("$notes" --version 0.2.0 --repo "$tmp/r3" 2>/dev/null)"
grep -q "the second thing" <<<"$out" || error "a floating tag on the release commit emptied the range"
grep -qi "No changes"      <<<"$out" && error "a floating tag produced the empty-result body"
note "floating tags such as production are not taken for the previous release"

# ---------------------------------------------------------------------------
# 10) A v-prefixed repository needs no --tag. The default tag was the bare
#     version, which did not exist, so describe returned v0.2.0 itself.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/r4"
( cd "$tmp/r4"
  git init --quiet -b main .
  echo one > a.txt; git_t add a.txt; git_t commit --quiet -m "feat: v one"
  git_t tag v0.1.0
  echo two > b.txt; git_t add b.txt; git_t commit --quiet -m "fix: v two"
  git_t tag v0.2.0
  # Work after the release, so HEAD is not the tag: a range that ends at HEAD
  # instead of at v0.2.0 would show it.
  echo three > c.txt; git_t add c.txt; git_t commit --quiet -m "feat: after the release"
)
out="$("$notes" --version 0.2.0 --repo "$tmp/r4" 2>/dev/null)"
grep -q "v two" <<<"$out" || error "a v-prefixed tag was not found without --tag"
grep -q "v one" <<<"$out" && error "a v-prefixed range reached back past v0.1.0"
grep -q "after the release" <<<"$out" && error "a v-prefixed release ran to HEAD instead of stopping at v0.2.0"
note "a v-prefixed tag is used when --tag is not given"

# ---------------------------------------------------------------------------
# 11) A relative --output is relative to the caller, not to --repo. It was
#     resolved after the cd, so the body landed in the other working tree.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/caller"
( cd "$tmp/caller" && "$notes" --version 0.2.0 --repo ../r1 --output body.md >/dev/null 2>&1 )
[[ -s "$tmp/caller/body.md" ]] || error "a relative --output was not written to the caller's directory"
[[ -e "$tmp/r1/body.md" ]] && error "a relative --output was written into the --repo working tree"
note "a relative --output is resolved against the caller's directory"

# ---------------------------------------------------------------------------
# 12) A shallow clone -- actions/checkout's default -- cannot answer "what
#     changed since the previous tag". It used to answer anyway: one commit,
#     described as a first release, exit 0. The CHANGELOG path needs no history,
#     so it still works there.
# ---------------------------------------------------------------------------
build_repo "$tmp/r5"
git clone --quiet --depth 1 "file://$tmp/r5" "$tmp/r5-shallow" 2>/dev/null
set +e
msg="$("$notes" --version 0.2.0 --repo "$tmp/r5-shallow" 2>&1 >/dev/null)"
status=$?
set -e
[[ "$status" -eq 1 ]] || error "a shallow clone produced commit notes (returned $status, expected 1)"
grep -q "fetch-depth" <<<"$msg" || error "the shallow-clone refusal did not say how to fix it"
printf '# Changelog\n\n## 2026-09-12 — v0.2.0\n\n- Written down.\n' > "$tmp/r5-shallow/CHANGELOG.md"
out="$("$notes" --version 0.2.0 --repo "$tmp/r5-shallow" 2>/dev/null)" \
  || error "a shallow clone with a CHANGELOG section was refused"
grep -q "Written down." <<<"$out" || error "a shallow clone did not use its CHANGELOG section"
note "a shallow clone refuses the commit fallback but still reads the CHANGELOG"

# ---------------------------------------------------------------------------
# 13) The gate does not accept a pre-release section for the final version.
# ---------------------------------------------------------------------------
printf '# Changelog\n\n## 2026-09-01 — v0.2.0-rc.1\n\n- The candidate.\n' > "$tmp/RC.md"
set +e
"$gate" --branch release/0.2.0 --changelog "$tmp/RC.md" --repo "$tmp/r1" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || error "the gate accepted a v0.2.0-rc.1 section for release/0.2.0 (returned $status)"
note "the gate does not take a pre-release section for the final version"

# ---------------------------------------------------------------------------
# 14) The template changelog_new_section writes is a section, not a write-up.
#     `./dev release X` in consumer repositories writes it; the gate passed it
#     and the release body was four empty headings.
# ---------------------------------------------------------------------------
build_repo "$tmp/r6"
( cd "$tmp/r6"
  printf '# Changelog\n\n' > CHANGELOG.md
  bash -c 'source "$1/helpers.sh"; shlib_import logging changelog; changelog_new_section CHANGELOG.md 0.2.0 --date 2026-09-13' _ "$root_dir" >/dev/null 2>&1
)
grep -q '^### Added' "$tmp/r6/CHANGELOG.md" || error "fixture: changelog_new_section did not write its template"
set +e
msg="$("$gate" --version 0.2.0 --repo "$tmp/r6" 2>&1 >/dev/null)"
status=$?
out="$("$notes" --version 0.2.0 --repo "$tmp/r6" 2>"$tmp/r6.err")"
notes_status=$?
set -e
[[ "$status" -eq 1 ]] || error "the gate accepted the empty changelog_new_section template (returned $status)"
grep -q "no entries" <<<"$msg" || error "the gate refused the template without saying it has no entries"
[[ "$notes_status" -eq 0 ]] || error "release_notes failed on an empty section (returned $notes_status)"
grep -q '^###' <<<"$out" && error "empty template headings were published as the release body"
grep -q "the third thing" <<<"$out" || error "an empty section did not fall back to the commits"
grep -q "no entries" "$tmp/r6.err" || error "release_notes did not warn that the section was empty"
note "an empty template section fails the gate and is not published"

# A header with nothing at all under it, before the next section.
printf '# Changelog\n\n## 2026-09-13 — v0.2.0\n\n## 2026-09-01 — v0.1.0\n\n- The older one.\n' > "$tmp/EMPTY.md"
set +e
"$gate" --version 0.2.0 --changelog "$tmp/EMPTY.md" --repo "$tmp/r1" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || error "the gate accepted a section with nothing under it (returned $status)"
note "a bare header with no body fails the gate"

# ---------------------------------------------------------------------------
# 15) A final release is described against the previous FINAL release. With
#     0.2.0-rc.1 counted as previous, 0.2.0's notes were only what landed after
#     the candidate. A pre-release is still described against the nearest tag.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/r7"
( cd "$tmp/r7"
  git init --quiet -b main .
  echo one > a.txt; git_t add a.txt; git_t commit --quiet -m "feat: before everything"
  git_t tag 0.1.0
  echo two > b.txt; git_t add b.txt; git_t commit --quiet -m "feat: in the first candidate"
  git_t tag 0.2.0-rc.1
  echo three > c.txt; git_t add c.txt; git_t commit --quiet -m "fix: in the second candidate"
  git_t tag 0.2.0-rc.2
  echo four > d.txt; git_t add d.txt; git_t commit --quiet -m "fix: after the candidates"
  git_t tag 0.2.0
)
out="$("$notes" --version 0.2.0 --repo "$tmp/r7" 2>/dev/null)"
grep -q "in the first candidate" <<<"$out" || error "0.2.0's notes stopped at a pre-release tag"
grep -q "after the candidates"   <<<"$out" || error "0.2.0's notes lost its own commit"
grep -q "before everything"      <<<"$out" && error "0.2.0's notes reached back past 0.1.0"
out="$("$notes" --version 0.2.0-rc.2 --repo "$tmp/r7" 2>/dev/null)"
grep -q "in the second candidate" <<<"$out" || error "rc.2's notes lost its own commit"
grep -q "in the first candidate"  <<<"$out" && error "rc.2's notes reached back past rc.1"
note "a final release skips pre-release tags; a pre-release does not"

# ---------------------------------------------------------------------------
# 16) A clone with full history but no tags cannot tell a first release from
#     tags that were never fetched. It must not call it a first release silently.
# ---------------------------------------------------------------------------
git clone --quiet --no-tags "file://$tmp/r5" "$tmp/r5-notags" 2>/dev/null
out="$("$notes" --version 0.2.0 --repo "$tmp/r5-notags" 2>"$tmp/notags.err")" \
  || error "a clone without tags was refused"
grep -q "no tags other than" "$tmp/notags.err" || error "a clone without tags was not warned about"
grep -q "not fetched" "$tmp/notags.err" || error "the no-tags warning did not name the likely cause"
# The same clone after a release job creates the tag locally: one tag, which is
# the one being released. Still not evidence of a first release.
( cd "$tmp/r5-notags" && git_t tag 0.2.0 )
"$notes" --version 0.2.0 --repo "$tmp/r5-notags" >/dev/null 2>"$tmp/notags2.err" \
  || error "a clone with only the release tag was refused"
grep -q "not fetched" "$tmp/notags2.err" || error "a clone whose only tag is the release tag was presented as a first release"
# A real history with an earlier release is not warned about.
"$notes" --version 0.2.0 --repo "$tmp/r3" >/dev/null 2>"$tmp/tags.err"
grep -q "not fetched" "$tmp/tags.err" && error "a clone with its earlier tags was warned about"
note "a clone with no other tags is warned about, not presented as a first release"

# ---------------------------------------------------------------------------
# 17) A failing `git log` is an error, not an empty release. Nothing else in
#     this suite reaches that branch, so a shim fails `git log` on purpose.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/shim"
real_git="$(command -v git)"
cat > "$tmp/shim/git" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "log" ]] && { echo "fatal: simulated log failure" >&2; exit 128; }
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/shim/git"
set +e
msg="$(PATH="$tmp/shim:$PATH" "$notes" --version 0.2.0 --repo "$tmp/r3" 2>&1 >/dev/null)"
status=$?
set -e
[[ "$status" -eq 1 ]] || error "a failing git log did not fail the script (returned $status)"
grep -q "git log" <<<"$msg" || error "a failing git log was not reported"
note "a failing git log fails the script"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
