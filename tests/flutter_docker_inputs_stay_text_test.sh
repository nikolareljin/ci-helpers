#!/usr/bin/env bash
# SCRIPT: flutter_docker_inputs_stay_text_test.sh
# DESCRIPTION: Renders steps of flutter-release.yml and docker-scan.yml as
#              GitHub does, with text inputs set to text a shell would
#              execute, and runs them against a stub docker. The store
#              inputs (package name, track, bundle id, team id) must be
#              refused, not run; the docker inputs must arrive unchanged,
#              nothing in them may run, and the *_build_command and
#              ios_archive_command inputs must still run as code.
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
mkdir -p "$work/wd" "$work/bin"

python3 - "$root" "$work" "$value" <<'PY'
import re, shlex, sys, yaml
root, work, value = sys.argv[1:4]

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

fr = steps("flutter-release.yml", "build")
ds = steps("docker-scan.yml", "scan")
cases = [
    ("inputs", fr["Check the release inputs"],
     {"deploy_google_play": "true", "deploy_app_store": "true", "build_android": "true"}),
    ("build", fr["Build Android appbundle"],
     {"android_build_command": "set -- one two\nprintf '%s\\n' \"$#\" > built"}),
    ("ios", fr["Build iOS (no codesign)"],
     {"ios_build_command": "set -- one two three\nprintf '%s\\n' \"$#\" > built-ios"}),
    ("archive", fr["Build iOS archive (no codesign)"],
     {"ios_archive_command": "set -- one two three four\nprintf '%s\\n' \"$#\" > built-archive"}),
    ("docker", ds["Build image"], {}),
]
for i, (tag, s, special) in enumerate(cases):
    with open(f"{work}/{tag}.env", "w") as f:
        for k, v in (s.get("env") or {}).items():
            f.write(f"export {k}={shlex.quote(render(str(v), special))}\n")
    open(f"{work}/{tag}.sh", "w").write(render(s["run"], special))
PY

for tool in docker; do
  cat > "$work/bin/$tool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/$tool.\$STEP.args"
EOF
  chmod +x "$work/bin/$tool"
done
export PATH="$work/bin:$PATH" GITHUB_WORKSPACE="$work/ws" HOME="$work/home"
fail=0
for tag in inputs build ios archive docker; do
  # The iOS steps refuse anything but macOS.
  export STEP="$tag" RUNNER_OS=Linux
  [[ "$tag" == archive || "$tag" == ios || "$tag" == inputs ]] && RUNNER_OS=macOS
  rc=0
  # shellcheck disable=SC1090
  (cd "$work/wd" && set -a && . "$work/$tag.env" && bash "$work/$tag.sh" > "$work/$tag.out" 2>&1) || rc=$?
  if [[ "$tag" == inputs ]]; then
    # Every store input is that text: each is refused, none runs.
    if [[ "$rc" == 0 ]] || [[ "$(grep -c '::error::' "$work/inputs.out")" -lt 5 ]]; then
      echo "FAIL the release inputs check passed text a shell would run: $(tr '\n' '|' < "$work/inputs.out")"
      fail=1
    fi
  elif [[ "$rc" != 0 ]]; then
    echo "FAIL step $tag exited non-zero: $(tail -1 "$work/$tag.out")"
    fail=1
  fi
done

if [[ -e "$work/wd/ran" ]]; then
  echo "FAIL a command inside an input ran"
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
if [[ "$(cat "$work/wd/built-archive" 2>/dev/null)" != 4 ]]; then
  echo "FAIL ios_archive_command did not run as code"
  fail=1
fi
expected="$(printf '%s\n' build -f "$value" -t "$value" "$value")"
if [[ "$(cat "$work/docker.docker.args" 2>/dev/null)" != "$expected" ]]; then
  echo "FAIL docker got: $(tr '\n' '|' 2>/dev/null < "$work/docker.docker.args")"
  fail=1
fi
[[ "$fail" == 0 ]] || exit 1
echo "ok: flutter-release and docker-scan inputs reach their tools as text"
