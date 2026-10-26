#!/usr/bin/env bash
# SCRIPT: flutter_docker_inputs_stay_text_test.sh
# DESCRIPTION: Renders steps of flutter-release.yml and docker-scan.yml as
#              GitHub does, with text inputs set to text a shell would
#              execute, and runs them against stub fastlane and docker. Lanes
#              must reach fastlane as their words, a quoted option as one, with
#              and without a Gemfile; working_directory and the
#              docker inputs must arrive unchanged, nothing in them may run,
#              and the *_build_command inputs must still run as code.
# USAGE: bash tests/flutter_docker_inputs_stay_text_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# No slash: the value is also a directory name. $5 must stay "$5", $(...)
# and backticks must not run.
# shellcheck disable=SC2016
value='a $5 "b" $(touch ran) `touch ran` c'
# A lane also carries a quoted option, which must stay one word.
lane_value="$value notes:\"x y\""
mkdir -p "$work/wd" "$work/bin"

python3 - "$root" "$work" "$value" "$lane_value" <<'PY'
import re, shlex, sys, yaml
root, work, value, lane_value = sys.argv[1:5]
# What fastlane must get: the lane split as the shell splits quoted words.
open(f"{work}/lane.want", "w").write("".join(w + "\n" for w in shlex.split(lane_value)))

def steps(f, job):
    # Each step with the job's env under its own, as the runner merges them.
    j = yaml.safe_load(open(f"{root}/.github/workflows/{f}"))["jobs"][job]
    return {s.get("name"): dict(s, env={**(j.get("env") or {}), **(s.get("env") or {})})
            for s in j["steps"]}

def render(text, special):
    # What the runner does before bash sees anything: each expression
    # becomes its value.
    for name, v in special.items():
        text = re.sub(r"\$\{\{\s*inputs\.%s\s*\}\}" % name, lambda m, v=v: v, text)
    return re.sub(r"\$\{\{.*?\}\}", lambda m: value, text)

fr = steps("flutter-release.yml", "flutter_release")
ds = steps("docker-scan.yml", "scan")
cases = [
    ("note", fr["Note for Android signing config"], {}),
    ("play", fr["Deploy to Google Play via Fastlane"],
     {"fastlane_android_lane": lane_value}),
    ("build", fr["Build Android appbundle"],
     {"android_build_command": "set -- one two\nprintf '%s\\n' \"$#\" > built"}),
    ("appstore", fr["Deploy to App Store via Fastlane"],
     {"fastlane_ios_lane": lane_value}),
    ("ios", fr["Build iOS (no codesign)"],
     {"ios_build_command": "set -- one two three\nprintf '%s\\n' \"$#\" > built-ios"}),
    ("cleanup", fr["Cleanup signing and deploy credentials"], {}),
    ("docker", ds["Build image"], {}),
]
for i, (tag, s, special) in enumerate(cases):
    with open(f"{work}/{tag}.env", "w") as f:
        for k, v in (s.get("env") or {}).items():
            f.write(f"export {k}={shlex.quote(render(str(v), special))}\n")
    open(f"{work}/{tag}.sh", "w").write(render(s["run"], special))
PY

for tool in fastlane bundle docker; do
  cat > "$work/bin/$tool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/$tool.\$STEP.args"
EOF
  chmod +x "$work/bin/$tool"
done
export PATH="$work/bin:$PATH" GITHUB_WORKSPACE="$work/ws" HOME="$work/home"
# Cleanup must find and remove these, under the literal working_directory.
mkdir -p "$work/ws/$value/android"
: > "$work/ws/$value/android/key.properties"
: > "$work/ws/$value/android/upload-keystore.jks"
fail=0
for tag in note play build appstore ios cleanup docker; do
  # The iOS steps refuse anything but macOS.
  export STEP="$tag" RUNNER_OS=Linux
  [[ "$tag" == appstore || "$tag" == ios ]] && RUNNER_OS=macOS
  # App Store runs with a Gemfile, so the bundle exec branch is covered too.
  if [[ "$tag" == appstore ]]; then : > "$work/wd/Gemfile"; else rm -f "$work/wd/Gemfile"; fi
  # shellcheck disable=SC1090
  if ! (cd "$work/wd" && set -a && . "$work/$tag.env" && bash "$work/$tag.sh" > "$work/$tag.out" 2>&1); then
    echo "FAIL step $tag exited non-zero: $(tail -1 "$work/$tag.out")"
    fail=1
  fi
done

if [[ -e "$work/wd/ran" ]]; then
  echo "FAIL a command inside an input ran"
  fail=1
fi
if ! grep -qF -- "$work/ws/$value/android/key.properties" "$work/note.out"; then
  echo "FAIL working_directory did not reach the note unchanged"
  fail=1
fi
# fastlane gets each lane's words, each unchanged; through bundle exec
# when there is a Gemfile.
if [[ "$(cat "$work/fastlane.play.args" 2>/dev/null)" != "$(cat "$work/lane.want")" ]]; then
  echo "FAIL fastlane (play) got: $(tr '\n' '|' 2>/dev/null < "$work/fastlane.play.args")"
  fail=1
fi
if [[ "$(cat "$work/bundle.appstore.args" 2>/dev/null)" != "$(printf 'exec\nfastlane\n'; cat "$work/lane.want")" ]]; then
  echo "FAIL bundle exec fastlane (appstore) got: $(tr '\n' '|' 2>/dev/null < "$work/bundle.appstore.args")"
  fail=1
fi
# The build commands are code: each runs, with its own positional parameters.
if [[ "$(cat "$work/wd/built" 2>/dev/null)" != 2 ]]; then
  echo "FAIL android_build_command did not run as code"
  fail=1
fi
if [[ "$(cat "$work/wd/built-ios" 2>/dev/null)" != 3 ]]; then
  echo "FAIL ios_build_command did not run as code"
  fail=1
fi
if [[ -e "$work/ws/$value/android/key.properties" || -e "$work/ws/$value/android/upload-keystore.jks" ]]; then
  echo "FAIL cleanup did not remove the signing files under working_directory"
  fail=1
fi
expected="$(printf '%s\n' build -f "$value" -t "$value" "$value")"
if [[ "$(cat "$work/docker.docker.args" 2>/dev/null)" != "$expected" ]]; then
  echo "FAIL docker got: $(tr '\n' '|' 2>/dev/null < "$work/docker.docker.args")"
  fail=1
fi
[[ "$fail" == 0 ]] || exit 1
echo "ok: flutter-release and docker-scan inputs reach their tools as text"
