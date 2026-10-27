#!/usr/bin/env bash
# scripts/check_zizmor.sh against planted workflows: a checkout that keeps
# its token, a job with no permissions and a text input spliced into a run
# script must be reported; inputs.<name>_command and the fixed forms must
# pass.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${ROOT_DIR}/scripts/check_zizmor.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/.github/workflows"

cat > "$work/.github/workflows/bad.yml" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - run: make test
YAML
cat > "$work/.github/workflows/splice.yml" <<'YAML'
on:
  workflow_call:
    inputs:
      title:
        type: string
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    permissions: {}
    steps:
      - run: echo "${{ inputs.title }}"
YAML
cat > "$work/.github/workflows/ok.yml" <<'YAML'
on:
  workflow_call:
    inputs:
      test_command:
        type: string
      title:
        type: string
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - run: ${{ inputs.test_command }}
      - env:
          TITLE: ${{ inputs.title }}
        run: echo "$TITLE"
YAML

fail=0
rc=0
out="$(cd "$work" && bash "$CHECK" 2>&1)" || rc=$?
if (( rc != 1 )); then echo "FAIL: exit $rc, expected 1"; fail=1; fi
grep -q 'bad.yml:[0-9]*: artipacked' <<<"$out" || { echo "FAIL: artipacked not reported"; fail=1; }
grep -q 'bad.yml:[0-9]*: excessive-permissions' <<<"$out" || { echo "FAIL: excessive-permissions not reported"; fail=1; }
grep -q 'splice.yml:[0-9]*: template-injection:.*inputs.title' <<<"$out" || { echo "FAIL: spliced text input not reported"; fail=1; }
if grep -q 'ok.yml' <<<"$out"; then echo "FAIL: ok.yml reported (inputs.test_command is allowed)"; fail=1; fi

rm "$work/.github/workflows/bad.yml" "$work/.github/workflows/splice.yml"
if ! (cd "$work" && bash "$CHECK" >/dev/null 2>&1); then echo "FAIL: fixed forms did not pass"; fail=1; fi

(( fail == 0 )) && echo "check_zizmor: all three findings reported, *_command and fixed forms pass"
exit "$fail"
