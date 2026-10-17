#!/usr/bin/env bash
# SCRIPT: check_token_exposure.sh
# DESCRIPTION: Fail when zizmor reports a checkout that keeps its token on disk
#              (artipacked) or a job with broader permissions than it needs
#              (excessive-permissions). Other zizmor audits do not fail this.
# USAGE: ./scripts/check_token_exposure.sh [path ...]
# PARAMETERS:
#   path ...    Files or directories to audit (default: .github).
#   -h, --help  Show this help message.
# EXIT CODES:
#   0  No such finding.
#   1  One or more found; each is listed.
#   2  zizmor could not run.
# ----------------------------------------------------
set -euo pipefail

# zizmor 1.16.3, by digest: a tag can be repointed, a digest cannot.
ZIZMOR_IMAGE="ghcr.io/zizmorcore/zizmor@sha256:f09cee55087d54e7a162fc255ffe82ef942f68e683f967c8a6471ffe35e7ec64"

paths=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) grep '^#[^!]' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) paths+=("$1"); shift ;;
  esac
done
[[ ${#paths[@]} -gt 0 ]] || paths=(.github)

# zizmor exits non-zero whenever it finds anything, so its status alone says
# nothing; an empty or unparsable report is what means it did not run.
report="$(docker run --rm -v "$PWD":/repo:ro -w /repo "$ZIZMOR_IMAGE" \
  --offline --format json "${paths[@]}" 2>/dev/null || true)"

if ! hits="$(printf '%s' "$report" | python3 -c '
import json, sys
findings = json.load(sys.stdin)
for f in findings:
    if f["ident"] not in ("artipacked", "excessive-permissions"):
        continue
    loc = f["locations"][0]
    path = loc["symbolic"]["key"]["Local"]["given_path"]
    row = loc["concrete"]["location"]["start_point"]["row"] + 1
    note = loc["symbolic"].get("annotation", "")
    print("%s:%d: %s: %s" % (path, row, f["ident"], note))
')"; then
  echo "zizmor did not produce a report." >&2
  exit 2
fi

if [[ -n "$hits" ]]; then
  echo "Token exposure found:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo "No persisted credentials and no excessive permissions."
