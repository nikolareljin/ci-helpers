#!/usr/bin/env bash
# SCRIPT: ppa_dput_config_test.sh
# DESCRIPTION: Run the "Upload to PPA" step of ppa-deb.yml against stub dput
#              and ssh-keyscan: ftp (default) uploads anonymously with no key;
#              sftp gets the PPA's incoming path and login with the key in
#              place while dput runs; key and config are gone afterwards.
#              sftp pins the host key from launchpad_known_hosts and never
#              calls ssh-keyscan.
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
known_hosts_default="$(python3 - "$root/.github/workflows/ppa-deb.yml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(d[True]["workflow_call"]["inputs"]["launchpad_known_hosts"]["default"])
PY
)"

mkdir -p "$work/bin"
# Trust-on-first-use is the bug this guards: any keyscan call fails the run.
cat > "$work/bin/ssh-keyscan" <<'SH'
#!/usr/bin/env bash
echo "ssh-keyscan must not be called" >&2
exit 99
SH
# Stub dput: records its arguments, the config it sees and whether the key exists.
cat > "$work/bin/dput" <<'SH'
#!/usr/bin/env bash
echo "$*" > "$OUT/args"
cp "$HOME/.dput.cf" "$OUT/dput.cf"
if [ -s "$HOME/.ssh/id_ed25519" ]; then echo yes > "$OUT/key"; else echo no > "$OUT/key"; fi
cp "$HOME/.ssh/known_hosts" "$OUT/known_hosts" 2>/dev/null || true
cp "$HOME/.ssh/config" "$OUT/ssh_config" 2>/dev/null || true
exit 0
SH
chmod +x "$work/bin/"*

fail=0
run() { # name method target login key expected-rc
  local name="$1" rc=0
  shift
  rm -rf "${work:?}/home" "${work:?}/out"; mkdir -p "$work/home" "$work/out"
  HOME="$work/home" OUT="$work/out" PATH="$work/bin:$PATH" \
    UPLOAD_METHOD="$1" PPA_TARGET="$2" LAUNCHPAD_LOGIN="$3" LAUNCHPAD_SSH_PRIVATE_KEY="$4" \
    LAUNCHPAD_KNOWN_HOSTS="${KNOWN_HOSTS-$known_hosts_default}" \
    CHANGES="/x/pkg_1.0_source.changes" \
    bash -e "$work/step.sh" > "$work/log" 2>&1 || rc=$?
  if [ "$rc" != "$5" ]; then
    echo "FAIL $name: exit $rc, expected $5"; cat "$work/log"; fail=1; return 1
  fi
}
expect() { # name file pattern
  if ! grep -qxF -- "$3" "$work/out/$2" 2>/dev/null; then
    echo "FAIL $1: '$3' not in $2"; cat "$work/out/$2" 2>/dev/null; fail=1
  fi
}

if run "ftp default" ftp "ppa:alice/tools" "" "" 0; then
  expect "ftp default" dput.cf "method = ftp"
  expect "ftp default" dput.cf "fqdn = ppa.launchpad.net"
  expect "ftp default" dput.cf "incoming = ~alice/ubuntu/tools/"
  expect "ftp default" dput.cf "login = anonymous"
  expect "ftp default" args "ci-ppa /x/pkg_1.0_source.changes"
  expect "ftp default" key "no"
  [ ! -e "$work/home/.dput.cf" ] || { echo "FAIL ftp: dput.cf left on disk"; fail=1; }
fi
if run "sftp owner ppa" sftp "ppa:alice/tools" "" "stub-key" 0; then
  expect "sftp owner ppa" dput.cf "method = sftp"
  expect "sftp owner ppa" dput.cf "incoming = ~alice/ubuntu/tools/"
  expect "sftp owner ppa" dput.cf "login = alice"
  expect "sftp owner ppa" key "yes"
  expect "sftp owner ppa" known_hosts "$known_hosts_default"
  expect "sftp owner ppa" ssh_config "  StrictHostKeyChecking yes"
  [ ! -e "$work/home/.ssh/id_ed25519" ] || { echo "FAIL key left on disk"; fail=1; }
  [ ! -e "$work/home/.dput.cf" ] || { echo "FAIL dput.cf left on disk"; fail=1; }
fi
if run "sftp team ppa with login" sftp "ppa:team-x/debian/stuff" "bob" "stub-key" 0; then
  expect "sftp team ppa" dput.cf "incoming = ~team-x/debian/stuff/"
  expect "sftp team ppa" dput.cf "login = bob"
fi
run "sftp without key" sftp "ppa:alice/tools" "" "" 1 || true
KNOWN_HOSTS="" run "sftp without known_hosts" sftp "ppa:alice/tools" "" "stub-key" 1 || true
case "$known_hosts_default" in
  "ppa.launchpad.net ssh-rsa "*) ;;
  *) echo "FAIL launchpad_known_hosts default is not a ppa.launchpad.net key"; fail=1 ;;
esac
run "unknown method" scp "ppa:alice/tools" "" "stub-key" 1 || true
run "bad target" ftp "ppa:Alice/x;rm" "" "" 1 || true
run "bad login" sftp "ppa:alice/tools" "a b" "stub-key" 1 || true

[ "$fail" = 0 ] && echo "ok: dput uploads over ftp by default, sftp with the key"
exit "$fail"
