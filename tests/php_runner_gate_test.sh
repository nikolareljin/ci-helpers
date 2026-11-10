#!/usr/bin/env bash
# SCRIPT: php_runner_gate_test.sh
# DESCRIPTION: scripts/check_php_runner.py refuses a PHP job that defaults to
#              ubuntu-latest (the ondrej/php PPA has no suite for 26.04 yet)
#              and accepts the repository's workflows and the allowed forms.
# USAGE: bash tests/php_runner_gate_test.sh
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
gate="$root/scripts/check_php_runner.py"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0

expect() {  # expect <name> <rc> <yaml>
  local name="$1" want="$2" rc=0
  rm -rf "$work/wf"; mkdir -p "$work/wf"; printf '%s\n' "$3" > "$work/wf/w.yml"
  python3 "$gate" "$work/wf" > "$work/out" 2>&1 || rc=$?
  [[ "$rc" == "$want" ]] || { echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; }
}

preset() {  # preset <runner default> <runs-on>
  printf 'on:\n  workflow_call:\n    inputs:\n      runner:\n        type: string\n        default: "%s"\njobs:\n  j:\n    runs-on: %s\n    steps:\n      - run: bash x/scripts/setup_php.sh\n' "$1" "$2"
}
shared="\${{ inputs.php_version != '' && inputs.runner == 'ubuntu-latest' && 'ubuntu-24.04' || inputs.runner }}"

expect "preset defaulting to ubuntu-latest" 1 "$(preset ubuntu-latest '${{ inputs.runner }}')"
expect "preset defaulting to ubuntu-24.04" 0 "$(preset ubuntu-24.04 '${{ inputs.runner }}')"
expect "literal ubuntu-latest" 1 "$(preset x ubuntu-latest)"
expect "literal ubuntu-24.04" 0 "$(preset x ubuntu-24.04)"
expect "shared expression" 0 "$(preset '' "$shared")"
expect "other expression" 1 "$(preset '' "\${{ inputs.runner || 'ubuntu-latest' }}")"
expect "wrapper passes php_version on an ubuntu-latest default" 1 "$(printf 'on:\n  workflow_call:\n    inputs:\n      runner:\n        default: ubuntu-latest\njobs:\n  j:\n    uses: ./x.yml\n    with:\n      runner: ${{ inputs.runner }}\n      php_version: "8.4"\n')"
expect "wrapper passes php_version to ci.yml, which maps the runner" 0 "$(printf 'on:\n  workflow_call:\n    inputs:\n      runner:\n        default: ubuntu-latest\njobs:\n  j:\n    uses: ./.github/workflows/ci.yml\n    with:\n      runner: ${{ inputs.runner }}\n      php_version: "8.4"\n')"
expect "a non-PHP job on ubuntu-latest" 0 "$(printf 'jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make\n')"

python3 "$gate" "$root/.github/workflows" > "$work/out" 2>&1 || { echo "FAIL the repository's workflows:"; cat "$work/out"; fail=1; }

[[ "$fail" == 0 ]] && echo "ok: PHP jobs default to ubuntu-24.04; check_php_runner.py refuses ubuntu-latest"
exit "$fail"
