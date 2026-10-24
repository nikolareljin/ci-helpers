#!/usr/bin/env bash
# SCRIPT: release_upload_check_test.sh
# DESCRIPTION: Runs release-upload.yml's "Check the tag and the files" step as
#              written: it must refuse an empty or multi-word tag, a files glob
#              that leaves the artifact, and a glob that matches no files, and
#              accept a glob that matches (files only, not directories).
# USAGE: bash tests/release_upload_check_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 - "$root/.github/workflows/release-upload.yml" "$tmp/check.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = [s for j in d["jobs"].values() for s in j["steps"] if s.get("name") == "Check the tag and the files"]
assert len(steps) == 1, "want one 'Check the tag and the files' step"
open(sys.argv[2], "w").write(steps[0]["run"])
PY

mkdir -p "$tmp/w/release-files/sub.rpm"
touch "$tmp/w/release-files/a.rpm" "$tmp/w/release-files/b.rpm"
fail=0
check() {
  local tag="$1" files="$2" want="$3" got
  if (cd "$tmp/w" && IN_TAG="$tag" IN_FILES="$files" bash "$tmp/check.sh" >"$tmp/out" 2>&1); then
    got="ok:$(grep -c '^will attach:' "$tmp/out")"
  else
    got="refused"
  fi
  if [[ "$got" == "$want" ]]; then
    echo "ok: tag='${tag}' files='${files}' -> ${got}"
  else
    echo "FAIL: tag='${tag}' files='${files}': want ${want}, got ${got}"; cat "$tmp/out"; fail=1
  fi
}
check 1.0.0  '*.rpm'   ok:2      # the directory sub.rpm is not a file
check 1.0.0  '*'       ok:2
check 1.0.0  '*.deb'   refused
check ''     '*.rpm'   refused
check '1 0'  '*.rpm'   refused
check 1.0.0  '../x'    refused
check 1.0.0  '/etc/*'  refused
# Leaves the directory yet matches files: only the path guard refuses these.
check 1.0.0  '../release-files/*.rpm'  refused
check 1.0.0  "/${tmp#/}/w/release-files/*.rpm"  refused
exit "$fail"
