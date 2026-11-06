#!/usr/bin/env bash
# SCRIPT: rust_release_inputs_stay_text_test.sh
# DESCRIPTION: Renders the install and build steps of rust-release.yml as
#              GitHub does, with every string input set to text a shell would
#              execute and every build_* flag "true", and runs them against
#              stub sudo and cargo. apt_packages must reach apt-get as its
#              words, artifact_dir must name the directory unchanged, bin_name
#              and linux_gnu_aliases must be refused unless plain names, and
#              nothing in them may run.
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
    text = re.sub(r"\$\{\{\s*inputs\.bin_name\s*\}\}", "tool", text)
    text = re.sub(r"\$\{\{\s*inputs\.linux_gnu_aliases\s*\}\}", "deb", text)
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
got=()
while IFS= read -r line; do got+=("$line"); done < <(tail -n +5 "$STUB_APT_ARGS" 2>/dev/null)
if [[ "${got[*]-}" != "${want[*]}" || "${#got[@]}" != "${#want[@]}" ]]; then
  echo "FAIL apt-get got: ${got[*]-<nothing>}"
  fail=1
fi

for suffix in windows.exe linux musl deb; do
  if [[ ! -f "$work/wd/$value/tool-$suffix" ]]; then
    echo "FAIL missing artifact: tool-$suffix"
    fail=1
  fi
done

# Refused before anything is built, and without running what they hold.
for bad in "BIN_NAME=$value" "BIN_NAME=../evil" "BIN_NAME=-evil" "LINUX_GNU_ALIASES=../evil" "LINUX_GNU_ALIASES=deb,$value" "BIN_NAME=a..b" "LINUX_GNU_ALIASES=a..b" "LINUX_GNU_ALIASES=deb
../evil" "BIN_NAME=$(printf 'tool\303\251')"; do
  if (cd "$work/wd" && set -a && . "$work/env1.sh" && export "INPUT_$bad" && bash "$work/run1.sh" >/dev/null 2>&1); then
    echo "FAIL accepted: $bad"
    fail=1
  fi
  if [[ -e "$work/wd/ran" || -e "$work/evil-linux" || -e "$work/wd/evil-deb" ]]; then
    echo "FAIL $bad escaped or ran"
    fail=1
  fi
done
# rust-release-tarballs.yml: the same refusal, ahead of the build.
python3 - "$root" "$work/tar.sh" <<'PY'
import sys, yaml
root, out = sys.argv[1:3]
d = yaml.safe_load(open(f"{root}/.github/workflows/rust-release-tarballs.yml"))
for job in d["jobs"].values():
    for s in job.get("steps", []):
        if s.get("name") == "Build release binary":
            open(out, "w").write(s["run"])
PY
for bad in ../x -x a..b "a b" "$value"; do
  if (cd "$work/wd" && BIN_NAME="$bad" RUST_TARGET="" bash "$work/tar.sh" >"$work/tar.out" 2>&1) \
    || ! grep -q 'plain file name' "$work/tar.out"; then
    echo "FAIL tarballs accepted bin_name: $bad"
    fail=1
  fi
done
mkdir -p "$work/wd/target/release"; : > "$work/wd/target/release/tool"
if ! (cd "$work/wd" && BIN_NAME=tool RUST_TARGET="" GITHUB_OUTPUT="$work/gh" bash "$work/tar.sh" >/dev/null 2>&1); then
  echo "FAIL tarballs refused a plain bin_name"
  fail=1
fi

[[ "$fail" == 0 ]] || exit 1
echo "ok: rust-release inputs stay text, and unsafe names are refused"
