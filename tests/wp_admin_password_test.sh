#!/usr/bin/env bash
# The three steps that install a throwaway WordPress site, run with stub
# tools: an empty admin password (the default) reaches wp as a random
# 32-hex value, a different one each run; a password passed in is used as is.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 -I - "$ROOT_DIR" "$work" <<'PY'
import os, re, subprocess, sys, yaml
root, work = sys.argv[1], sys.argv[2]
bin_dir = os.path.join(work, "bin")
os.makedirs(bin_dir)
def stub(name, body):
    p = os.path.join(bin_dir, name)
    open(p, "w").write("#!/bin/sh\n" + body + "\n")
    os.chmod(p, 0o755)
# Each stub records the password the way the real tool receives it.
stub("docker", 'echo "pw=$WPC_ADMIN_PASSWORD" >> "$CALLS"')
stub("wpc-script", 'while [ $# -gt 0 ]; do [ "$1" = --admin-password ] && echo "pw=$2" >> "$CALLS"; shift; done')
stub("php", 'for a; do case "$a" in --admin_password=*) echo "pw=${a#--admin_password=}" >> "$CALLS";; esac; done')
stub("curl", 'touch wp-cli.phar')
stub("nc", 'exit 0')
stub("sleep", 'exit 0')

def step(path, pick):
    doc = yaml.safe_load(open(os.path.join(root, path)))
    steps = doc["runs"]["steps"] if "runs" in doc else [s for j in doc["jobs"].values() for s in j.get("steps", [])]
    found = [s for s in steps if pick(s)]
    assert len(found) == 1, (path, len(found))
    return found[0]

cases = [
    (".github/actions/wp-plugin-check/action.yml", "WPC_ADMIN_PASSWORD",
     lambda s: s.get("name") == "Install WordPress", {}),
    (".github/workflows/wp-plugin-check.yml", "WPC_ADMIN_PASSWORD",
     lambda s: "WPC_ADMIN_PASSWORD" in (s.get("env") or {}),
     {"WPC_SCRIPT": os.path.join(bin_dir, "wpc-script")}),
    (".github/workflows/php-scan.yml", "INPUT_WP_ADMIN_PASSWORD",
     lambda s: "INPUT_WP_ADMIN_PASSWORD" in (s.get("env") or {}), {}),
]
fail = 0
for path, var, pick, extra in cases:
    s = step(path, pick)
    # The pinned wp-cli digest, so the checksum stub matches whatever is pinned.
    m = re.search(r'expected="([0-9a-f]{64})"', s["run"])
    stub("sha256sum", 'echo "%s  wp-cli.phar"' % (m.group(1) if m else "0" * 64))
    seen = []
    for given in ["", "", "given-pw"]:
        calls = os.path.join(work, "calls")
        open(calls, "w").close()
        run_dir = os.path.join(work, "run")
        subprocess.run(["rm", "-rf", run_dir]); os.makedirs(run_dir)
        env = {k: "x" for k in (s.get("env") or {})}
        env.update(extra, PATH=bin_dir + os.pathsep + os.environ["PATH"], CALLS=calls,
                   HOME=work, WPC_MULTISITE="false")
        env[var] = given
        r = subprocess.run(["bash", "-c", s["run"]], cwd=run_dir, env=env,
                           capture_output=True, text=True)
        pws = {l[3:] for l in open(calls).read().splitlines() if l.startswith("pw=")}
        if r.returncode != 0 or len(pws) != 1:
            print(f"FAIL: {path} given={given!r}: rc={r.returncode} passwords={pws} {r.stderr[-300:]}")
            fail = 1
            continue
        pw = pws.pop()
        if given:
            if pw != given:
                print(f"FAIL: {path}: passed {given!r}, wp got {pw!r}"); fail = 1
        elif not re.fullmatch(r"[0-9a-f]{32}", pw):
            print(f"FAIL: {path}: empty password reached wp as {pw!r}"); fail = 1
        else:
            seen.append(pw)
    if len(seen) == 2 and seen[0] == seen[1]:
        print(f"FAIL: {path}: two runs got the same password"); fail = 1
sys.exit(fail)
PY
echo "wp_admin_password: empty gets a random password per run, a given one is kept"
