#!/usr/bin/env bash
# SCRIPT: flutter_release_secret_order_test.sh
# DESCRIPTION: In flutter-release.yml, no step that reads a secret runs
#              before the last toolchain step (Java, Flutter, pub get, the
#              library checkout, Ruby, gems, fastlane), the Ruby step is a
#              script from the library checkout and not a third-party
#              action, every file a secret is written to is removed by the
#              always() cleanup step, and no job-level env holds a secret.
#              The same check runs on a fixture with the old order and must
#              fail there.
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

TOOLCHAIN_USES = re.compile(r"^(actions/setup-|actions/cache@|subosito/flutter-action@|actions/checkout@)")
TOOLCHAIN_RUN = re.compile(r"flutter pub get|setup_ruby\.sh|bundle install|gem install|\.ci-helpers-scripts")
SECRET = re.compile(r"\$\{\{[^}]*\bsecrets\.")

doc = yaml.safe_load(open(sys.argv[1]))
job = doc["jobs"]["flutter_release"]
steps = job["steps"]
problems = []

if SECRET.search(yaml.safe_dump(job.get("env") or {})):
    problems.append("the job-level env holds a secret")

def is_toolchain(step):
    uses = step.get("uses") or ""
    run = step.get("run") or ""
    return bool(TOOLCHAIN_USES.match(uses) or TOOLCHAIN_RUN.search(run))

def reads_secret(step):
    # Anywhere in the step: env, with, run, if.
    return bool(SECRET.search(yaml.safe_dump(step, width=10**9)))

# The publication steps at the end check out the library again; they are
# not toolchain steps. The toolchain ends at the last step before the first
# secret-free build note, counted among the steps before 'Cleanup'.
cleanup = next((i for i, s in enumerate(steps) if (s.get("name") or "").startswith("Cleanup signing")), None)
if cleanup is None:
    problems.append("no 'Cleanup signing and deploy credentials' step")
    cleanup = len(steps)
before = steps[:cleanup]
last_tool = max((i for i, s in enumerate(before) if is_toolchain(s)), default=-1)
for i, s in enumerate(before):
    if i < last_tool and reads_secret(s):
        problems.append(f"step {i} '{s.get('name')}' reads a secret before toolchain step {last_tool} '{before[last_tool].get('name')}'")

ruby = [s for s in steps if (s.get("name") or "") == "Setup Ruby"]
if not ruby:
    problems.append("no 'Setup Ruby' step")
elif "uses" in ruby[0] or ".ci-helpers-scripts/scripts/setup_ruby.sh" not in (ruby[0].get("run") or ""):
    problems.append("'Setup Ruby' is not scripts/setup_ruby.sh from the library checkout")

# Every file a secret is written to is removed by the cleanup step.
cleanup_run = steps[cleanup].get("run") if cleanup < len(steps) else ""
if cleanup < len(steps) and not (steps[cleanup].get("if") or "").startswith("${{ always()"):
    problems.append("the cleanup step does not run on always()")
for needle in ("upload-keystore.jks", "key.properties", "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_FILE_PATH", ".appstoreconnect/private_keys"):
    if needle not in (cleanup_run or ""):
        problems.append(f"the cleanup step does not remove {needle}")

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY

name="this tree"
if ! python3 "$work/check.py" "$root/.github/workflows/flutter-release.yml" > "$work/out" 2>&1; then
  echo "FAIL $name:"; cat "$work/out"; fail=1
fi

# The old order: Ruby after the keystore was written. Built from this tree's
# workflow by moving the toolchain steps after 'Configure Android signing'.
python3 - "$root/.github/workflows/flutter-release.yml" "$work/old.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["flutter_release"]["steps"]
names = [s.get("name") for s in steps]
tool = [s for s in steps if s.get("name") in ("Setup Ruby", "Install gems (Gemfile)", "Install Fastlane (no Gemfile)")]
rest = [s for s in steps if s not in tool]
at = next(i for i, s in enumerate(rest) if s.get("name") == "Configure Android signing") + 1
doc["jobs"]["flutter_release"]["steps"] = rest[:at] + tool + rest[at:]
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
name="the old order is refused"
rc=0; python3 "$work/check.py" "$work/old.yml" > "$work/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q "'Configure Android signing' reads a secret before toolchain step" "$work/out"; then
  echo "FAIL $name: exit $rc"; cat "$work/out"; fail=1
fi

# The action is refused even in the right place.
python3 - "$root/.github/workflows/flutter-release.yml" "$work/action.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for s in doc["jobs"]["flutter_release"]["steps"]:
    if s.get("name") == "Setup Ruby":
        s.pop("run"); s["uses"] = "ruby/setup-ruby@de492cf36cbab201753d720ce4f4e336cd688c94"
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
name="ruby/setup-ruby in place of the script is refused"
rc=0; python3 "$work/check.py" "$work/action.yml" > "$work/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q "'Setup Ruby' is not scripts/setup_ruby.sh" "$work/out"; then
  echo "FAIL $name: exit $rc"; cat "$work/out"; fail=1
fi

# A secret at job level is refused.
python3 - "$root/.github/workflows/flutter-release.yml" "$work/jobenv.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
doc["jobs"]["flutter_release"].setdefault("env", {})["MATCH_PASSWORD"] = "${{ secrets.match_password }}"
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
name="a job-level secret is refused"
rc=0; python3 "$work/check.py" "$work/jobenv.yml" > "$work/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q "job-level env holds a secret" "$work/out"; then
  echo "FAIL $name: exit $rc"; cat "$work/out"; fail=1
fi

# A secret read in run: or if: before a toolchain step is refused, as is
# one in env:.
for where in run if env; do
python3 - "$root/.github/workflows/flutter-release.yml" "$work/early-$where.yml" "$where" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["flutter_release"]["steps"]
at = next(i for i, s in enumerate(steps) if s.get("name") == "Setup Ruby")
step = {"name": "Early secret", "run": "true"}
if sys.argv[3] == "run":
    step["run"] = 'echo "${{ secrets.match_password }}" > /tmp/x'
elif sys.argv[3] == "if":
    step["if"] = "${{ secrets.match_password != '' }}"
else:
    step["env"] = {"X": "${{ secrets.match_password }}"}
steps.insert(at, step)
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
name="a secret in $where: before a toolchain step is refused"
rc=0; python3 "$work/check.py" "$work/early-$where.yml" > "$work/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q "'Early secret' reads a secret before toolchain step" "$work/out"; then
  echo "FAIL $name: exit $rc"; cat "$work/out"; fail=1
fi
done

# A cleanup step that forgets the keystore is refused.
python3 - "$root/.github/workflows/flutter-release.yml" "$work/cleanup.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for s in doc["jobs"]["flutter_release"]["steps"]:
    if (s.get("name") or "").startswith("Cleanup signing"):
        s["run"] = s["run"].replace("upload-keystore.jks", "something-else")
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
name="a cleanup step that leaves the keystore is refused"
rc=0; python3 "$work/check.py" "$work/cleanup.yml" > "$work/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q "does not remove upload-keystore.jks" "$work/out"; then
  echo "FAIL $name: exit $rc"; cat "$work/out"; fail=1
fi

[ "$fail" = 0 ] && echo "ok: flutter-release.yml installs every toolchain before a secret is read, runs Ruby from the library's script, and removes every credential file on always()"
exit "$fail"
