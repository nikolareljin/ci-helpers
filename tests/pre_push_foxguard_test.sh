#!/usr/bin/env bash
# SCRIPT: pre_push_foxguard_test.sh
# DESCRIPTION: .githooks/pre-push refuses a push that adds a foxguard finding
#              at or above the block level (default high), and one it cannot
#              check: no foxguard, a changed file foxguard skips, a level that
#              is not one. A clean push, an old finding and level off pass.
#              The hook file is the real one and so is the vendored foxguard
#              step. The three steps before it (scan output, private names,
#              credentials) are replaced with passes: they need gitleaks and a
#              names list, and have their own tests upstream.
# USAGE: bash tests/pre_push_foxguard_test.sh
# PARAMETERS:
#   FOXGUARD_CMD      foxguard to use for the finding cases (default: foxguard
#                     on PATH). Without one those cases are skipped.
#   FOXGUARD_REQUIRE  1 makes a missing foxguard a failure, not a skip.
# EXIT CODES:
#   0  Every case passed (finding cases may have been skipped).
#   1  A case failed, or FOXGUARD_REQUIRE=1 and there is no foxguard.
# ----------------------------------------------------
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

fox="${FOXGUARD_CMD:-$(command -v foxguard 2>/dev/null || true)}"

# A PATH without foxguard, for the cases where it must be missing. A directory
# that holds foxguard is replaced by links to everything else in it: it may
# also hold git or python3.
bare_path=""
mirrors=0
IFS=: read -r -a path_dirs <<< "$PATH"
for dir in "${path_dirs[@]}"; do
  [[ -n "$dir" && -d "$dir" ]] || continue
  if [[ -e "$dir/foxguard" || -e "$dir/foxguard.exe" ]]; then
    mirrors=$((mirrors + 1))
    mkdir -p "$work/path$mirrors"
    ln -s "$dir"/* "$work/path$mirrors/" 2>/dev/null
    rm -f "$work/path$mirrors/foxguard" "$work/path$mirrors/foxguard.exe"
    dir="$work/path$mirrors"
  fi
  bare_path="${bare_path:+$bare_path:}$dir"
done

# No global or system git config: a machine-wide hooks path or signing setup
# must not run in the scratch repositories.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git_id=(-c user.name=test -c user.email=test@example.invalid)

# new_repo: a repository with the real hook, the vendored library behind a
# shim that passes the three steps before foxguard, and one commit that the
# remote "origin" already has.
repos=0
new_repo() {
  repos=$((repos + 1))
  repo="$work/repo$repos"
  git init -q -b main "$repo"
  mkdir -p "$repo/.githooks" "$repo/vendor/script-helpers/scripts"
  cp "$root/.githooks/pre-push" "$repo/.githooks/pre-push"
  cat > "$repo/vendor/script-helpers/scripts/security_hooks.sh" <<EOF
source "$root/vendor/script-helpers/scripts/security_hooks.sh" || return 1
sec_scan_output() { return 0; }
sec_private_names() { return 0; }
sec_sensitive_push() { return 0; }
EOF
  printf 'import subprocess\n\n\ndef old(cmd):\n    return subprocess.run(cmd, shell=True)\n' > "$repo/old.py"
  printf 'def add(a, b):\n    return a + b\n' > "$repo/clean.py"
  git -C "$repo" add -A
  git -C "$repo" "${git_id[@]}" commit -q -m base
  git init -q --bare "$repo.git"
  git -C "$repo" remote add origin "$repo.git"
  git -C "$repo" push -q origin main
  git -C "$repo" fetch -q origin
}

# commit_change: commit what the case wrote into $repo.
commit_change() {
  git -C "$repo" add -A
  git -C "$repo" "${git_id[@]}" commit -q -m change
}

# push_rc <path> [<foxguard>]: run the hook as git would for a push of main to
# origin; print its exit code. The hook writes the reasons to a private report
# under HOME (here $work/home); neither that nor its output is ever printed.
push_rc() {
  local rc=0
  rm -rf "${work:?}/home"
  mkdir -p "$work/home"
  (
    cd "$repo" || exit 99
    export HOME="$work/home" XDG_CACHE_HOME="$work/home/.cache" PATH="$1"
    export SCRIPT_HELPERS_NO_AUTO_INSTALL=1
    # A developer's push, also when this test runs in CI: there the hook
    # deletes its report, and the reasons could not be checked.
    unset FOXGUARD_CMD SCRIPT_HELPERS_FOXGUARD_BLOCK CI GITHUB_ACTIONS
    [[ -n "${2:-}" ]] && export FOXGUARD_CMD="$2"
    printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$(git rev-parse origin/main)" \
      | bash .githooks/pre-push origin "$work/unused.git"
  ) > "$repo.log" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# check <name> <want: pass|refuse> <rc> [<text the private report must hold>]
check() {
  local ok=1
  if [[ "$2" == pass ]]; then [[ "$3" -eq 0 ]] || ok=0; else [[ "$3" -eq 1 ]] || ok=0; fi
  if [[ "$2" == refuse ]] && ! grep -q -F -- "Foxguard check failed." "$repo.log"; then ok=0; fi
  if [[ -n "${4:-}" ]] && ! grep -r -q -F -- "$4" "$work/home"; then ok=0; fi
  if [[ "$ok" -eq 1 ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1: wanted $2, got exit $3${4:+" or no \"$4\" in the report"}" >&2
    failures=$((failures + 1))
  fi
}

# No foxguard at all.
new_repo
printf 'def sub(a, b):\n    return a - b\n' >> "$repo/clean.py"
commit_change
check "no foxguard refuses the push" refuse "$(push_rc "$bare_path")" "foxguard is not installed"
git -C "$repo" config security.foxguardBlock off
check "no foxguard passes at level off" pass "$(push_rc "$bare_path")"
git -C "$repo" config security.foxguardBlock none
check "a level that is not one refuses the push" refuse "$(push_rc "$bare_path")" "invalid block level"

if [[ -z "$fox" ]]; then
  if [[ "${FOXGUARD_REQUIRE:-0}" == 1 ]]; then
    echo "FAIL foxguard is not installed and FOXGUARD_REQUIRE=1" >&2
    exit 1
  fi
  echo "SKIP finding cases: foxguard is not installed"
  exit $((failures > 0))
fi

new_repo
printf 'def sub(a, b):\n    return a - b\n' >> "$repo/clean.py"
commit_change
check "a clean change passes" pass "$(push_rc "$bare_path" "$fox")"

new_repo
printf 'import subprocess\n\n\ndef new(cmd):\n    return subprocess.run(cmd, shell=True)\n' > "$repo/new.py"
commit_change
check "a new high finding refuses the push" refuse "$(push_rc "$bare_path" "$fox")" "BLOCK (foxguard)"
git -C "$repo" config security.foxguardBlock off
check "the same push passes at level off" pass "$(push_rc "$bare_path" "$fox")"

new_repo
printf '\n\ndef later(a):\n    return a\n' >> "$repo/old.py"
commit_change
check "a finding the remote already has passes" pass "$(push_rc "$bare_path" "$fox")" "WARNING (foxguard)"

new_repo
printf 'def broken(:\n' > "$repo/broken.py"
commit_change
check "a changed file foxguard cannot parse refuses the push" refuse "$(push_rc "$bare_path" "$fox")" "foxguard skipped 1 changed file(s)"

exit $((failures > 0))
