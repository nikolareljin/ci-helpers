#!/usr/bin/env bash
# SCRIPT: flutter_docker_inputs_stay_text_test.sh
# DESCRIPTION: Renders steps of flutter-release.yml and docker-scan.yml as
#              GitHub does, with text inputs set to text a shell would
#              execute, and runs them against stub fastlane and docker. Lanes
#              must reach fastlane as their words, working_directory and the
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
mkdir -p "$work/wd" "$work/bin"

python3 - "$root" "$work" "$value" <<'PY'
import re, shlex, sys, yaml
root, work, value = sys.argv[1:4]

def steps(f, job):
    d = yaml.safe_load(open(f"{root}/.github/workflows/{f}"))
    return {s.get("name"): s for s in d["jobs"][job]["steps"]}

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
    ("play", fr["Deploy to Google Play via Fastlane"], {}),
    ("build", fr["Build Android appbundle"],
     {"android_build_command": "set -- one two\nprintf '%s\\n' \"$#\" > built"}),
    ("docker", ds["Build image"], {}),
]
for i, (tag, s, special) in enumerate(cases):
    with open(f"{work}/{tag}.env", "w") as f:
        for k, v in (s.get("env") or {}).items():
            f.write(f"export {k}={shlex.quote(render(str(v), special))}\n")
    open(f"{work}/{tag}.sh", "w").write(render(s["run"], special))
PY

for tool in fastlane docker; do
  cat > "$work/bin/$tool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/$tool.args"
EOF
  chmod +x "$work/bin/$tool"
done
export PATH="$work/bin:$PATH" GITHUB_WORKSPACE="$work/ws" RUNNER_OS=Linux
fail=0
for tag in note play build docker; do
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
# fastlane gets the lane's words, each unchanged.
read -r -a want <<< "$value"
got=()
while IFS= read -r line; do got+=("$line"); done < "$work/fastlane.args"
if [[ "${got[*]-}" != "${want[*]}" || "${#got[@]}" != "${#want[@]}" ]]; then
  echo "FAIL fastlane got: ${got[*]-<nothing>}"
  fail=1
fi
# The build command is code: it runs, with its own positional parameters.
if [[ "$(cat "$work/wd/built" 2>/dev/null)" != 2 ]]; then
  echo "FAIL android_build_command did not run as code"
  fail=1
fi
expected="$(printf '%s\n' build -f "$value" -t "$value" "$value")"
if [[ "$(cat "$work/docker.args")" != "$expected" ]]; then
  echo "FAIL docker got: $(tr '\n' '|' < "$work/docker.args")"
  fail=1
fi
[[ "$fail" == 0 ]] || exit 1
echo "ok: flutter-release and docker-scan inputs reach their tools as text"
