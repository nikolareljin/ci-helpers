#!/usr/bin/env bash
# Scanner diagnostics are ephemeral and never become job output or artifacts.
set -euo pipefail
umask 077
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$dir/../../../vendor/script-helpers/scripts/security_notice.sh"
fail() { security_notice Gitleaks; exit 1; }
py="$(security_python)" || fail
"$py" -I -c 'import tomllib' >/dev/null 2>&1 || fail
[[ "${UPLOAD_ARTIFACT:-false}" == false && "${FAIL_ON_FINDINGS:-true}" == true ]] || fail
[[ -n "${GL_BIN:-}" && -x "$GL_BIN" ]] || fail
scan_path="${SCAN_PATH:-.}"
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
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! "$py" -I "$dir/prepare_rules.py" "$tmp" >"$tmp/check.log" 2>&1; then fail; fi
# gitleaks also reads <source>/.gitleaksignore, beside the approved copy it is
# given, so a work tree whose file differs from the base's could silence what
# the review adds. Refused rather than merged: the two must be the same bytes.
tree_ignore="$scan_path/.gitleaksignore"
if [[ -e "$tree_ignore" || -L "$tree_ignore" ]]; then
  if [[ -L "$tree_ignore" || ! -f "$tree_ignore" ]] || ! cmp -s "$tree_ignore" "$tmp/approved-ignore"; then fail; fi
fi
args=(detect --source "$scan_path" --config "$tmp/rules.toml" --gitleaks-ignore-path "$tmp/approved-ignore"
  --ignore-gitleaks-allow --max-archive-depth 3 --no-color --no-banner
  --exit-code 3 --redact)
if ! git -C "$scan_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  args+=(--no-git)
fi
rc=0
diagnostics="$("$GL_BIN" "${args[@]}" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail
# Read the whole pipe: grep -q can turn printf into a SIGPIPE under pipefail.
if printf '%s\n' "$diagnostics" | grep -E 'git error encountered|fatal: not a git repository|scanned ~0 bytes' >/dev/null; then fail; fi
