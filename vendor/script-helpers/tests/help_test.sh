#!/usr/bin/env bash
# SCRIPT: help_test.sh
# DESCRIPTION: Tests for header-comment metadata extraction and help rendering.
# USAGE: bash tests/help_test.sh
# ----------------------------------------------------
#
# lib/help.sh used to return its result through a bash 4.3 nameref, so every
# --help path in this library was dead on the bash 3.2 that macOS ships. It now
# writes "<prefix>_<field>" variables instead; these tests pin that contract.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging help

failures=0
note()  { echo "[help_test] $*"; }
error() { echo "[help_test][ERROR] $*" >&2; failures=$((failures+1)); }

expect() {
  local label="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then note "$label"; else error "$label: want '$want', got '$got'"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/sample.sh" <<'EOF'
#!/usr/bin/env bash
# SCRIPT: sample.sh
# DESCRIPTION: A sample used by the tests.
# USAGE: sample.sh [OPTIONS]
# PARAMETERS:
#   --alpha   the first
#   --beta    the second
# EXAMPLE: sample.sh --alpha
# EXIT_CODES: 0 ok
#   2 bad arguments
# AUTHOR: nobody
# VERSION: 1.2.3
echo body
EOF

get_script_metadata "$tmp/sample.sh" meta

expect "single-line field: name"        "sample.sh"                    "$meta_name"
expect "single-line field: description" "A sample used by the tests."  "$meta_description"
expect "single-line field: version"     "1.2.3"                        "$meta_version"
expect "single-line field: author"      "nobody"                       "$meta_author"
expect "single-line field: example"     "sample.sh --alpha"            "$meta_example"

# Continuation lines belong to the field above them.
case "$meta_exit_codes" in
  *"0 ok"*) case "$meta_exit_codes" in
              *"2 bad arguments"*) note "multi-line field accumulates continuations" ;;
              *) error "exit_codes lost its continuation line: $meta_exit_codes" ;;
            esac ;;
  *) error "exit_codes did not capture the first line: $meta_exit_codes" ;;
esac

case "$meta_param_lines" in
  *"--alpha"*) case "$meta_param_lines" in
                 *"--beta"*) note "param_lines collects every parameter" ;;
                 *) error "param_lines lost --beta: $meta_param_lines" ;;
               esac ;;
  *) error "param_lines lost --alpha: $meta_param_lines" ;;
esac

# Tab-indented continuation lines. `\t` in a bash [[ =~ ]] regex is not a tab,
# so this header lost its PARAMETERS block entirely and rendered no Parameters
# section at all -- the same silent shape as the GNU \s and \b this release
# removed. printf rather than a heredoc so the tabs cannot be reformatted away.
printf '#!/usr/bin/env bash\n# SCRIPT: tabbed.sh\n# DESCRIPTION: tabbed\n# PARAMETERS:\n#\t--alpha\tthe first\n#\t--beta\tthe second\n# EXIT_CODES: 0 ok\n#\t2 bad arguments\n# ----------------------------------------------------\n' > "$tmp/tabbed.sh"
get_script_metadata "$tmp/tabbed.sh" tabbed
case "${tabbed_param_lines}" in
  *"--alpha"*) case "${tabbed_param_lines}" in
                 *"--beta"*) note "tab-indented param lines are collected" ;;
                 *) error "tab-indented param_lines lost --beta: ${tabbed_param_lines}" ;;
               esac ;;
  *) error "tab-indented param_lines lost --alpha: ${tabbed_param_lines}" ;;
esac
case "${tabbed_exit_codes}" in
  *"2 bad arguments"*) note "tab-indented continuation lines accumulate" ;;
  *) error "a tab-indented continuation line was dropped: ${tabbed_exit_codes}" ;;
esac
# The indentation of a space-indented block is rendered as written, so the fix
# must consume exactly one whitespace character, not a greedy run of them.
case "${meta_param_lines}" in
  "  --alpha"*) note "space indentation beyond the first column is preserved" ;;
  *) error "leading indentation was eaten: [${meta_param_lines}]" ;;
esac

# The prefix is the contract: two prefixes must not collide.
cat > "$tmp/other.sh" <<'EOF'
#!/usr/bin/env bash
# SCRIPT: other.sh
# VERSION: 9.9.9
EOF
get_script_metadata "$tmp/other.sh" second
expect "a second prefix is independent" "other.sh"  "$second_name"
expect "the first prefix is untouched"  "sample.sh" "$meta_name"

# Fields absent from a header must be empty, not stale from the previous call.
get_script_metadata "$tmp/other.sh" meta
expect "re-use of a prefix clears old values" "" "$meta_description"

# Indirect expansion is how callers are documented to read these back.
ref="second_version"
expect "readable by indirect expansion" "9.9.9" "${!ref}"

# A file with no header must not error, and must still render.
printf '#!/usr/bin/env bash\necho hi\n' > "$tmp/bare.sh"
get_script_metadata "$tmp/bare.sh" bare
expect "a header-less file yields empty fields" "" "$bare_name"

for mode in display_help print_help show_help; do
  if out="$("$mode" "$tmp/sample.sh" 2>&1)"; then
    case "$out" in
      *"sample.sh"*) note "$mode renders the script name" ;;
      *) error "$mode did not mention the script: $out" ;;
    esac
  else
    error "$mode returned non-zero"
  fi
done

if out="$(display_help "$tmp/does-not-exist.sh" 2>&1)"; then
  error "display_help succeeded on a missing file"
else
  note "display_help fails on a missing file"
fi

# The prefix becomes half a variable name. An invalid one must be refused up
# front rather than turning every assignment into a printf error, and an empty
# one must not silently write _name, _usage and friends.
for bad in "" "a-b" "1abc" "has space" 'x;y'; do
  if get_script_metadata "$tmp/sample.sh" "$bad" >/dev/null 2>&1; then
    error "an invalid prefix '$bad' was accepted"
  fi
done
note "invalid prefixes are refused"

# A *missing* argument, not an empty one: under `set -u` a bare "$2" aborts on
# the expansion before any validation can run, so the two are not the same test.
out="$(bash -c 'set -u; source ./helpers.sh; shlib_import logging help; get_script_metadata '"$tmp"'/sample.sh; echo "rc=$?"' 2>&1)"
case "$out" in
  *"unbound variable"*) error "a missing prefix aborted the caller under set -u: $out" ;;
  *rc=2*) note "a missing prefix returns 2 under set -u" ;;
  *) error "a missing prefix did not return 2: $out" ;;
esac

out="$(bash -c 'set -u; source ./helpers.sh; shlib_import logging help; get_script_metadata; echo "rc=$?"' 2>&1)"
case "$out" in
  *"unbound variable"*) error "no arguments at all aborted the caller: $out" ;;
  *rc=2*) note "no arguments returns 2 under set -u" ;;
  *) error "no arguments did not return 2: $out" ;;
esac

# An unreadable script file, from a caller under `set -e`. Left to the
# redirection on the read loop this aborted the caller with a raw
# "No such file or directory" citing lib/help.sh and a line number -- not the
# path the caller passed. A directory was worse: the redirection succeeds, read
# fails without assigning, and the loop condition aborted on an unbound
# variable. display_help guards this; get_script_metadata is public API too.
for bad_path in "$tmp/no-such-file.sh" "$tmp"; do
  out="$(bash -c 'set -euo pipefail; source ./helpers.sh; shlib_import logging help; get_script_metadata "$1" meta || echo "rc=$?"' _ "$bad_path" 2>&1)"
  case "$out" in
    *"unbound variable"*|*"read error"*)
      error "an unreadable path aborted the caller instead of returning: $out" ;;
    *"No such file or directory"*)
      error "an unreadable path failed on the redirection, not the guard: $out" ;;
    *rc=2*)
      case "$out" in
        *"$bad_path"*) note "an unreadable path returns 2 and names the path" ;;
        *) error "the refusal did not name the path: $out" ;;
      esac ;;
    *) error "an unreadable path did not return 2: $out" ;;
  esac
done

get_script_metadata "$tmp/sample.sh" "" >/dev/null 2>&1
rc=$?
expect "an invalid prefix returns 2 (bad arguments)" "2" "$rc"

msg="$(get_script_metadata "$tmp/sample.sh" "a-b" 2>&1)" || true
case "$msg" in
  *prefix*) note "the refusal names the prefix" ;;
  *) error "the refusal did not mention the prefix: $msg" ;;
esac

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
