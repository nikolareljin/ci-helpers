#!/usr/bin/env bash
# SCRIPT: check_runner_retirement_test.sh
# DESCRIPTION: scripts/check_runner_retirement.sh against a stub gh. A pinned
#              image whose retirement GitHub announced fails and names the
#              announcement and the pin; an announcement that removes one tool
#              from that image does not; a version in a comment is not a pin;
#              a failed lookup fails; a title naming two versions counts for
#              both; the search must still find GitHub's 20.04 retirement
#              or nothing is trusted; --list asks nothing. Also: this tree's
#              pins are found, security-weekly runs the check, and Report
#              Failure opens the tracking issue when it fails.
# USAGE: bash tests/check_runner_retirement_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/check_runner_retirement.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

mkdir -p "$work/bin" "$work/state" "$work/repo/.github/workflows"
# Stub gh: answers the search with $STATE/<version>.tsv (url<TAB>title lines,
# the shape the --jq gives), and the 20.04 self-check (the query that says
# "deprecation") with $STATE/canary.tsv; no file means the lookup fails.
# Every call is logged.
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$STATE/calls"
q=""
for a in "$@"; do
  case "$a" in q=*) q="$a" ;; esac
done
case "$q" in
  *deprecation*) f="$STATE/canary.tsv" ;;
  *) f="$STATE/$(grep -oE '"[0-9]{2}\.[0-9]{2}"' <<< "$q" | tr -d '"').tsv" ;;
esac
[ -f "$f" ] || { echo "HTTP 403: rate limited" >&2; exit 1; }
cat "$f"
SH
chmod +x "$work/bin/gh"

cat > "$work/repo/.github/workflows/build.yml" <<'EOF'
jobs:
  old:
    runs-on: ubuntu-20.04
  mid:
    runs-on: ubuntu-22.04 # moved from ubuntu-18.04
  # ubuntu-16.04 was here once
  matrix:
    strategy:
      matrix:
        os: [ubuntu-22.04-arm, ubuntu-latest]
EOF

run() {
  (cd "$work/repo" && PATH="$work/bin:$PATH" STATE="$work/state" bash "$script" "$@") \
    > "$work/out" 2>&1
}
expect() { # expect <exit> <description>
  local want="$1" desc="$2" got=0
  shift 2
  run "$@" || got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL $desc: exit $got, want $want"; cat "$work/out"; fail=1
  fi
}
has() {
  grep -qF -- "$1" "$work/out" || { echo "FAIL output lacks: $1"; cat "$work/out"; fail=1; }
}
lacks() {
  if grep -qF -- "$1" "$work/out"; then echo "FAIL output has: $1"; cat "$work/out"; fail=1; fi
}

# --list: both pinned versions, comments ignored, nothing asked.
: > "$work/state/calls"
expect 0 "--list" --list
has "ubuntu-20.04:"
has ".github/workflows/build.yml:3"
has "ubuntu-22.04:"
has ".github/workflows/build.yml:5"
has ".github/workflows/build.yml:10"
lacks "18.04"
lacks "16.04"
[ -s "$work/state/calls" ] && { echo "FAIL --list called gh"; fail=1; }

real_2004='https://x/11101	The Ubuntu 20.04 Actions runner image will begin deprecation on 2025-02-01 and will be fully unsupported by 2025-04-15'
printf '%b\n' "$real_2004" > "$work/state/canary.tsv"

# No announcement for either: passes.
printf 'https://x/1\t[Ubuntu] Go 1.24 will be removed from the tool-cache\n' > "$work/state/20.04.tsv"
: > "$work/state/22.04.tsv"
expect 0 "no retirement announced"
has "OK ubuntu-20.04"
has "OK ubuntu-22.04"

# A tool removed from the image is not the image going.
printf 'https://x/2\tClang 12 will be removed from Ubuntu 22.04 image on September 25\n' > "$work/state/22.04.tsv"
expect 0 "a tool removal is not a retirement"

# GitHub's real 20.04 announcement: fails, names it and the pin.
printf '%b\n' "$real_2004" > "$work/state/20.04.tsv"
expect 1 "retirement announced"
has "::error::ubuntu-20.04 is announced for retirement: The Ubuntu 20.04 Actions runner image"
has "(https://x/11101)"
has "  .github/workflows/build.yml:3"
has "OK ubuntu-22.04"

# One title, two versions: the second has no "Ubuntu" right before it.
printf 'https://x/9\tThe Ubuntu 18.04 and 22.04 Actions runner images will begin deprecation\n' \
  > "$work/state/22.04.tsv"
: > "$work/state/20.04.tsv"
expect 1 "second version in a title"
has "::error::ubuntu-22.04 is announced for retirement"
has "OK ubuntu-20.04"

# 22.04 must not match 122.04 or 22.041.
printf 'https://x/8\tThe Ubuntu 122.04 image will begin deprecation\n' > "$work/state/22.04.tsv"
expect 0 "a longer number is not the version"

# The search no longer finds 20.04's retirement: nothing is trusted.
: > "$work/state/canary.tsv"
expect 1 "self-check finds nothing"
has "no longer finds GitHub's Ubuntu 20.04 retirement announcement"
lacks "OK ubuntu-"
rm "$work/state/canary.tsv"
expect 1 "self-check lookup fails"
has "::error::Could not search actions/runner-images"
printf '%b\n' "$real_2004" > "$work/state/canary.tsv"

# A failed lookup is not a pass.
rm "$work/state/22.04.tsv"
expect 1 "failed lookup"
has "::error::Could not ask actions/runner-images about ubuntu-22.04"

# This tree: its pins are found, security-weekly runs the check, and Report
#              Failure opens the tracking issue when it fails.
(cd "$root" && bash "$script" --list) > "$work/out" 2>&1 || { echo "FAIL --list on this tree"; fail=1; }
has "ubuntu-22.04:"
has ".github/workflows/rust-release-tarballs.yml"
grep -q 'bash scripts/check_runner_retirement.sh' "$root/.github/workflows/security-weekly.yml" \
  || { echo "FAIL security-weekly.yml does not run the check"; fail=1; }
grep -qE '^    needs: \[.*runner-retirement.*\]' "$root/.github/workflows/security-weekly.yml" \
  || { echo "FAIL Report Failure does not wait on runner-retirement, so no issue opens"; fail=1; }
grep -q 'needs.runner-retirement.result' "$root/.github/workflows/security-weekly.yml" \
  || { echo "FAIL Report Failure does not read the runner-retirement result"; fail=1; }

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "check_runner_retirement: all cases pass"
