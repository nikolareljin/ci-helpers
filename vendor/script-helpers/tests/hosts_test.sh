#!/usr/bin/env bash
# SCRIPT: hosts_test.sh
# DESCRIPTION: Regression tests for lib/hosts.sh, chiefly the duplicate-entry bug.
# USAGE: bash tests/hosts_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging hosts

failures=0
note()  { echo "[hosts_test] $*"; }
error() { echo "[hosts_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
HOSTS_FILE="$tmp/hosts"; export HOSTS_FILE
printf '127.0.0.1\tlocalhost\n' > "$HOSTS_FILE"

# The bug this guards: the presence test used GNU \s, which BSD grep never
# matches, so a second call appended the domain again. It is silent on both
# platforms -- nothing errors, the file just grows.
add_to_etc_hosts demo.local 127.0.0.1 >/dev/null 2>&1
add_to_etc_hosts demo.local 127.0.0.1 >/dev/null 2>&1
add_to_etc_hosts demo.local 127.0.0.1 >/dev/null 2>&1

count="$(grep -c '[[:space:]]demo\.local$' "$HOSTS_FILE")"
if [[ "$count" -eq 1 ]]; then
  note "three calls produce exactly one entry"
else
  error "expected 1 entry for demo.local, found $count"
fi

if grep -q 'localhost' "$HOSTS_FILE"; then
  note "existing entries are preserved"
else
  error "pre-existing localhost line was lost"
fi

# A domain that is a prefix of another must not count as present.
add_to_etc_hosts demo.local.uk 127.0.0.2 >/dev/null 2>&1
if grep -q 'demo\.local\.uk' "$HOSTS_FILE"; then
  note "a longer domain sharing a prefix is still added"
else
  error "demo.local.uk was wrongly treated as already present"
fi

# A dot in a hostname is a regex metacharacter. Interpolated into a pattern,
# "demo.local" matches the literal "demoXlocal", so the real entry would be
# judged already present and silently never added.
#
# This needs a file that does NOT already contain demo.local, or the assertion
# passes either way and proves nothing.
wildcard="$tmp/hosts_wildcard"
printf '198.51.100.7\tdemoXlocal\n' > "$wildcard"
HOSTS_FILE="$wildcard" add_to_etc_hosts demo.local 127.0.0.1 >/dev/null 2>&1
if grep -q '[[:space:]]demo\.local$' "$wildcard"; then
  note "a dot is matched literally, not as a wildcard"
else
  error "demo.local was treated as present because 'demoXlocal' matched it as a regex"
fi

# A hostname that is only a substring of a token in the file is not present.
substr="$tmp/hosts_substr"
printf '198.51.100.8\tprefix.other.local\n' > "$substr"
HOSTS_FILE="$substr" add_to_etc_hosts other.local 127.0.0.1 >/dev/null 2>&1
if grep -q '[[:space:]]other\.local$' "$substr"; then
  note "a substring match does not count as present"
else
  error "other.local was treated as present because it is a substring of prefix.other.local"
fi

# Commented-out entries are not entries. In /etc/hosts everything from the
# first # is a comment, wherever on the line it appears.
for fixture in '# 1.2.3.4 commented.local' \
               '   # 1.2.3.4 commented.local' \
               '198.51.100.9\trealhost # commented.local'; do
  tmp2="$tmp/hosts_comment"; printf "$fixture\n" > "$tmp2"
  HOSTS_FILE="$tmp2" add_to_etc_hosts commented.local 127.0.0.1 >/dev/null 2>&1
  if [[ "$(grep -c '^127\.0\.0\.1' "$tmp2")" -eq 1 ]]; then
    note "not present in: ${fixture}"
  else
    error "treated as already present in: ${fixture}"
  fi
done

# A real entry on a line that also carries a comment is still an entry.
tmp3="$tmp/hosts_inline"; printf '198.51.100.10\tlive.local # a note\n' > "$tmp3"
HOSTS_FILE="$tmp3" add_to_etc_hosts live.local 127.0.0.1 >/dev/null 2>&1
if [[ "$(grep -c 'live\.local' "$tmp3")" -eq 1 ]]; then
  note "a host before an inline comment is still found"
else
  error "a host before an inline comment was duplicated"
fi

# Missing arguments must be an error, not an abort in the caller under set -u.
out="$(bash -c 'set -u; source ./helpers.sh; shlib_import logging hosts; add_to_etc_hosts; echo "rc=$?"' 2>&1)"
case "$out" in
  *"unbound variable"*) error "missing arguments aborted the caller: $out" ;;
  *rc=2*) note "missing arguments return 2 under set -u" ;;
  *) error "missing arguments did not return 2: $out" ;;
esac

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
