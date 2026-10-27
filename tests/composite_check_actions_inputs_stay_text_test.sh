#!/usr/bin/env bash
# SCRIPT: composite_check_actions_inputs_stay_text_test.sh
# DESCRIPTION: Renders every run step of the wp-plugin-check and
#              pimcore-bundle-check composite actions as GitHub does, with
#              each text input set to text a shell would execute, and runs
#              them against a stub docker that also runs the sh -lc script
#              it is given, against a stub wp. Each value must reach docker
#              and wp unchanged, and nothing in it may run, on the runner or
#              in the container. composer_command must still run as code.
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
mkdir -p "$work/wd/$value" "$work/bin" "$work/container"

python3 - "$root" "$work" "$value" <<'PY'
import re, shlex, sys, yaml
root, work, value = sys.argv[1:4]
# Inputs that must hold a name or a number for the step to get anywhere.
special = {"plugin_src_env": "SRC_DIR", "bundle_src_env": "SRC_DIR",
           "php_version_env": "PHP_VERSION",
           "db_wait_seconds": "0", "fail_on_findings": "false"}

def render(text, flag):
    # What the runner does before bash sees anything: each expression
    # becomes its value. A *_command input is code, here a no-op.
    def one(m):
        n = re.fullmatch(r"\s*inputs\.(\w+)\s*", m.group(1))
        if n and n.group(1) == "composer_command":
            # Quotes must survive to the container shell.
            return 'touch "composer ran"'
        if n and n.group(1).endswith("_command"):
            return "true"
        if n and n.group(1) in ("multisite", "activate_network"):
            return flag
        if n and n.group(1) in special:
            return special[n.group(1)]
        return value
    return re.sub(r"\$\{\{(.*?)\}\}", one, text, flags=re.S)

names = []
# Twice: multisite and activate_network true, then false, so both
# branches of the install and activate steps run.
for flag in ("true", "false"):
  for action in ("wp-plugin-check", "pimcore-bundle-check"):
    steps = yaml.safe_load(open(f"{root}/.github/actions/{action}/action.yml"))["runs"]["steps"]
    for i, s in enumerate(steps):
        if "run" not in s or s.get("shell") != "bash":
            continue
        tag = f"{action}.{i}.{flag}"
        names.append(tag)
        with open(f"{work}/{tag}.env", "w") as f:
            for k, v in (s.get("env") or {}).items():
                f.write(f"export {k}={shlex.quote(render(str(v), flag))}\n")
        open(f"{work}/{tag}.sh", "w").write(render(s["run"], flag))
open(f"{work}/steps", "w").write("\n".join(names) + "\n")
PY

# docker records its arguments, one per line, and runs any sh -lc script
# as the container would: with only the variables named by -e, in its own
# directory. wp records its arguments, lists check in
# `wp help`, reports no site installed yet and prints empty JSON results.
cat > "$work/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$work/docker.args"
pass=(PATH="\$PATH")
while [[ \$# -gt 0 && "\$1" != sh ]]; do
  if [[ "\$1" == -e ]]; then pass+=("\$2=\${!2-}"); shift; fi
  shift
done
if [[ "\${1:-}" == sh && "\${2:-}" == -lc ]]; then cd "$work/container" && exec env -i "\${pass[@]}" sh -c "\$3"; fi
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
if ! grep -qxF -- "$value" "$work/docker.args"; then
  echo "FAIL docker got no argument that was exactly the value"
  fail=1
fi
# The install flags, once from multisite-install and once from install.
for want in "--title=$value" "--admin_user=$value" "--admin_password=$value" \
            "--admin_email=$value" "--url=localhost:$value"; do
  if [[ "$(grep -cxF -- "$want" "$work/wp.args" || true)" != 2 ]]; then
    echo "FAIL wp core install and multisite-install did not both get: $want"
    fail=1
  fi
done
if ! grep -qxF -- "/workspace/$value" "$work/wp.args"; then
  echo "FAIL meta_check_script did not reach wp eval-file whole"
  fail=1
fi
# plugin_slug: activate --network, plain activate, and check twice.
if [[ "$(grep -cxF -- "$value" "$work/wp.args" || true)" != 4 ]]; then
  echo "FAIL plugin_slug did not reach each wp plugin activate and check whole"
  fail=1
fi
# composer_command is code, run with its quotes by the container shell.
if [[ ! -e "$work/container/composer ran" ]]; then
  echo "FAIL composer_command did not run as written in the container"
  fail=1
fi
[[ "$fail" == 0 ]] || exit 1
echo "ok: wp-plugin-check and pimcore-bundle-check inputs reach docker and wp as text"
