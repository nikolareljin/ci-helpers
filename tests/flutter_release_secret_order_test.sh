#!/usr/bin/env bash
# SCRIPT: flutter_release_secret_order_test.sh
# DESCRIPTION: In flutter-release.yml the build job, which runs the caller's
#              code, reads no secret at all. In the jobs that hold the
#              upload key and store credentials (sign-android,
#              upload-app-store) no step that reads a secret runs before the
#              last toolchain step (Java, the library checkout, Ruby,
#              fastlane), every step that reads one runs a library script
#              (scripts/flutter_*.sh, which write key files only under a
#              directory their EXIT trap removes) with `lib_path.sh secret`,
#              Ruby and Flutter come from the library's scripts and not
#              third-party actions, the build's library checkout is
#              unconditional and precedes Flutter, and no job-level env
#              holds a secret. Each rule is also run on a broken copy of
#              the workflow and must fail there.
# USAGE: bash tests/flutter_release_secret_order_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

cat > "$work/check.py" <<'PY'
import re, sys
import yaml

TOOLCHAIN_USES = re.compile(r"^(actions/setup-|actions/checkout@)")
TOOLCHAIN_RUN = re.compile(r"setup_ruby\.sh|install_fastlane\.sh|lib_isolate\.sh")
SECRET = re.compile(r"\$\{\{[^}]*\bsecrets\.")

doc = yaml.safe_load(open(sys.argv[1]))
jobs = doc["jobs"]
problems = []

def dump(x):
    return yaml.safe_dump(x, width=10**9)

for name, job in jobs.items():
    if SECRET.search(dump(job.get("env") or {})):
        problems.append(f"the job-level env of {name} holds a secret")
for i, s in enumerate(jobs["build"]["steps"]):
    if SECRET.search(dump(s)):
        problems.append(f"build step {i} '{s.get('name')}' reads a secret; the build runs the caller's code")

def is_toolchain(step):
    return bool(TOOLCHAIN_USES.match(step.get("uses") or "") or TOOLCHAIN_RUN.search(step.get("run") or ""))

for name in ("sign-android", "upload-app-store"):
    steps = jobs[name]["steps"]
    last_tool = max((i for i, s in enumerate(steps) if is_toolchain(s) and not (s.get("with") or {}).get("path", "").startswith(".ci-helpers-publication")), default=-1)
    for i, s in enumerate(steps):
        if not SECRET.search(dump(s)):
            continue
        if i < last_tool:
            problems.append(f"{name} step {i} '{s.get('name')}' reads a secret before toolchain step {last_tool} '{steps[last_tool].get('name')}'")
        run = s.get("run") or ""
        if not re.search(r'/bin/bash "\$run_lib/scripts/flutter_[a-z_]+\.sh"', run) or '. "$run_lib/scripts/lib_path.sh" secret' not in run:
            problems.append(f"{name} step '{s.get('name')}' reads a secret outside a library flutter_*.sh script in secret mode")
    ruby = [s for s in steps if s.get("name") == "Setup Ruby"]
    if not ruby or "uses" in ruby[0] or '"$run_lib/scripts/setup_ruby.sh"' not in (ruby[0].get("run") or ""):
        problems.append(f"{name}: 'Setup Ruby' is not scripts/setup_ruby.sh from the verified library copy")

build = jobs["build"]["steps"]
fl = [s for s in build if s.get("name") == "Setup Flutter"]
if not fl or "uses" in fl[0] or '"$run_lib/scripts/setup_flutter.sh"' not in (fl[0].get("run") or ""):
    problems.append("'Setup Flutter' is not scripts/setup_flutter.sh from the verified library copy")
checkout = next((i for i, s in enumerate(build) if (s.get("name") or "") == "Check out ci-helpers scripts"), None)
flutter = next((i for i, s in enumerate(build) if (s.get("name") or "") == "Setup Flutter"), None)
if checkout is None or flutter is None or checkout > flutter:
    problems.append("'Check out ci-helpers scripts' does not precede 'Setup Flutter'")
elif build[checkout].get("if"):
    problems.append("'Check out ci-helpers scripts' is conditional; 'Setup Flutter' runs on every run")

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY

# The scripts that write a key to disk do it under a directory their EXIT
# trap removes.
for f in flutter_android_sign.sh flutter_play_upload.sh flutter_app_store_upload.sh; do
  if grep -qE "^trap '?(rm -rf \"\\\$work\"|cleanup)'? EXIT" "$root/scripts/$f" && grep -q 'work="$(mktemp -d)"' "$root/scripts/$f"; then
    echo "ok   scripts/$f removes its key files on exit"
  else
    echo "FAIL scripts/$f has no EXIT trap removing its work directory"; fail=1
  fi
done

name="this tree"
if ! python3 "$work/check.py" "$root/.github/workflows/flutter-release.yml" > "$work/out" 2>&1; then
  echo "FAIL $name:"; cat "$work/out"; fail=1
fi

# mutate NAME EXPECT PYTHON: apply PYTHON to the parsed workflow (doc, jobs)
# and require the check to fail with EXPECT.
mutate() {
  python3 - "$root/.github/workflows/flutter-release.yml" "$work/m.yml" "$3" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
jobs = doc["jobs"]
exec(sys.argv[3])
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
  local rc=0
  python3 "$work/check.py" "$work/m.yml" > "$work/out" 2>&1 || rc=$?
  if [ "$rc" != 1 ] || ! grep -q -- "$2" "$work/out"; then
    echo "FAIL $1 is not refused: exit $rc"; cat "$work/out"; fail=1
  else
    echo "ok   $1 is refused"
  fi
}
mutate "Ruby installed after the upload key is read" "'Sign the Android app bundle' reads a secret before toolchain step" '
st = jobs["sign-android"]["steps"]
tool = [s for s in st if s.get("name") in ("Setup Ruby", "Install fastlane")]
rest = [s for s in st if s not in tool]
at = next(i for i, s in enumerate(rest) if s.get("name") == "Sign the Android app bundle") + 1
jobs["sign-android"]["steps"] = rest[:at] + tool + rest[at:]'
mutate "ruby/setup-ruby in place of the script" "'Setup Ruby' is not scripts/setup_ruby.sh" '
for s in jobs["upload-app-store"]["steps"]:
    if s.get("name") == "Setup Ruby":
        s.pop("run"); s["uses"] = "ruby/setup-ruby@de492cf36cbab201753d720ce4f4e336cd688c94"'
mutate "subosito/flutter-action in place of the script" "'Setup Flutter' is not scripts/setup_flutter.sh" '
for s in jobs["build"]["steps"]:
    if s.get("name") == "Setup Flutter":
        s.pop("run"); s["uses"] = "subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2"'
mutate "a conditional library checkout" "'Check out ci-helpers scripts' is conditional" '
for s in jobs["build"]["steps"]:
    if s.get("name") == "Check out ci-helpers scripts":
        s["if"] = "${{ inputs.deploy_google_play }}"'
mutate "a job-level secret" "job-level env of sign-android holds a secret" '
jobs["sign-android"].setdefault("env", {})["MATCH_PASSWORD"] = "${{ secrets.match_password }}"'
for where in run if env; do
mutate "a secret in the build job's $where:" "build step .* reads a secret" "
st = jobs['build']['steps']
step = {'name': 'Early secret', 'run': 'true'}
if '$where' == 'run':
    step['run'] = 'echo \"\${{ secrets.android_keystore_password }}\" > key'
elif '$where' == 'if':
    step['if'] = \"\${{ secrets.match_password != '' }}\"
else:
    step['env'] = {'X': '\${{ secrets.match_password }}'}
st.insert(3, step)"
done
mutate "a secret written by an inline step" "reads a secret outside a library flutter_" '
st = jobs["sign-android"]["steps"]
st.append({"name": "Inline key", "run": "echo \"${{ secrets.android_keystore_base64 }}\" > k.jks"})'

[ "$fail" = 0 ] && echo "ok: flutter-release.yml reads no secret in the build job and reads one only in library scripts after every toolchain step"
exit "$fail"
