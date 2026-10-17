#!/usr/bin/env bash
# scripts/check_no_self_refs.sh against planted workflows: every floating
# self-reference must be reported, and the allowed forms must pass.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${ROOT_DIR}/scripts/check_no_self_refs.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

git -C "$work" init -q
mkdir -p "$work/.github/workflows"
cat > "$work/.github/workflows/bad.yml" <<'YAML'
jobs:
  a:
    steps:
      - uses: someone/ci-helpers/.github/actions/x@production
      - uses: "someone/ci-helpers/.github/actions/y@v1"
      -   uses:   someone/ci-helpers/.github/workflows/z.yml@0123456789012345678901234567890123456789
      - uses: someone/ci-helpers@production
      - uses: 'someone/ci-helpers/tools/action@main'
  b:
    uses: someone/ci-helpers/.github/workflows/w.yml@main
YAML
cat > "$work/.github/workflows/ok.yml" <<'YAML'
# uses: someone/ci-helpers/.github/workflows/w.yml@production
jobs:
  a:
    steps:
      - uses: ./.ci-helpers-actions/.github/actions/x
      - uses: someone/ci-helpers-extra/.github/actions/x@v1
      - uses: actions/checkout@0123456789012345678901234567890123456789 # v7
        with:
          repository: someone/ci-helpers
YAML
git -C "$work" add -A

fail=0
rc=0
out="$(cd "$work" && bash "$CHECK" 2>&1)" || rc=$?
if (( rc != 1 )); then echo "FAIL: exit $rc, expected 1"; fail=1; fi
for line in 4 5 6 7 8 10; do
  if ! grep -q "bad.yml:${line}:" <<<"$out"; then echo "FAIL: bad.yml:${line} not reported"; fail=1; fi
done
if grep -q 'ok.yml' <<<"$out"; then echo "FAIL: ok.yml reported"; grep ok.yml <<<"$out"; fail=1; fi

rm "$work/.github/workflows/bad.yml"
git -C "$work" add -A
if ! (cd "$work" && bash "$CHECK" >/dev/null 2>&1); then echo "FAIL: allowed forms alone did not pass"; fail=1; fi

(( fail == 0 )) && echo "check_no_self_refs: 6 floating forms reported, 4 allowed forms pass"
exit "$fail"
