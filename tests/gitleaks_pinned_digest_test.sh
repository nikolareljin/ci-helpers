#!/usr/bin/env bash
# gitleaks-scan's install step with curl and uname stubbed: the archive is
# checked against a digest held in the action, never a checksums file from
# the release. A version without a pinned digest needs gitleaks_sha256.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT_DIR/.github/actions/gitleaks-scan/action.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$ACTION" > "$work/step.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
print(next(s["run"] for s in steps if s.get("id") == "install"))
PY
default="$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["inputs"]["gitleaks_version"]["default"])' "$ACTION")"

# A stand-in release archive: a tar.gz holding a `gitleaks` script.
mkdir -p "$work/pkg" "$work/bin"
printf '#!/bin/sh\necho fake gitleaks\n' > "$work/pkg/gitleaks"
chmod +x "$work/pkg/gitleaks"
tar -czf "$work/fake.tar.gz" -C "$work/pkg" gitleaks
fake_sha="$(sha256sum "$work/fake.tar.gz" | cut -d' ' -f1)"

cat > "$work/bin/curl" <<'SH'
#!/bin/sh
# Records each URL and serves the stand-in archive for -o.
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
echo "$url" >> "$CALLS"
cp "$FAKE" "$out"
SH
# shellcheck disable=SC2016 # $1 belongs to the stub
printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac\n' > "$work/bin/uname"
chmod +x "$work/bin/curl" "$work/bin/uname"

run_step() {  # $1 = version, $2 = gitleaks_sha256
  : > "$work/calls"; : > "$work/out"
  env PATH="$work/bin:$PATH" CALLS="$work/calls" FAKE="$work/fake.tar.gz" \
    RUNNER_TEMP="$work" GITHUB_OUTPUT="$work/out" ACTION_PATH="$(dirname "$ACTION")" \
    GITLEAKS_VERSION="$1" GITLEAKS_SHA256="$2" bash "$work/step.sh" 2>&1
}

fail=0
ver="${default#v}"
# The digests live in scanner-pins.env, for the version the input defaults to.
# Both files name the version, so this is what keeps them equal.
pins="$ROOT_DIR/scanner-pins.env"
pinned_ver="$(awk -F= '$1 == "GITLEAKS_VERSION" { print $2 }' "$pins")"
[[ "$pinned_ver" == "$ver" ]] \
  || { echo "FAIL: gitleaks_version defaults to $default but scanner-pins.env pins GITLEAKS_VERSION=$pinned_ver"; fail=1; }
wf_default="$(python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print((d.get(True) or d.get("on"))["workflow_call"]["inputs"]["gitleaks_version"]["default"])' "$ROOT_DIR/.github/workflows/gitleaks-scan.yml")"
[[ "$wf_default" == "$default" ]] \
  || { echo "FAIL: gitleaks-scan.yml defaults gitleaks_version to $wf_default, the action to $default"; fail=1; }
for key in LINUX_X64 LINUX_ARM64 DARWIN_X64 DARWIN_ARM64 WINDOWS_X64 WINDOWS_ARM64; do
  sha="$(awk -F= -v k="GITLEAKS_SHA256_$key" '$1 == k { print $2 }' "$pins")"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: GITLEAKS_SHA256_$key in scanner-pins.env is '$sha'"; fail=1; }
done
if grep -q 'pinned=[0-9a-f]\{64\}' "$ACTION"; then
  echo "FAIL: the action still carries a digest of its own; scanner-pins.env is the one place"; fail=1
fi

rc=0; out="$(run_step "$default" "")" || rc=$?
if (( rc == 0 )); then echo "FAIL: an archive that is not the pinned one ran"; fail=1; fi
grep -q "Checksum mismatch" <<<"$out" || { echo "FAIL: no mismatch reported: $out"; fail=1; }
if grep -q checksums "$work/calls"; then echo "FAIL: fetched a checksums file"; fail=1; fi

rc=0; out="$(run_step v9.9.9 "")" || rc=$?
if (( rc == 0 )); then echo "FAIL: an unpinned version ran without gitleaks_sha256"; fail=1; fi
grep -q "No pinned sha256 for gitleaks_9.9.9_linux_x64.tar.gz" <<<"$out" || { echo "FAIL: missing digest not named: $out"; fail=1; }

# A pinned version keeps its pinned digest: gitleaks_sha256 may repeat it, not
# replace it, so a caller cannot swap in another binary under the pinned tag.
pinned_sha="$(sed -n "s/.*gitleaks_${ver}_linux_x64.tar.gz) *pinned=\([0-9a-f]*\).*/\1/p" "$ACTION" | head -n1)"
rc=0; out="$(run_step "$default" "$fake_sha")" || rc=$?
if (( rc == 0 )); then echo "FAIL: gitleaks_sha256 overrode the pinned digest of $default"; fail=1; fi
grep -q "differs from the digest pinned" <<<"$out" || { echo "FAIL: override not named: $out"; fail=1; }
rc=0; out="$(run_step "$default" "$(tr '[:lower:]' '[:upper:]' <<<"$pinned_sha")")" || rc=$?
if grep -q "differs from the digest pinned" <<<"$out"; then echo "FAIL: gitleaks_sha256 equal to the pin was refused: $out"; fail=1; fi
grep -q "Checksum mismatch" <<<"$out" || { echo "FAIL: equal gitleaks_sha256 skipped verification: $out"; fail=1; }

rc=0; out="$(run_step v9.9.9 "$fake_sha")" || rc=$?
if (( rc != 0 )); then echo "FAIL: gitleaks_sha256 matching the archive gave exit $rc: $out"; fail=1; fi
grep -q '^gl_bin=.*/gitleaks$' "$work/out" || { echo "FAIL: gl_bin not set"; fail=1; }

rc=0; out="$(run_step v9.9.9 "$(tr '[:lower:]' '[:upper:]' <<<"$fake_sha")")" || rc=$?
if (( rc != 0 )); then echo "FAIL: an upper-case gitleaks_sha256 gave exit $rc: $out"; fail=1; fi

rc=0; out="$(run_step v9.9.9 "  $fake_sha  gitleaks_9.9.9_linux_x64.tar.gz")" || rc=$?
if (( rc != 0 )); then echo "FAIL: a pasted checksums.txt line gave exit $rc: $out"; fail=1; fi

rc=0; out="$(run_step v9.9.9 "${fake_sha:0:40}")" || rc=$?
if (( rc == 0 )); then echo "FAIL: a truncated gitleaks_sha256 was accepted"; fail=1; fi
grep -q "must be 64 hex characters" <<<"$out" || { echo "FAIL: bad digest not named: $out"; fail=1; }

(( fail == 0 )) && echo "gitleaks_pinned_digest: pinned digest checked, unpinned version needs gitleaks_sha256"
exit "$fail"
