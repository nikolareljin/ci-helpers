#!/usr/bin/env bash
# SCRIPT: tauri_upload_once_test.sh
# DESCRIPTION: Run the "Upload installers" step of tauri-release.yml against a
#              stub gh: a new installer is uploaded, one already published with
#              the same sha256 passes, a different sha256 fails and is never
#              replaced, and each repository gets its own token.
# USAGE: bash tests/tauri_upload_once_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$root/.github/workflows/tauri-release.yml" > "$work/step.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in d["jobs"]["release"]["steps"] if s.get("id") == "upload"]
assert len(steps) == 1, "no Upload installers step"
print(steps[0]["run"])
PY

mkdir -p "$work/bin"
# Stub gh. Assets per repo live in $STATE/<repo>/; "nodigest" marks a repo
# whose assets report no digest. Every call is logged with its token.
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$GH_TOKEN $*" >> "$STATE/calls"
case "$1 $2" in
  "api repos/"*)
    repo="${2#repos/}"; repo="${repo%/releases/tags/*}"
    d="$STATE/$repo"
    [ -d "$d" ] || { echo "Not Found" >&2; exit 1; }
    printf '{"assets":['
    sep=""
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      n="$(basename "$f")"
      [ "$n" = nodigest ] && continue
      if [ -f "$d/nodigest" ]; then dg=null; else dg="\"sha256:$(sha256sum "$f" | cut -d' ' -f1)\""; fi
      printf '%s{"name":"%s","digest":%s}' "$sep" "$n" "$dg"; sep=,
    done
    printf ']}\n' ;;
  "release upload")
    repo="$6"; cp "$4" "$STATE/$repo/" ;;
  "release download")
    repo="$5"; mkdir -p "$9"; cp "$STATE/$repo/$7" "$9/" ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
SH
chmod +x "$work/bin/gh"

fail=0
check() { # name expected-rc
  local name="$1" want="$2" rc=0
  ( cd "$work/run" && PATH="$work/bin:$PATH" bash -e "$work/step.sh" ) > "$work/out" 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1
  else
    echo "ok   $name"
  fi
}

reset() {
  rm -rf "$work/run" "$work/state"
  mkdir -p "$work/run/tauri-linux-artifacts" "$work/state/own/app" "$work/state/dist/app"
  echo build-1 > "$work/run/tauri-linux-artifacts/app.deb"
  : > "$work/state/calls"
}

export STATE="$work/state" OWN_TOKEN=own-token DIST_TOKEN=dist-token \
  VERSION=1.0.0 GITHUB_REPOSITORY=own/app DIST_REPO=""

reset
check "new installer is uploaded" 0
cmp -s "$work/state/own/app/app.deb" "$work/run/tauri-linux-artifacts/app.deb" || { echo "FAIL not uploaded"; fail=1; }

cp "$work/run/tauri-linux-artifacts/app.deb" "$work/state/own/app/"
: > "$work/state/calls"
check "same sha256 passes" 0
grep -q 'release upload' "$work/state/calls" && { echo "FAIL same sha256 was uploaded again"; fail=1; }

echo build-2 > "$work/run/tauri-linux-artifacts/app.deb"
: > "$work/state/calls"
check "different sha256 fails" 1
grep -q 'release upload' "$work/state/calls" && { echo "FAIL replaced a published installer"; fail=1; }
grep -q 'build-1' "$work/state/own/app/app.deb" || { echo "FAIL published bytes changed"; fail=1; }

touch "$work/state/own/app/nodigest"
check "different sha256 fails without a digest" 1

reset
cp "$work/run/tauri-linux-artifacts/app.deb" "$work/state/own/app/"
touch "$work/state/own/app/nodigest"
check "same sha256 passes without a digest" 0

reset
rm -rf "$work/state/own/app"
check "missing release fails" 1

reset
export DIST_REPO=dist/app
check "dist repo gets its own token" 0
grep -q '^own-token .*own/app' "$work/state/calls" || { echo "FAIL own repo token"; fail=1; }
grep -q '^dist-token .*dist/app' "$work/state/calls" || { echo "FAIL dist repo token"; fail=1; }
grep -q '^own-token .*dist/app' "$work/state/calls" && { echo "FAIL own token sent to dist repo"; fail=1; }
[ -f "$work/state/dist/app/app.deb" ] || { echo "FAIL not uploaded to dist repo"; fail=1; }

exit "$fail"
