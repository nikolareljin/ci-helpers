#!/usr/bin/env bash
# scripts/install_trivy.sh with curl and uname stubbed: the archive is checked
# against the sha256 pinned in scanner-pins.env, never a checksums file from
# the release; a mismatch leaves no binary; a platform or pin it does not know
# is refused; --download-db fetches the database into the run's cache.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/install_trivy.sh"
PINS="$ROOT_DIR/scanner-pins.env"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A stand-in release archive: a tar.gz holding a `trivy` script that records
# how it was called.
mkdir -p "$work/pkg" "$work/bin"
cat > "$work/pkg/trivy" <<'SH'
#!/bin/sh
echo "$*" >> "$TRIVY_CALLS"
SH
chmod +x "$work/pkg/trivy"
tar -czf "$work/fake.tar.gz" -C "$work/pkg" trivy
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
printf '#!/bin/sh\ncase "$1" in -s) echo "${FAKE_OS:-Linux}" ;; -m) echo "${FAKE_ARCH:-x86_64}" ;; esac\n' > "$work/bin/uname"
chmod +x "$work/bin/curl" "$work/bin/uname"

# A pins file whose digest is the stand-in archive's.
cat > "$work/pins.env" <<EOF
# comment line
TRIVY_VERSION=9.9.9
TRIVY_SHA256_LINUX_64BIT=$fake_sha
TRIVY_SHA256_LINUX_ARM64=$(printf '%064d' 1)
EOF

run_install() {  # $@ = script arguments
  : > "$work/calls"; : > "$work/trivy_calls"; : > "$work/out"
  rm -rf "$work/dest"
  env PATH="$work/bin:$PATH" CALLS="$work/calls" FAKE="$work/fake.tar.gz" \
    TRIVY_CALLS="$work/trivy_calls" RUNNER_TEMP="$work" GITHUB_OUTPUT="$work/out" \
    FAKE_OS="${FAKE_OS:-}" FAKE_ARCH="${FAKE_ARCH:-}" \
    bash "$SCRIPT" --dest "$work/dest" "$@" 2>&1
}

fail=0

# The committed pins file: a version and a 64-hex digest for every platform the
# script installs on.
ver="$(awk -F= '$1 == "TRIVY_VERSION" { print $2 }' "$PINS")"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL: TRIVY_VERSION in scanner-pins.env is '$ver'"; fail=1; }
for key in LINUX_64BIT LINUX_ARM64 MACOS_64BIT MACOS_ARM64; do
  sha="$(awk -F= -v k="TRIVY_SHA256_$key" '$1 == k { print $2 }' "$PINS")"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: TRIVY_SHA256_$key in scanner-pins.env is '$sha'"; fail=1; }
done

# 1. The committed pins refuse an archive that is not the pinned release.
rc=0; out="$(run_install)" || rc=$?
if (( rc == 0 )); then echo "FAIL: an archive that is not the pinned one was installed"; fail=1; fi
grep -q "Checksum mismatch" <<<"$out" || { echo "FAIL: no mismatch reported: $out"; fail=1; }
if [[ -x "$work/dest/bin/trivy" ]]; then echo "FAIL: a binary was left executable after a mismatch"; fail=1; fi
if grep -q checksums "$work/calls"; then echo "FAIL: fetched a checksums file"; fail=1; fi
grep -q "releases/download/v${ver}/trivy_${ver}_Linux-64bit.tar.gz" "$work/calls" \
  || { echo "FAIL: did not fetch the pinned release: $(cat "$work/calls")"; fail=1; }

# 2. A matching digest installs, reports the binary, downloads no database
#    unless asked.
rc=0; out="$(run_install --pins "$work/pins.env")" || rc=$?
if (( rc != 0 )); then echo "FAIL: a matching digest gave exit $rc: $out"; fail=1; fi
grep -q '^trivy_bin=.*/bin/trivy$' "$work/out" || { echo "FAIL: trivy_bin not set: $(cat "$work/out")"; fail=1; }
grep -q '^cache_dir=.*/cache$' "$work/out" || { echo "FAIL: cache_dir not set: $(cat "$work/out")"; fail=1; }
[[ -x "$work/dest/bin/trivy" ]] || { echo "FAIL: binary not installed"; fail=1; }
[[ -s "$work/trivy_calls" ]] && { echo "FAIL: trivy was run without --download-db: $(cat "$work/trivy_calls")"; fail=1; }
grep -q "releases/download/v9.9.9/trivy_9.9.9_Linux-64bit.tar.gz" "$work/calls" \
  || { echo "FAIL: version from the pins file not used: $(cat "$work/calls")"; fail=1; }

# 3. --download-db fetches the database into the run's cache, and nothing else.
rc=0; out="$(run_install --pins "$work/pins.env" --download-db)" || rc=$?
if (( rc != 0 )); then echo "FAIL: --download-db gave exit $rc: $out"; fail=1; fi
grep -q -- "--cache-dir $work/dest/cache --quiet image --download-db-only" "$work/trivy_calls" \
  || { echo "FAIL: database not downloaded into the cache: $(cat "$work/trivy_calls")"; fail=1; }
[[ "$(wc -l < "$work/trivy_calls")" -eq 1 ]] || { echo "FAIL: trivy ran more than once: $(cat "$work/trivy_calls")"; fail=1; }

# 4. A pin that is not 64 hex characters is refused before any download.
sed "s/^TRIVY_SHA256_LINUX_64BIT=.*/TRIVY_SHA256_LINUX_64BIT=${fake_sha:0:40}/" "$work/pins.env" > "$work/short.env"
rc=0; out="$(run_install --pins "$work/short.env")" || rc=$?
if (( rc != 2 )); then echo "FAIL: a truncated pin gave exit $rc, expected 2: $out"; fail=1; fi
grep -q "No 64-hex sha256 pinned" <<<"$out" || { echo "FAIL: bad pin not named: $out"; fail=1; }
[[ -s "$work/calls" ]] && { echo "FAIL: downloaded with a bad pin: $(cat "$work/calls")"; fail=1; }

# 5. A platform with no pin is refused; the arm64 pin is read for arm64.
rc=0; out="$(FAKE_OS=FreeBSD run_install --pins "$work/pins.env")" || rc=$?
if (( rc != 2 )); then echo "FAIL: FreeBSD gave exit $rc, expected 2: $out"; fail=1; fi
grep -q "Unsupported runner OS" <<<"$out" || { echo "FAIL: unsupported OS not named: $out"; fail=1; }
rc=0; out="$(FAKE_ARCH=aarch64 run_install --pins "$work/pins.env")" || rc=$?
if (( rc == 0 )); then echo "FAIL: the arm64 archive passed against the 64bit pin"; fail=1; fi
grep -q "trivy_9.9.9_Linux-ARM64.tar.gz" "$work/calls" || { echo "FAIL: arm64 asset not requested: $(cat "$work/calls")"; fail=1; }
grep -q "Checksum mismatch" <<<"$out" || { echo "FAIL: arm64 pin not compared: $out"; fail=1; }

# 6. An unreadable pins file is a usage error, not a download.
rc=0; out="$(run_install --pins "$work/missing.env")" || rc=$?
if (( rc != 2 )); then echo "FAIL: a missing pins file gave exit $rc, expected 2: $out"; fail=1; fi

(( fail == 0 )) && echo "install_trivy: pinned digest checked from scanner-pins.env, mismatch leaves nothing, database only on request"
exit "$fail"
