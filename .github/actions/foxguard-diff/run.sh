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
config_set=0
if grep -q '[^[:space:]]' "$config"; then config_set=1; fi
fg_base="$("$py" -I "$dir/rename_base.py" "$scan_path" "$merge_base" "$tmp" "$config_set" 2>"$tmp/base.log")" || fail
[[ "$fg_base" =~ ^[0-9a-f]{40}$ || "$fg_base" =~ ^[0-9a-f]{64}$ ]] || fail
# A review that adds or changes nothing under scan_path (a deletion) may leave
# foxguard nothing to read; only then is a scan of no files a pass.
changed="$(git -C "$scan_path" diff --name-only --diff-filter=ACMRT "$merge_base" HEAD -- . 2>"$tmp/base.log")" || fail
# foxguard skips what .gitignore, .git/info/exclude or .ignore names, and the
# review controls those files. Refused: a .gitignore or .ignore anywhere in
# the repository that is a link (git does not read one, foxguard does), and a
# changed file that the head tree's rules name. An ignore file edit that
# hides no changed file passes.
if ! "$py" -I -c '
import os, subprocess, sys
env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
def files(*args, where="."):
    p = subprocess.run(["git", "-C", sys.argv[1], *args, "--", where], capture_output=True, env=env)
    if p.returncode:
        sys.exit(1)
    return set(p.stdout.split(b"\0")) - {b""}
def is_rules(path):
    return path.rsplit(b"/", 1)[-1] in (b".gitignore", b".ignore")
top = ":/"
for entry in files("ls-files", "-z", "-s", where=top):
    meta, _, path = entry.partition(b"\t")
    if is_rules(path) and meta.startswith(b"120000 "):
        sys.exit(1)
changed = files("diff", "--name-only", "-z", "--relative", "--diff-filter=ACMRT", sys.argv[2], "HEAD")
ignored = (files("ls-files", "-z", "-c", "-i", "--exclude-standard")
           | files("ls-files", "-z", "-c", "-i", "--exclude-per-directory=.ignore"))
sys.exit(1 if changed & ignored else 0)
' "$scan_path" "$merge_base" >"$tmp/check.log" 2>&1; then fail; fi
# git splits GIT_ALTERNATE_OBJECT_DIRECTORIES on ':' unless the entry is C-quoted.
alt="$tmp/objects"; alt="${alt//\\/\\\\}"; alt="\"${alt//\"/\\\"}\""
rc=0
GIT_ALTERNATE_OBJECT_DIRECTORIES="$alt" "$FG_BIN" diff "$fg_base" --config "$config" -f json -s "$severity" \
  --output "$tmp/report.json" -- "$scan_path" >"$tmp/scan.log" 2>&1 || rc=$?
# 0 is clean, 1 is new findings, anything else a scanner error.
[[ "$rc" -eq 0 ]] || fail
# The report names the base it compared with and how many files were read;
# report_ok prints that count.
report_ok() {
  "$py" -I -c '
import json, sys
with open(sys.argv[1], "rb") as fh:
    doc = json.load(fh)
if not (doc["scanner"]["name"] == "foxguard"
        and doc["finding_counts"]["total"] == 0
        and doc["target"]["diff_base"] == sys.argv[2]):
    sys.exit(1)
print(int(doc["target"]["files_scanned"]))
' "$tmp/report.json" "$1" 2>"$tmp/check.log"
}
read_count="$(report_ok "$fg_base")" || fail
# foxguard skips hidden entries, what its own reading of the ignore files
# names, and some paths and names (vendor/, build/, a.min.js) even when they
# are named, on the base side too. So every changed regular file is also
# copied, base and head, to neutral paths in a repository of its own
# (neutral_tree.py) and scanned there in one call; no path of the review
# decides whether a changed file is read.
# A reviewed config comes along with its ignore paths moved to the neutral
# names; it is read on stdin, so neutral_tree.py opens no path.
neutral_config="$config"
neutral_arg=""
[[ "$config_set" == 1 ]] && neutral_arg="$config"
"$py" -I "$dir/neutral_tree.py" "$scan_path" "$merge_base" "$fg_base" "$tmp" "$neutral_arg" \
  <"$config" >"$tmp/neutral.out" 2>"$tmp/base.log" || fail
neutral_base="$(head -n 1 "$tmp/neutral.out")"
[[ "$neutral_base" =~ ^[0-9a-f]{40}$ || "$neutral_base" =~ ^[0-9a-f]{64}$ ]] || fail
if [[ "$config_set" == 1 ]]; then
  tail -n +2 "$tmp/neutral.out" >"$tmp/neutral/.foxguard-reviewed.yml" || fail
  neutral_config="$tmp/neutral/.foxguard-reviewed.yml"
fi
mkdir "$tmp/home" || fail
rc=0
(cd "$tmp/neutral" && env -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_DIR -u GIT_WORK_TREE \
  HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  "$FG_BIN" diff "$neutral_base" --config "$neutral_config" -f json -s "$severity" \
  --output "$tmp/report.json" -- .) >"$tmp/scan.log" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail
# neutral_tree.py refuses a changed file over foxguard's --max-file-size
# (1 MiB) before the scan; a skip the log reports is refused too.
if grep -q -e 'exceeds --max-file-size' -e '[0-9] too large' "$tmp/scan.log"; then fail; fi
n="$(report_ok "$neutral_base")" || fail
read_count=$((read_count + n))
# A scan of nothing (files foxguard cannot parse, say) is refused rather
# than reported clean, unless the review changed nothing there.
[[ "$read_count" -gt 0 || -z "$changed" ]] || fail
