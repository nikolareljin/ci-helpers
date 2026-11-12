#!/usr/bin/env bash
# SCRIPT: java_scan_nvd_split_test.sh
# DESCRIPTION: java-scan.yml fetches the NVD data in an `nvd` job that holds
#              nvd_api_key and runs no caller code, and the scan job, which
#              runs the caller's commands, gets the data as an artifact and no
#              key. install_dependency_check.sh refuses a zip whose sha256 is
#              not the pin and keeps the key out of argv; the scan job's
#              verify step refuses a changed, added or missing file, a
#              symlink, and a manifest path that leaves the artifact. The
#              dependency-check CLI and curl are stubbed.
# USAGE: bash tests/java_scan_nvd_split_test.sh
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows/java-scan.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# --- the workflow shape -----------------------------------------------------
python3 - "$wf" <<'PY' || fail=1
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
jobs = d["jobs"]
bad = 0
def text(j): return yaml.safe_dump(j)
if "secrets.nvd_api_key" in text(jobs["scan"]):
    print("FAIL the scan job still reads nvd_api_key"); bad = 1
if "secrets.nvd_api_key" not in text(jobs["nvd"]):
    print("FAIL the nvd job does not hold nvd_api_key"); bad = 1
for s in jobs["nvd"]["steps"]:
    if s.get("uses", "").startswith("actions/checkout") and "repository" not in (s.get("with") or {}):
        print("FAIL the nvd job checks out the caller's repository"); bad = 1
if jobs["nvd"].get("permissions") != {}:
    print("FAIL the nvd job has permissions"); bad = 1
if not bad:
    print("ok   the key is in the nvd job only, which checks out nothing of the caller's")
sys.exit(bad)
PY

# --- install_dependency_check.sh --------------------------------------------
mkdir -p "$work/zip/dependency-check/bin" "$work/bin"
cat > "$work/zip/dependency-check/bin/dependency-check.sh" <<'SH'
#!/usr/bin/env bash
# Stub CLI: records argv and the properties file, writes one data file.
printf '%s\n' "$@" > "$DC_ARGS_LOG"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data) d="$2"; shift 2 ;;
    --propertyfile) cp "$2" "$DC_PROPS_COPY"; stat -c %a "$2" > "$DC_PROPS_MODE"; shift 2 ;;
    *) shift ;;
  esac
done
echo db > "$d/odc.mv.db"
# The real database is hundreds of MiB, over publication-check's 64 MiB per file.
[[ -z "${DC_BIG:-}" ]] || { head -c 140000000 /dev/urandom > "$d/big.mv.db"; sha256sum < "$d/big.mv.db" > "$DC_BIG"; }
SH
(cd "$work/zip" && zip -qr "$work/dc.zip" dependency-check)
sum="$(sha256sum < "$work/dc.zip" | cut -d' ' -f1)"
printf 'DEPENDENCY_CHECK_VERSION=13.0.0\nDEPENDENCY_CHECK_SHA256=%s\n' "$sum" > "$work/pins.good"
printf 'DEPENDENCY_CHECK_VERSION=13.0.0\nDEPENDENCY_CHECK_SHA256=%s\n' "$(printf '0%.0s' {1..64})" > "$work/pins.bad"
printf 'DEPENDENCY_CHECK_VERSION=13.0.0;id\nDEPENDENCY_CHECK_SHA256=%s\n' "$sum" > "$work/pins.inject"
export DC_ARGS_LOG="$work/args" DC_PROPS_COPY="$work/props" DC_PROPS_MODE="$work/mode"

inst() {  # inst <pins> <data> [key]
  env RUNNER_TEMP="$work" NVD_API_KEY="${3-k3y-value}" DC_DOWNLOAD_URL="file://$work/dc.zip" \
    bash "$root/scripts/install_dependency_check.sh" --data "$2" --pins "$1" > "$work/log" 2>&1
}
rc=0; inst "$work/pins.good" "$work/data" || rc=$?
if (( rc == 0 )) && [[ -f "$work/data/odc.mv.db" ]] && grep -qx -- --updateonly "$work/args"; then
  ok "fetches the data with --updateonly into --data"
else bad "fetch (rc=$rc)"; sed 's/^/     /' "$work/log"; fi
if ! grep -q 'k3y-value' "$work/args" && grep -qx 'nvd.api.key=k3y-value' "$work/props" && [[ "$(cat "$work/mode")" == 600 ]]; then
  ok "the key is in a mode 600 properties file, not in argv"
else bad "the key reached argv or the properties file is not 600"; fi
rc=0; inst "$work/pins.bad" "$work/data2" || rc=$?
if (( rc == 1 )) && grep -q 'Checksum mismatch' "$work/log" && [[ ! -e "$work/data2" ]]; then
  ok "refuses a zip whose sha256 is not the pin"
else bad "tampered zip (rc=$rc)"; fi
rc=0; inst "$work/pins.inject" "$work/data3" || rc=$?
if (( rc == 2 )); then ok "refuses a version that is not X.Y.Z"; else bad "version injection (rc=$rc)"; fi
rc=0; inst "$work/pins.good" "$work/data" || rc=$?
if (( rc == 2 )); then ok "refuses a data directory that already exists"; else bad "existing data dir (rc=$rc)"; fi
ln -s "$work" "$work/link"
rc=0; inst "$work/pins.good" "$work/link" || rc=$?
if (( rc == 2 )); then ok "refuses a data directory that is a symlink"; else bad "symlinked data dir (rc=$rc)"; fi
for d in "relative/data" "$work/x/../data5" "$work/a;id"; do
  rc=0; inst "$work/pins.good" "$d" || rc=$?
  if (( rc == 2 )); then ok "refuses --data '$d'"; else bad "--data '$d' (rc=$rc)"; fi
done
rc=0; inst "$work/pins.good" "$work/data4" "" || rc=$?
if (( rc == 2 )); then ok "refuses an empty key"; else bad "empty key (rc=$rc)"; fi

# A file over the per-file publication limit leaves as parts (the nvd step
# runs artifact_parts.sh split after the install) and comes back whole.
rc=0; DC_BIG="$work/big.sum" inst "$work/pins.good" "$work/databig" || rc=$?
bash "$root/scripts/artifact_parts.sh" split "$work/databig"
over="$(find "$work/databig" -type f -size +62914560c | wc -l)"
parts="$(find "$work/databig" -name 'big.mv.db.split-*' | wc -l)"
if (( rc == 0 )) && [[ "$over" == 0 && "$parts" == 3 && ! -e "$work/databig/big.mv.db" ]]; then
  ok "a file over 60 MiB is stored as parts of at most 60 MiB"
else bad "big file not split (rc=$rc, over=$over, parts=$parts)"; sed 's/^/     /' "$work/log"; fi

# --- the scan job's verify step ---------------------------------------------
# The step runs scripts/artifact_parts.sh verify from the library copy with
# the path pattern below; the test runs the same script with that pattern.
python3 - "$wf" > "$work/re" <<'PY'
import re, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
s = [s for s in d["jobs"]["scan"]["steps"] if s.get("name") == "Verify the NVD data against its manifest"]
assert len(s) == 1
m = re.search(r'artifact_parts\.sh" verify "\$RUNNER_TEMP/java-scan-nvd-in" "\$list" \'([^\']+)\'', s[0]["run"])
assert m, "the verify step does not run artifact_parts.sh verify"
print(m.group(1))
PY
re_paths="$(cat "$work/re")"
cat > "$work/verify.sh" <<'SH'
list="$RUNNER_TEMP/m.sha256"
printf '%s\n' "$MANIFEST" > "$list"
bash "$ROOT/scripts/artifact_parts.sh" verify "$DIR" "$list" "$RE_PATHS"
SH
export ROOT="$root" RE_PATHS="$re_paths"
manifest="$(cd "$work/data" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum -- "$f"; done)"

verify() {  # verify <tamper> -> rc
  rm -rf "$work/in" "$work/tmp"; mkdir -p "$work/tmp"
  cp -R "$work/data" "$work/in"
  local m="$manifest"
  case "$1" in
    change) echo x >> "$work/in/odc.mv.db" ;;
    add) echo x > "$work/in/extra" ;;
    remove) rm "$work/in/odc.mv.db" ;;
    link) ln -s /etc/passwd "$work/in/passwd" ;;
    traverse) m="$m"$'\n'"$(sha256sum < /etc/hostname | cut -d' ' -f1)  ./../../etc/hostname" ;;
    absolute) m="$(sha256sum < /etc/hostname | cut -d' ' -f1)  /etc/hostname" ;;
    inject) m="$m"$'\n'"\$(id)" ;;
    empty) m="" ;;
  esac
  env RUNNER_TEMP="$work/tmp" DIR="$work/in" MANIFEST="$m" bash "$work/verify.sh" > "$work/log" 2>&1
}
if verify ""; then ok "verify accepts the artifact as built"; else bad "verify refused the artifact as built"; sed 's/^/     /' "$work/log"; fi
bigman="$(cd "$work/databig" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum -- "$f"; done)"
rm -rf "$work/inbig"; cp -R "$work/databig" "$work/inbig"
if [[ "$parts" -gt 0 ]] && env RUNNER_TEMP="$work/tmp" DIR="$work/inbig" MANIFEST="$bigman" bash "$work/verify.sh" > "$work/log" 2>&1 \
    && [[ "$(sha256sum < "$work/inbig/big.mv.db")" == "$(cat "$work/big.sum")" ]] \
    && [[ -z "$(find "$work/inbig" -name '*.split-*')" ]]; then
  ok "verify joins the parts back into the original file"
else bad "verify did not rebuild the split file"; sed 's/^/     /' "$work/log"; fi
for t in change add remove link traverse absolute inject empty; do
  if verify "$t"; then bad "verify accepted: $t"; else ok "verify refuses: $t"; fi
done

exit "$fail"
