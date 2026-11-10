#!/usr/bin/env bash
# Scan the commits under review for secrets. Scanner diagnostics are
# ephemeral and never become job output or artifacts.
set -euo pipefail
umask 077
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$dir/../../../vendor/script-helpers/scripts/security_notice.sh"
fail() { security_notice Gitleaks; exit 1; }
py="$(security_python)" || fail
"$py" -I -c 'import tomllib' >/dev/null 2>&1 || fail
[[ "${FAIL_ON_FINDINGS:-true}" == true ]] || fail
[[ -n "${GL_BIN:-}" && -x "$GL_BIN" ]] || fail
scan_path="${SCAN_PATH:-.}"
[[ -d "$scan_path" ]] || fail
# A scan_path a tool could read as an option ("-s") is refused; every
# scanner call also passes it after "--".
[[ "$scan_path" != -* ]] || fail
tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/security.XXXXXX")" || fail
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
if ! "$py" -I -c '
import os, subprocess, sys
path = os.path.realpath(sys.argv[1])
workspace = os.path.realpath(os.environ.get("GITHUB_WORKSPACE", os.getcwd()))
try:
    inside = os.path.commonpath([path, workspace]) == workspace
except ValueError:
    inside = False
if inside:
    sys.exit(1)
env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
p = subprocess.run(["git", "-C", path, "rev-parse", "--is-inside-work-tree"], capture_output=True, env=env)
sys.exit(p.returncode == 0 and p.stdout.strip() == b"true")
' "$tmp" >"$tmp/check.log" 2>&1; then fail; fi
# The review starts at the merge base of HEAD and the base commit. No base,
# no merge base or an empty range refuses the scan; nothing passes by default.
merge_base="$("$py" -I "$dir/../../../scripts/resolve_scan_base.py" "$scan_path" 2>"$tmp/base.log")" || fail
[[ "$merge_base" =~ ^[0-9a-f]{40}$ || "$merge_base" =~ ^[0-9a-f]{64}$ ]] || fail
# Rules and the approved ignore list come from the base commit, so a config
# or .gitleaksignore the review adds cannot silence what it adds.
if ! REVIEWED_REF="$merge_base" "$py" -I "$dir/../gitleaks-scan/prepare_rules.py" "$tmp" >"$tmp/check.log" 2>&1; then fail; fi
# gitleaks also reads <source>/.gitleaksignore, beside the approved copy it is
# given, so a work tree whose file differs from the base's could silence what
# the review adds. Refused rather than merged: the two must be the same bytes.
tree_ignore="$scan_path/.gitleaksignore"
if [[ -e "$tree_ignore" || -L "$tree_ignore" ]]; then
  if [[ -L "$tree_ignore" || ! -f "$tree_ignore" ]] || ! cmp -s "$tree_ignore" "$tmp/approved-ignore"; then fail; fi
fi
# `git` mode over the reviewed range reads every commit's patch, so a secret
# added in one commit and removed in a later one of the same review is found.
args=(git --log-opts="${merge_base}..HEAD" --config "$tmp/rules.toml"
  --gitleaks-ignore-path "$tmp/approved-ignore" --ignore-gitleaks-allow
  --max-archive-depth 3 --no-color --no-banner --exit-code 3 --redact -- "$scan_path")
rc=0
diagnostics="$("$GL_BIN" "${args[@]}" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail
# Read the whole pipe: grep -q can turn printf into a SIGPIPE under pipefail.
if printf '%s\n' "$diagnostics" | grep -E 'git error encountered|fatal: ' >/dev/null; then fail; fi
