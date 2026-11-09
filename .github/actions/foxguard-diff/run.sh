#!/usr/bin/env bash
# Report only the findings the review adds. Scanner diagnostics are ephemeral
# and never become job output or artifacts.
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
[[ -d "$scan_path" ]] || fail
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
# The review starts at the merge base of HEAD and the base commit. No base,
# no merge base or an empty range refuses the scan; nothing passes by default.
merge_base="$("$py" -I "$dir/../../../scripts/resolve_scan_base.py" "$scan_path" 2>"$tmp/base.log")" || fail
[[ "$merge_base" =~ ^[0-9a-f]{40}$ || "$merge_base" =~ ^[0-9a-f]{64}$ ]] || fail
# The reviewed config, read at the merge base, or an empty one: an explicit
# --config stops foxguard discovering a .foxguard.yml planted in the tree.
if ! REVIEWED_REF="$merge_base" "$py" -I "$dir/../foxguard-scan/prepare_config.py" "$tmp" >"$tmp/check.log" 2>&1; then fail; fi
config="$(cat "$tmp/config.path")" || fail
# Never scan the action's own checkout as the caller's: the workflows check
# the library out beside the caller's tree, never under it, and a layout
# that puts it under scan_path is refused rather than excluded.
own="$(cd "$dir/../../.." && pwd -P)"
if root="$(cd "$scan_path" 2>/dev/null && pwd -P)" && [[ "$own" == "$root"/* ]]; then fail; fi
# foxguard matches findings by path: a file the review only renames would
# report its old findings as new, so the base it is given has the renames
# (identical content, inside scan_path, and only with an empty config).
fg_base="$("$py" -I "$dir/rename_base.py" "$scan_path" "$merge_base" "$tmp" "$config" 2>"$tmp/base.log")" || fail
[[ "$fg_base" =~ ^[0-9a-f]{40}$ || "$fg_base" =~ ^[0-9a-f]{64}$ ]] || fail
# A review that adds or changes nothing under scan_path (a deletion) may leave
# foxguard nothing to read; only then is a scan of no files a pass.
changed="$(git -C "$scan_path" diff --name-only --diff-filter=ACMRT "$merge_base" HEAD -- . 2>"$tmp/base.log")" || fail
# foxguard skips what .gitignore, .git/info/exclude or .ignore names, and the
# review controls those files: a changed file they name is refused, not read.
if ! "$py" -I -c '
import os, subprocess, sys
env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
def files(*args):
    p = subprocess.run(["git", "-C", sys.argv[1], *args, "--", "."], capture_output=True, env=env)
    if p.returncode:
        sys.exit(1)
    return set(p.stdout.split(b"\0")) - {b""}
changed = files("diff", "--name-only", "-z", "--relative", "--diff-filter=ACMRT", sys.argv[2], "HEAD")
ignored = (files("ls-files", "-z", "-c", "-i", "--exclude-standard")
           | files("ls-files", "-z", "-c", "-i", "--exclude-per-directory=.ignore"))
sys.exit(1 if changed & ignored else 0)
' "$scan_path" "$merge_base" >"$tmp/check.log" 2>&1; then fail; fi
rc=0
GIT_ALTERNATE_OBJECT_DIRECTORIES="$tmp/objects" "$FG_BIN" diff "$fg_base" --config "$config" -f json -s "$severity" \
  --output "$tmp/report.json" "$scan_path" >"$tmp/scan.log" 2>&1 || rc=$?
# 0 is clean, 1 is new findings, anything else a scanner error.
[[ "$rc" -eq 0 ]] || fail
# The report names the base it compared with and how many files were read. A
# scan of nothing (a directory of files foxguard cannot parse, say) is refused
# rather than reported clean, unless the review changed nothing there.
if ! "$py" -I -c '
import json, sys
with open(sys.argv[1], "rb") as fh:
    doc = json.load(fh)
ok = (doc["scanner"]["name"] == "foxguard"
      and doc["finding_counts"]["total"] == 0
      and (doc["target"]["files_scanned"] > 0 or sys.argv[3] == "")
      and doc["target"]["diff_base"] == sys.argv[2])
sys.exit(0 if ok else 1)
' "$tmp/report.json" "$fg_base" "$changed" >"$tmp/check.log" 2>&1; then fail; fi
