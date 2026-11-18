#!/usr/bin/env bash
# SCRIPT: action_pin_consistency_test.sh
# DESCRIPTION: scripts/check_action_pin_consistency.py passes on this tree,
#              refuses one action repository at two commits (sub-actions and
#              case differences included) and ignores comments and tags.
# USAGE: bash tests/action_pin_consistency_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
check="$root/scripts/check_action_pin_consistency.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
A=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222

if ! python3 "$check" --root "$root" > "$work/out" 2>&1; then
  echo "FAIL this tree has findings:"; cat "$work/out"; fail=1
fi

# expect <name> <rc> <pattern-or-empty> ; action.yml body on stdin
expect() {
  local name="$1" want="$2" pattern="$3" rc=0
  rm -rf "${work:?}/t"; mkdir -p "$work/t/.github/workflows" "$work/t/.github/actions/x"
  printf 'jobs:\n  a:\n    steps:\n      - uses: github/codeql-action/init@%s # v1\n' "$A" \
    > "$work/t/.github/workflows/w.yml"
  cat > "$work/t/.github/actions/x/action.yml"
  python3 "$check" --root "$work/t" > "$work/out" 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 0
  fi
  if [ -n "$pattern" ] && ! grep -qF -- "$pattern" "$work/out"; then
    echo "FAIL $name: no '$pattern' in output"; cat "$work/out"; fail=1
  fi
}

expect "sub-action at another commit" 1 "github/codeql-action is pinned at 2 commits" <<YAML
runs:
  steps:
    - uses: github/codeql-action/upload-sarif@$B # v2
YAML
expect "case differs" 1 "2222222222222222222222222222222222222222: .github/actions/x/action.yml:3" <<YAML
runs:
  steps:
    - uses: "Github/CodeQL-Action/upload-sarif@$B"
YAML
expect "same commit, other sub-action" 0 "" <<YAML
runs:
  steps:
    - uses: github/codeql-action/upload-sarif@$A # v1.0.0
YAML
expect "commented-out old pin" 0 "" <<YAML
runs:
  steps:
    # - uses: github/codeql-action/upload-sarif@$B
    - uses: github/codeql-action/analyze@$A
YAML
expect "tag refs not compared" 0 "" <<YAML
runs:
  steps:
    - uses: github/codeql-action/analyze@v4
YAML
expect "other repository" 0 "" <<YAML
runs:
  steps:
    - uses: actions/checkout@$B
YAML

rc=0; python3 "$check" --root "$work/none" > "$work/out" 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL missing .github: exit $rc, expected 2"; fail=1; }

[ "$fail" = 0 ] && echo "PASS action_pin_consistency_test"
exit "$fail"
