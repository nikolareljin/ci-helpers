#!/usr/bin/env bash
# SCRIPT: flutter_play_upload.sh
# DESCRIPTION: Upload the one signed .aab in DIR to Google Play with
#              `fastlane supply`, every parameter from a checked workflow
#              input. No caller Fastfile or lane runs (fastlane_run.sh).
# USAGE: DIR=<dir> PACKAGE_NAME=... TRACK=... RELEASE_STATUS=... \
#          GOOGLE_PLAY_JSON=... RUBY_BIN=... GEMS=... LIB_SCRIPTS=... \
#          bash scripts/flutter_play_upload.sh
# ENVIRONMENT:
#   DIR               Holds exactly one .aab.
#   PACKAGE_NAME      Android application id, e.g. com.example.app.
#   TRACK             internal, alpha, beta, production or a custom track
#                     ([a-z0-9_:-], up to 50 characters).
#   RELEASE_STATUS    completed, draft, halted or inProgress.
#   GOOGLE_PLAY_JSON  The service account JSON (written to a 0600 file).
#   RUBY_BIN, GEMS    See fastlane_run.sh.
# EXIT CODES:
#   0  Uploaded.
#   1  A refusal or a fastlane failure.
#   2  Usage error.
# ----------------------------------------------------
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }
[[ -n "${LIB_SCRIPTS:-}" && -f "$LIB_SCRIPTS/fastlane_run.sh" ]] || { echo "::error::LIB_SCRIPTS has no fastlane_run.sh." >&2; exit 2; }
# shellcheck source=fastlane_run.sh
. "$LIB_SCRIPTS/fastlane_run.sh"
[[ "${PACKAGE_NAME:-}" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]] || fail "android_package_name '${PACKAGE_NAME:-}' is not an application id such as com.example.app."
[[ "${TRACK:-}" =~ ^[a-z0-9][a-z0-9_:-]{0,49}$ ]] || fail "google_play_track '${TRACK:-}' is not a track name."
[[ "${RELEASE_STATUS:-}" =~ ^(completed|draft|halted|inProgress)$ ]] || fail "google_play_release_status '${RELEASE_STATUS:-}' is not completed, draft, halted or inProgress."
[[ -n "${GOOGLE_PLAY_JSON:-}" ]] || fail "google_play_service_account_json is empty."
[[ -n "${DIR:-}" && -d "$DIR" && ! -L "$DIR" ]] || { echo "::error::DIR is not a directory." >&2; exit 2; }
shopt -s nullglob
aabs=("$DIR"/*.aab)
shopt -u nullglob
[[ ${#aabs[@]} -eq 1 ]] || fail "expected one .aab to upload, found ${#aabs[@]}."
[[ -f "${aabs[0]}" && ! -L "${aabs[0]}" ]] || fail "'${aabs[0]}' is not a regular file."
aab="$(cd "$DIR" && pwd -P)/${aabs[0]##*/}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
(umask 077 && printf '%s' "$GOOGLE_PLAY_JSON" > "$work/play.json")
fastlane_run supply --aab "$aab" --package_name "$PACKAGE_NAME" --track "$TRACK" \
  --release_status "$RELEASE_STATUS" --json_key "$work/play.json" \
  --skip_upload_apk true --skip_upload_metadata true --skip_upload_changelogs true \
  --skip_upload_images true --skip_upload_screenshots true
