#!/usr/bin/env bash
# SCRIPT: cloudflare_deploy_split_test.sh
# DESCRIPTION: cloudflare-deploy.yml builds in a `build` job with no
#              Cloudflare secret and deploys in a `deploy` job that checks
#              out nothing of the caller's and runs only the pinned wrangler.
#              Checks the workflow shape, that deploy_command and
#              wrangler_command are refused, the deploy_args allowlist and
#              every value that reaches wrangler's argv, the config check
#              (refused keys, assets outside the tree, env files, symlinks),
#              the artifact check (tamper, symlink, traversal), the staging
#              script, setup_wrangler.sh's digest and lockfile checks, and
#              that wrangler_run.sh keeps the token out of argv. npm, curl
#              and node are stubbed for the scripts that call them.
# USAGE: bash tests/cloudflare_deploy_split_test.sh
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows/cloudflare-deploy.yml"
wfb="$root/.github/workflows/cloudflare-build.yml"
cw="$root/scripts/cloudflare_wrangler.py"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# --- the workflow shape -----------------------------------------------------
python3 - "$wf" "$wfb" <<'PY' || fail=1
import re, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
db = yaml.safe_load(open(sys.argv[2]))
jobs = d["jobs"]
bad = 0
def text(j): return yaml.safe_dump(j)
def err(m):
    global bad
    print(f"FAIL {m}"); bad = 1
if set(jobs) != {"resolve", "disabled-notice", "build", "deploy"}:
    err(f"jobs are {sorted(jobs)}")
b, p = jobs.get("build", {}), jobs.get("deploy", {})
if "secrets." in text(b) or b.get("environment"):
    err("the build job reads a secret or an Environment")
if b.get("permissions") != {"contents": "read"}:
    err("the build job's permissions are not contents: read")
if p.get("runs-on") != "${{ inputs.deploy_runner }}":
    err("the deploy job does not run on deploy_runner")
if "build" not in (p.get("needs") or []):
    err("the deploy job does not need build")
for s in p.get("steps", []):
    if str(s.get("uses", "")).startswith("actions/checkout") and "repository" not in (s.get("with") or {}):
        err("the deploy job checks out the caller's repository")
    blob = text(s)
    for name in ("build_command", "install_command", "deploy_command", "wrangler_command", "config_glob"):
        if f"inputs.{name}" in blob:
            err(f"the deploy job step '{s.get('name')}' reads inputs.{name}")
    if "secrets.CLOUDFLARE_API_TOKEN" in blob and s.get("name") not in ("Preflight credentials", "Deploy"):
        err(f"the token reaches step '{s.get('name')}'")
ver = [s for s in p.get("steps", []) if s.get("id") == "verify"]
if not ver or 'cloudflare_wrangler.py" bundle "$in/bundle"' not in ver[0].get("run", ""):
    err("the verify step does not check the bundle's source map comments")
dep = [s for s in p.get("steps", []) if s.get("name") == "Deploy"]
if not dep or "wrangler_run.sh\" deploy" not in dep[0].get("run", "") or "lib_path.sh\" secret" not in dep[0].get("run", ""):
    err("the Deploy step does not run wrangler_run.sh deploy in lib_path secret mode")
inputs = d.get("on", d.get(True))["workflow_call"]["inputs"]
for name in ("deploy_command", "wrangler_command"):
    if "REMOVED" not in inputs[name].get("description", ""):
        err(f"{name} is not described as removed")
if inputs["wrangler_version"].get("default") != "":
    err("wrangler_version still has a default")
if "deploy_runner" not in inputs:
    err("no deploy_runner input")
outs = d.get("on", d.get(True))["workflow_call"]["outputs"]
for k in ("deployed", "environment", "version", "url"):
    if k not in outs:
        err(f"output {k} is gone")
bi = db.get("on", db.get(True))["workflow_call"]["inputs"]
if "REMOVED" not in bi["wrangler_command"].get("description", ""):
    err("cloudflare-build.yml wrangler_command is not described as removed")
if "npx" in open(sys.argv[1]).read() + open(sys.argv[2]).read():
    err("a workflow still runs npx")
sys.exit(bad)
PY
[[ $fail == 0 ]] && ok "workflow shape: build has no secret, deploy checks out nothing of the caller's"

# --- removed inputs are refused, naming the replacement -------------------
python3 - "$wf" "$wfb" > "$work/runs" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
s = [x for x in d["jobs"]["resolve"]["steps"] if x.get("id") == "decide"][0]["run"]
print(s, end="")
PY
db_run="$(python3 -c 'import sys,yaml;d=yaml.safe_load(open(sys.argv[1]));print([s for s in d["jobs"]["build"]["steps"] if s.get("name")=="Refuse removed inputs"][0]["run"])' "$wfb")"
resolve() {  # resolve VAR=value... ; runs the resolve step
  env -i PATH="$PATH" GITHUB_OUTPUT="$work/out" IN_ENABLED=true VAR_ENABLED= IN_ENVIRONMENT=staging \
    IN_PRODUCTION_ENVIRONMENT=production IN_REF= IN_COMMAND=deploy IN_WRANGLER_ENV= IN_DEPLOY_ARGS= \
    IN_DEPLOY_COMMAND= IN_WRANGLER_COMMAND= IN_CONFIG_PATH= IN_CONFIG_GLOB= EVENT_NAME=push REF_TYPE=branch \
    REF_NAME=main COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 "$@" bash -c "$(cat "$work/runs")" 2>&1
}
: > "$work/out"
if out="$(resolve IN_DEPLOY_COMMAND='./dev deploy')"; then bad "deploy_command accepted"
elif [[ "$out" == *"deploy_command is removed"*"build_command"* ]]; then ok "deploy_command refused, naming build_command"
else bad "deploy_command refused without naming the replacement: $out"; fi
if out="$(resolve IN_WRANGLER_COMMAND='pnpm exec wrangler')"; then bad "wrangler_command accepted"
elif [[ "$out" == *"wrangler_command is removed"*"toolchain-pins.env"* ]]; then ok "wrangler_command refused, naming the pinned wrangler"
else bad "wrangler_command refused without naming the replacement: $out"; fi
if out="$(env -i PATH="$PATH" IN_WRANGLER_COMMAND='npx wrangler' bash -c "$db_run" 2>&1)"; then bad "cloudflare-build accepted wrangler_command"
elif [[ "$out" == *"wrangler_command is removed"* ]]; then ok "cloudflare-build refuses wrangler_command"
else bad "cloudflare-build refusal: $out"; fi
if out="$(resolve IN_WRANGLER_ENV='a;b')"; then bad "a wrangler env with ; accepted"; else ok "a wrangler env outside the pattern is refused"; fi
if out="$(resolve IN_COMMAND='pages deploy' IN_CONFIG_PATH=wrangler.toml)"; then bad "pages deploy with config_path accepted"; else ok "pages deploy with a config path is refused"; fi
if out="$(resolve IN_DEPLOY_ARGS=$'dist\n--x')"; then bad "deploy_args with a newline accepted"; else ok "deploy_args with a line break is refused"; fi
: > "$work/out"
if resolve >/dev/null && grep -qx 'wrangler_env=staging' "$work/out" && grep -qx 'command=deploy' "$work/out"; then
  ok "a plain run resolves"
else bad "a plain run does not resolve: $(cat "$work/out")"; fi

# --- deploy_args allowlist ---------------------------------------------------
args() { CF_COMMAND="$1" CF_DEPLOY_ARGS="$2" python3 -I "$cw" args 2>&1; }
# shellcheck disable=SC2016  # the $(id) is the injection under test
for a in "--config=/etc/passwd" "--name foo;rm" '--name $(id)' "--outdir /tmp" "--custom-build x" \
         "src/index.js" "--name" "--name UPPER" "--compatibility-date 2024-1-1" "--tag a b" \
         "--keep-vars=yes" "--env other" "--var X:1" "--assets /proc/self" "--x"; do
  if args deploy "$a" >/dev/null; then bad "deploy_args '$a' accepted for deploy"; fi
done
for a in "dist --project-name ../x" "../dist --project-name s" "/abs --project-name s" "--project-name s" \
         "dist other" "dist --branch -x" "dist --commit-hash zz" "dist --project-name s --config w.toml" \
         "dist/./x" "dist --project-name s\`id\`"; do
  if args "pages deploy" "$a" >/dev/null; then bad "deploy_args '$a' accepted for pages deploy"; fi
done
[[ $fail == 0 ]] && ok "deploy_args: every flag outside the allowlist, bad value and stray word is refused"
if [[ "$(args "pages deploy" "dist/ --project-name example-site --branch feat/x --commit-dirty=true")" == "pages_dir=dist" ]] \
   && [[ "$(args deploy "--name w --compatibility-date 2024-01-01 --keep-vars --tag v1.2.3")" == "pages_dir=" ]]; then
  ok "deploy_args: allowed flags pass"
else bad "deploy_args: allowed flags refused"; fi
if args "rm -rf" "" >/dev/null; then bad "command 'rm -rf' accepted"; else ok "a command outside the allowlist is refused"; fi

# --- argv: every value reaching wrangler ------------------------------------
argv() { env -i PATH="$PATH" CF_MODE=deploy CF_COMMAND=deploy CF_DEPLOY_ARGS="--name w" CF_ENV_NAME=staging \
  CF_VERSION_VAR=VERSION CF_VERSION=1.2.3-abc1234 CF_CONFIG=tree/ci-helpers-deploy.wrangler.json \
  CF_ENTRY=bundle/index.js "$@" python3 -I "$cw" argv 2>&1 | tr '\0' ' '; }
want="deploy bundle/index.js --no-bundle --config tree/ci-helpers-deploy.wrangler.json --env staging --var VERSION:1.2.3-abc1234 --name w "
if [[ "$(argv)" == "$want" ]]; then ok "argv: the Workers deploy argv"; else bad "argv: got '$(argv)'"; fi
for kv in "CF_VERSION=1.0;id" "CF_VERSION=" "CF_VERSION=-x" "CF_VERSION_VAR=A:B" "CF_VERSION_VAR=1A" \
          "CF_ENV_NAME=--dry-run" "CF_ENV_NAME=a b" "CF_ENTRY=bundle/../x.js" "CF_ENTRY=/etc/x.js" "CF_ENTRY=bundle/x.sh" \
          "CF_CONFIG=/etc/w.toml" "CF_CONFIG=tree/../w.toml" "CF_CONFIG=" "CF_COMMAND=delete" "CF_MODE=other" \
          "CF_DEPLOY_ARGS=--config x"; do
  if env "$kv" true && out="$(argv "$kv")" && [[ "$out" != *"::error::"* ]]; then bad "argv accepted $kv: $out"; fi
done
[[ $fail == 0 ]] && ok "argv: a bad version, var, env, entry, config, command or flag is refused"
want="pages deploy site --project-name s "
if [[ "$(argv CF_COMMAND="pages deploy" CF_DEPLOY_ARGS="dist --project-name s" CF_PAGES_DIR=site CF_CONFIG= CF_ENTRY=)" == "$want" ]]; then
  ok "argv: the Pages argv uploads the staged site/, not the caller's path"
else bad "argv: pages got '$(argv CF_COMMAND="pages deploy" CF_DEPLOY_ARGS="dist --project-name s" CF_PAGES_DIR=site CF_CONFIG= CF_ENTRY=)'"; fi
if [[ "$(argv CF_ENV_NAME=none CF_VERSION_VAR=)" == "deploy bundle/index.js --no-bundle --config tree/ci-helpers-deploy.wrangler.json --name w " ]]; then
  ok "argv: wrangler_env none and an empty version_var omit --env and --var"
else bad "argv: none got '$(argv CF_ENV_NAME=none CF_VERSION_VAR=)'"; fi

# --- the config check --------------------------------------------------------
cfg() {  # cfg <toml body> [extra args]; tree in $work/t
  rm -rf "$work/t"; mkdir -p "$work/t/public"; echo hi > "$work/t/public/a.txt"
  printf '%s\n' "$1" > "$work/t/wrangler.toml"; shift
  python3 -I "$cw" config "$work/t" wrangler.toml staging "$@" 2>&1
}
base=$'name = "w"\nmain = "src/index.ts"\ncompatibility_date = "2025-01-01"\n[assets]\ndirectory = "public"'
if [[ "$(cfg "$base")" == $'assets=public\nentry=index.js' ]]; then ok "config: assets and entry"; else bad "config: got '$(cfg "$base")'"; fi
for extra in $'[[containers]]\nimage = "./Dockerfile"' $'[site]\nbucket = "/"' \
             $'[wasm_modules]\nX = "/proc/self/environ"' $'[text_blobs]\nX = "/etc/passwd"' \
             $'[env.staging.text_blobs]\nX = "/etc/passwd"'; do
  if cfg "$base"$'\n'"$extra" >/dev/null; then bad "config accepted: $extra"; fi
done
if cfg 'base_dir = "/"'$'\n'"$base" >/dev/null; then bad "config accepted base_dir"; fi
for dir in "/proc/self" "../.." "../outside" "."; do
  if cfg "${base/directory = \"public\"/directory = \"$dir\"}" >/dev/null; then bad "config accepted assets directory $dir"; fi
done
[[ $fail == 0 ]] && ok "config: refused keys and an assets directory outside the tree are refused"
# An allowlist of keys: an unknown key, unsafe.capnp (wrangler runs capnp or
# reads compiled_schema from any path) and pages_build_output_dir are refused.
for extra in $'made_up_key = 1\n[assets]' $'[unsafe.capnp]\ncompiled_schema = "/proc/self/environ"' \
             $'[env.staging.unsafe.capnp]\nbase_path = "/"\nsource_schemas = ["x"]' \
             $'pages_build_output_dir = "/"\n[assets]' $'[env.staging]\nmade_up_key = 1' $'[env.staging.env.x]\nname = "y"' \
             $'[[rules]]\ntype = "ESModule"\nglobs = ["**/*.txt"]' $'[[env.staging.rules]]\ntype = "CommonJS"\nglobs = ["**/*"]' \
             $'[env.staging]\npython_modules = { exclude = [] }'; do
  if [[ "$extra" == *$'\n[assets]' ]]; then body="${extra%$'\n[assets]'}"$'\n'"$base"; else body="$base"$'\n'"$extra"; fi
  if cfg "$body" >/dev/null; then bad "config accepted: $extra"; fi
done
out="$(cfg $'find_additional_modules = true\n'"$base")" || true
if [[ "$out" == *"find_additional_modules"*"bundle"* ]]; then ok "config: find_additional_modules is refused with a reason"; else bad "config: find_additional_modules got '$out'"; fi
keep=$'upload_source_maps = true\n[vars]\nA = "b"\n[dev]\nport = 1\n[[unsafe.bindings]]\nname = "R"\ntype = "ratelimit"\n[env.staging]\nname = "w-s"\n[[env.staging.kv_namespaces]]\nbinding = "K"\nid = "x"'
if [[ "$(cfg "$base"$'\n'"$keep" 2>&1)" == $'assets=public\nentry=index.js' ]]; then
  ok "config: known keys (source maps, unsafe.bindings, env bindings) pass"
else bad "config: known keys refused: $(cfg "$base"$'\n'"$keep")"; fi
[[ $fail == 0 ]] && ok "config: an unknown key, unsafe.capnp and a nested env are refused"
out="$(cfg "$base"$'\n[build]\ncommand = "touch /tmp/x"\n[env.staging]\nname = "w-s"\n[env.staging.build]\ncommand = "id"' --write)"
if [[ "$out" == *"config=ci-helpers-deploy.wrangler.json"* ]] && ! grep -q '"build"' "$work/t/ci-helpers-deploy.wrangler.json" \
   && grep -q '"w-s"' "$work/t/ci-helpers-deploy.wrangler.json"; then
  ok "config --write: build is dropped at the top level and in env, the rest kept"
else bad "config --write: $out"; fi
cfg "$base" >/dev/null
touch "$work/t/ci-helpers-deploy.wrangler.json"
if python3 -I "$cw" config "$work/t" wrangler.toml staging --write >/dev/null 2>&1; then bad "config --write overwrote an existing file"; else ok "config --write refuses an existing checked-config path"; fi
for f in .env .env.production .dev.vars public/.env; do
  cfg "$base" >/dev/null; : > "$work/t/$f"
  if python3 -I "$cw" config "$work/t" wrangler.toml staging --write >/dev/null 2>&1; then bad "config --write accepted $f"; fi
done
cfg "$base" >/dev/null; ln -s /etc/passwd "$work/t/public/p"
if python3 -I "$cw" config "$work/t" wrangler.toml staging --write >/dev/null 2>&1; then bad "config --write accepted a symlink"; fi
[[ $fail == 0 ]] && ok "config --write: env files and symlinks in the deploy tree are refused"
rm -rf "$work/t"; mkdir -p "$work/t/dist/w" "$work/t/dist/client"
cat > "$work/t/dist/w/wrangler.json" <<'EOF'
// generated
{
  "name": "w", /* inline */ "main": "index.js",
  "assets": { "directory": "../client", },
  "vars": { "URL": "https://x//y" },
}
EOF
if [[ "$(python3 -I "$cw" config "$work/t" dist/w/wrangler.json staging 2>&1)" == $'assets=dist/client\nentry=index.js' ]]; then
  ok "config: JSONC with comments and trailing commas, assets relative to the config"
else bad "config: jsonc got '$(python3 -I "$cw" config "$work/t" dist/w/wrangler.json staging 2>&1)'"; fi
if python3 -I "$cw" config "$work/t" ../t/dist/w/wrangler.json staging >/dev/null 2>&1; then bad "config accepted a .. config path"; fi
if python3 -I "$cw" config "$work/t" /etc/passwd staging >/dev/null 2>&1; then bad "config accepted an absolute config path"; fi

# --- staging -----------------------------------------------------------------
stage="$root/scripts/cloudflare_stage.sh"
rm -rf "$work/w" "$work/o"; mkdir -p "$work/w/public/sub" "$work/o/bundle"
echo c > "$work/w/wrangler.toml"; echo a > "$work/w/public/sub/a.txt"; echo b > "$work/o/bundle/index.js"
if bash "$stage" workers "$work/w" "$work/o" wrangler.toml public > "$work/list" \
   && [[ "$(sed -E 's/^[0-9a-f]{64}  //' "$work/list" | tr '\n' ' ')" == "./bundle/index.js ./tree/public/sub/a.txt ./tree/wrangler.toml " ]]; then
  ok "stage: config, assets and bundle listed"
else bad "stage: $(cat "$work/list")"; fi
ln -s /etc/passwd "$work/w/public/p"
rm -rf "$work/o"; mkdir -p "$work/o/bundle"
if bash "$stage" workers "$work/w" "$work/o" wrangler.toml public >/dev/null 2>&1; then bad "stage accepted a symlink in assets"; else ok "stage: a symlink in the assets is refused"; fi
rm "$work/w/public/p"
for a in ../x /etc ./public "public/../.."; do
  rm -rf "$work/o"; mkdir -p "$work/o/bundle"
  if bash "$stage" workers "$work/w" "$work/o" wrangler.toml "$a" >/dev/null 2>&1; then bad "stage accepted assets $a"; fi
done
ln -s /etc "$work/w/linked"
rm -rf "$work/o"; mkdir -p "$work/o"
if bash "$stage" pages "$work/w" "$work/o" linked >/dev/null 2>&1; then bad "stage accepted a symlinked pages dir"; fi
rm -rf "$work/o"; mkdir -p "$work/o"
if bash "$stage" pages "$work/w" "$work/o" public > "$work/list" && grep -q '  ./site/sub/a.txt$' "$work/list"; then ok "stage: the Pages directory goes to site/"; else bad "stage: pages"; fi
[[ $fail == 0 ]] && ok "stage: traversal and symlinked directories are refused"

# --- the deploy job's artifact check ----------------------------------------
parts="$root/scripts/artifact_parts.sh"
re='(tree|bundle)/[^[:cntrl:]\\]+'
mk() {
  rm -rf "$work/in"; mkdir -p "$work/in/tree" "$work/in/bundle"
  echo c > "$work/in/tree/wrangler.toml"; echo b > "$work/in/bundle/index.js"
  (cd "$work/in" && find . -type f | sort | while IFS= read -r f; do sha256sum -- "$f"; done) > "$work/m"
}
mk; if bash "$parts" verify "$work/in" "$work/m" "$re" >/dev/null 2>&1; then ok "verify: an untouched artifact passes"; else bad "verify: untouched refused"; fi
mk; echo evil > "$work/in/bundle/index.js"
if bash "$parts" verify "$work/in" "$work/m" "$re" >/dev/null 2>&1; then bad "verify accepted a changed file"; fi
mk; echo x > "$work/in/tree/extra"
if bash "$parts" verify "$work/in" "$work/m" "$re" >/dev/null 2>&1; then bad "verify accepted an added file"; fi
mk; rm "$work/in/tree/wrangler.toml"; ln -s /etc/passwd "$work/in/tree/wrangler.toml"
if bash "$parts" verify "$work/in" "$work/m" "$re" >/dev/null 2>&1; then bad "verify accepted a symlink"; fi
mk; printf '%s  ./tree/../../etc/passwd\n' "$(printf x | sha256sum | cut -d' ' -f1)" >> "$work/m"
if bash "$parts" verify "$work/in" "$work/m" "$re" >/dev/null 2>&1; then bad "verify accepted a traversal line"; fi
mk; mkdir -p "$work/in/other"; echo o > "$work/in/other/x"; sha256sum "$work/in/other/x" | sed "s#  .*#  ./other/x#" >> "$work/m"
if bash "$parts" verify "$work/in" "$work/m" "$re" >/dev/null 2>&1; then bad "verify accepted a path outside tree/ and bundle/"; fi
[[ $fail == 0 ]] && ok "verify: a changed, added, symlinked, traversing or out-of-pattern file is refused"

# --- setup_wrangler.sh: pinned tarball and lockfile --------------------------
lib="$work/lib"; rm -rf "$lib"; mkdir -p "$lib/scripts" "$work/bin"
cp -R "$root/scripts/setup_wrangler.sh" "$root/scripts/wrangler" "$lib/scripts/"
printf 'fake wrangler tarball\n' > "$work/tarball"
sha="$(sha256sum "$work/tarball" | cut -d' ' -f1)"
sri="$(openssl dgst -sha512 -binary "$work/tarball" | base64 | tr -d '\n')"
python3 - "$lib/scripts/wrangler/package-lock.json" "$sri" <<'PY'
import json, sys
p, sri = sys.argv[1:]
d = json.load(open(p))
d["packages"]["node_modules/wrangler"]["integrity"] = "sha512-" + sri
json.dump(d, open(p, "w"), indent=2)
PY
ver="$(sed -n 's/^WRANGLER_VERSION=//p' "$root/toolchain-pins.env")"
cat > "$work/bin/curl" <<EOF
#!/usr/bin/env bash
out=; while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; esac; shift; done
cp "$work/tarball" "\$out"
EOF
cat > "$work/bin/npm" <<EOF
#!/usr/bin/env bash
echo "\$*" > "$work/npm-args"
env > "$work/npm-env"
mkdir -p node_modules/wrangler/bin
echo '{"version":"$ver"}' > node_modules/wrangler/package.json
echo 'x' > node_modules/wrangler/bin/wrangler.js
EOF
chmod +x "$work/bin/curl" "$work/bin/npm"
pins() { printf 'WRANGLER_VERSION=%s\nWRANGLER_TARBALL_SHA256=%s\n' "$1" "$2" > "$work/pins"; }
setup() { PATH="$work/bin:$PATH" TOOLCHAIN_PINS="$work/pins" RUNNER_TEMP="$work" GITHUB_OUTPUT="$work/gh" bash "$lib/scripts/setup_wrangler.sh" 2>&1; }
pins "$ver" "$sha"; : > "$work/gh"
if out="$(setup)" && grep -q '^wrangler=.*/node_modules/wrangler/bin/wrangler.js$' "$work/gh" \
   && grep -q -- '--ignore-scripts' "$work/npm-args" && grep -q '^ci ' "$work/npm-args" \
   && grep -q '^NPM_CONFIG_GLOBALCONFIG=/dev/null$' "$work/npm-env"; then
  ok "setup_wrangler: the pinned tarball installs with npm ci --ignore-scripts and no global npmrc"
else bad "setup_wrangler: $out"; fi
pins "$ver" "$(printf '0%.0s' {1..64})"
if out="$(setup)"; then bad "setup_wrangler accepted a sha256 mismatch"
elif [[ "$out" == *"has sha256"* ]]; then ok "setup_wrangler: a tarball digest mismatch is refused"; else bad "setup_wrangler digest: $out"; fi
pins "$ver" "$sha"; printf 'other\n' > "$work/tarball"; pins "$ver" "$(sha256sum "$work/tarball" | cut -d' ' -f1)"
if out="$(setup)"; then bad "setup_wrangler accepted a lockfile integrity mismatch"
elif [[ "$out" == *"lockfile's sha512"* ]]; then ok "setup_wrangler: a tarball that is not the lockfile's is refused"; else bad "setup_wrangler integrity: $out"; fi
printf 'fake wrangler tarball\n' > "$work/tarball"
pins "9.9.9" "$sha"
if setup >/dev/null; then bad "setup_wrangler accepted a pin the lockfile does not hold"; else ok "setup_wrangler: a version the lockfile does not pin is refused"; fi
python3 - "$lib/scripts/wrangler/package-lock.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
k = next(k for k in d["packages"] if k and k != "node_modules/wrangler")
d["packages"][k]["resolved"] = "https://evil.example/x.tgz"
json.dump(d, open(p, "w"), indent=2)
PY
pins "$ver" "$sha"
if setup >/dev/null; then bad "setup_wrangler accepted a dependency from another registry"; else ok "setup_wrangler: a lockfile entry off the registry is refused"; fi

# --- wrangler_run.sh: argv and environment -----------------------------------
mkdir -p "$work/n/node_modules/wrangler/bin"; : > "$work/n/node_modules/wrangler/bin/wrangler.js"
cat > "$work/n/node" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/run-argv"
env > "$work/run-env"
pwd > "$work/run-pwd"
EOF
chmod +x "$work/n/node"
mkdir -p "$work/in2"
marker="not-a-token-$$"
run() { env -i PATH="/usr/bin:/bin" RUNNER_TEMP="$work" NODE="$work/n/node" WRANGLER_JS="$work/n/node_modules/wrangler/bin/wrangler.js" \
  CF_WORKDIR="$work/in2" CF_COMMAND=deploy CF_DEPLOY_ARGS= CF_ENV_NAME=staging CF_VERSION_VAR=VERSION CF_VERSION=1.0.0 \
  CF_CONFIG=tree/c.json CF_ENTRY=bundle/index.js CLOUDFLARE_API_TOKEN="$marker" \
  CLOUDFLARE_ACCOUNT_ID=0123456789abcdef0123456789abcdef CALLER_VAR=leak NODE_OPTIONS=--require=/x "$@" \
  bash "$root/scripts/wrangler_run.sh" deploy 2>&1; }
if out="$(run)" && ! grep -qF "$marker" "$work/run-argv" && grep -qxF "CLOUDFLARE_API_TOKEN=$marker" "$work/run-env" \
   && grep -qx 'CLOUDFLARE_ENV=staging' "$work/run-env" && ! grep -q '^CALLER_VAR=\|^NODE_OPTIONS=' "$work/run-env" \
   && [[ "$(cat "$work/run-pwd")" == "$work/in2" ]] && [[ "$out" != *"$marker"* ]]; then
  ok "wrangler_run: the token is in wrangler's environment only, nothing else of the caller's"
else bad "wrangler_run: $out"; fi
if run CLOUDFLARE_ACCOUNT_ID=abc >/dev/null; then bad "wrangler_run accepted a bad account id"; else ok "wrangler_run: an account id that is not 32 hex is refused"; fi
if run CLOUDFLARE_API_TOKEN= >/dev/null; then bad "wrangler_run deployed with no token"; else ok "wrangler_run: no token, no deploy"; fi
if run WRANGLER_JS=/usr/bin/id >/dev/null; then bad "wrangler_run ran another script"; else ok "wrangler_run: WRANGLER_JS must be the installed wrangler"; fi
if run CF_VERSION='1;id' >/dev/null; then bad "wrangler_run accepted an injected version"; else ok "wrangler_run: a version outside the pattern is refused before wrangler runs"; fi
run CF_COMMAND="pages deploy" CF_DEPLOY_ARGS="dist --project-name s" CF_PAGES_DIR=site >/dev/null || true
if ! grep -q '^CLOUDFLARE_ENV=' "$work/run-env" && [[ "$(tr '\n' ' ' < "$work/run-argv")" == *"pages deploy site --project-name s "* ]]; then
  ok "wrangler_run: Pages sets no CLOUDFLARE_ENV"
else bad "wrangler_run: pages env or argv"; fi
# wrangler pages deploy looks for a wrangler config in its directory and
# every parent; a stub in the directory stops that walk.
if [[ "$(cat "$work/in2/wrangler.json" 2>/dev/null)" == "{}" ]]; then
  ok "wrangler_run: Pages runs beside an empty config, so no parent config is read"
else bad "wrangler_run: no stub config for Pages"; fi
rm -f "$work/in2/wrangler.json"; echo 'x' > "$work/in2/wrangler.toml"; : > "$work/run-argv"
if run CF_COMMAND="pages deploy" CF_DEPLOY_ARGS="dist --project-name s" CF_PAGES_DIR=site >/dev/null || [[ -s "$work/run-argv" ]]; then
  bad "wrangler_run: Pages ran beside an existing config"
else ok "wrangler_run: Pages refuses a config already in its directory"; fi
rm -f "$work/in2/wrangler.toml"

# --- deploy_args: a single-value flag given twice ----------------------------
for a in "--name a --name b" "--name=a --name b" "--keep-vars --keep-vars=false"; do
  if args deploy "$a" >/dev/null; then bad "deploy_args '$a' accepted twice"; fi
done
for a in "dist --project-name a --project-name b" "dist --branch a --branch=b"; do
  if args "pages deploy" "$a" >/dev/null; then bad "deploy_args '$a' accepted twice"; fi
done
if [[ "$(args deploy "--compatibility-flag a --compatibility-flag b")" == "pages_dir=" ]]; then
  ok "deploy_args: a single-value flag given twice is refused; --compatibility-flag repeats"
else bad "deploy_args: repeated --compatibility-flag refused"; fi

# --- bundle: a source map comment must name a file in the bundle -------------
rm -rf "$work/b"; mkdir -p "$work/b/sub"
printf 'x\n//# sourceMappingURL=index.js.map\n' > "$work/b/index.js"; echo '{}' > "$work/b/index.js.map"
printf 'y\n//# sourceMappingURL=sub/h.mjs.map\n' > "$work/b/h.mjs"; mkdir -p "$work/b/sub"; echo '{}' > "$work/b/sub/h.mjs.map"
if python3 -I "$cw" bundle "$work/b" >/dev/null 2>&1; then ok "bundle: source maps inside the bundle pass"; else bad "bundle: $(python3 -I "$cw" bundle "$work/b" 2>&1)"; fi
for u in /proc/self/environ ../../etc/passwd file:///etc/passwd missing.map 'sub/../../x.map'; do
  printf 'x\n//# sourceMappingURL=%s\n' "$u" > "$work/b/index.js"
  if python3 -I "$cw" bundle "$work/b" >/dev/null 2>&1; then bad "bundle accepted sourceMappingURL=$u"; fi
done
printf 'x\n//# sourceMappingURL=index.js.map\n' > "$work/b/index.js"
printf '//# sourceMappingURL=/etc/passwd\n' > "$work/b/sub/c.cjs"
if python3 -I "$cw" bundle "$work/b" >/dev/null 2>&1; then bad "bundle accepted an outside map in a nested module"; fi
printf 'var r = /# sourceMappingURL=(.+)/g;\nexport default r;\n' > "$work/b/sub/c.cjs"
if python3 -I "$cw" bundle "$work/b" >/dev/null 2>&1; then ok "bundle: a sourceMappingURL in code, not the trailing comment, is ignored"; else bad "bundle: false positive on code"; fi
printf 'x\n//# sourceMappingURL=../../etc/passwd\n' > "$work/b/sub/m.txt"
if python3 -I "$cw" bundle "$work/b" >/dev/null 2>&1; then bad "bundle accepted an outside map in a .txt module (rules can make it ESM)"; fi
rm -f "$work/b/sub/m.txt"
[[ $fail == 0 ]] && ok "bundle: a source map comment naming a file outside the bundle is refused"

# --- config: a TOML config on a Python without tomllib fails clearly ---------
mkdir -p "$work/notoml"; printf 'raise ModuleNotFoundError("No module named tomllib", name="tomllib")\n' > "$work/notoml/tomllib.py"
cfg "$base" >/dev/null
out="$(PYTHONPATH="$work/notoml" python3 "$cw" config "$work/t" wrangler.toml staging 2>&1 || true)"
if [[ "$out" == *"::error::"*"Python 3.11"* && "$out" != *Traceback* ]]; then ok "config: no tomllib names Python 3.11"; else bad "config without tomllib: $out"; fi

exit "$fail"
