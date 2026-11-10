#!/usr/bin/env bash
# SCRIPT: setup_pnpm_test.sh
# DESCRIPTION: scripts/setup_pnpm.sh resolves the pnpm version the way the
#              replaced action did (pnpm_version, else devEngines, else
#              packageManager, else refuse; a disagreement is refused), hands
#              a packageManager hash to corepack as written, writes PATH, ENV
#              and OUTPUT, and fails when corepack is absent or refuses. A
#              stub corepack records what it is asked; node is real.
# USAGE: bash tests/setup_pnpm_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/setup_pnpm.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

command -v node >/dev/null 2>&1 || { echo "SKIP: node is required for this test"; exit 0; }

# A corepack that records its calls and installs a pnpm that reports the
# version it was told to prepare. STUB_PREPARE_RC fails `prepare`;
# STUB_PNPM_SAYS makes the installed pnpm report another version.
mkdir -p "$work/stub"
cat > "$work/stub/corepack" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1" in
  --version) echo 0.0.0-stub ;;
  enable)
    dir="$3"
    printf '#!/usr/bin/env bash\ncat "%s/version"\n' "$STUB_STATE" > "$dir/pnpm"
    chmod +x "$dir/pnpm" ;;
  prepare)
    spec="$2"
    if [[ "${STUB_PREPARE_RC:-0}" != 0 ]]; then
      echo "Internal Error: Mismatch hashes. Expected 0000, got ffff" >&2
      exit "$STUB_PREPARE_RC"
    fi
    v="${spec#pnpm@}"; v="${v%%+*}"
    [[ "$v" == latest ]] && v=12.0.0
    printf '%s\n' "${STUB_PNPM_SAYS:-$v}" > "$STUB_STATE/version" ;;
esac
STUB
chmod +x "$work/stub/corepack"

# run <name> <expected rc> <package.json body or -> [PNPM_VERSION]
run() {
  local name="$1" want="$2" manifest="$3" version="${4-}" rc=0
  rm -rf "${work:?}/ws" "${work:?}/state" "${work:?}/gh"; mkdir -p "$work/ws" "$work/state" "$work/gh"
  [[ "$manifest" != "-" ]] && printf '%s\n' "$manifest" > "$work/ws/package.json"
  : > "$work/log"
  PATH="$work/stub:$PATH" STUB_LOG="$work/log" STUB_STATE="$work/state" \
    PNPM_VERSION="$version" GITHUB_WORKSPACE="$work/ws" RUNNER_TEMP="$work" \
    GITHUB_PATH="$work/gh/path" GITHUB_ENV="$work/gh/env" GITHUB_OUTPUT="$work/gh/out" \
    bash "$script" > "$work/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 1
  fi
  return 0
}
# prepared <spec>: the stub's `prepare` line names this spec
prepared() {
  grep -qxF "prepare $1 --activate" "$work/log" || {
    echo "FAIL $name: corepack did not prepare '$1':"; cat "$work/log"; fail=1
  }
}
says() {
  grep -qF -- "$1" "$work/out" || { echo "FAIL $name: no '$1' in output:"; cat "$work/out"; fail=1; }
}

name="pnpm_version alone"
if run "$name" 0 - latest; then
  prepared pnpm@latest
  grep -q "^pnpm_spec=pnpm@latest$" "$work/gh/out" || { echo "FAIL $name: no pnpm_spec output"; fail=1; }
  grep -q "^COREPACK_ENABLE_DOWNLOAD_PROMPT=0$" "$work/gh/env" || { echo "FAIL $name: download prompt not disabled in GITHUB_ENV"; fail=1; }
  grep -q "^COREPACK_ENABLE_STRICT=0$" "$work/gh/env" || { echo "FAIL $name: strict mode not disabled in GITHUB_ENV"; fail=1; }
  bin="$(sed -n 's/^pnpm_bin=//p' "$work/gh/out")"
  [[ -n "$bin" && -x "$bin/pnpm" ]] || { echo "FAIL $name: pnpm_bin '$bin' holds no pnpm"; fail=1; }
  grep -qxF "$bin" "$work/gh/path" || { echo "FAIL $name: pnpm_bin not appended to GITHUB_PATH"; fail=1; }
  grep -qxF "enable --install-directory $bin pnpm" "$work/log" || { echo "FAIL $name: shims not installed into a private directory"; cat "$work/log"; fail=1; }
fi

name="pnpm_version with no package.json at the root"
run "$name" 0 - 9.1.0 && prepared pnpm@9.1.0

name="pnpm_version that disagrees with packageManager"
run "$name" 2 '{"packageManager":"pnpm@10.0.0"}' 9.1.0 && says "Multiple versions of pnpm specified"
grep -q "^prepare" "$work/log" && { echo "FAIL $name: corepack was still asked to prepare"; fail=1; }

name="latest with a packageManager is a disagreement, as before"
run "$name" 2 '{"packageManager":"pnpm@10.0.0"}' latest && says "Multiple versions"

name="pnpm_version equal to packageManager keeps its hash"
run "$name" 0 '{"packageManager":"pnpm@10.0.0+sha512.abc"}' 10.0.0 && prepared pnpm@10.0.0+sha512.abc

name="packageManager alone, hash as written"
run "$name" 0 '{"packageManager":"pnpm@10.0.0+sha512.abc"}' && prepared pnpm@10.0.0+sha512.abc

name="devEngines wins over packageManager"
run "$name" 0 '{"packageManager":"pnpm@10.0.0","devEngines":{"packageManager":{"name":"pnpm","version":"9.15.9"}}}' && prepared pnpm@9.15.9

name="devEngines for another manager is ignored"
run "$name" 0 '{"packageManager":"pnpm@10.0.0","devEngines":{"packageManager":{"name":"yarn","version":"4.0.0"}}}' && prepared pnpm@10.0.0

name="packageManager for another manager does not disagree"
run "$name" 0 '{"packageManager":"yarn@4.0.0"}' latest && prepared pnpm@latest

name="no version anywhere"
run "$name" 2 '{"name":"x"}' && says "No pnpm version is specified"

name="a range is handed to corepack"
run "$name" 0 - '^9' && prepared 'pnpm@^9'

name="corepack refuses the download"
STUB_PREPARE_RC=1 run "$name" 1 '{"packageManager":"pnpm@10.0.0+sha512.0000"}' && says "Mismatch hashes"

name="an exact version that does not come up is refused"
STUB_PNPM_SAYS=9.9.9 run "$name" 1 - 10.0.0 && says "pnpm --version says 9.9.9"

name="a dist-tag is not compared to pnpm --version"
STUB_PNPM_SAYS=12.3.4 run "$name" 0 - latest

name="no corepack on PATH"
rc=0
mkdir -p "$work/nocp"; ln -sf "$(command -v node)" "$work/nocp/node"; ln -sf "$(command -v bash)" "$work/nocp/bash"
PATH="$work/nocp:/usr/bin:/bin" PNPM_VERSION=latest GITHUB_WORKSPACE="$work/ws" bash "$script" > "$work/out" 2>&1 || rc=$?
if [[ "$rc" != 2 ]] || ! grep -q "corepack is not on PATH" "$work/out"; then
  if command -v corepack >/dev/null 2>&1 && [[ "$(command -v corepack)" == /usr/bin/* || "$(command -v corepack)" == /bin/* ]]; then
    echo "SKIP $name: corepack is in /usr/bin here"
  else
    echo "FAIL $name: exit $rc"; cat "$work/out"; fail=1
  fi
fi

[[ "$fail" = 0 ]] && echo "ok: setup_pnpm resolves the version in the action's order, refuses a disagreement, keeps the hash, and fails closed"
exit "$fail"
