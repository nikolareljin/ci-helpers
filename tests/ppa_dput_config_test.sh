#!/usr/bin/env bash
# SCRIPT: ppa_dput_config_test.sh
# DESCRIPTION: Run the "Upload to PPA" step of ppa-deb.yml against stub dput
#              and ssh-keyscan: dput gets an sftp host with the PPA's incoming
#              path and login, the key is in place while dput runs, and both
#              the key and the config are gone afterwards.
# USAGE: bash tests/ppa_dput_config_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$root/.github/workflows/ppa-deb.yml" > "$work/step.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in d["jobs"]["ppa"]["steps"] if s.get("name") == "Upload to PPA"]
assert len(steps) == 1, "no Upload to PPA step"
print(steps[0]["run"])
PY

mkdir -p "$work/bin"
cat > "$work/bin/ssh-keyscan" <<'SH'
#!/usr/bin/env bash
echo "|1|stub ssh-ed25519 AAAA"
SH
# Stub dput: records its arguments, the config it sees and whether the key exists.
cat > "$work/bin/dput" <<'SH'
#!/usr/bin/env bash
echo "$*" > "$OUT/args"
cp "$HOME/.dput.cf" "$OUT/dput.cf"
[ -s "$HOME/.ssh/id_ed25519" ] && echo yes > "$OUT/key"
exit 0
SH
chmod +x "$work/bin/"*

fail=0
run() { # name target login expected-rc
  local name="$1" rc=0
  rm -rf "${work:?}/home" "${work:?}/out"; mkdir -p "$work/home" "$work/out"
  HOME="$work/home" OUT="$work/out" PATH="$work/bin:$PATH" \
    PPA_TARGET="$2" LAUNCHPAD_LOGIN="$3" LAUNCHPAD_SSH_PRIVATE_KEY="stub-key" \
    CHANGES="/x/pkg_1.0_source.changes" \
    bash -e "$work/step.sh" > "$work/log" 2>&1 || rc=$?
  if [ "$rc" != "$4" ]; then
    echo "FAIL $name: exit $rc, expected $4"; cat "$work/log"; fail=1; return 1
  fi
}
expect() { # name file pattern
  if ! grep -qxF -- "$3" "$work/out/$2" 2>/dev/null; then
    echo "FAIL $1: '$3' not in $2"; cat "$work/out/$2" 2>/dev/null; fail=1
  fi
}

if run "owner ppa" "ppa:alice/tools" "" 0; then
  expect "owner ppa" dput.cf "method = sftp"
  expect "owner ppa" dput.cf "fqdn = ppa.launchpad.net"
  expect "owner ppa" dput.cf "incoming = ~alice/ubuntu/tools/"
  expect "owner ppa" dput.cf "login = alice"
  expect "owner ppa" args "ci-ppa /x/pkg_1.0_source.changes"
  expect "owner ppa" key "yes"
  [ ! -e "$work/home/.ssh/id_ed25519" ] || { echo "FAIL key left on disk"; fail=1; }
  [ ! -e "$work/home/.dput.cf" ] || { echo "FAIL dput.cf left on disk"; fail=1; }
fi
if run "team ppa with login" "ppa:team-x/debian/stuff" "bob" 0; then
  expect "team ppa" dput.cf "incoming = ~team-x/debian/stuff/"
  expect "team ppa" dput.cf "login = bob"
fi
run "bad target" "ppa:Alice/x;rm" "" 1 || true
run "bad login" "ppa:alice/tools" "a b" 1 || true

[ "$fail" = 0 ] && echo "ok: dput uploads over sftp with the key"
exit "$fail"
