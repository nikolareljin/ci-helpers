#!/usr/bin/env bash
# SCRIPT: tauri_macos_sign.sh
# DESCRIPTION: Turn the unsigned .app the tauri-release build job tarred
#              into the published macOS files: <Name>_<version>_universal.dmg
#              and <Name>.app.tar.gz (the updater bundle), plus
#              <Name>.app.tar.gz.sig when the updater key is set. With
#              SIGN=true the app is codesigned with the hardened runtime
#              and the DMG is signed; with NOTARIZE=true the DMG is
#              notarized, and the DMG and app are stapled before the
#              updater bundle is made. Only system tools and the pinned
#              signer run; no Tauri bundler, no hook from tauri.conf.
# USAGE: IN=<verified artifact> OUT=<empty dir> LIB_SCRIPTS=<dir> \
#          bash scripts/tauri_macos_sign.sh
# ENVIRONMENT:
#   IN               Holds app.tar.gz and, optionally, entitlements.plist.
#   OUT              Empty directory for the published files.
#   LIB_SCRIPTS      The library's scripts directory (safe_untar.py).
#   SIGN             true: codesign. Anything else: unsigned files.
#   NOTARIZE         true (with SIGN=true): notarize and staple.
#   IDENTITY         Signing identity (SIGN=true).
#   KEYCHAIN         Keychain holding it (SIGN=true).
#   APPLE_ID, APPLE_PASSWORD, TEAM_ID   notarytool credentials (NOTARIZE=true).
#   SIGNER           cargo-tauri, when the updater key is set.
#   TAURI_SIGNING_PRIVATE_KEY[_PASSWORD]  The updater key; empty: no .sig.
# EXIT CODES:
#   0  Done.
#   1  A refusal or a tool failure.
#   2  Usage error.
# ----------------------------------------------------
set -euo pipefail
export LC_ALL=C
# spctl is in /usr/sbin, which a lib_path.sh secret PATH leaves out.
export PATH="$PATH:/usr/sbin"

fail() { echo "::error::$*" >&2; exit 1; }
[[ -n "${IN:-}" && -d "$IN" && ! -L "$IN" ]] || { echo "::error::IN is not a directory." >&2; exit 2; }
[[ "${OUT:-}" == /* && -d "$OUT" && ! -L "$OUT" ]] || { echo "::error::OUT is not an absolute directory path." >&2; exit 2; }
[[ -z "$(ls -A "$OUT")" ]] || { echo "::error::OUT is not empty." >&2; exit 2; }
[[ -n "${LIB_SCRIPTS:-}" && -f "$LIB_SCRIPTS/safe_untar.py" ]] || { echo "::error::LIB_SCRIPTS has no safe_untar.py." >&2; exit 2; }
SIGN="${SIGN:-false}"
NOTARIZE="${NOTARIZE:-false}"
[[ "$SIGN" == true ]] || NOTARIZE=false
[[ -f "$IN/app.tar.gz" && ! -L "$IN/app.tar.gz" ]] || fail "the artifact has no app.tar.gz."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/app" "$work/dmg"
# Name: letters, digits, space, dot, underscore, plus, hyphen; it becomes
# part of every published file name and of the DMG volume name.
name="$(/usr/bin/python3 -I "$LIB_SCRIPTS/safe_untar.py" "$IN/app.tar.gz" "$work/app" '[A-Za-z0-9][A-Za-z0-9 ._+-]{0,99}\.app')"
app="$work/app/$name"
base="${name%.app}"
plist="$app/Contents/Info.plist"
[[ -f "$plist" && ! -L "$plist" ]] || fail "$name has no Contents/Info.plist."
version="$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" || fail "Info.plist has no CFBundleShortVersionString."
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$ ]] || fail "CFBundleShortVersionString '$version' is not a version."

if [[ "$SIGN" == true ]]; then
  [[ -n "${IDENTITY:-}" && -n "${KEYCHAIN:-}" ]] || fail "SIGN=true needs IDENTITY and KEYCHAIN."
  ent=()
  if [[ -e "$IN/entitlements.plist" || -L "$IN/entitlements.plist" ]]; then
    [[ -f "$IN/entitlements.plist" && ! -L "$IN/entitlements.plist" ]] || fail "entitlements.plist is not a regular file."
    plutil -lint -s "$IN/entitlements.plist" || fail "entitlements.plist is not a property list."
    ent=(--entitlements "$IN/entitlements.plist")
  fi
  codesign --force --deep --options runtime --timestamp --keychain "$KEYCHAIN" --sign "$IDENTITY" ${ent[@]+"${ent[@]}"} "$app"
  codesign --verify --deep --strict "$app"
fi

dmg="$OUT/${base}_${version}_universal.dmg"
ditto "$app" "$work/dmg/$name"
ln -s /Applications "$work/dmg/Applications"
hdiutil create -volname "$base" -srcfolder "$work/dmg" -ov -format UDZO "$dmg"
if [[ "$SIGN" == true ]]; then
  codesign --force --timestamp --keychain "$KEYCHAIN" --sign "$IDENTITY" "$dmg"
fi
if [[ "$NOTARIZE" == true ]]; then
  [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${TEAM_ID:-}" ]] || fail "NOTARIZE=true needs APPLE_ID, APPLE_PASSWORD and TEAM_ID."
  xcrun notarytool submit "$dmg" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$TEAM_ID" --wait
  xcrun stapler staple "$dmg"
  # Notarizing the DMG notarizes the app inside it; the updater bundle
  # carries the stapled app.
  xcrun stapler staple "$app"
  spctl --assess --type open --context context:primary-signature "$dmg"
fi

updater="$OUT/$name.tar.gz"
(cd "$work/app" && COPYFILE_DISABLE=1 tar -czf "$updater" "$name")
if [[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
  /bin/bash "$LIB_SCRIPTS/tauri_updater_sign.sh" "$updater"
fi
ls -la "$OUT"
