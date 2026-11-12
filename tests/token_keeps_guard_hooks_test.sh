#!/usr/bin/env bash
# SCRIPT: token_keeps_guard_hooks_test.sh
# DESCRIPTION: The publication guard sets core.hooksPath through
#              GIT_CONFIG_COUNT/KEY_0/VALUE_0. A step that hands git the token
#              as an extraheader must add its entry after the guard's, not
#              replace it, or every push in that step skips the outbound hooks.
#              Steps that start a clean environment (env -i) must carry the
#              guard's entry and GITLEAKS_BIN across, and refuse to run
#              without it.
# USAGE: bash tests/token_keeps_guard_hooks_test.sh
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
git init -q "$work/repo"

sites=0
while IFS=: read -r file line; do
  sites=$((sites + 1))
  text="$(sed -n "$((line - 1)),${line}p" "$file" | sed "s/^ *//")"
  got="$(cd "$work/repo" || exit 1; env -i PATH=/usr/bin:/bin HOME="$work" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/guard/hooks \
    GITHUB_SERVER_URL=https://github.com auth=dG9rZW4= \
    bash -euo pipefail -c "$text"$'\n''git config --get core.hooksPath; git config --get http.https://github.com/.extraheader' 2>&1 || true)"
  if [[ "$got" == $'/guard/hooks\nAUTHORIZATION: basic dG9rZW4=' ]]; then
    echo "ok   ${file#"$root"/}:$line keeps the guard's hooksPath"
  else
    echo "FAIL ${file#"$root"/}:$line drops the guard's hooksPath: $got"; fail=1
  fi
done < <(grep -n -E 'GIT_CONFIG_(KEY|VALUE)_[^=]*=.*extraheader' "$root"/.github/workflows/*.yml | cut -d: -f1,2)
[[ "$sites" -gt 0 ]] || { echo "FAIL no extraheader sites found"; fail=1; }

# Clean-environment steps that push: the guard's entry crosses env -i.
for wf in auto-tag.yml update-production.yml; do
  f="$root/.github/workflows/$wf"
  n_envi="$(grep -c 'exec /usr/bin/env -i .*PUSH_TOKEN=' "$f" || true)"
  # shellcheck disable=SC2016 # literal $NAME text in the workflow
  n_pass="$(grep -c 'exec /usr/bin/env -i .*PUSH_TOKEN=.*GUARD_COUNT="\$GUARD_COUNT" GUARD_KEY="\$GUARD_KEY" GUARD_HOOKS="\$GUARD_HOOKS" GITLEAKS_BIN="\$GITLEAKS_BIN"' "$f" || true)"
  n_req="$(grep -c 'the outbound guard is not configured; nothing is pushed' "$f" || true)"
  if [[ "$n_envi" -gt 0 && "$n_pass" == "$n_envi" && "$n_req" == "$n_envi" ]]; then
    echo "ok   $wf: $n_envi clean-environment push steps carry and require the guard"
  else
    echo "FAIL $wf: env -i push steps $n_envi, carrying the guard $n_pass, requiring it $n_req"; fail=1
  fi
done
exit "$fail"
