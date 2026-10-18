#!/usr/bin/env bash
# SCRIPT: deb_build_sign_test.sh
# DESCRIPTION: Run the "Sign packages" step of deb-build.yml with a throwaway
#              GPG key: every file gets a verifying .asc, SHA256SUMS checks
#              and its .asc verifies, no keyring is left behind. With no key
#              the step passes and signs nothing; a wrong passphrase fails.
# USAGE: bash tests/deb_build_sign_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'gpgconf --homedir "$work/gnupg" --kill all >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

python3 - "$root/.github/workflows/deb-build.yml" > "$work/step.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in d["jobs"]["sign"]["steps"] if s.get("name") == "Sign packages"]
assert len(steps) == 1, "no Sign packages step"
print(steps[0]["run"])
PY

# Throwaway key, made in its own keyring; only the exported block is used.
export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase "pw" \
  --quick-gen-key "CI Test <ci@example.invalid>" ed25519 sign never 2>/dev/null
fpr="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr/{print $10; exit}')"
key="$(gpg --batch --pinentry-mode loopback --passphrase "pw" --armor --export-secret-keys "$fpr")"

fail=0
run() { # name passphrase key-block key-id expected-rc
  local rc=0
  rm -rf "$work/job"; mkdir -p "$work/job/release-files" "$work/job/tmp"
  printf 'deb-a' > "$work/job/release-files/a_1.0_amd64.deb"
  printf 'deb-b' > "$work/job/release-files/b_1.0_all.deb"
  (cd "$work/job" && env -u GNUPGHOME RUNNER_TEMP="$work/job/tmp" GITHUB_OUTPUT="$work/job/out" \
    GPG_PRIVATE_KEY="$3" GPG_PASSPHRASE="$2" KEY_ID="$4" \
    bash -e "$work/step.sh") > "$work/log" 2>&1 || rc=$?
  if [ "$rc" != "$5" ]; then
    echo "FAIL $1: exit $rc, expected $5"; cat "$work/log"; fail=1; return 1
  fi
}

if run "signs" "pw" "$key" "$fpr" 0; then
  sigs="$work/job/tmp/signatures"
  for f in a_1.0_amd64.deb b_1.0_all.deb; do
    gpg --batch --verify "$sigs/$f.asc" "$work/job/release-files/$f" 2>/dev/null \
      || { echo "FAIL $f.asc does not verify"; fail=1; }
  done
  (cd "$work/job/release-files" && sha256sum -c --quiet "$sigs/SHA256SUMS") \
    || { echo "FAIL SHA256SUMS does not check"; fail=1; }
  gpg --batch --verify "$sigs/SHA256SUMS.asc" "$sigs/SHA256SUMS" 2>/dev/null \
    || { echo "FAIL SHA256SUMS.asc does not verify"; fail=1; }
  grep -qx "signed=true" "$work/job/out" || { echo "FAIL no signed=true output"; fail=1; }
  printf 'tampered' > "$work/job/release-files/a_1.0_amd64.deb"
  if gpg --batch --verify "$sigs/a_1.0_amd64.deb.asc" "$work/job/release-files/a_1.0_amd64.deb" 2>/dev/null; then
    echo "FAIL a tampered file verifies"; fail=1
  fi
fi
if run "no key" "" "" "" 0; then
  [ ! -e "$work/job/tmp/signatures" ] || { echo "FAIL no key: signatures written"; fail=1; }
  grep -q "published unsigned" "$work/log" || { echo "FAIL no key: no notice"; fail=1; }
  ! grep -q "signed=true" "$work/job/out" 2>/dev/null || { echo "FAIL no key: signed=true"; fail=1; }
fi
run "wrong passphrase" "nope" "$key" "$fpr" 2 || true
# A file named like an option is refused before anything is signed.
rm -rf "$work/job"; mkdir -p "$work/job/release-files" "$work/job/tmp"
printf 'x' > "$work/job/release-files/--output=pwned"
rc=0
(cd "$work/job" && env -u GNUPGHOME RUNNER_TEMP="$work/job/tmp" GITHUB_OUTPUT="$work/job/out" \
  GPG_PRIVATE_KEY="$key" GPG_PASSPHRASE="pw" KEY_ID="$fpr" bash -e "$work/step.sh") > "$work/log" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q "refusing to sign" "$work/log"; then
  echo "FAIL option-like name: exit $rc"; cat "$work/log"; fail=1
fi
# The keyring and passphrase file live under RUNNER_TEMP and are gone after.
[ -z "$(find "$work/job/tmp" -mindepth 1 -maxdepth 1 ! -name signatures)" ] || { echo "FAIL keyring or passphrase file left in RUNNER_TEMP"; ls -la "$work/job/tmp"; fail=1; }

[ "$fail" = 0 ] && echo "ok: deb-build signs each file and SHA256SUMS"
exit "$fail"
