#!/usr/bin/env bash
# SCRIPT: update_pinned_actions_newer_tag_test.sh
# DESCRIPTION: scripts/update_pinned_actions.sh against a stub gh. With
#              --check --allow-newer-tag, a pin whose SHA is the commit of a
#              newer release tag than its comment names is NEWER and passes;
#              an unknown SHA, a branch commit, an older tag, a pre-release and
#              a branch in the comment stay STALE; a failed tag listing is a
#              warning. A plain --check is unchanged. Without --check the
#              comment moves to the tag and the SHA stays.
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
export STATE="$work/state"

fail=0
pin() { # name sha ref [repo, default tool] -> writes $work/<name>/.github/w.yml
  mkdir -p "$work/$1/.github"
  printf 'jobs:\n  a:\n    steps:\n      - uses: acme/%s@%s # %s @ 2026-01-01\n' "${4:-tool}" "$2" "$3" > "$work/$1/.github/w.yml"
}
run() { # name expected-rc mode (check | dependabot | update)
  local name="$1" want="$2" mode="$3" rc=0
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

(( fail == 0 )) && echo "update_pinned_actions: NEWER accepted, 5 refused forms STALE, listing failure warns, comment corrected"
exit "$fail"
