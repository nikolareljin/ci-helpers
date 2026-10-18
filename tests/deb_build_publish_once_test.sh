#!/usr/bin/env bash
# SCRIPT: deb_build_publish_once_test.sh
# DESCRIPTION: Run the "Keep what is already published" step of deb-build.yml
#              against a stub gh: files already on the release with the same
#              sha256 are dropped from the upload, a different sha256 fails,
#              a published signature is kept only next to its kept file.
# USAGE: bash tests/deb_build_publish_once_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$root/.github/workflows/deb-build.yml" > "$work/step.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in d["jobs"]["release"]["steps"] if s.get("name") == "Keep what is already published"]
assert len(steps) == 1, "no Keep what is already published step"
print(steps[0]["run"])
PY

# Stub gh. $PUB holds the published assets; $DIGESTS=0 hides their digests,
# so the step has to download them.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  [ -d "$PUB" ] || exit 1
  printf '{"assets":['
  sep=""
  for f in "$PUB"/*; do
    [ -f "$f" ] || continue
    d="null"
    [ "${DIGESTS:-1}" = 1 ] && d="\"sha256:$(sha256sum "$f" | cut -d' ' -f1)\""
    printf '%s{"name":"%s","digest":%s}' "$sep" "$(basename "$f")" "$d"
    sep=","
  done
  printf ']}'
  exit 0
fi
if [ "$1" = "release" ] && [ "$2" = "download" ]; then
  # release download VERSION -R repo -p NAME -D DIR
  cp "$PUB/$7" "$9/"
  exit 0
fi
exit 9
STUB
chmod +x "$work/bin/gh"

fail=0
setup() { # local files: name=content ...
  rm -rf "$work/job"; mkdir -p "$work/job/release-files"
  for kv in "$@"; do printf '%s' "${kv#*=}" > "$work/job/release-files/${kv%%=*}"; done
}
publish() { # published files: name=content ...
  rm -rf "$work/pub"; mkdir -p "$work/pub"
  for kv in "$@"; do printf '%s' "${kv#*=}" > "$work/pub/${kv%%=*}"; done
}
run() { # name expected-rc
  local rc=0
  (cd "$work/job" && PATH="$work/bin:$PATH" PUB="$work/pub" GITHUB_REPOSITORY=o/r VERSION=1.0.0 \
    bash -e "$work/step.sh") > "$work/log" 2>&1 || rc=$?
  if [ "$rc" != "$2" ]; then echo "FAIL $1: exit $rc, expected $2"; cat "$work/log"; fail=1; return 1; fi
}
left() { find "$work/job/release-files" -type f -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '; }
expect_left() { # name expected
  [ "$(left)" = "$2" ] || { echo "FAIL $1: left '$(left)', expected '$2'"; fail=1; }
}

setup a.deb=A a.deb.asc=sigA SHA256SUMS=S SHA256SUMS.asc=sigS
rm -rf "$work/pub"
run "no release yet" 0 && expect_left "no release yet" "SHA256SUMS SHA256SUMS.asc a.deb a.deb.asc "

setup a.deb=A a.deb.asc=sigA2 SHA256SUMS=S SHA256SUMS.asc=sigS2
publish a.deb=A a.deb.asc=sigA SHA256SUMS=S SHA256SUMS.asc=sigS
run "rerun, same bytes" 0 && expect_left "rerun, same bytes" ""

DIGESTS=0 run "rerun, no digest" 0 && expect_left "rerun, no digest" ""
export DIGESTS=1

setup a.deb=A2 a.deb.asc=sigA2
publish a.deb=A a.deb.asc=sigA
run "different bytes" 1 || true
grep -q "refusing to replace a published package" "$work/log" || { echo "FAIL different bytes: no error"; fail=1; }

setup a.deb=A2 a.deb.asc=sigA2
publish a.deb.asc=sigA
run "stale signature" 1 || true
grep -q "old signature would not verify" "$work/log" || { echo "FAIL stale signature: no error"; fail=1; }

setup b.deb=B b.deb.asc=sigB
publish a.deb=A a.deb.asc=sigA
run "new file next to old ones" 0 && expect_left "new file" "b.deb b.deb.asc "

[ "$fail" = 0 ] && echo "ok: deb-build never replaces a published package or signature"
exit "$fail"
