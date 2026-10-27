#!/usr/bin/env bash
# go-deploy.yml's deploy step with ssh and rsync stubbed: a missing
# extra_files entry fails before anything is copied, unless
# allow_missing_extra_files is true, which skips it with a warning.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$ROOT_DIR/.github/workflows/go-deploy.yml" > "$work/step.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = [s for j in wf["jobs"].values() for s in j.get("steps", [])
         if "INPUT_EXTRA_FILES" in (s.get("env") or {})]
assert len(steps) == 1, len(steps)
print(steps[0]["run"])
PY

mkdir -p "$work/bin" "$work/tree"
for tool in ssh rsync; do
  # shellcheck disable=SC2016 # $* and $CALLS expand in the stub, not here
  printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$tool" > "$work/bin/$tool"
  chmod +x "$work/bin/$tool"
done
touch "$work/tree/app" "$work/tree/app.env"

run_step() {  # $1 = extra_files, $2 = allow_missing_extra_files
  : > "$work/calls"
  (cd "$work/tree" && env PATH="$work/bin:$PATH" CALLS="$work/calls" \
    DEPLOY_SSH_HOST=deploy.example DEPLOY_SSH_USER=u DEPLOY_SSH_KEY=k \
    DEPLOY_SSH_KNOWN_HOSTS="deploy.example ssh-ed25519 AAAA" \
    INPUT_REMOTE_PATH=/srv/app INPUT_BIN_NAME=app INPUT_REMOTE_BIN_NAME= \
    INPUT_EXTRA_FILES="$1" INPUT_ALLOW_MISSING_EXTRA_FILES="$2" \
    INPUT_POST_DEPLOY_COMMAND= bash "$work/step.sh" 2>&1)
}

fail=0
rc=0; out="$(run_step "app.env, missing.conf" false)" || rc=$?
if (( rc != 1 )); then echo "FAIL: missing extra file gave exit $rc, expected 1"; fail=1; fi
grep -q "extra file 'missing.conf' not found" <<<"$out" || { echo "FAIL: missing file not named"; fail=1; }
if [[ -s "$work/calls" ]]; then echo "FAIL: copied before failing:"; cat "$work/calls"; fail=1; fi

rc=0; out="$(run_step "app.env, missing.conf" true)" || rc=$?
if (( rc != 0 )); then echo "FAIL: allow_missing_extra_files gave exit $rc: $out"; fail=1; fi
grep -q "::warning::extra file 'missing.conf' not found" <<<"$out" || { echo "FAIL: no warning for skipped file"; fail=1; }
grep -q 'rsync .* app.env ' "$work/calls" || { echo "FAIL: app.env not copied"; fail=1; }

rc=0; out="$(run_step "app.env" false)" || rc=$?
if (( rc != 0 )); then echo "FAIL: present extra file gave exit $rc: $out"; fail=1; fi
[[ "$(grep -c '^rsync ' "$work/calls")" == 2 ]] || { echo "FAIL: expected binary and app.env copied"; cat "$work/calls"; fail=1; }

(( fail == 0 )) && echo "go_deploy_extra_files: missing file fails before copying, opt-in skips it"
exit "$fail"
