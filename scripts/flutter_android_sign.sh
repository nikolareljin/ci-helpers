#!/usr/bin/env bash
# SCRIPT: flutter_android_sign.sh
# DESCRIPTION: Sign the Android App Bundles flutter-release's build job made
#              with the upload key, in the sign-android job, which runs no
#              caller code. Each .aab in IN/android loses the signature the
#              build left (zip_strip_signature.py), is signed with jarsigner
#              and verified, and lands in OUT under the same name. With none
#              of the four keystore values set, the files are copied as they
#              are (the project's own signing config) unless REQUIRE_SIGNING
#              is true; a partial set warns and copies, as before.
# USAGE: IN=<verified artifact> OUT=<empty dir> LIB_SCRIPTS=<dir> \
#          JARSIGNER=<path> bash scripts/flutter_android_sign.sh
# ENVIRONMENT:
#   IN, OUT, LIB_SCRIPTS  As above; OUT must be empty.
#   JARSIGNER             Absolute path of jarsigner (when signing).
#   ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS,
#   ANDROID_KEY_PASSWORD  The upload key.
#   REQUIRE_SIGNING       true: refuse to copy unsigned (deploy_google_play).
# EXIT CODES:
#   0  Done.
#   1  A refusal or a jarsigner failure.
#   2  Usage error.
# ----------------------------------------------------
set -euo pipefail
export LC_ALL=C

fail() { echo "::error::$*" >&2; exit 1; }
[[ -n "${IN:-}" && -d "$IN/android" && ! -L "$IN/android" ]] || { echo "::error::IN has no android directory." >&2; exit 2; }
[[ "${OUT:-}" == /* && -d "$OUT" && ! -L "$OUT" && -z "$(ls -A "$OUT")" ]] || { echo "::error::OUT is not an empty absolute directory." >&2; exit 2; }
[[ -n "${LIB_SCRIPTS:-}" && -f "$LIB_SCRIPTS/zip_strip_signature.py" ]] || { echo "::error::LIB_SCRIPTS has no zip_strip_signature.py." >&2; exit 2; }

shopt -s nullglob
files=("$IN"/android/*)
shopt -u nullglob
[[ ${#files[@]} -gt 0 ]] || fail "the artifact holds no Android files."
for f in "${files[@]}"; do
  [[ -f "$f" && ! -L "$f" ]] || fail "'$f' is not a regular file."
  [[ "${f##*/}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,150}\.(aab|apk)$ ]] || fail "'${f##*/}' is not an .aab or .apk name."
done

set_count=0
for v in ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
  [[ -z "${!v:-}" ]] || set_count=$((set_count + 1))
done
if [[ "$set_count" != 4 ]]; then
  [[ "${REQUIRE_SIGNING:-false}" != true ]] || fail "deploy_google_play needs android_keystore_base64, android_keystore_password, android_key_alias and android_key_password."
  if [[ "$set_count" == 0 ]]; then
    echo "::warning::No Android signing secrets provided; the bundle keeps the project's own signing."
  else
    echo "::warning::Incomplete Android signing secrets: only some of the four are set, so the bundle keeps the project's own signing. Provide all four: android_keystore_base64, android_keystore_password, android_key_alias and android_key_password."
  fi
  cp -P -- "${files[@]}" "$OUT/"
  exit 0
fi

[[ "${JARSIGNER:-}" == /* && -x "$JARSIGNER" ]] || fail "JARSIGNER '${JARSIGNER:-}' is not an absolute path to a program."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
(umask 077 && printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 -d > "$work/upload.jks") || fail "android_keystore_base64 is not base64."
export ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_PASSWORD
for f in "${files[@]}"; do
  name="${f##*/}"
  [[ "$name" == *.aab ]] || fail "'$name': only .aab files are signed here (an .apk needs apksigner); build an app bundle."
  /usr/bin/python3 -I "$LIB_SCRIPTS/zip_strip_signature.py" "$f" "$work/$name"
  "$JARSIGNER" -keystore "$work/upload.jks" -storepass:env ANDROID_KEYSTORE_PASSWORD -keypass:env ANDROID_KEY_PASSWORD \
    -signedjar "$OUT/$name" "$work/$name" "$ANDROID_KEY_ALIAS" > "$work/sign.log" 2>&1 || { cat "$work/sign.log" >&2; fail "jarsigner could not sign $name."; }
  "$JARSIGNER" -verify "$OUT/$name" > "$work/verify.log" 2>&1 || { cat "$work/verify.log" >&2; fail "$name does not verify."; }
  grep -q '^jar verified' "$work/verify.log" || { cat "$work/verify.log" >&2; fail "$name does not verify."; }
  echo "signed: $name"
done
