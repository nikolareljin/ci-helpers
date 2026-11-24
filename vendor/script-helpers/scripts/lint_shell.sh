#!/usr/bin/env bash
# SCRIPT: lint_shell.sh
# DESCRIPTION: Run ShellCheck over every tracked shell file and fail on a finding.
# USAGE: bash scripts/lint_shell.sh [--list]
# PARAMETERS:
#   --list      Print the files that would be checked and exit.
#   -h, --help  Show help.
#   SHELLCHECK_SEVERITY  Minimum severity that fails (error|warning|info|style). Default: warning.
# EXIT_CODES:
#   0  No finding at or above the severity.
#   1  ShellCheck reported a finding.
#   2  Bad argument or SHELLCHECK_SEVERITY, not a git work tree, or shellcheck
#      not installed.
# EXAMPLE: SHELLCHECK_SEVERITY=info bash scripts/lint_shell.sh
# ----------------------------------------------------
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "lint_shell: expected at most one argument, got $# (see --help)" >&2; exit 2
fi
case "${1:-}" in
  -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  ""|--list) ;;
  *) echo "lint_shell: unknown argument '$1' (see --help)" >&2; exit 2 ;;
esac

# A failed `git ls-files` inside the process substitution below would look
# like an empty tree and pass, so check for a work tree first.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "lint_shell: not inside a git work tree." >&2
  exit 2
fi
# git ls-files lists only the current directory, so run from the top level.
cd "$(git rev-parse --show-toplevel)"

severity="${SHELLCHECK_SEVERITY:-warning}"
case "$severity" in
  error|warning|info|style) ;;
  *) echo "lint_shell: SHELLCHECK_SEVERITY must be error, warning, info or style (got '$severity')" >&2; exit 2 ;;
esac

# Tracked *.sh files, plus tracked files without the suffix whose first line
# is a sh, bash, dash or ksh shebang (git hooks, bin/ tools, the dev shim template).
files=()
while IFS= read -r -d '' f; do
  [[ -f "$f" ]] || continue
  if [[ "$f" == *.sh ]]; then
    files+=("$f")
    continue
  fi
  first=""
  IFS= read -r first < "$f" || true
  if [[ "$first" =~ ^#!.*(/|[[:space:]])(ba|da|k)?sh([[:space:]]|$) ]]; then
    files+=("$f")
  fi
done < <(git ls-files -z)

# Checked before any "${files[@]}": bash 3.2 treats an empty array as unset.
if [[ ${#files[@]} -eq 0 ]]; then
  [[ "${1:-}" == "--list" ]] || echo "lint_shell: no shell files found."
  exit 0
fi

if [[ "${1:-}" == "--list" ]]; then
  printf '%s\n' "${files[@]}"
  exit 0
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "lint_shell: shellcheck is not installed." >&2
  exit 2
fi

echo "lint_shell: checking ${#files[@]} file(s) at severity '$severity'."
shellcheck -S "$severity" -- "${files[@]}"
