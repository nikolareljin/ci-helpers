#!/usr/bin/env bash
# SCRIPT: update_pinned_actions_newer_tag_test.sh
# DESCRIPTION: scripts/update_pinned_actions.sh against a stub gh. With
#              --check --allow-newer-tag, a pin whose SHA is the commit of a
#              newer release tag than its comment names is NEWER and passes;
#              an unknown SHA, a branch commit, an older tag, a pre-release and
#              a branch in the comment stay STALE; a failed tag listing is a
#              warning. A plain --check is unchanged. Without --check the
#              comment moves to the tag and the SHA stays. Also: each failure of
#              the tag lookup warns, and the gates pass the option as documented.
# USAGE: bash tests/update_pinned_actions_newer_tag_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/update_pinned_actions.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # v1.0.0
sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb   # v1.1.0, and where v1 points
sha_z=0000000000000000000000000000000000000000   # v0.9.0
sha_c=cccccccccccccccccccccccccccccccccccccccc   # main, no tag
sha_r=1111111111111111111111111111111111111111   # v1.2.0-rc1
sha_m=2222222222222222222222222222222222222222   # v2 and v2.0.0
sha_x=3333333333333333333333333333333333333333   # nowhere
sha_h=4444444444444444444444444444444444444444   # acme/multi v3.0.0, v3.1.0, v3.2.0
sha_n=5555555555555555555555555555555555555555   # acme/other v3.0.0, no v3

mkdir -p "$work/bin" "$work/state/tags/acme"
# Stub gh. commits/<ref> answers from $STATE/commits ("repo ref sha" lines);
# the tag listing is $STATE/tags/<repo>, already in the shape the --jq gives,
# and a repository without one fails the listing. Every call is logged.
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$STATE/calls"
[ "$1" = auth ] && exit 0
[ "$1" = api ] || { echo "unexpected gh $*" >&2; exit 1; }
path=""
for a in "$@"; do
  case "$a" in repos/*) path="$a" ;; esac
done
case "$path" in
  repos/*/*/commits/*)
    repo="${path#repos/}"; repo="${repo%/commits/*}"
    ref="${path##*/commits/}"
    sha="$(awk -v r="$repo" -v f="$ref" '$1 == r && $2 == f { print $3 }' "$STATE/commits")"
    [ -n "$sha" ] || { echo "Not Found" >&2; exit 1; }
    echo "$sha" ;;
  repos/*/*/tags*)
    repo="${path#repos/}"; repo="${repo%/tags*}"
    [ -f "$STATE/tags/$repo" ] || { echo "Not Found" >&2; exit 1; }
    cat "$STATE/tags/$repo" ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
SH
chmod +x "$work/bin/gh"

cat > "$work/state/commits" <<EOF
acme/tool v1.0.0 $sha_a
acme/tool v1.1.0 $sha_b
acme/tool v1 $sha_b
acme/tool v0.9.0 $sha_z
acme/tool main $sha_c
acme/tool v1.2.0-rc1 $sha_r
acme/tool v2 $sha_m
acme/tool v2.0.0 $sha_m
acme/notags v1.0.0 $sha_a
acme/notags v1.1.0 $sha_b
acme/multi v2.9.0 $sha_z
acme/multi v3.0.0 $sha_h
acme/multi v3.1.0 $sha_h
acme/multi v3.2.0 $sha_h
acme/other v2 $sha_m
acme/other v3.0.0 $sha_n
acme/disagree v1.0.0 $sha_a
acme/disagree v1.1.0 $sha_c
acme/gone v1.0.0 $sha_a
acme/solo v1.0.0 $sha_a
acme/solo v1.1.0 $sha_b
acme/line v1 $sha_b
acme/line v1.0.2 $sha_a
acme/spelled v1.2.3 $sha_b
EOF
cat > "$work/state/tags/acme/tool" <<EOF
v2.0.0 $sha_m
v2 $sha_m
v1.2.0-rc1 $sha_r
v1.1.0 $sha_b
v1 $sha_b
v1.0.0 $sha_a
v0.9.0 $sha_z
EOF
# The highest tag sits in the middle, so neither first nor last wins by accident.
cat > "$work/state/tags/acme/multi" <<EOF
v3.1.0 $sha_h
v3.2.0 $sha_h
v3.0.0 $sha_h
EOF
cat > "$work/state/tags/acme/other" <<EOF
v3.0.0 $sha_n
EOF
# v1.1.0 is listed at sha_b, its commit lookup says sha_c.
cat > "$work/state/tags/acme/disagree" <<EOF
v1.1.0 $sha_b
v1.0.0 $sha_a
EOF
# v1.1.0 is listed at sha_b, its commit lookup fails.
cat > "$work/state/tags/acme/gone" <<EOF
v1.1.0 $sha_b
v1.0.0 $sha_a
EOF
cat > "$work/state/tags/acme/solo" <<EOF
v1.1.0 $sha_b
v1.0.0 $sha_a
EOF
cat > "$work/state/tags/acme/line" <<EOF
v1 $sha_b
v1.0.2 $sha_a
EOF
# Only the `v` spelling exists: `# 1.2.3` and `# 1.2` name nothing upstream.
cat > "$work/state/tags/acme/spelled" <<EOF
v1.2.3 $sha_b
EOF
export STATE="$work/state"

fail=0
pin() { # name sha ref [repo, default tool] -> writes $work/<name>/.github/w.yml
  mkdir -p "$work/$1/.github"
  printf 'jobs:\n  a:\n    steps:\n      - uses: acme/%s@%s # %s @ 2026-01-01\n' "${4:-tool}" "$2" "$3" > "$work/$1/.github/w.yml"
}
run() { # name expected-rc mode (check | dependabot | update)
  local name="$1" want="$2" mode="$3" rc=0
  last_pin="$work/$name/.github/w.yml"
  : > "$STATE/calls"
  cd "$work/$name"
  case "$mode" in
    check)      ( PATH="$work/bin:$PATH" bash "$script" --dir .github --check ) > "$work/out" 2>&1 || rc=$? ;;
    dependabot) ( PATH="$work/bin:$PATH" bash "$script" --dir .github --check --allow-newer-tag ) > "$work/out" 2>&1 || rc=$? ;;
    update)     ( PATH="$work/bin:$PATH" bash "$script" --dir .github ) > "$work/out" 2>&1 || rc=$? ;;
    *) echo "bad mode $mode"; exit 2 ;;
  esac
  cd "$root"
  if [ "$rc" != "$want" ]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1
  else
    echo "ok   $name: exit $rc"
  fi
}
expect() { # name pattern
  if ! grep -q -- "$2" "$work/out"; then
    echo "FAIL $1: output lacks '$2'"; cat "$work/out"; fail=1
  fi
}
refuse() { # name pattern
  if grep -q -- "$2" "$work/out"; then
    echo "FAIL $1: output has '$2'"; cat "$work/out"; fail=1
  fi
}
listed_tags() { # name
  if grep -q "/tags" "$STATE/calls"; then
    echo "FAIL $1: listed tags"; fail=1
  fi
}

# Accepted: the SHA is v1.1.0, the comment says v1.0.0.
pin newer "$sha_b" v1.0.0
run newer 0 dependabot
expect newer "NEWER .*acme/tool"
expect newer "= v1.1.0"
expect newer "0 stale, 1 newer than their comment, 0 warnings"
refuse newer "^STALE"

# A plain --check does not ask about tags and stays STALE.
run newer 1 check
expect "newer, plain --check" "^STALE"
expect "newer, plain --check" "1 stale, 0 newer"
listed_tags "newer, plain --check"

# Refused with the option: each stays STALE and fails.
pin unknown "$sha_x" v1.0.0
run unknown 1 dependabot
expect unknown "^STALE"

pin branch-commit "$sha_c" v1.0.0
run branch-commit 1 dependabot
expect branch-commit "^STALE"

pin older "$sha_z" v1.0.0
run older 1 dependabot
expect older "^STALE"

pin prerelease "$sha_r" v1.0.0
run prerelease 1 dependabot
expect prerelease "^STALE"

pin branch-comment "$sha_b" main
run branch-comment 1 dependabot
expect branch-comment "^STALE"
listed_tags branch-comment

# A major-only comment moves only to a major-only tag.
pin major "$sha_m" v1
run major 0 dependabot
expect major "= v2$"

# The listing failed: a warning, which fails, not a pass and not STALE.
pin nolisting "$sha_b" v1.0.0 notags
run nolisting 1 dependabot
expect nolisting "^WARN .*could not resolve the tags of acme/notags"
expect nolisting "0 stale, 0 newer than their comment, 1 warnings"

# An up-to-date pin is OK and lists nothing.
pin current "$sha_a" v1.0.0
run current 0 dependabot
expect current "^OK "
listed_tags current

# Without --check the comment moves to the tag; the SHA stays.
today="$(date +%Y-%m-%d)"
pin update "$sha_b" v1.0.0
run update 0 update
expect update "^NEWER"
expect update "UPDATED"
want="      - uses: acme/tool@${sha_b} # v1.1.0 @ ${today}"
got="$(tail -n 1 "$work/update/.github/w.yml")"
[ "$got" = "$want" ] || { echo "FAIL update: got '$got', want '$want'"; fail=1; }

# Spacing and anything after the date survive the rewrite.
mkdir -p "$work/spacing/.github"
printf 'jobs:\n  a:\n    steps:\n      - name: x\n        uses:   acme/tool@%s   #  v1.0.0  @  2026-01-01  # keep\n' "$sha_b" > "$work/spacing/.github/w.yml"
run spacing 0 update
want="        uses:   acme/tool@${sha_b}   #  v1.1.0  @  ${today}  # keep"
got="$(tail -n 1 "$work/spacing/.github/w.yml")"
[ "$got" = "$want" ] || { echo "FAIL spacing: got '$got', want '$want'"; fail=1; }

# Without --check a SHA that is no tag still moves to the comment's ref.
pin revert "$sha_c" v1.0.0
run revert 0 update
expect revert "^STALE"
want="      - uses: acme/tool@${sha_a} # v1.0.0 @ ${today}"
got="$(tail -n 1 "$work/revert/.github/w.yml")"
[ "$got" = "$want" ] || { echo "FAIL revert: got '$got', want '$want'"; fail=1; }

unchanged() { # name line: the last run left this as its pin
  local got
  got="$(tail -n 1 "$last_pin")"
  [ "$got" = "$2" ] || { echo "FAIL $1: got '$got', want '$2'"; fail=1; }
}
tag_calls() { # name count
  local got
  got="$(grep -c "/tags" "$STATE/calls" || true)"
  [ "$got" = "$2" ] || { echo "FAIL $1: $got tag listings, expected $2"; fail=1; }
}

# The listing and the commit lookup disagree: not a verified tag, so STALE.
pin disagree "$sha_b" v1.0.0 disagree
run disagree 1 dependabot
expect disagree "^STALE"

# The commit lookup of a listed tag fails: a warning, not STALE.
pin lookup-fails "$sha_b" v1.0.0 gone
run lookup-fails 1 dependabot
expect lookup-fails "^WARN .*could not resolve the tags of acme/gone"
refuse lookup-fails "^STALE"

# Three tags on one SHA: the highest, wherever the listing puts it.
pin two-tags "$sha_h" v2.9.0 multi
run two-tags 0 dependabot
expect two-tags "= v3.2.0$"

# The listing asks for every page.
run newer 0 dependabot
if ! grep -q -- "--paginate repos/acme/tool/tags" "$STATE/calls"; then
  echo "FAIL paginate: $(grep /tags "$STATE/calls" || echo 'no tag listing')"; fail=1
fi

# Two pins of one repository list its tags once.
mkdir -p "$work/cached/.github"
printf 'jobs:\n  a:\n    steps:\n      - uses: acme/tool@%s # v1.0.0 @ 2026-01-01\n      - uses: acme/tool/sub@%s # v1.0.0 @ 2026-01-01\n' "$sha_b" "$sha_m" > "$work/cached/.github/w.yml"
run cached 0 dependabot
expect cached "2 newer than their comment"
tag_calls cached 1

# A failed listing is asked once too, and each pin still warns.
mkdir -p "$work/cached-fail/.github"
printf 'jobs:\n  a:\n    steps:\n      - uses: acme/notags@%s # v1.0.0 @ 2026-01-01\n      - uses: acme/notags/sub@%s # v1.0.0 @ 2026-01-01\n' "$sha_b" "$sha_m" > "$work/cached-fail/.github/w.yml"
run cached-fail 1 dependabot
expect cached-fail "0 newer than their comment, 2 warnings"
tag_calls cached-fail 1

# The comparer crashes or answers nonsense: the plain run warns and keeps the
# bump. A copy of the script next to a broken comparer, so the real one is safe.
mkdir -p "$work/broken/scripts"
cp "$script" "$work/broken/scripts/update_pinned_actions.sh"
real_script="$script"
crash() { # comparer-body sha ref repo
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$work/broken/scripts/semver_compare.sh"
  pin crash "$2" "$3" "$4"
  local before
  before="$(tail -n 1 "$work/crash/.github/w.yml")"
  script="$work/broken/scripts/update_pinned_actions.sh"
  run crash 0 update
  script="$real_script"
  expect crash "^WARN .*could not resolve the tags of acme/$4"
  refuse crash "^STALE"
  refuse crash "^NEWER"
  unchanged crash "$before"
}
crash 'exit 3' "$sha_b" v1.0.0 solo
crash 'echo nonsense' "$sha_b" v1.0.0 solo
crash 'echo gt; exit 3' "$sha_b" v1.0.0 solo
# Fails only when comparing two candidates, not a candidate with the comment.
crash '[ "$2" = 2.9.0 ] && echo gt || exit 3' "$sha_h" v2.9.0 multi
# The tag of another shape.
crash 'exit 3' "$sha_n" v2 other

# `# v2` at the commit of v3.0.0, no v3 tag: warn and keep the line.
pin other-shape "$sha_n" v2 other
before="$(tail -n 1 "$work/other-shape/.github/w.yml")"
run other-shape 0 update
expect other-shape "^WARN .*pinned at v3.0.0, newer than its comment v2"
refuse other-shape "^STALE"
unchanged other-shape "$before"
run other-shape 1 dependabot
expect other-shape "^WARN .*pinned at v3.0.0"

# Equal versions spelled differently are not newer, so the comment stays wrong
# and is reported, in the same shape and cut down from a longer tag.
for spelled in 1.2.3 1.2; do
  name="spelled-$spelled"
  pin "$name" "$sha_b" "$spelled" spelled
  before="$(tail -n 1 "$work/$name/.github/w.yml")"
  run "$name" 1 dependabot
  expect "$name" "^WARN .*could not fetch SHA for acme/spelled@$spelled"
  refuse "$name" "^NEWER"
  run "$name" 0 update
  expect "$name" "^WARN .*could not fetch SHA for acme/spelled@$spelled"
  refuse "$name" "^NEWER"
  unchanged "$name" "$before"
done

# `# v1` at an old commit of that line (v1.0.2, while v1 moved on) is stale, not
# another shape: the plain run still refreshes it.
pin floating "$sha_a" v1 line
run floating 0 update
expect floating "^STALE"
refuse floating "^WARN"
unchanged floating "      - uses: acme/line@${sha_b} # v1 @ ${today}"

# The comment's tag is deleted upstream: the bump still gets its comment.
pin deleted "$sha_b" v0.5.0
run deleted 0 update
expect deleted "^NEWER"
unchanged deleted "      - uses: acme/tool@${sha_b} # v1.1.0 @ ${today}"
pin deleted "$sha_b" v0.5.0
run deleted 0 dependabot
expect deleted "= v1.1.0"

# Deleted, and the SHA is no tag either: a warning, nothing rewritten.
pin deleted-unknown "$sha_x" v0.5.0
before="$(tail -n 1 "$work/deleted-unknown/.github/w.yml")"
run deleted-unknown 0 update
expect deleted-unknown "^WARN .*could not fetch SHA for acme/tool@v0.5.0"
unchanged deleted-unknown "$before"

# A plain --check of a deleted tag warns and lists nothing.
pin deleted "$sha_b" v0.5.0
run deleted 1 check
expect deleted "^WARN .*could not fetch SHA"
listed_tags "deleted, plain --check"

# The gates. Drive the real step of workflow-yaml-check.yml against a stand-in
# script that records its arguments: strict only on a release branch pull request.
mkdir -p "$work/gate/scripts"
cat > "$work/gate/scripts/update_pinned_actions.sh" <<'SH'
echo "$*" > "$GATE_ARGS"
exit "${GATE_RC:-0}"
SH
python3 - "$root/.github/workflows/workflow-yaml-check.yml" > "$work/gate/step.sh" <<'PY_STEP'
import sys, yaml
for step in yaml.safe_load(open(sys.argv[1]))["jobs"]["yaml"]["steps"]:
    if step.get("name") == "Action pins are annotated and current":
        print(step["run"])
PY_STEP
gate() { # head-ref expected-args
  local got
  ( cd "$work/gate" && GATE_ARGS="$work/gate/args" HEAD_REF="$1" bash -e step.sh )
  got="$(cat "$work/gate/args")"
  [ "$got" = "$2" ] || { echo "FAIL gate '$1': got '$got', want '$2'"; fail=1; }
}
gate "" "--check --allow-newer-tag"
gate "dependabot/github_actions/x" "--check --allow-newer-tag"
gate "fix/release/1.2.3" "--check --allow-newer-tag"
gate "release/1.2.3" "--check"
grep -q "run: bash scripts/update_pinned_actions.sh --check --allow-newer-tag$" "$root/.github/workflows/security-weekly.yml" ||
  { echo "FAIL security-weekly.yml does not pass --allow-newer-tag"; fail=1; }
grep -q "run: bash scripts/update_pinned_actions.sh --check$" "$root/.github/workflows/production-branch.yml" ||
  { echo "FAIL production-branch.yml is not a plain --check"; fail=1; }

# The real gate step of auto-tag-release-push.yml, with stub git and gh: only a
# merged non-release pull request that is this commit relaxes the check.
mkdir -p "$work/tagbin"
cat > "$work/tagbin/git" <<'SH'
#!/usr/bin/env bash
echo "$SUBJECT"
SH
cat > "$work/tagbin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" > "$GH_LOG"
[ -n "$GH_ANSWER" ] || exit 1
echo "$GH_ANSWER"
SH
chmod +x "$work/tagbin/git" "$work/tagbin/gh"
python3 - "$root/.github/workflows/auto-tag-release-push.yml" > "$work/gate/tag_step.sh" <<'PY_STEP'
import sys, yaml
for step in yaml.safe_load(open(sys.argv[1]))["jobs"]["gate"]["steps"]:
    if step.get("name") == "Check stale SHA pins":
        print(step["run"])
PY_STEP
tag_gate() { # subject gh-answer expected-args
  local got
  rm -f "$work/gate/args"
  ( cd "$work/gate" && PATH="$work/tagbin:$PATH" GATE_ARGS="$work/gate/args" GH_LOG="$work/gate/gh.log" \
      GITHUB_SHA=abc GITHUB_REPOSITORY=acme/lib SUBJECT="$1" GH_ANSWER="$2" bash -e -o pipefail tag_step.sh )
  got="$(cat "$work/gate/args")"
  [ "$got" = "$3" ] || { echo "FAIL tag gate '$1' '$2': got '$got', want '$3'"; fail=1; }
}
relaxed="--check --allow-newer-tag"
tag_gate "fix: a thing (#12)" "true abc fix/thing" "$relaxed"
grep -q "repos/acme/lib/pulls/12 " "$work/gate/gh.log" || { echo "FAIL tag gate asked $(cat "$work/gate/gh.log")"; fail=1; }
tag_gate "Merge pull request #13 from acme/fix/thing" "true abc fix/thing" "$relaxed"
tag_gate "Release 1.2.3 (#14)" "true abc release/1.2.3" "--check"
tag_gate "Merge pull request #14 from acme/release/1.2.3" "true abc release/1.2.3" "--check"
# An edited squash subject naming another pull request: not this commit.
tag_gate "Release 1.2.3 (#12)" "true other fix/thing" "--check"
tag_gate "fix: not merged (#15)" "false abc fix/thing" "--check"
tag_gate "fix: lookup fails (#16)" "" "--check"
tag_gate "direct push" "true abc fix/thing" "--check"
# No head ref in the answer: not placed, so strict.
tag_gate "fix: no head ref (#17)" "true abc" "--check"

# A strict failure keeps its exit code and points at the recovery; a pass or a
# relaxed failure prints no pointer.
tag_rc() { # subject gh-answer script-rc expected-rc pointer(yes|no)
  local rc=0
  ( cd "$work/gate" && PATH="$work/tagbin:$PATH" GATE_ARGS="$work/gate/args" GH_LOG="$work/gate/gh.log" GATE_RC="$3" \
      GITHUB_SHA=abc GITHUB_REPOSITORY=acme/lib SUBJECT="$1" GH_ANSWER="$2" bash -e -o pipefail tag_step.sh ) > "$work/out" 2>&1 || rc=$?
  [ "$rc" = "$4" ] || { echo "FAIL tag gate rc '$1': exit $rc, expected $4"; fail=1; }
  if [ "$5" = yes ]; then
    expect "tag gate pointer" "^::error::.*docs/RELEASE_RC_PR.md"
  else
    refuse "tag gate pointer" "docs/RELEASE_RC_PR.md"
  fi
}
tag_rc "Release 1.2.3 (#14)" "true abc release/1.2.3" 3 3 yes
tag_rc "Release 1.2.3 (#14)" "true abc release/1.2.3" 0 0 no
tag_rc "fix: a thing (#12)" "true abc fix/thing" 3 3 no
grep -q "^### A release merge fails the pin gate$" "$root/docs/RELEASE_RC_PR.md" ||
  { echo "FAIL docs/RELEASE_RC_PR.md lacks the section the pointer names"; fail=1; }

(( fail == 0 )) && echo "update_pinned_actions: NEWER accepted, refused forms STALE, lookup failures warn, comment corrected, gates as documented"
exit "$fail"
