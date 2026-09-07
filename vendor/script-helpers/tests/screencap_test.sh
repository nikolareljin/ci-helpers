#!/usr/bin/env bash
# SCRIPT: screencap_test.sh
# DESCRIPTION: Smoke tests for lib/screencap.sh (shot, record, frame, gif).
# USAGE: ./tests/screencap_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/screencap_test.sh
# ----------------------------------------------------
#
# Capture needs a device or simulator, which a test host will not usually have.
# Everything device-dependent is a skip with a note, never a failure — the same
# contract as tests/svg_test.sh and tests/ios_test.sh.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[screencap_test] $*"; }
error() { echo "[screencap_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import screencap

# 1) functions defined after import
for fn in screencap_available screencap_shot screencap_record \
          screencap_record_stop screencap_frame screencap_gif; do
  if declare -f "$fn" >/dev/null 2>&1; then
    note "$fn is defined"
  else
    error "$fn is NOT defined"
  fi
done

# 2) the module pulls in its own dependencies — a caller should only have to
#    ask for `screencap`.
for fn in adb_ready_serials ios_available; do
  declare -f "$fn" >/dev/null 2>&1 \
    || error "$fn is not defined — screencap did not load its dependency module"
done
note "dependency modules are loaded by import"

# 3) bad args return exactly 2
set +e
screencap_shot --nonsense >/dev/null 2>&1;    [[ $? -eq 2 ]] || error "screencap_shot with an unknown option did not return 2"
screencap_record --nonsense >/dev/null 2>&1;  [[ $? -eq 2 ]] || error "screencap_record with an unknown option did not return 2"
screencap_record --seconds 0 >/dev/null 2>&1; [[ $? -eq 2 ]] || error "screencap_record --seconds 0 did not return 2"
screencap_record --seconds x >/dev/null 2>&1; [[ $? -eq 2 ]] || error "screencap_record --seconds x did not return 2"
screencap_frame >/dev/null 2>&1;              [[ $? -eq 2 ]] || error "screencap_frame with no args did not return 2"
screencap_gif >/dev/null 2>&1;                [[ $? -eq 2 ]] || error "screencap_gif with no args did not return 2"
set -e
note "bad arguments return 2"

# 4) a missing input file is an argument error, not a crash
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
set +e
screencap_frame "$tmp/nope.mp4" "$tmp/out.png" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "screencap_frame on a missing video returned $status (expected 2)"

# 5) ffmpeg-dependent functions return 3 when ffmpeg is absent
printf 'not really a video' > "$tmp/fake.mp4"
if command -v ffmpeg >/dev/null 2>&1; then
  note "ffmpeg is installed — skipping the missing-ffmpeg assertion"
else
  set +e
  screencap_gif "$tmp/fake.mp4" "$tmp/out.gif" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 3 ]] || error "screencap_gif without ffmpeg returned $status (expected 3)"
fi

# 6) record_stop is safe when nothing is recording
set +e
screencap_record_stop >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 0 ]] || error "screencap_record_stop returned $status with nothing recording (expected 0)"
note "record_stop is safe to call when idle"

# 7) with no device at all, capture reports 3 rather than producing an empty file
if screencap_available 2>/dev/null; then
  note "a device or simulator is attached — running a real capture"
  out="$(SCREENCAP_DIR="$tmp" screencap_shot 2>/dev/null)"
  if [[ -n "$out" && -s "$out" ]]; then
    note "captured $out"
    # The header of a PNG, so a truncated or text file is caught.
    head -c 8 "$out" | od -An -tx1 | grep -q '89 50 4e 47' \
      || error "the captured file is not a PNG"
  else
    error "screencap_shot produced nothing with a device attached"
  fi
else
  set +e
  SCREENCAP_DIR="$tmp" screencap_shot >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 3 ]] || error "screencap_shot with no device returned $status (expected 3)"
  note "no device attached — skipping the real capture (not a failure)"
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
