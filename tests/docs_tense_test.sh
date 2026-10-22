#!/usr/bin/env bash
# SCRIPT: docs_tense_test.sh
# DESCRIPTION: scripts/check_docs_tense.py passes on this tree, refuses each
#              history phrase on a published page, and stays quiet on
#              present-tense look-alikes and on fenced code.
# USAGE: bash tests/docs_tense_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
check="$root/scripts/check_docs_tense.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

if ! python3 "$check" --root "$root" > "$work/out" 2>&1; then
  echo "FAIL this tree has findings:"; cat "$work/out"; fail=1
fi

# expect <name> <rc> ; page body on stdin, written to docs/page.md
expect() {
  local name="$1" want="$2" rc=0
  rm -rf "${work:?}/t"; mkdir -p "$work/t/docs"
  cat > "$work/t/docs/page.md"
  python3 "$check" --root "$work/t" > "$work/out" 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1
  fi
}

echo "There was none here before." | expect "there was none" 1
echo "The previous default installed a tool." | expect "previous default" 1
echo "Lint is off. The default used to be on." | expect "used to be" 1
echo "A caller no longer needs this." | expect "no longer" 1
echo "| runner | New in 0.24.0 |" | expect "new in version" 1
echo "Until 0.30.0 only two presets forwarded it." | expect "until version" 1
echo "It now runs a pinned binary." | expect "it now" 1
echo "Accepted as an alias (#97)." | expect "issue reference" 1
echo "Three plugins in this fleet each wrote one." | expect "this fleet" 1
echo "The input was added for Go." | expect "was added" 1
echo "Support for pnpm has been added." | expect "has been added" 1
echo "The preset now supports pnpm." | expect "now supports" 1
echo "Lint now defaults to on." | expect "now defaults" 1
echo "Builds are now cached." | expect "are now" 1
echo "New in this release: pnpm." | expect "new in this release" 1
echo "The default changed from 18 to 20." | expect "changed from" 1
printf '%s\n' '```' 'ok' '```' 'It now runs.' | expect "prose after a fence" 1

echo "Install dependencies before the build." | expect "present-tense before" 0
echo "Runs on pull_request and on every commit." | expect "pull request and commit" 0
echo "A password used to decrypt the match repository." | expect "used to decrypt" 0
echo "Pass the output to a later job with needs." | expect "plain prose" 0
printf '%s\n' '```text' 'There was none here before.' '```' | expect "fenced code" 0
printf '%s\n' '~~~' 'It now runs.' '~~~' | expect "tilde fence" 0
printf '%s\n' '1. Step:' '' '    ```' '    It now runs.' '    ```' | expect "fence in a list item" 0
printf '%s\n' '````md' '```' 'It now runs.' '```' '````' | expect "nested fence" 0
echo 'Run `git log --since now` or `it now runs` here.' | expect "inline code" 0
echo 'Headings look like `## Unreleased`.' | expect "quoted CHANGELOG heading" 0
echo "Run it now." | expect "plain now" 0
echo "Right now this is off." | expect "now this" 0

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "docs tense gate: passes this tree and refuses each history phrase"
