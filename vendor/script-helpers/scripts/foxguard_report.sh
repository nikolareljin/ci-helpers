#!/usr/bin/env bash
# SCRIPT: foxguard_report.sh
# DESCRIPTION: Scan files with foxguard and write the findings as formatted JSON, to keep as evidence or compare later.
# USAGE: bash scripts/foxguard_report.sh [--base <ref>] [--output <file>] [--] [<path>...]
# PARAMETERS:
#   --base <ref>     Scan the files changed between <ref> and HEAD (the pre-push
#                    hook prints this with the remote's commit). Default when no
#                    paths are given: the upstream branch, else origin/HEAD.
#   --output <file>  Where to write the JSON (default: foxguard-report.json).
#   <path>...        Scan these files instead of a range.
# EXIT_CODES:
#   0  No findings.
#   1  Findings (written to the file).
#   2  Usage or git error, the report could not be written, or a file could not
#      be scanned (listed under "errors").
#   3  foxguard not installed and not installable here.
# EXAMPLE:
#   bash scripts/script-helpers/scripts/foxguard_report.sh --base origin/main --output foxguard-report.json
# ----------------------------------------------------
set -euo pipefail

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="" output="foxguard-report.json"
paths=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) [[ $# -ge 2 ]] || { echo "[foxguard_report] --base needs a ref" >&2; exit 2; }; base="$2"; shift ;;
    --output) [[ $# -ge 2 ]] || { echo "[foxguard_report] --output needs a file" >&2; exit 2; }; output="$2"; shift ;;
    -h|--help) sed -n '2,/^# ------/p' "${BASH_SOURCE[0]}" | sed -e '/^# ---/d' -e 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; paths+=("$@"); break ;;
    -*) echo "[foxguard_report] unknown option: $1" >&2; exit 2 ;;
    *) paths+=("$1") ;;
  esac
  shift
done

# shellcheck source=/dev/null
source "$src_root/helpers.sh"
shlib_import logging foxguard
if ! bin="$(foxguard_bin)"; then
  if [[ -n "${CI:-}" || "${SCRIPT_HELPERS_NO_AUTO_INSTALL:-}" == 1 ]]; then
    echo "[foxguard_report] foxguard is not installed (not installing: CI or SCRIPT_HELPERS_NO_AUTO_INSTALL=1). See docs/security-gates.md." >&2
    exit 3
  fi
  echo "[foxguard_report] foxguard is not installed; installing the pinned release." >&2
  foxguard_install >&2 || exit 3
  bin="$(foxguard_bin)" || exit 3
fi

if [[ ${#paths[@]} -eq 0 ]]; then
  if [[ -z "$base" ]]; then
    base="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    [[ -n "$base" ]] || base="origin/HEAD"
  fi
  git rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "[foxguard_report] not a commit: $base" >&2; exit 2; }
  # No common history: the range below would fail inside <(...) and read as
  # "nothing changed".
  git merge-base "$base" HEAD >/dev/null 2>&1 || { echo "[foxguard_report] $base and HEAD share no history; name the files instead." >&2; exit 2; }
  while IFS= read -r -d '' f; do
    [[ -f "$f" ]] && paths+=("$f")
  # Three dots: what HEAD changed since it left <ref>, not what <ref> gained since.
  done < <(git diff -z --name-only --diff-filter=ACMR "$base...HEAD")
fi
if [[ ${#paths[@]} -eq 0 ]]; then
  echo "[foxguard_report] no files to scan${base:+ (nothing changed since $base)}." >&2
  exit 0
fi

py="$(command -v python3 || command -v python || true)"
[[ -n "$py" ]] || { echo "[foxguard_report] python3 is needed to write the JSON." >&2; exit 2; }
# foxguard takes one path per run, and exits 0 with -f json whatever it finds:
# run it per file and count the findings from its output.
rc=0
"$py" -I -c '
import json, subprocess, sys
fox, out, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
report = {"tool": "foxguard", "files": [], "findings": [], "errors": []}
v = subprocess.run([fox, "--version"], capture_output=True, text=True)
report["version"] = (v.stdout or v.stderr).strip() or None
for p in paths:
    r = subprocess.run([fox, "-f", "json", "-q", p], capture_output=True, text=True)
    try:
        doc = json.loads(r.stdout)
    except ValueError:
        report["errors"].append({"file": p, "exit": r.returncode, "message": (r.stderr or r.stdout).strip()[:500]})
        continue
    report["files"].append(p)
    for f in doc.get("findings", []):
        f.setdefault("file", p)
        report["findings"].append(f)
sev = {}
for f in report["findings"]:
    s = str(f.get("severity", "unknown")).lower()
    sev[s] = sev.get(s, 0) + 1
report["finding_counts"] = {"total": len(report["findings"]), "by_severity": sev}
try:
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, sort_keys=True)
        fh.write("\n")
except OSError as e:
    print("[foxguard_report] could not write %s: %s" % (out, e), file=sys.stderr)
    sys.exit(2)
print("[foxguard_report] %d file(s) scanned, %d finding(s), %d error(s); results in %s"
      % (len(report["files"]), len(report["findings"]), len(report["errors"]), out))
# A file that could not be scanned is not a clean one.
sys.exit(2 if report["errors"] else (1 if report["findings"] else 0))
' "$bin" "$output" "${paths[@]}" || rc=$?
exit "$rc"
