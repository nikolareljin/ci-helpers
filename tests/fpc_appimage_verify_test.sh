#!/usr/bin/env bash
# SCRIPT: fpc_appimage_verify_test.sh
# DESCRIPTION: fpc-release.yml's fetch_verified (appimagetool and the AppImage
#              runtime) refuses an empty, malformed or wrong sha256 and
#              removes the download, accepts the right one, and the default
#              URLs are releases with a digest, not the rolling 'continuous'.
# USAGE: bash tests/fpc_appimage_verify_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows/fpc-release.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

python3 - "$wf" > "$work/defaults" <<'PY'
import sys, yaml
inputs = yaml.safe_load(open(sys.argv[1]))[True]["workflow_call"]["inputs"]
for name in ("appimagetool", "appimage_runtime"):
    print(name, inputs[name + "_url"]["default"], inputs[name + "_sha256"]["default"])
PY
while read -r name url sha; do
  case "$url" in
    */continuous/*|"") echo "FAIL $name default URL is rolling or empty: $url"; fail=1 ;;
  esac
  [ "${#sha}" = 64 ] || { echo "FAIL $name default sha256 is not 64 hex: '$sha'"; fail=1; }
done < "$work/defaults"

# The function as the workflow defines it, unindented.
sed -n '/^ *fetch_verified() {/,/^ *}$/p' "$wf" | sed 's/^                //' > "$work/fn.sh"
if ! grep -q 'fetch_verified() {' "$work/fn.sh"; then
  echo "FAIL fetch_verified not found in fpc-release.yml"; exit 1
fi
grep -q -- '--runtime-file /tmp/appimage-runtime' "$wf" \
  || { echo "FAIL appimagetool is not given the verified runtime"; fail=1; }

# Stub downloaders: write a fixed payload to the -O/-o target.
mkdir -p "$work/bin"
cat > "$work/bin/wget" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = "-O" ] && { printf 'payload' > "$2"; exit 0; }; shift; done
exit 1
SH
chmod +x "$work/bin/wget"
good="$(printf 'payload' | sha256sum | awk '{print $1}')"

run() { # name sha expected-rc
  local rc=0
  rm -f "$work/dl"
  PATH="$work/bin:$PATH" bash -euo pipefail -c ". '$work/fn.sh'; fetch_verified tool https://example.invalid/t '$2' '$work/dl'" \
    > "$work/log" 2>&1 || rc=$?
  if [ "$rc" != "$3" ]; then echo "FAIL $1: exit $rc, expected $3"; cat "$work/log"; fail=1; return 0; fi
  if [ "$3" != 0 ] && [ -e "$work/dl" ]; then echo "FAIL $1: unverified file left on disk"; fail=1; fi
}
run "right digest" "$good" 0
run "empty digest" "" 1
run "not hex" "$(printf 'z%.0s' $(seq 64))" 1
run "short digest" "abc" 1
run "wrong digest" "$(printf '0%.0s' $(seq 64))" 1

[ "$fail" = 0 ] && echo "ok: appimagetool and runtime are pinned releases, verified by sha256"
exit "$fail"
