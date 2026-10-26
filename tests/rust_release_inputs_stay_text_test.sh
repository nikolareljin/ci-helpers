#!/usr/bin/env bash
# SCRIPT: rust_release_inputs_stay_text_test.sh
# DESCRIPTION: Renders the install and build steps of rust-release.yml as
#              GitHub does, with every string input set to text a shell would
#              execute and every build_* flag "true", and runs them against
#              stub sudo and cargo. apt_packages must reach apt-get as its
#              words, bin_name, artifact_dir and linux_gnu_aliases must name
#              the artifacts unchanged, and nothing in them may run.
# USAGE: bash tests/rust_release_inputs_stay_text_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# No slash and no comma: the value is used as a file name and as a single
# alias. $5 must stay "$5", $(...) and backticks must not run.
# shellcheck disable=SC2016
value='a $5 "b" $(touch ran) `touch ran` c'
# apt_packages also spans lines, CRLF included, as a YAML block gives it.
apt_value="$value"$'\r\nd e\nf'
mkdir -p "$work/wd" "$work/bin"

python3 - "$root" "$work" "$value" "$apt_value" <<'PY'
import re, shlex, sys, yaml
root, work, value, apt_value = sys.argv[1:5]
d = yaml.safe_load(open(f"{root}/.github/workflows/rust-release.yml"))
steps = {s.get("name"): s for s in d["jobs"]["build"]["steps"]}

def render(text):
    # What the runner does before bash sees anything: each expression
    # becomes its value. Booleans are "true" so every target branch runs.
    text = re.sub(r"\$\{\{\s*inputs\.build_\w+\s*\}\}", "true", text)
    text = re.sub(r"\$\{\{\s*inputs\.apt_packages\s*\}\}", lambda m: apt_value, text)
    return re.sub(r"\$\{\{.*?\}\}", lambda m: value, text)

for i, name in enumerate(["Install build dependencies", "Build release binaries"]):
    s = steps[name]
    with open(f"{work}/env{i}.sh", "w") as f:
        for k, v in (s.get("env") or {}).items():
            f.write(f"export {k}={shlex.quote(render(str(v)))}\n")
    open(f"{work}/run{i}.sh", "w").write(render(s["run"]))
PY

cat > "$work/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$2" == install ]] && printf '%s\n' "$@" > "$STUB_APT_ARGS"
exit 0
EOF
cat > "$work/bin/cargo" <<'EOF'
#!/usr/bin/env bash
t="${3#--target=}"
[[ "$t" == "$3" ]] && exit 0
ext=""; [[ "$t" == *windows* ]] && ext=".exe"
mkdir -p "target/$t/release"
: > "target/$t/release/${INPUT_BIN_NAME}${ext}"
EOF
chmod +x "$work/bin/sudo" "$work/bin/cargo"

export STUB_APT_ARGS="$work/apt-args"
export PATH="$work/bin:$PATH"
fail=0
for i in 0 1; do
  # shellcheck disable=SC1090
  if ! (cd "$work/wd" && set -a && . "$work/env$i.sh" && bash "$work/run$i.sh" >/dev/null 2>&1); then
    echo "FAIL step $i exited non-zero"
    fail=1
  fi
done

if [[ -e "$work/wd/ran" ]]; then
  echo "FAIL a command inside an input ran"
  fail=1
fi

# apt-get gets "install -y --" and then the input's words, each unchanged,
# from every line.
read -r -a want <<< "$value d e f"
mapfile -t got < <(tail -n +5 "$STUB_APT_ARGS" 2>/dev/null)
if [[ "${got[*]-}" != "${want[*]}" || "${#got[@]}" != "${#want[@]}" ]]; then
  echo "FAIL apt-get got: ${got[*]-<nothing>}"
  fail=1
fi

for suffix in windows.exe linux musl "$value"; do
  if [[ ! -f "$work/wd/$value/$value-$suffix" ]]; then
    echo "FAIL missing artifact: $value-$suffix"
    fail=1
  fi
done
[[ "$fail" == 0 ]] || exit 1
echo "ok: rust-release inputs reach apt-get and the artifact names as text"
