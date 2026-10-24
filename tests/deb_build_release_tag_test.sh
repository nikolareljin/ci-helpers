#!/usr/bin/env bash
# SCRIPT: deb_build_release_tag_test.sh
# DESCRIPTION: Runs deb-build.yml's "Resolve release tag" step as written and
#              checks the release it names follows what was built: release_tag,
#              else ref, else the workflow's own ref. Without that, a tag push of
#              1.0.0 with ref 0.9.0 attached 0.9.0's packages to release 1.0.0.
# USAGE: bash tests/deb_build_release_tag_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 - "$root/.github/workflows/deb-build.yml" "$tmp/resolve.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in d["jobs"]["build"]["steps"] if s.get("id") == "resolve"]
assert len(steps) == 1, "want one step with id resolve"
open(sys.argv[2], "w").write(steps[0]["run"])
PY

fail=0
# case: GITHUB_REF  UPLOAD_MODE  release_tag  ref  -> expected ("tag=X", "skip", or "error")
check() {
  local gref="$1" mode="$2" rtag="$3" ref="$4" want="$5" out rc got
  out="$tmp/out"; : > "$out"
  rc=0
  GITHUB_REF="$gref" GITHUB_REF_NAME="${gref#refs/*/}" UPLOAD_MODE="$mode" \
    INPUT_TAG="$rtag" INPUT_REF="$ref" GITHUB_OUTPUT="$out" \
    bash "$tmp/resolve.sh" >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then got="error"
  elif grep -qx 'skip=true' "$out"; then got="skip"
  else got="$(grep '^tag=' "$out" || true)"; fi
  if [[ "$got" == "$want" ]]; then
    echo "ok: ${gref} mode=${mode} release_tag=${rtag:-''} ref=${ref:-''} -> ${got}"
  else
    echo "FAIL: ${gref} mode=${mode} release_tag=${rtag:-''} ref=${ref:-''}: want ${want}, got ${got}"
    fail=1
  fi
}

check refs/tags/1.0.0 auto ""    ""               "tag=1.0.0"
check refs/heads/main auto ""    ""               "skip"
check refs/tags/1.0.0 auto ""    0.9.0            "tag=0.9.0"
check refs/heads/main true ""    0.9.0            "tag=0.9.0"
check refs/heads/main auto ""    refs/tags/0.9.0  "tag=0.9.0"
check refs/heads/main auto ""    main             "skip"
check refs/heads/main true ""    main             "error"
check refs/heads/main auto 0.8.0 0.9.0            "tag=0.8.0"
check refs/heads/main true 0.8.0 ""               "tag=0.8.0"

exit "$fail"
