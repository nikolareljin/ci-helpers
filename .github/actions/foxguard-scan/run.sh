#!/usr/bin/env bash
# Scanner diagnostics are ephemeral and never become job output or artifacts.
set -euo pipefail
umask 077
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$dir/../../../vendor/script-helpers/scripts/security_notice.sh"
fail() { security_notice Foxguard; exit 1; }
py="$(security_python)" || fail
[[ "${FAIL_ON_FINDINGS:-true}" == true ]] || fail
[[ -n "${FG_BIN:-}" && -x "$FG_BIN" ]] || fail
severity="$(printf '%s' "${SEVERITY:-medium}" | tr '[:upper:]' '[:lower:]')"
case "$severity" in low|medium|high|critical) ;; *) fail ;; esac
scan_path="${SCAN_PATH:-.}"
[[ -e "$scan_path" ]] || fail
# A scan_path a tool could read as an option ("-s") is refused; every
# scanner call also passes it after "--".
[[ "$scan_path" != -* ]] || fail
tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/security.XXXXXX")" || fail
# The vetted config may sit in the caller's tree (see prepare_config.py);
# its path is in $tmp/config.path and it goes when the action does.
cleanup() {
  local placed=""
  [[ -s "$tmp/config.path" ]] && placed="$(cat "$tmp/config.path")"
  [[ -n "$placed" ]] && rm -f -- "$placed"
  rm -rf "$tmp"
}
trap cleanup EXIT
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
# The reviewed config, or an empty one: an explicit --config stops foxguard
# discovering a .foxguard.yml planted in the scanned tree.
if ! "$py" -I "$dir/prepare_config.py" "$tmp" >"$tmp/check.log" 2>&1; then fail; fi
config="$(cat "$tmp/config.path")" || fail
# Never scan the action's own checkout as the caller's: foxguard-scan.yml
# checks the library out beside the caller's tree, never under it, and a
# layout that puts it under scan_path is refused rather than excluded.
own="$(cd "$dir/../../.." && pwd -P)"
if root="$(cd "$scan_path" 2>/dev/null && pwd -P)" && [[ "$own" == "$root"/* ]]; then fail; fi
rc=0
"$FG_BIN" --config "$config" -f json -q -s "$severity" \
  --output "$tmp/report.json" -- "$scan_path" >"$tmp/scan.log" 2>&1 || rc=$?
# 0 is clean, 1 is findings, anything else a scanner error.
[[ "$rc" -eq 0 ]] || fail
# The report says how many files were read. A scan of nothing (a directory of
# files foxguard cannot parse, say) is refused rather than reported clean.
if ! "$py" -I -c '
import json, sys
with open(sys.argv[1], "rb") as fh:
    doc = json.load(fh)
ok = (doc["scanner"]["name"] == "foxguard"
      and doc["finding_counts"]["total"] == 0
      and doc["target"]["files_scanned"] > 0)
sys.exit(0 if ok else 1)
' "$tmp/report.json" >"$tmp/check.log" 2>&1; then fail; fi
