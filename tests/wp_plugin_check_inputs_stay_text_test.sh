#!/usr/bin/env bash
# SCRIPT: wp_plugin_check_inputs_stay_text_test.sh
# DESCRIPTION: Renders the plugin-check step of wp-plugin-check.yml as GitHub
#              does, with every expression's value set to text a shell would
#              execute, and runs it against a stub ci_wp_plugin_check.sh. Each
#              flag value must reach the stub byte for byte, and nothing in it
#              may run. An expression spliced into the run script fails this.
# USAGE: bash tests/wp_plugin_check_inputs_stay_text_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# $5 must stay "$5", $(...) and backticks must not run, a quote must not end
# the argument.
value="a \$5 \"b\" \$(touch $work/ran) \`touch $work/ran\` c"

python3 - "$root" "$work" "$value" <<'PY'
import re, shlex, sys, yaml
root, work, value = sys.argv[1:4]
d = yaml.safe_load(open(f"{root}/.github/workflows/wp-plugin-check.yml"))
step = next(s for s in d["jobs"]["check"]["steps"] if s.get("name") == "WordPress plugin check")

def render(text):
    # What the runner does before bash sees anything: each expression becomes
    # its value. runner.temp is the one value this test chooses.
    text = re.sub(r"\$\{\{\s*runner\.temp\s*\}\}", f"{work}/rt", text)
    return re.sub(r"\$\{\{.*?\}\}", lambda m: value, text)

with open(f"{work}/env.sh", "w") as f:
    for name, expr in (step.get("env") or {}).items():
        f.write(f"export {name}={shlex.quote(render(str(expr)))}\n")
open(f"{work}/run.sh", "w").write(render(step["run"]))
flags = len(re.findall(r"^\s*--[a-z-]+ ", step["run"], re.M))
open(f"{work}/flags", "w").write(f"{flags}\n")
PY

mkdir -p "$work/rt/script-helpers/scripts"
cat > "$work/rt/script-helpers/scripts/ci_wp_plugin_check.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGS"
EOF
chmod +x "$work/rt/script-helpers/scripts/ci_wp_plugin_check.sh"

export STUB_ARGS="$work/args"
: > "$STUB_ARGS"
# shellcheck disable=SC1091
source "$work/env.sh"
bash "$work/run.sh" || true

fail=0
if [[ -e "$work/ran" ]]; then
  echo "FAIL a command inside an input ran"
  fail=1
fi
expected="$(cat "$work/flags")"
got="$(grep -cxF -- "$value" "$work/args" || true)"
if [[ "$got" != "$expected" ]]; then
  echo "FAIL $got of $expected flag values reached the script unchanged"
  fail=1
fi
[[ "$fail" == 0 ]] || exit 1
echo "ok: $expected wp-plugin-check inputs reach the script as text"
