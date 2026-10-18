#!/usr/bin/env bash
# scripts/check_token_exposure.sh against planted workflows: a checkout that
# keeps its token and a job with no permissions must be reported; the fixed
# forms must pass.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${ROOT_DIR}/scripts/check_token_exposure.sh"
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
cat > "$work/.github/workflows/ok.yml" <<'YAML'
on: push
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
      - run: make test
YAML

fail=0
rc=0
out="$(cd "$work" && bash "$CHECK" 2>&1)" || rc=$?
if (( rc != 1 )); then echo "FAIL: exit $rc, expected 1"; fail=1; fi
grep -q 'bad.yml:[0-9]*: artipacked' <<<"$out" || { echo "FAIL: artipacked not reported"; fail=1; }
grep -q 'bad.yml:[0-9]*: excessive-permissions' <<<"$out" || { echo "FAIL: excessive-permissions not reported"; fail=1; }
if grep -q 'ok.yml' <<<"$out"; then echo "FAIL: ok.yml reported"; fail=1; fi

rm "$work/.github/workflows/bad.yml"
if ! (cd "$work" && bash "$CHECK" >/dev/null 2>&1); then echo "FAIL: fixed forms did not pass"; fail=1; fi

(( fail == 0 )) && echo "check_token_exposure: both findings reported, fixed forms pass"
exit "$fail"
