#!/usr/bin/env bash
# foxguard-scan's install step with curl and uname stubbed: the binary is
# checked against a digest held in scanner-pins.env, never a checksums file
# from the release or a table inside the action. A version without a pinned
# digest needs foxguard_sha256.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT_DIR/.github/actions/foxguard-scan/action.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$ACTION" > "$work/step.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
print(next(s["run"] for s in steps if s.get("id") == "install"))
PY
default="$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["inputs"]["foxguard_version"]["default"])' "$ACTION")"

# A stand-in release binary: the release ships bare executables.
mkdir -p "$work/bin"
printf '#!/bin/sh\necho fake foxguard\n' > "$work/fake"
fake_sha="$(sha256sum "$work/fake" | cut -d' ' -f1)"

cat > "$work/bin/curl" <<'SH'
#!/bin/sh
# Records each URL and serves the stand-in binary for -o.
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
echo "$url" >> "$CALLS"
cp "$FAKE" "$out"
SH
# shellcheck disable=SC2016 # $1 belongs to the stub
printf '#!/bin/sh\ncase "$1" in -s) echo "$STUB_OS" ;; -m) echo "$STUB_ARCH" ;; esac\n' > "$work/bin/uname"
chmod +x "$work/bin/curl" "$work/bin/uname"

run_step() {  # $1 = version, $2 = foxguard_sha256
  : > "$work/calls"; : > "$work/out"
  env PATH="$work/bin:$PATH" CALLS="$work/calls" FAKE="$work/fake" \
    STUB_OS="${STUB_OS:-Linux}" STUB_ARCH="${STUB_ARCH:-x86_64}" \
    RUNNER_TEMP="$work" GITHUB_OUTPUT="$work/out" ACTION_PATH="$(dirname "$ACTION")" \
    FOXGUARD_VERSION="$1" FOXGUARD_SHA256="$2" bash "$work/step.sh" 2>&1
}

fail=0
ver="${default#v}"
# The digests live in scanner-pins.env, the one versions file, for the version
# the input defaults to. Both files name the version, so this keeps them equal.
pins="$ROOT_DIR/scanner-pins.env"
pinned_ver="$(awk -F= '$1 == "FOXGUARD_VERSION" { print $2 }' "$pins")"
[[ "$pinned_ver" == "$ver" ]] \
  || { echo "FAIL: foxguard_version defaults to $default but scanner-pins.env pins FOXGUARD_VERSION=$pinned_ver"; fail=1; }
wf_default="$(python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print((d.get(True) or d.get("on"))["workflow_call"]["inputs"]["foxguard_version"]["default"])' "$ROOT_DIR/.github/workflows/foxguard-scan.yml")"
[[ "$wf_default" == "$default" ]] \
  || { echo "FAIL: foxguard-scan.yml defaults foxguard_version to $wf_default, the action to $default"; fail=1; }
for key in LINUX_X86_64 LINUX_AARCH64 MACOS_X86_64 MACOS_AARCH64 WINDOWS_X86_64; do
  digest="$(awk -F= -v k="FOXGUARD_SHA256_$key" '$1 == k { print $2 }' "$pins")"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] \
    || { echo "FAIL: scanner-pins.env has no 64-hex FOXGUARD_SHA256_$key (got '$digest')"; fail=1; }
done
# The action reads the file; it holds no digest of its own, so a bump edits
# one file and the test above cannot pass on a stale copy.
if grep -qE 'pinned=[0-9a-f]{64}' "$ACTION"; then
  echo "FAIL: action.yml still holds a digest table; the pins belong in scanner-pins.env"; fail=1
fi
grep -q 'scanner-pins.env' "$ACTION" || { echo "FAIL: action.yml does not read scanner-pins.env"; fail=1; }

rc=0; out="$(run_step "$default" "")" || rc=$?
if (( rc == 0 )); then echo "FAIL: a binary that is not the pinned one ran"; fail=1; fi
grep -q "Checksum mismatch" <<<"$out" || { echo "FAIL: no mismatch reported: $out"; fail=1; }
if grep -q checksums "$work/calls"; then echo "FAIL: fetched a checksums file"; fail=1; fi
grep -q "releases/download/${default}/foxguard-linux-x86_64\$" "$work/calls" \
  || { echo "FAIL: unexpected download URL: $(cat "$work/calls")"; fail=1; }

rc=0; out="$(run_step v9.9.9 "")" || rc=$?
if (( rc == 0 )); then echo "FAIL: an unpinned version ran without foxguard_sha256"; fail=1; fi
grep -q "No pinned sha256 for v9.9.9 foxguard-linux-x86_64" <<<"$out" || { echo "FAIL: missing digest not named: $out"; fail=1; }

# The pin is keyed on tag and asset together: the 0.14.1 digest must not
# verify a 0.15.0 download of the same asset name.
rc=0; out="$(run_step v0.15.0 "")" || rc=$?
if (( rc == 0 )); then echo "FAIL: another version ran against the pinned digest"; fail=1; fi
grep -q "No pinned sha256 for v0.15.0" <<<"$out" || { echo "FAIL: other version not refused: $out"; fail=1; }

# A pinned version keeps its pinned digest: foxguard_sha256 may repeat it, not
# replace it, so a caller cannot swap in another binary under the pinned tag.
pinned_sha="$(awk -F= '$1 == "FOXGUARD_SHA256_LINUX_X86_64" { print $2 }' "$pins")"
rc=0; out="$(run_step "$default" "$fake_sha")" || rc=$?
if (( rc == 0 )); then echo "FAIL: foxguard_sha256 overrode the pinned digest of $default"; fail=1; fi
grep -q "differs from the digest pinned" <<<"$out" || { echo "FAIL: override not named: $out"; fail=1; }
rc=0; out="$(run_step "$default" "$(tr '[:lower:]' '[:upper:]' <<<"$pinned_sha")")" || rc=$?
if grep -q "differs from the digest pinned" <<<"$out"; then echo "FAIL: foxguard_sha256 equal to the pin was refused: $out"; fail=1; fi
grep -q "Checksum mismatch" <<<"$out" || { echo "FAIL: equal foxguard_sha256 skipped verification: $out"; fail=1; }

rc=0; out="$(run_step v9.9.9 "$fake_sha")" || rc=$?
if (( rc != 0 )); then echo "FAIL: foxguard_sha256 matching the binary gave exit $rc: $out"; fail=1; fi
grep -q '^fg_bin=.*/foxguard$' "$work/out" || { echo "FAIL: fg_bin not set"; fail=1; }
bin="$(sed -n 's/^fg_bin=//p' "$work/out")"
[[ -x "$bin" ]] || { echo "FAIL: fg_bin is not executable"; fail=1; }

rc=0; out="$(run_step v9.9.9 "$(tr '[:lower:]' '[:upper:]' <<<"$fake_sha")")" || rc=$?
if (( rc != 0 )); then echo "FAIL: an upper-case foxguard_sha256 gave exit $rc: $out"; fail=1; fi

rc=0; out="$(run_step v9.9.9 "  $fake_sha  foxguard-linux-x86_64")" || rc=$?
if (( rc != 0 )); then echo "FAIL: a pasted checksums.txt line gave exit $rc: $out"; fail=1; fi

rc=0; out="$(run_step v9.9.9 "${fake_sha:0:40}")" || rc=$?
if (( rc == 0 )); then echo "FAIL: a truncated foxguard_sha256 was accepted"; fail=1; fi
grep -q "must be 64 hex characters" <<<"$out" || { echo "FAIL: bad digest not named: $out"; fail=1; }

rc=0; out="$(STUB_OS=Darwin STUB_ARCH=arm64 run_step v9.9.9 "$fake_sha")" || rc=$?
if (( rc != 0 )); then echo "FAIL: macOS arm64 gave exit $rc: $out"; fail=1; fi
grep -q "/foxguard-macos-aarch64\$" "$work/calls" || { echo "FAIL: macOS arm64 asset: $(cat "$work/calls")"; fail=1; }

rc=0; out="$(STUB_OS=MINGW64_NT-10.0 STUB_ARCH=x86_64 run_step v9.9.9 "$fake_sha")" || rc=$?
if (( rc != 0 )); then echo "FAIL: Windows x86_64 gave exit $rc: $out"; fail=1; fi
grep -q "/foxguard-windows-x86_64.exe\$" "$work/calls" || { echo "FAIL: Windows asset: $(cat "$work/calls")"; fail=1; }
grep -q '^fg_bin=.*/foxguard.exe$' "$work/out" || { echo "FAIL: Windows fg_bin not .exe"; fail=1; }

rc=0; out="$(STUB_OS=MINGW64_NT-10.0 STUB_ARCH=aarch64 run_step v9.9.9 "$fake_sha")" || rc=$?
if (( rc == 0 )); then echo "FAIL: Windows arm64, which has no release binary, ran"; fail=1; fi
if [[ -s "$work/calls" ]]; then echo "FAIL: Windows arm64 downloaded something"; fail=1; fi

(( fail == 0 )) && echo "foxguard_pinned_digest: digest from scanner-pins.env checked, unpinned version needs foxguard_sha256"
exit "$fail"
