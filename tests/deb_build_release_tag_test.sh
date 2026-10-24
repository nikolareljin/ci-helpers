#!/usr/bin/env bash
# SCRIPT: deb_build_release_tag_test.sh
# DESCRIPTION: Runs the "Resolve release tag" step of deb-build.yml and
#              rpm-build.yml as written and checks the release it names follows
#              what was built: release_tag, else ref, else the workflow's own ref. Without that, a tag push of
#              1.0.0 with ref 0.9.0 attached 0.9.0's packages to release 1.0.0.
# USAGE: bash tests/deb_build_release_tag_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
for wf in deb-build rpm-build; do
python3 - "$root/.github/workflows/${wf}.yml" "$tmp/resolve.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in d["jobs"]["build"]["steps"] if s.get("id") == "resolve"]
assert len(steps) == 1, "want one step with id resolve"
open(sys.argv[2], "w").write(steps[0]["run"])
PY
echo "-- ${wf}"
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
check refs/tags/1.0.0 false ""   ""               "skip"
check refs/heads/main auto ""    ""               "skip"
check refs/tags/1.0.0 auto ""    0.9.0            "tag=0.9.0"
check refs/heads/main true ""    0.9.0            "tag=0.9.0"
check refs/heads/main auto ""    refs/tags/0.9.0  "tag=0.9.0"
check refs/heads/main auto ""    main             "skip"
check refs/heads/main true ""    main             "error"
check refs/heads/main auto 0.8.0 0.9.0            "tag=0.8.0"
check refs/heads/main true 0.8.0 ""               "tag=0.8.0"
done

# A new tag is created where the packages came from: the built commit, which
# ref can make differ from github.sha.
# A new tag is created where the packages came from: the built commit, which
# ref can make differ from github.sha.
python3 - "$root/.github/workflows" <<'PY' || fail=1
import sys, yaml
wf = sys.argv[1]
def load(name):
    d = yaml.safe_load(open(f"{wf}/{name}"))
    return d, d.get("on", d.get(True))

for name in ("deb-build.yml", "rpm-build.yml"):
    d, _ = load(name)
    build = d["jobs"]["build"]
    assert build["outputs"].get("commit") == "${{ steps.built.outputs.commit }}", f"{name}: build job has no commit output"
    steps = build["steps"]
    built = [s for s in steps if s.get("id") == "built"]
    assert built and "git rev-parse HEAD" in built[0]["run"], f"{name}: no step records the built commit"
    first_checkout = next(i for i, s in enumerate(steps) if s.get("uses", "").startswith("actions/checkout"))
    assert first_checkout < steps.index(built[0]), f"{name}: built commit recorded before checkout"

d, on = load("deb-build.yml")
up = [s for s in d["jobs"]["release"]["steps"] if s.get("uses", "").startswith("softprops/action-gh-release")]
assert len(up) == 1 and up[0]["with"].get("target_commitish") == "${{ needs.build.outputs.commit }}", "deb-build: upload does not pass target_commitish"
assert on["workflow_call"]["inputs"]["release_notes"]["default"] is True
for s in d["jobs"]["build"]["steps"]:
    if s.get("id") == "notes" or s.get("name") == "Checkout script-helpers for release notes":
        assert "inputs.release_notes" in s.get("if", ""), f"deb-build: {s.get('name')}: not guarded by release_notes"
print("ok: deb-build creates a new tag at the built commit; release_notes: false skips the notes")

# rpm-build stays read-only (a write job would stop read-only callers from
# starting) and hands release-upload.yml what it needs.
d, on = load("rpm-build.yml")
for jn, j in d["jobs"].items():
    assert j.get("permissions") == {"contents": "read"}, f"rpm-build: job {jn} asks for {j.get('permissions')}"
outs = on["workflow_call"]["outputs"]
for k in ("artifact_id", "tag", "commit", "skip"):
    assert k in outs, f"rpm-build: no workflow output {k}"
assert on["workflow_call"]["inputs"]["upload_to_release"]["default"] == "false"
d, on = load("release-upload.yml")
up = [s for j in d["jobs"].values() for s in j["steps"] if s.get("uses", "").startswith("softprops/action-gh-release")]
assert len(up) == 1, "release-upload: want one upload step"
w = up[0]["with"]
assert w.get("target_commitish") == "${{ inputs.commit }}", "release-upload: no target_commitish"
assert "body" not in w and "body_path" not in w, "release-upload must not change the release body"
print("ok: rpm-build is read-only with release outputs; release-upload leaves notes alone and tags the built commit")
PY

exit "$fail"
