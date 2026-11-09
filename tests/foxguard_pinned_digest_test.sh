#!/usr/bin/env bash
# foxguard-scan's install step with curl and uname stubbed: the binary is
# checked against a digest held in the action, never a checksums file from
# the release. A version without a pinned digest needs foxguard_sha256.
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
    RUNNER_TEMP="$work" GITHUB_OUTPUT="$work/out" \
    FOXGUARD_VERSION="$1" FOXGUARD_SHA256="$2" bash "$work/step.sh" 2>&1
}

fail=0
for asset in linux-x86_64 linux-aarch64 macos-x86_64 macos-aarch64 windows-x86_64.exe; do
  grep -q "${default}/foxguard-${asset})" "$ACTION" \
    || { echo "FAIL: default $default has no pinned digest for foxguard-${asset}"; fail=1; }
done

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

(( fail == 0 )) && echo "foxguard_pinned_digest: pinned digest checked, unpinned version needs foxguard_sha256"
exit "$fail"
