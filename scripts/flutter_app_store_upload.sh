#!/usr/bin/env bash
# SCRIPT: flutter_app_store_upload.sh
# DESCRIPTION: Export the unsigned .xcarchive flutter-release's build job
#              made into a signed IPA and upload it, in a job that runs no
#              caller code. The archive is unpacked with safe_untar.py and
#              its app's CFBundleIdentifier must equal BUNDLE_ID. Signing
#              material comes from `fastlane match appstore --readonly`
#              into a temporary keychain; exportOptions.plist is written
#              here from the checked inputs; `xcodebuild -exportArchive`
#              signs; `fastlane pilot upload` (TestFlight) or `fastlane
#              deliver` (App Store, no metadata, no submission) uploads.
#              No caller Fastfile, Appfile, Matchfile or lane runs.
# USAGE: IN=<verified artifact> LIB_SCRIPTS=<dir> BUNDLE_ID=... TEAM_ID=... \
#          DESTINATION=testflight|app_store RUBY_BIN=... GEMS=... \
#          bash scripts/flutter_app_store_upload.sh
# ENVIRONMENT:
#   IN                Holds ios/archive.tar.gz.
#   BUNDLE_ID         The app's bundle identifier.
#   TEAM_ID           10-character Apple team id.
#   DESTINATION       testflight (pilot) or app_store (deliver).
#   MATCH_GIT_URL, MATCH_PASSWORD, MATCH_GIT_BASIC_AUTHORIZATION   match.
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_BASE64   App Store Connect API key.
#   RUBY_BIN, GEMS    See fastlane_run.sh.
# EXIT CODES:
#   0  Uploaded.
#   1  A refusal or a tool failure.
#   2  Usage error.
# ----------------------------------------------------
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }
[[ -n "${LIB_SCRIPTS:-}" && -f "$LIB_SCRIPTS/fastlane_run.sh" && -f "$LIB_SCRIPTS/safe_untar.py" ]] || { echo "::error::LIB_SCRIPTS lacks fastlane_run.sh or safe_untar.py." >&2; exit 2; }
# shellcheck source=fastlane_run.sh
. "$LIB_SCRIPTS/fastlane_run.sh"
[[ "${BUNDLE_ID:-}" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || fail "ios_bundle_id '${BUNDLE_ID:-}' is not a bundle identifier such as com.example.app."
[[ "${TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || fail "ios_team_id '${TEAM_ID:-}' is not a 10-character Apple team id."
[[ "${DESTINATION:-}" =~ ^(testflight|app_store)$ ]] || fail "app_store_destination '${DESTINATION:-}' is not testflight or app_store."
[[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_BASE64:-}" ]] || fail "the App Store Connect API key needs app_store_connect_api_key_base64, app_store_connect_key_id and app_store_connect_issuer_id."
[[ -n "${MATCH_GIT_URL:-}" && -n "${MATCH_PASSWORD:-}" ]] || fail "match_git_url and match_password are needed to sign the IPA."
[[ -n "${IN:-}" && -f "$IN/ios/archive.tar.gz" && ! -L "$IN/ios/archive.tar.gz" ]] || fail "the artifact has no ios/archive.tar.gz."

work="$(mktemp -d)"
keychain="$work/upload.keychain-db"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
chmod 700 "$work"
mkdir "$work/archive" "$work/export"
name="$(/usr/bin/python3 -I "$LIB_SCRIPTS/safe_untar.py" "$IN/ios/archive.tar.gz" "$work/archive" '[A-Za-z0-9][A-Za-z0-9 ._+-]{0,99}\.xcarchive')"
archive="$work/archive/$name"
shopt -s nullglob
apps=("$archive"/Products/Applications/*.app)
shopt -u nullglob
[[ ${#apps[@]} -eq 1 ]] || fail "the archive holds ${#apps[@]} apps under Products/Applications, not one."
got="$(plutil -extract CFBundleIdentifier raw -o - "${apps[0]}/Info.plist")" || fail "the archived app has no CFBundleIdentifier."
[[ "$got" == "$BUNDLE_ID" ]] || fail "the archived app is '$got', not ios_bundle_id '$BUNDLE_ID'."

# A keychain of this job's own, with a random password, removed on exit.
kc_pw="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
security create-keychain -p "$kc_pw" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$kc_pw" "$keychain"
# shellcheck disable=SC2046 # the existing search list, one path per word
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

# Credentials go by env (match reads MATCH_*), never argv: a git URL can
# carry a token, and argv is visible to every process on the runner.
export MATCH_PASSWORD MATCH_GIT_URL MATCH_GIT_BASIC_AUTHORIZATION="${MATCH_GIT_BASIC_AUTHORIZATION:-}" MATCH_KEYCHAIN_PASSWORD="$kc_pw"
fastlane_run match appstore --readonly true --app_identifier "$BUNDLE_ID" --team_id "$TEAM_ID" \
  --keychain_name "$keychain"

profile="match AppStore $BUNDLE_ID"
plist="$work/exportOptions.plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$BUNDLE_ID</key><string>$profile</string>
  </dict>
</dict>
</plist>
PLIST
plutil -lint -s "$plist" || fail "the generated exportOptions.plist does not parse."
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" -exportOptionsPlist "$plist"
shopt -s nullglob
ipas=("$work/export"/*.ipa)
shopt -u nullglob
[[ ${#ipas[@]} -eq 1 ]] || fail "xcodebuild exported ${#ipas[@]} IPAs, not one."

(umask 077 && ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" ASC_KEY_BASE64="$ASC_KEY_BASE64" /usr/bin/python3 -I -c '
import base64, json, os, sys
key = base64.b64decode(os.environ["ASC_KEY_BASE64"], validate=False).decode()
json.dump({"key_id": os.environ["ASC_KEY_ID"], "issuer_id": os.environ["ASC_ISSUER_ID"],
           "key": key, "in_house": False}, sys.stdout)
' > "$work/asc.json") || fail "app_store_connect_api_key_base64 is not a base64 .p8 key."

if [[ "$DESTINATION" == testflight ]]; then
  fastlane_run pilot upload --ipa "${ipas[0]}" --api_key_path "$work/asc.json" --skip_waiting_for_build_processing true
else
  fastlane_run deliver --ipa "${ipas[0]}" --api_key_path "$work/asc.json" --skip_metadata true \
    --skip_screenshots true --submit_for_review false --force true --run_precheck_before_submit false
fi
