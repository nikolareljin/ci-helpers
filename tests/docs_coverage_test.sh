#!/usr/bin/env bash
# SCRIPT: docs_coverage_test.sh
# DESCRIPTION: scripts/check_docs_coverage.py passes on this tree and refuses a
#              copy with each kind of documentation gap: a workflow with no
#              section, an undocumented input, a wrong default or type, a
#              stale action section, a drifted README count, and a broken
#              example.
# USAGE: bash tests/docs_coverage_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
check="$root/scripts/check_docs_coverage.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

if ! python3 "$check" --root "$root" > "$work/out" 2>&1; then
  echo "FAIL this tree has findings:"; cat "$work/out"; fail=1
fi

# A copy of the parts the gate reads.
fresh() {
  rm -rf "${work:?}/t"; mkdir -p "$work/t/docs/assets" "$work/t/.github"
  cp -R "$root/.github/workflows" "$root/.github/actions" "$work/t/.github/"
  cp "$root/README.md" "$work/t/"
  cp "$root"/docs/*.md "$work/t/docs/"
  cp "$root/docs/assets/hero.svg" "$work/t/docs/assets/"
}

# expect <name> <pattern> ; the tree in $work/t has been broken by the caller
expect() {
  local name="$1" pattern="$2" rc=0
  python3 "$check" --root "$work/t" > "$work/out" 2>&1 || rc=$?
  if [ "$rc" != 1 ]; then
    echo "FAIL $name: exit $rc, expected 1"; cat "$work/out"; fail=1; return 0
  fi
  if ! grep -qF -- "$pattern" "$work/out"; then
    echo "FAIL $name: no '$pattern' in output"; cat "$work/out"; fail=1
  fi
}

# Python, not sed: the edits must behave the same on GNU and BSD.
edit() { python3 - "$work/t/$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path, encoding="utf-8").read()
if old not in text:
    sys.exit(f"fixture edit: {old!r} not in {path}")
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
}

fresh; edit docs/workflows.md "## wp-build.yml

Workflow: \`.github/workflows/wp-build.yml\`" "## wp-build-gone"
edit docs/presets.md "\`.github/workflows/wp-build.yml\`" "wp-build"
expect "workflow with no section" "wp-build.yml: no section"

fresh; edit docs/workflows.md "- \`verify_command\` (string" "- \`verify_cmd\` (string"
expect "undocumented input" "wp-build.yml: input \`verify_command\` is not documented"

fresh; edit docs/workflows.md "- \`retention_days\` (number, default \`7\`)" "- \`retention_days\` (number, default \`30\`)"
expect "wrong default" "\`retention_days\` documented default \`30\`, declared \`7\`"

fresh; edit docs/presets.md "- \`migrate_command\`: \`php artisan config:clear" "- \`migrate_command\`: \`php artisan migrate"
expect "wrong preset default" "laravel.yml: \`migrate_command\` listed with default"

fresh; edit docs/workflows.md "- \`zip\` (boolean, default \`true\`)" "- \`zip\` (string, default \`true\`)"
expect "wrong type" "\`zip\` documented as string, declared boolean"

fresh; edit docs/workflows.md "- \`zip\` (boolean, default \`true\`)" "- \`zip\` (boolean, default \`true\`)
- \`no_such_input\` (string, default \`\"\"\`)"
expect "input that does not exist" "documents input \`no_such_input\`, which it does not have"

fresh; rm -rf "$work/t/.github/actions/data-safety-scan"
expect "section for a removed action" "documents \`data-safety-scan\`, which is not an action here"

fresh; edit docs/actions.md "\`skip_dirs\`" "\`skip-dirs\`"
expect "undocumented action input" "action trivy-scan: input \`skip_dirs\` is not documented"

fresh; edit README.md "76 reusable workflows" "75 reusable workflows"
expect "README count drift" "README.md says 75 reusable workflows"

fresh; edit docs/assets/hero.svg "28 stack presets" "22 stack presets"
expect "hero count drift" "docs/assets/hero.svg says"

fresh; edit README.md "\`.github/workflows/wp-build.yml\`" "the build workflow"
edit README.md "\`wp-build.yml\` (the release zip)" "a build workflow"
expect "README missing a workflow" "README.md does not name wp-build.yml"

fresh; edit docs/presets.md "      slug: my-plugin" "      plugin_slug: my-plugin"
expect "example with an unknown input" "example passes \`plugin_slug\` to wp-build"

fresh; edit docs/workflows.md "    uses: nikolareljin/ci-helpers/.github/workflows/wp-build.yml@production" "    uses: nikolareljin/ci-helpers/.github/workflows/wp-built.yml@production"
expect "example calling a missing workflow" "example calls workflows/wp-built, which does not exist"

fresh; edit docs/actions.md "  run: echo \"result=\$RESULT\"" "  run: echo \"Result: \$RESULT\""
expect "example that is not YAML" "docs/actions.md: example calling this repository is not valid YAML"

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "docs coverage gate: passes this tree and refuses each kind of gap"
