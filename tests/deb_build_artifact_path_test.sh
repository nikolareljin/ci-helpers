#!/usr/bin/env bash
# SCRIPT: deb_build_artifact_path_test.sh
# DESCRIPTION: actions/upload-artifact refuses a path with a '..' segment,
#              so no workflow may default an uploaded path to one.
#              Then run deb-build.yml's "Collect the built packages" step on a
#              fake runner layout: the .deb files dpkg-buildpackage leaves next
#              to working_directory land where the default artifact_glob
#              points; no .deb fails. The step runs only for the default glob,
#              so a caller glob such as '**/*.deb' never matches a copy too.
# USAGE: bash tests/deb_build_artifact_path_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$root/.github/workflows" "$work/step.sh" "$work/default" <<'PY'
import glob, os, re, sys, yaml
bad = []
for wf in sorted(glob.glob(os.path.join(sys.argv[1], "*.yml"))):
    d = yaml.safe_load(open(wf))
    on = d.get(True) or d.get("on") or {}
    inputs = (on.get("workflow_call") or {}).get("inputs") or {} if isinstance(on, dict) else {}
    for job in (d.get("jobs") or {}).values():
        for s in job.get("steps") or []:
            if "actions/upload-artifact@" not in str(s.get("uses", "")):
                continue
            path = str((s.get("with") or {}).get("path", ""))
            for name in re.findall(r"inputs\.([A-Za-z0-9_-]+)", path):
                default = str((inputs.get(name) or {}).get("default", ""))
                for line in default.replace(",", "\n").splitlines():
                    if ".." in line.strip().split("/"):
                        bad.append(f"{os.path.basename(wf)}: input {name} defaults to {default!r}")
assert not bad, "upload-artifact refuses '..' segments:\n" + "\n".join(bad)

d = yaml.safe_load(open(os.path.join(sys.argv[1], "deb-build.yml")))
steps = d["jobs"]["build"]["steps"]
names = [s.get("name") for s in steps]
assert "Collect the built packages" in names, "no Collect the built packages step"
assert names.index("Build package") < names.index("Collect the built packages") < names.index("Upload artifacts")
collect = steps[names.index("Collect the built packages")]
inputs = (d.get(True) or d.get("on"))["workflow_call"]["inputs"]
default = inputs["artifact_glob"]["default"]
want = "${{ inputs.artifact_glob == '%s' }}" % default
assert collect.get("if") == want, f"collect step must run only for the default glob: if is {collect.get('if')!r}, wanted {want!r}"
open(sys.argv[2], "w").write(collect["run"])
open(sys.argv[3], "w").write(default)
PY
default="$(cat "$work/default")"

fail=0
# run_step <workspace> <working_directory>
run_step() {
  (cd "$1/$2" && GITHUB_WORKSPACE="$1" bash "$work/step.sh") > "$work/out" 2>&1
}
expect() { # expect <description> <rc wanted> <rc got>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (rc $3, wanted $2)"; cat "$work/out"; fail=1; fi
}

# working_directory "." : dpkg writes next to the workspace.
ws="$work/a/ws"; mkdir -p "$ws"; touch "$work/a/app_1.0_amd64.deb" "$work/a/app_1.0_amd64.changes"
rc=0; run_step "$ws" . || rc=$?
expect "packages from '..' are collected" 0 "$rc"
(cd "$ws" && compgen -G "$default" >/dev/null) && echo "ok: default glob matches from the workspace" || { echo "FAIL: default glob matches nothing"; fail=1; }
[ -e "$work/a/app_1.0_amd64.deb" ] && echo "ok: the original .deb stays in place" || { echo "FAIL: original .deb moved"; fail=1; }
[ ! -e "$ws/dist/deb/app_1.0_amd64.changes" ] && echo "ok: only .deb files are collected" || { echo "FAIL: .changes collected"; fail=1; }

# working_directory "pkg" : dpkg writes into the workspace root.
ws="$work/b/ws"; mkdir -p "$ws/pkg"; touch "$ws/lib_2.0_all.deb"
rc=0; run_step "$ws" pkg || rc=$?
expect "subdirectory working_directory" 0 "$rc"
[ -e "$ws/dist/deb/lib_2.0_all.deb" ] && echo "ok: collected into the workspace" || { echo "FAIL: not in workspace dist/deb"; fail=1; }

# No .deb fails instead of uploading nothing.
ws="$work/c/ws"; mkdir -p "$ws"
rc=0; run_step "$ws" . || rc=$?
expect "no package fails" 1 "$rc"

exit "$fail"
