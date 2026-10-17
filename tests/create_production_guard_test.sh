#!/usr/bin/env bash
# Probes for the production guard in scripts/create_production.sh, against a
# throwaway bare remote. Each case says whether the move must be refused.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/create_production.sh"
export SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}/vendor/script-helpers}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

fail=0
pass=0

# Fresh remote: main has 1.0.0 and 1.1.0, production at 1.0.0; a side branch
# carries 9.0.0, which is not on main.
setup() {
  rm -rf "$work/remote.git" "$work/clone"
  git init -q --bare -b main "$work/remote.git"
  git init -q -b main "$work/clone"
  local g=(git -C "$work/clone")
  "${g[@]}" remote add origin "$work/remote.git"
  "${g[@]}" commit -q --allow-empty -m one
  "${g[@]}" tag 1.0.0
  "${g[@]}" commit -q --allow-empty -m two
  "${g[@]}" tag 1.1.0
  "${g[@]}" tag 1.1.0-beta
  "${g[@]}" tag 1.2.0-rc1
  "${g[@]}" commit -q --allow-empty -m three
  "${g[@]}" tag 1.2.0
  "${g[@]}" tag v1.3.0
  "${g[@]}" push -q origin main
  "${g[@]}" switch -q -c side
  "${g[@]}" commit -q --allow-empty -m side
  "${g[@]}" tag 9.0.0
  "${g[@]}" switch -q main
  "${g[@]}" tag production 1.0.0
  "${g[@]}" push -q origin --tags
  "${g[@]}" push -q origin 1.0.0:refs/heads/production
}

# expect <refuse|move|stay> <description> <args...>
# stay: exit 0 and production unchanged (a dry run).
expect() {
  local want="$1" desc="$2"; shift 2
  setup
  local rc=0
  "$SCRIPT" --repo "$work/clone" "$@" >"$work/log" 2>&1 || rc=$?
  local prod
  prod="$(git -C "$work/remote.git" rev-parse refs/tags/production)"
  local start
  start="$(git -C "$work/remote.git" rev-parse '1.0.0^{commit}')"
  if [[ "$want" == stay ]]; then
    if (( rc == 0 )) && [[ "$prod" == "$start" ]]; then
      pass=$((pass + 1)); echo "ok   stay:   $desc"
    else
      fail=$((fail + 1)); echo "FAIL stay:   $desc (rc=$rc)"
      sed 's/^/     /' "$work/log"
    fi
  elif [[ "$want" == refuse ]]; then
    if (( rc != 0 )) && [[ "$prod" == "$start" ]]; then
      pass=$((pass + 1)); echo "ok   refuse: $desc"
    else
      fail=$((fail + 1)); echo "FAIL refuse: $desc (rc=$rc, production moved: $([[ $prod != "$start" ]] && echo yes || echo no))"
      sed 's/^/     /' "$work/log"
    fi
  else
    if (( rc == 0 )) && [[ "$prod" != "$start" ]]; then
      pass=$((pass + 1)); echo "ok   move:   $desc"
    else
      fail=$((fail + 1)); echo "FAIL move:   $desc (rc=$rc)"
      sed 's/^/     /' "$work/log"
    fi
  fi
}

expect refuse "tag not on main"                    -t 9.0.0 --fetch-tags
expect refuse "pre-release suffix -beta"           -t 1.1.0-beta --fetch-tags
expect refuse "release candidate"                  -t 1.2.0-rc1 --fetch-tags
expect move   "newer tag on main"                  -t 1.2.0 --fetch-tags
expect move   "newer v-prefixed tag on main"       -t v1.3.0 --fetch-tags
expect move   "candidate with --allow-prerelease"  -t 1.2.0-rc1 --fetch-tags --allow-prerelease
expect refuse "base branch that is a refspec"       -t 1.2.0 --fetch-tags --base-branch 'main:refs/heads/evil'
expect refuse "dry run of an off-main tag"         -t 9.0.0 --fetch-tags --dry-run
expect stay   "dry run of a good tag pushes nothing" -t 1.2.0 --fetch-tags --dry-run
expect refuse "off main even with both allow flags" -t 9.0.0 --fetch-tags --allow-prerelease --allow-rollback

# Older than production: move production to 1.2.0 first, then try 1.1.0.
older() {
  local want="$1" desc="$2"; shift 2
  setup
  "$SCRIPT" --repo "$work/clone" -t 1.2.0 --fetch-tags >/dev/null 2>&1
  local before rc=0
  before="$(git -C "$work/remote.git" rev-parse refs/tags/production)"
  "$SCRIPT" --repo "$work/clone" -t 1.1.0 --fetch-tags "$@" >"$work/log" 2>&1 || rc=$?
  local after
  after="$(git -C "$work/remote.git" rev-parse refs/tags/production)"
  if [[ "$want" == refuse ]] && (( rc != 0 )) && [[ "$before" == "$after" ]]; then
    pass=$((pass + 1)); echo "ok   refuse: $desc"
  elif [[ "$want" == move ]] && (( rc == 0 )) && [[ "$before" != "$after" ]]; then
    pass=$((pass + 1)); echo "ok   move:   $desc"
  else
    fail=$((fail + 1)); echo "FAIL $want: $desc (rc=$rc)"
    sed 's/^/     /' "$work/log"
  fi
}

older refuse "older than current production"
older move   "rollback with --allow-rollback" --allow-rollback

# Re-running the same release is idempotent, not a refusal.
setup
"$SCRIPT" --repo "$work/clone" -t 1.2.0 --fetch-tags >/dev/null 2>&1
if "$SCRIPT" --repo "$work/clone" -t 1.2.0 --fetch-tags >"$work/log" 2>&1; then
  pass=$((pass + 1)); echo "ok   move:   same tag again is a no-op success"
else
  fail=$((fail + 1)); echo "FAIL move:   same tag again"; sed 's/^/     /' "$work/log"
fi

# chain <description> <tag> [args...] ...: run each move in order on one remote;
# every step must succeed. Steps are separated by "--".
chain() {
  local desc="$1"; shift
  setup
  git -C "$work/clone" tag 1.9.0 1.2.0
  git -C "$work/clone" commit -q --allow-empty -m four
  git -C "$work/clone" tag 1.10.0
  git -C "$work/clone" push -q origin main --tags
  local step=() rc=0
  for a in "$@" --; do
    if [[ "$a" == -- ]]; then
      "$SCRIPT" --repo "$work/clone" --fetch-tags "${step[@]}" >"$work/log" 2>&1 || rc=$?
      (( rc == 0 )) || break
      step=()
    else
      step+=("$a")
    fi
  done
  if (( rc == 0 )); then
    pass=$((pass + 1)); echo "ok   move:   $desc"
  else
    fail=$((fail + 1)); echo "FAIL move:   $desc (rc=$rc)"; sed 's/^/     /' "$work/log"
  fi
}

chain "final after its promoted candidate" -t 1.2.0-rc1 --allow-prerelease -- -t 1.2.0
chain "1.10.0 after 1.9.0 (numeric, not text)" -t 1.9.0 -- -t 1.10.0

# A repository whose default branch is master: no flag needed, and a tag
# that is only on main there is refused.
setup
git -C "$work/clone" push -q origin main:master
git -C "$work/clone" switch -q -c extra
git -C "$work/clone" commit -q --allow-empty -m extra
git -C "$work/clone" tag 2.0.0
git -C "$work/clone" push -q origin extra:main 2.0.0
git -C "$work/remote.git" symbolic-ref HEAD refs/heads/master
rc=0; "$SCRIPT" --repo "$work/clone" -t 1.2.0 --fetch-tags >"$work/log" 2>&1 || rc=$?
if (( rc == 0 )); then pass=$((pass + 1)); echo "ok   move:   default branch master, tag on master"
else fail=$((fail + 1)); echo "FAIL move:   default branch master"; sed 's/^/     /' "$work/log"; fi
rc=0; "$SCRIPT" --repo "$work/clone" -t 2.0.0 --fetch-tags >"$work/log" 2>&1 || rc=$?
if (( rc != 0 )); then pass=$((pass + 1)); echo "ok   refuse: default branch master, tag only on main"
else fail=$((fail + 1)); echo "FAIL refuse: tag only on main moved production of a master repo"; fi

# A shallow clone cannot prove ancestry: refuse, and say why.
setup
rm -rf "$work/shallow"
git clone -q --depth 1 "file://$work/remote.git" "$work/shallow"
rc=0; "$SCRIPT" --repo "$work/shallow" -t 1.2.0 >"$work/log" 2>&1 || rc=$?
if (( rc != 0 )) && grep -q 'shallow clone' "$work/log"; then
  pass=$((pass + 1)); echo "ok   refuse: shallow clone, with the reason"
else
  fail=$((fail + 1)); echo "FAIL refuse: shallow clone (rc=$rc)"; sed 's/^/     /' "$work/log"
fi

echo "passed: $pass, failed: $fail"
(( fail == 0 ))
