#!/usr/bin/env bash
# SCRIPT: check_zizmor.sh
# DESCRIPTION: Fail on every zizmor finding, with one exception: a
#              template-injection whose expression is exactly
#              inputs.<name>_command, an input that is shell code by design.
#              A finding that is deliberate carries a
#              `# zizmor: ignore[<audit>]` comment with its reason, which
#              zizmor honours.
# USAGE: ./scripts/check_zizmor.sh [path ...]
# PARAMETERS:
#   path ...    Files or directories to audit (default: .github).
#   -h, --help  Show this help message.
# EXIT CODES:
#   0  No finding outside the exception.
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
errlog="$(mktemp)"
trap 'rm -f "$errlog"' EXIT
report="$(docker run --rm -v "$PWD":/repo:ro -w /repo "$ZIZMOR_IMAGE" \
  --offline --format json "${paths[@]}" 2>"$errlog" || true)"

# shellcheck disable=SC2016 # the Python matches a literal ${{ }}
if ! hits="$(printf '%s' "$report" | python3 -c '
import json, re, sys
findings = json.load(sys.stdin)
for f in findings:
    # Every finding has a Primary location; the first one stands in if not.
    loc = next((l for l in f["locations"] if l["symbolic"].get("kind") == "Primary"),
               f["locations"][0])
    path = loc["symbolic"]["key"]["Local"]["given_path"]
    span = loc["concrete"]["location"]["offset_span"]
    with open(path, "rb") as fh:
        text = fh.read()[span["start"]:span["end"]].decode()
    # The span is the expression body, with or without its ${{ }}.
    expr = re.sub(r"^\$\{\{|\}\}$", "", text.strip()).strip()
    if f["ident"] == "template-injection" and re.fullmatch(r"inputs\.\w+_command", expr):
        continue
    row = loc["concrete"]["location"]["start_point"]["row"] + 1
    note = loc["symbolic"].get("annotation", "")
    print("%s:%d: %s: %s: %s" % (path, row, f["ident"], note, (text.splitlines() or [""])[0][:80]))
')"; then
  echo "zizmor did not produce a report:" >&2
  tail -n 20 "$errlog" >&2
  exit 2
fi

if [[ -n "$hits" ]]; then
  echo "zizmor findings:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo "No zizmor finding outside inputs.<name>_command."
