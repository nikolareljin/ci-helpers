#!/usr/bin/env bash
# SCRIPT: composite_check_actions_inputs_stay_text_test.sh
# DESCRIPTION: Renders every run step of the wp-plugin-check and
#              pimcore-bundle-check composite actions as GitHub does, with
#              each text input set to text a shell would execute, and runs
#              them against a stub docker that also runs the sh -lc script
#              it is given, against a stub wp. Each value must reach docker
#              and wp unchanged, and nothing in it may run, on the runner or
#              in the container.
# USAGE: bash tests/composite_check_actions_inputs_stay_text_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# No slash: the value is also a directory name. $5 must stay "$5", $(...)
# and backticks must not run.
# shellcheck disable=SC2016
value='a $5 "b" $(touch ran) `touch ran` c'
mkdir -p "$work/wd/$value" "$work/bin"

python3 - "$root" "$work" "$value" <<'PY'
import re, shlex, sys, yaml
root, work, value = sys.argv[1:4]
# Inputs that must hold a name or a number for the step to get anywhere.
special = {"plugin_src_env": "SRC_DIR", "bundle_src_env": "SRC_DIR",
           "php_version_env": "PHP_VERSION",
           "db_wait_seconds": "0", "multisite": "true",
           "activate_network": "true", "fail_on_findings": "false"}

def render(text):
    # What the runner does before bash sees anything: each expression
    # becomes its value. A *_command input is code, here a no-op.
    def one(m):
        n = re.fullmatch(r"\s*inputs\.(\w+)\s*", m.group(1))
        if n and n.group(1).endswith("_command"):
            return "true"
        if n and n.group(1) in special:
            return special[n.group(1)]
        return value
    return re.sub(r"\$\{\{(.*?)\}\}", one, text, flags=re.S)

names = []
for action in ("wp-plugin-check", "pimcore-bundle-check"):
    steps = yaml.safe_load(open(f"{root}/.github/actions/{action}/action.yml"))["runs"]["steps"]
    for i, s in enumerate(steps):
        if "run" not in s or s.get("shell") != "bash":
            continue
        tag = f"{action}.{i}"
        names.append(tag)
        with open(f"{work}/{tag}.env", "w") as f:
            for k, v in (s.get("env") or {}).items():
                f.write(f"export {k}={shlex.quote(render(str(v)))}\n")
        open(f"{work}/{tag}.sh", "w").write(render(s["run"]))
open(f"{work}/steps", "w").write("\n".join(names) + "\n")
PY

# docker records its arguments, one per line, and runs any sh -lc script
# as the container would: with only the variables named by -e. wp records its arguments, lists check in
# `wp help`, reports no site installed yet and prints empty JSON results.
cat > "$work/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$work/docker.args"
pass=(PATH="\$PATH")
while [[ \$# -gt 0 && "\$1" != sh ]]; do
  if [[ "\$1" == -e ]]; then pass+=("\$2=\${!2-}"); shift; fi
  shift
done
if [[ "\${1:-}" == sh && "\${2:-}" == -lc ]]; then exec env -i "\${pass[@]}" sh -c "\$3"; fi
EOF
cat > "$work/bin/wp" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == help ]]; then echo check; exit 0; fi
if [[ "\$1 \${2:-}" == "core is-installed" ]]; then exit 1; fi
printf '%s\n' "\$@" >> "$work/wp.args"
if [[ "\$1 \${2:-}" == "plugin check" || "\$1" == eval-file ]]; then echo '[]'; fi
EOF
chmod +x "$work/bin/docker" "$work/bin/wp"
export PATH="$work/bin:$PATH" GITHUB_ENV="$work/github_env"

fail=0
while IFS= read -r tag; do
  # shellcheck disable=SC1090
  if ! (cd "$work/wd" && set -a && . "$work/$tag.env" && bash "$work/$tag.sh" > "$work/$tag.out" 2>&1); then
    echo "FAIL step $tag exited non-zero: $(tail -1 "$work/$tag.out")"
    fail=1
  fi
done < "$work/steps"

if [[ -n "$(find "$work" -name ran)" ]]; then
  echo "FAIL a command inside an input ran"
  fail=1
fi
# Each value arrives as one whole argument, to docker and to wp.
for want in "$value" "--title=$value" "--admin_user=$value" "--admin_password=$value" \
            "--admin_email=$value" "--url=localhost:$value" "/workspace/$value"; do
  if ! grep -qxF -- "$want" "$work/docker.args" "$work/wp.args"; then
    echo "FAIL no argument was exactly: $want"
    fail=1
  fi
done
if [[ "$(grep -cxF -- "$value" "$work/wp.args" || true)" -lt 2 ]]; then
  echo "FAIL plugin_slug did not reach wp plugin activate and check whole"
  fail=1
fi
[[ "$fail" == 0 ]] || exit 1
echo "ok: wp-plugin-check and pimcore-bundle-check inputs reach docker and wp as text"
