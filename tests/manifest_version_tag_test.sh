#!/usr/bin/env bash
# manifest-version.yml's tag-and-dispatch job re-checks the version the
# version job handed over, since that job ran the caller's version_command.
# A value with a second line passes a line-based grep and would write extra
# GITHUB_OUTPUT lines (skipped=true) and a bad tag; it must be refused.
# USAGE: bash tests/manifest_version_tag_test.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 - "$ROOT_DIR/.github/workflows/manifest-version.yml" > "$work/compute.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in wf["jobs"]["tag-and-dispatch"]["steps"] if s.get("id") == "compute"]
assert len(steps) == 1
print(steps[0]["run"])
PY
git -C "$work" init -q repo
fail=0
run() {  # run <version> -> exit code
  : > "$work/out"
  (cd "$work/repo" && env VERSION="$1" TAG_PREFIX=v SKIP_IF_TAGGED=false \
    GITHUB_OUTPUT="$work/out" bash "$work/compute.sh" >/dev/null 2>&1)
}
for good in 1.2.3 1.2.3-rc.1 1.2.3+build.5; do
  run "$good" || { echo "FAIL: refused '$good'"; fail=1; }
  grep -qx "tag=v$good" "$work/out" || { echo "FAIL: no tag for '$good'"; fail=1; }
done
for bad in "" 1.2 v1.2.3 "1.2.3 " $'1.2.3\nskipped=true' $'x\n1.2.3' '1.2.3;id' '-1.2.3'; do
  if run "$bad"; then echo "FAIL: accepted '$bad'"; fail=1; fi
  if grep -q '^skipped=' "$work/out"; then echo "FAIL: wrote outputs for '$bad'"; fail=1; fi
done
(( fail == 0 )) && echo "manifest_version_tag: the handed-over version is checked as one X.Y.Z line"
exit "$fail"
