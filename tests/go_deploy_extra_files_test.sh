#!/usr/bin/env bash
# go-deploy.yml's split path with ssh and rsync stubbed: the build job's
# stage step, the artifact handed over as a copy, then the deploy job's
# verify and deploy steps. A missing extra_files entry fails in the build
# job, before anything is staged, unless allow_missing_extra_files is true,
# which skips it with a warning. A file changed after staging, or one added
# to the artifact, or a bin_file that is not a plain name under bin/, stops
# the deploy before ssh runs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

step() {  # step <job> <name> -> the step's run: on stdout
  python3 - "$ROOT_DIR/.github/workflows/go-deploy.yml" "$1" "$2" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in wf["jobs"][sys.argv[2]]["steps"] if s.get("name") == sys.argv[3]]
assert len(steps) == 1, (sys.argv[2], sys.argv[3], len(steps))
print(steps[0]["run"])
PY
}
step build "Stage the deploy files" > "$work/stage.sh"
step deploy "Verify the deploy files against the build manifest" > "$work/verify.sh"
step deploy "Deploy to remote" > "$work/deploy.sh"

mkdir -p "$work/bin" "$work/tree/conf"
for tool in ssh rsync; do
  # shellcheck disable=SC2016 # $* and $CALLS expand in the stub, not here
  printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$tool" > "$work/bin/$tool"
  chmod +x "$work/bin/$tool"
done
echo binary > "$work/tree/app"
echo env > "$work/tree/app.env"
echo hidden > "$work/tree/conf/.env"

output() {  # output <file> <key>: a value written to GITHUB_OUTPUT, heredoc form too
  python3 - "$1" "$2" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
key = sys.argv[2]
for i, ln in enumerate(lines):
    if ln.startswith(key + "="):
        print(ln[len(key) + 1:]); break
    if ln.startswith(key + "<<"):
        d = ln[len(key) + 2:]; j = lines.index(d, i + 1)
        print("\n".join(lines[i + 1:j])); break
PY
}

stage() {  # stage <extra_files> <allow_missing>
  rm -rf "$work/tmp"; mkdir -p "$work/tmp"; : > "$work/out"
  (cd "$work/tree" && env RUNNER_TEMP="$work/tmp" GITHUB_OUTPUT="$work/out" \
    GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 BIN=app \
    INPUT_EXTRA_FILES="$1" INPUT_ALLOW_MISSING_EXTRA_FILES="$2" bash "$work/stage.sh" 2>&1)
}

deploy() {  # hand the staged files over as the artifact, verify, deploy
  rm -rf "$work/tmp/go-deploy-in"; cp -R "$work/tmp/go-deploy-out" "$work/tmp/go-deploy-in"
  local in="$work/tmp/go-deploy-in"
  case "${1:-}" in
    "") ;;
    change) echo evil > "$in/bin/app" ;;
    add) echo extra > "$in/bin/more" ;;
    remove) rm "$in/extra/1/app.env" ;;
  esac
  : > "$work/calls"
  env RUNNER_TEMP="$work/tmp" DIR="$work/tmp/go-deploy-in" \
    MANIFEST="$(output "$work/out" manifest)" bash "$work/verify.sh" 2>&1 || return
  (cd "$work/tmp/go-deploy-in" && env PATH="$work/bin:$PATH" CALLS="$work/calls" \
    DEPLOY_SSH_HOST=deploy.example DEPLOY_SSH_USER=u DEPLOY_SSH_KEY=k \
    DEPLOY_SSH_KNOWN_HOSTS="deploy.example ssh-ed25519 AAAA" \
    INPUT_REMOTE_PATH=/srv/app INPUT_BIN_NAME=app INPUT_REMOTE_BIN_NAME= \
    BIN_FILE="${BIN_OVERRIDE-$(output "$work/out" bin_file)}" \
    INPUT_POST_DEPLOY_COMMAND= bash "$work/deploy.sh" 2>&1)
}

fail=0
rc=0; out="$(stage "app.env, missing.conf" false)" || rc=$?
if (( rc != 1 )); then echo "FAIL: missing extra file gave exit $rc, expected 1"; fail=1; fi
grep -q "extra file 'missing.conf' not found" <<<"$out" || { echo "FAIL: missing file not named"; fail=1; }
if [[ -s "$work/out" ]]; then echo "FAIL: staged before failing"; fail=1; fi

rc=0; out="$(stage "app.env, missing.conf" true)" || rc=$?
if (( rc != 0 )); then echo "FAIL: allow_missing_extra_files gave exit $rc: $out"; fail=1; fi
grep -q "::warning::extra file 'missing.conf' not found" <<<"$out" || { echo "FAIL: no warning for skipped file"; fail=1; }
rc=0; out="$(deploy)" || rc=$?
if (( rc != 0 )); then echo "FAIL: deploy gave exit $rc: $out"; fail=1; fi
grep -q 'rsync .* -- bin/app u@deploy.example:/srv/app/app$' "$work/calls" || { echo "FAIL: binary not copied"; cat "$work/calls"; fail=1; }
grep -q 'rsync .* extra/1/app.env u@deploy.example:/srv/app/' "$work/calls" || { echo "FAIL: app.env not copied"; fail=1; }

rc=0; out="$(stage "app.env, conf/.env" false)" || rc=$?
if (( rc != 0 )); then echo "FAIL: present extra files gave exit $rc: $out"; fail=1; fi
rc=0; out="$(deploy)" || rc=$?
if (( rc != 0 )); then echo "FAIL: deploy gave exit $rc: $out"; fail=1; fi
[[ "$(grep -c '^rsync ' "$work/calls")" == 3 ]] || { echo "FAIL: expected binary, app.env and .env copied"; cat "$work/calls"; fail=1; }
grep -q 'extra/2/.env ' "$work/calls" || { echo "FAIL: a dot file was not copied"; fail=1; }

for tamper in change add remove; do
  rc=0; out="$(deploy "$tamper")" || rc=$?
  if (( rc == 0 )); then echo "FAIL: deployed after: $tamper"; fail=1; fi
  if [[ -s "$work/calls" ]]; then echo "FAIL: ssh or rsync ran after: $tamper"; fail=1; fi
done

# bin_file is a build job output: caller code can set it to any path.
echo secret > "$work/tmp/key"
for bad in ../key ../../key -oX "" "app/../../key" $'app\nx'; do
  rc=0; out="$(BIN_OVERRIDE="$bad" deploy)" || rc=$?
  if (( rc == 0 )); then echo "FAIL: deployed with bin_file '$bad'"; fail=1; fi
  if [[ -s "$work/calls" ]]; then echo "FAIL: ssh or rsync ran with bin_file '$bad'"; fail=1; fi
done

ln -s /etc/hostname "$work/tree/link.conf"
rc=0; out="$(stage "link.conf" false)" || rc=$?
if (( rc == 0 )); then echo "FAIL: staged a symlinked extra file"; fail=1; fi
grep -q "symlinks are refused" <<<"$out" || { echo "FAIL: symlink not named: $out"; fail=1; }
rm "$work/tree/link.conf"
echo x > "$work/outside"
rc=0; out="$(stage "../outside" false)" || rc=$?
if (( rc == 0 )); then echo "FAIL: staged a file outside the working directory"; fail=1; fi
rm "$work/outside"

(( fail == 0 )) && echo "go_deploy_extra_files: missing file fails in the build job, opt-in skips it, a changed artifact stops the deploy, a symlink or outside file is not staged"
exit "$fail"
