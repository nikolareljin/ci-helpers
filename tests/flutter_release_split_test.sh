#!/usr/bin/env bash
# SCRIPT: flutter_release_split_test.sh
# DESCRIPTION: flutter-release.yml builds with no secret and signs and
#              uploads in sign-android and upload-app-store, which run no
#              caller code and only the library's fastlane. With stub tools
#              (jarsigner, ruby, plutil, security, xcodebuild) this checks:
#              zip_strip_signature.py drops the old signature and refuses
#              bad entry names; flutter_android_sign.sh signs each .aab,
#              copies unsigned only when allowed, refuses an .apk to sign,
#              a bad name and a symlink; flutter_play_upload.sh and
#              flutter_app_store_upload.sh refuse every malformed input
#              before fastlane runs, run fastlane from an empty directory,
#              pass only checked values, check the archive's bundle id and
#              remove the key files and keychain; install_fastlane.sh
#              installs only from the library's checksummed lockfile; and
#              the workflow checks the artifact name and the release inputs.
# USAGE: bash tests/flutter_release_split_test.sh
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
log="$work/calls.log"

mkaab() {  # mkaab FILE [extra entry]
  python3 - "$@" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for n in ("base/manifest/AndroidManifest.xml", "BUNDLE-METADATA/x", "META-INF/MANIFEST.MF",
              "META-INF/ANDROIDD.SF", "META-INF/ANDROIDD.RSA", "META-INF/services/keep.txt"):
        z.writestr(n, "x")
    for n in sys.argv[2:]:
        z.writestr(n, "x")
PY
}
names() { python3 -c 'import sys, zipfile; print(" ".join(sorted(zipfile.ZipFile(sys.argv[1]).namelist())))' "$1"; }

# ---------------------------------------------------------------- zip_strip_signature.py
mkaab "$work/a.aab"
python3 -I "$root/scripts/zip_strip_signature.py" "$work/a.aab" "$work/a.stripped.aab"
if [[ "$(names "$work/a.stripped.aab")" == "BUNDLE-METADATA/x META-INF/services/keep.txt base/manifest/AndroidManifest.xml" ]]; then
  ok "zip_strip_signature drops MANIFEST.MF, .SF and .RSA and keeps the rest"
else
  bad "zip_strip_signature kept: $(names "$work/a.stripped.aab")"
fi
for e in "../evil" "/abs" 'a\b'; do
  rm -f "$work/e.aab" "$work/e.out"
  mkaab "$work/e.aab" "$e"
  if python3 -I "$root/scripts/zip_strip_signature.py" "$work/e.aab" "$work/e.out" >/dev/null 2>&1; then bad "zip_strip_signature accepted entry '$e'"; else ok "zip_strip_signature refuses entry '$e'"; fi
done

# ---------------------------------------------------------------- flutter_android_sign.sh
stubs="$work/stubs"; mkdir -p "$stubs"
cat > "$stubs/jarsigner" <<EOF
#!/bin/bash
echo "jarsigner \$*" >> "$log"
if [[ "\$1" == -verify ]]; then [[ -n "\${JS_BAD_VERIFY:-}" ]] && echo "jar is unsigned." || echo "jar verified."; exit 0; fi
ks="\$2"; out=""; args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do [[ "\${args[i]}" == -signedjar ]] && out="\${args[i+1]}"; done
in="\${args[\${#args[@]}-2]}"
echo "keystore=\$(cat "\$ks") pw=\$ANDROID_KEYSTORE_PASSWORD entries=\$(python3 -c 'import sys,zipfile;print(",".join(sorted(zipfile.ZipFile(sys.argv[1]).namelist())))' "\$in")" >> "$log"
echo "kspath=\$ks" >> "$log"
cp "\$in" "\$out"
EOF
chmod +x "$stubs/jarsigner"
android_in() {
  rm -rf "$work/ain" "$work/aout" && mkdir -p "$work/ain/android" "$work/aout"
  : > "$log"
}
run_sign() {
  env -i PATH=/usr/bin:/bin HOME="$work" IN="$work/ain" OUT="$work/aout" LIB_SCRIPTS="$root/scripts" JARSIGNER="$stubs/jarsigner" "$@" \
    bash "$root/scripts/flutter_android_sign.sh" > "$work/sign.out" 2>&1
}
keys=(ANDROID_KEYSTORE_BASE64="$(printf 'KS' | base64)" ANDROID_KEYSTORE_PASSWORD=spw ANDROID_KEY_ALIAS=upload ANDROID_KEY_PASSWORD=kpw)

android_in; mkaab "$work/ain/android/app-release.aab"
if run_sign "${keys[@]}" && grep -q 'keystore=KS pw=spw entries=BUNDLE-METADATA/x,META-INF/services/keep.txt,base/manifest/AndroidManifest.xml' "$log" \
    && grep -q -- '-storepass:env ANDROID_KEYSTORE_PASSWORD -keypass:env ANDROID_KEY_PASSWORD' "$log" \
    && grep -q -- '-verify' "$log" && [[ -f "$work/aout/app-release.aab" ]] && ! grep -q 'spw\|kpw' <(grep '^jarsigner' "$log"); then
  ks="$(sed -n 's/^kspath=//p' "$log")"
  if [[ -e "$ks" ]]; then bad "the keystore $ks is left on disk"; else ok "android: stripped, signed with passwords from env, verified, keystore removed"; fi
else
  bad "android signing"; cat "$work/sign.out" "$log"
fi
android_in; mkaab "$work/ain/android/app-release.aab"
if run_sign && [[ -f "$work/aout/app-release.aab" ]] && ! grep -q '^jarsigner' "$log" && grep -q 'No Android signing secrets' "$work/sign.out"; then
  ok "android: no keystore, the bundle is copied as built with a warning"
else
  bad "android without a keystore"; cat "$work/sign.out"
fi
android_in; mkaab "$work/ain/android/app-release.aab"
if run_sign REQUIRE_SIGNING=true; then bad "deploy_google_play without a keystore passed"; else ok "android: deploy_google_play without a keystore is refused"; fi
android_in; mkaab "$work/ain/android/app-release.aab"
if run_sign ANDROID_KEYSTORE_PASSWORD=x && grep -q 'Incomplete Android signing secrets' "$work/sign.out" && ! grep -q '^jarsigner' "$log"; then
  ok "android: a partial keystore set warns and copies"
else
  bad "android partial keystore"
fi
android_in; mkaab "$work/ain/android/app-release.apk"
if run_sign "${keys[@]}"; then bad "an .apk was signed with jarsigner"; else ok "android: an .apk is refused for signing"; fi
android_in; mkaab "$work/ain/android/app-release.aab"
if run_sign "${keys[@]}" JS_BAD_VERIFY=1; then bad "a bundle that does not verify passed"; else ok "android: a bundle that does not verify fails"; fi
for n in 'a;b.aab' '$(id).aab' '-x.aab' 'x.zip'; do
  android_in; mkaab "$work/ain/android/$n"
  if run_sign "${keys[@]}"; then bad "android accepted the name '$n'"; else ok "android refuses the name '$n'"; fi
done
android_in; ln -s /etc/passwd "$work/ain/android/x.aab"
if run_sign; then bad "android copied a symlink"; else ok "android refuses a symlink"; fi
android_in; mkaab "$work/ain/android/app-release.aab"
if run_sign "${keys[@]}" ANDROID_KEYSTORE_BASE64='***not base64***'; then bad "a bad keystore base64 passed"; else ok "android: a keystore that is not base64 is refused"; fi

# ---------------------------------------------------------------- fastlane stubs
rb="$work/rubybin"; gems="$work/gems"; mkdir -p "$rb" "$gems/bundler/bin" "$gems/app"
: > "$gems/bundler/bin/bundle"; : > "$gems/app/Gemfile.lock"
# ruby <gems>/bundler/bin/bundle exec fastlane ARGS
cat > "$rb/ruby" <<EOF
#!/bin/bash
[[ "\$2 \$3" == "exec fastlane" ]] || { echo "not bundle exec fastlane: \$*" >> "$log"; exit 9; }
shift 3
echo "fastlane \$* | cwd-entries=\$(ls -A | wc -l) skip=\${FASTLANE_SKIP_UPDATE_CHECK:-} frozen=\${BUNDLE_FROZEN:-} gemfile=\${BUNDLE_GEMFILE:-unset}" >> "$log"
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
  case "\${args[i]}" in --json_key|--api_key_path) echo "keyfile=\${args[i+1]} content=\$(cat "\${args[i+1]}")" >> "$log" ;; esac
done
exit \${RUBY_RC:-0}
EOF
chmod +x "$rb/ruby"

# ---------------------------------------------------------------- flutter_play_upload.sh
mkdir -p "$work/play"; mkaab "$work/play/app.aab"
run_play() {
  : > "$log"
  env -i PATH=/usr/bin:/bin HOME="$work" DIR="$work/play" LIB_SCRIPTS="$root/scripts" RUBY_BIN="$rb" GEMS="$gems" \
    PACKAGE_NAME=com.example.app TRACK=internal RELEASE_STATUS=completed GOOGLE_PLAY_JSON='{"type":"service_account"}' "$@" \
    bash "$root/scripts/flutter_play_upload.sh" > "$work/play.out" 2>&1
}
if run_play && grep -q "^fastlane supply --aab $work/play/app.aab --package_name com.example.app --track internal --release_status completed --json_key .* | cwd-entries=0 skip=1 frozen=true gemfile=$gems/app/Gemfile" "$log" \
    && grep -q 'content={"type":"service_account"}' "$log"; then
  key="$(sed -n 's/^keyfile=\([^ ]*\) .*/\1/p' "$log")"
  if [[ -e "$key" ]]; then bad "the Play key $key is left on disk"; else ok "play: supply with checked values, from an empty directory, key removed"; fi
else
  bad "play upload"; cat "$work/play.out" "$log"
fi
for kv in 'PACKAGE_NAME=com.example;id' 'PACKAGE_NAME=$(id)' 'PACKAGE_NAME=noDots' 'TRACK=$(id)' 'TRACK=Internal' 'TRACK=a b' \
          'RELEASE_STATUS=bogus' 'RELEASE_STATUS=completed --x' 'GOOGLE_PLAY_JSON='; do
  if run_play "$kv"; then bad "play accepted $kv"; elif grep -q '^fastlane' "$log"; then bad "play ran fastlane with $kv"; else ok "play refuses $kv before fastlane runs"; fi
done
mkaab "$work/play/second.aab"
if run_play; then bad "play uploaded with two bundles"; else ok "play refuses two .aab files"; fi
rm "$work/play/second.aab"

# ---------------------------------------------------------------- flutter_app_store_upload.sh
cat > "$stubs/plutil" <<EOF
#!/bin/bash
echo "plutil \$*" >> "$log"
if [[ "\$1" == -extract ]]; then sed -n 's/^ID=//p' "\${@: -1}"; exit 0; fi
if [[ "\$1" == -lint ]]; then cp "\${@: -1}" "$work/exportOptions.copy"; exit 0; fi
exit 2
EOF
cat > "$stubs/security" <<EOF
#!/bin/bash
echo "security \$*" >> "$log"
EOF
cat > "$stubs/xcodebuild" <<EOF
#!/bin/bash
echo "xcodebuild \$*" >> "$log"
args=("\$@"); for ((i=0; i<\${#args[@]}; i++)); do [[ "\${args[i]}" == -exportPath ]] && : > "\${args[i+1]}/Runner.ipa"; done
true
EOF
chmod +x "$stubs"/*
ios_in() {  # ios_in BUNDLE_ID [extra tar spec]
  rm -rf "$work/iin" "$work/arch" && mkdir -p "$work/iin/ios" "$work/arch/Runner.xcarchive/Products/Applications/Runner.app"
  printf 'ID=%s\n' "$1" > "$work/arch/Runner.xcarchive/Products/Applications/Runner.app/Info.plist"
  [[ $# -lt 2 ]] || ln -s "$2" "$work/arch/Runner.xcarchive/escape"
  (cd "$work/arch" && tar -czf "$work/iin/ios/archive.tar.gz" Runner.xcarchive)
}
run_asc() {
  : > "$log"
  env -i PATH="$stubs:/usr/bin:/bin" HOME="$work" IN="$work/iin" LIB_SCRIPTS="$root/scripts" RUBY_BIN="$rb" GEMS="$gems" \
    BUNDLE_ID=com.example.app TEAM_ID=ABCDE12345 DESTINATION=testflight MATCH_GIT_URL=https://git.example/certs MATCH_PASSWORD=mpw \
    ASC_KEY_ID=KEY123 ASC_ISSUER_ID=issuer-1 ASC_KEY_BASE64="$(printf 'P8KEY' | base64)" "$@" \
    bash "$root/scripts/flutter_app_store_upload.sh" > "$work/asc.out" 2>&1
}
ios_in com.example.app
if run_asc; then
  order="$(awk '/^fastlane match appstore --readonly true --app_identifier com.example.app --team_id ABCDE12345 /{printf "M"} /^xcodebuild -exportArchive/{printf "X"} /^fastlane pilot upload --ipa .*Runner.ipa --api_key_path .* --skip_waiting_for_build_processing true/{printf "P"} /^security delete-keychain/{printf "D"}' "$log")"
  key="$(sed -n 's/^keyfile=\([^ ]*\) .*/\1/p' "$log")"
  if [[ "$order" == MXPD ]] && grep -q 'content={"key_id": "KEY123", "issuer_id": "issuer-1", "key": "P8KEY", "in_house": false}' "$log" \
      && grep -q '<key>com.example.app</key><string>match AppStore com.example.app</string>' "$work/exportOptions.copy" \
      && grep -q '<key>teamID</key><string>ABCDE12345</string>' "$work/exportOptions.copy" \
      && ! grep -q 'cwd-entries=[1-9]' "$log" && [[ ! -e "$key" ]]; then
    ok "app store: match, export, pilot, keychain deleted, key file removed, fastlane from an empty directory"
  else
    bad "app store order '$order'"; cat "$log"
  fi
else
  bad "app store upload"; cat "$work/asc.out"
fi
ios_in com.example.app
if run_asc DESTINATION=app_store && grep -q '^fastlane deliver --ipa .* --submit_for_review false' "$log" && ! grep -q '^fastlane pilot' "$log"; then
  ok "app store: app_store_destination app_store runs deliver without submitting"
else
  bad "app store deliver"; cat "$log"
fi
ios_in com.other.app
if run_asc; then bad "an archive of another bundle id was uploaded"; elif grep -q '^fastlane' "$log"; then bad "fastlane ran for the wrong bundle id"; else ok "app store refuses an archive whose bundle id differs"; fi
for kv in 'BUNDLE_ID=com.example.app</string><key>x' 'BUNDLE_ID=$(id)' 'BUNDLE_ID=single' 'TEAM_ID=abcde12345' 'TEAM_ID=ABCDE1234' \
          'DESTINATION=both' 'MATCH_PASSWORD=' 'ASC_KEY_ID='; do
  ios_in com.example.app
  if run_asc "$kv"; then bad "app store accepted $kv"; elif grep -q '^fastlane\|^xcodebuild\|^security create' "$log"; then bad "app store ran a tool with $kv"; else ok "app store refuses $kv before any tool runs"; fi
done
ios_in com.example.app /etc
if run_asc; then bad "an archive with an escaping symlink was used"; elif grep -q '^fastlane' "$log"; then bad "fastlane ran on an escaping archive"; else ok "app store refuses an archive with a symlink out of it"; fi

# ---------------------------------------------------------------- install_fastlane.sh
# Stub curl serves a fake bundler.gem; the test pins its sha256. Stub ruby
# plays gem and bundle. The real checksum check is Bundler's (2.6+).
gb="$work/gembin"; cb="$work/curlbin"; mkdir -p "$gb" "$cb"
printf 'fake bundler gem' > "$work/bundler.gem"
fake_sha="$(sha256sum "$work/bundler.gem" | cut -d' ' -f1)"
cat > "$cb/curl" <<EOF
#!/bin/bash
args=("\$@"); for ((i=0; i<\${#args[@]}; i++)); do [[ "\${args[i]}" == -o ]] && cp "$work/bundler.gem" "\${args[i+1]}"; done
echo "curl \$*" >> "$work/gem.log"
true
EOF
cat > "$gb/ruby" <<EOF
#!/bin/bash
echo "ruby \$* cwd-entries=\$(ls -A | wc -l) frozen=\${BUNDLE_FROZEN:-} gemfile=\${BUNDLE_GEMFILE:-unset}" >> "$work/gem.log"
args=("\$@"); for ((i=0; i<\${#args[@]}; i++)); do [[ "\${args[i]}" == --bindir ]] && mkdir -p "\${args[i+1]}" && : > "\${args[i+1]}/bundle"; done
true
EOF
: > "$gb/gem"; chmod +x "$gb/ruby" "$cb/curl"
fv="$(awk -F= '$1 == "FASTLANE_VERSION" { print $2 }' "$root/toolchain-pins.env")"
bv="$(awk -F= '$1 == "BUNDLER_VERSION" { print $2 }' "$root/toolchain-pins.env")"
mkpins() { printf 'FASTLANE_VERSION=%s\nBUNDLER_VERSION=%s\nBUNDLER_GEM_SHA256=%s\n' "$fv" "$bv" "${1:-$fake_sha}" > "$work/pins.env"; }
lockcopy() { rm -rf "$work/lock" && mkdir "$work/lock" && cp "$root/scripts/fastlane/Gemfile" "$root/scripts/fastlane/Gemfile.lock" "$work/lock/"; }
inst() {  # inst GEMS_NAME: run with the test pins and lock copy
  : > "$work/gem.log"
  env -i PATH="$cb:/usr/bin:/bin" RUBY_BIN="$gb" GEMS="$work/$1" TOOLCHAIN_PINS="$work/pins.env" FASTLANE_LOCK_DIR="$work/lock" \
    BUNDLE_GEMFILE=/x/Gemfile bash "$root/scripts/install_fastlane.sh" > "$work/inst.out" 2>&1
}
mkpins; lockcopy
if inst fl && [[ "$(tail -1 "$work/inst.out")" == "gems=$work/fl" ]] \
    && grep -q "^ruby $gb/gem install --local .*bundler.gem -N --install-dir $work/fl/bundler" "$work/gem.log" \
    && grep -q "^ruby $work/fl/bundler/bin/bundle _${bv}_ install --jobs 4 cwd-entries=0 frozen=true gemfile=$work/fl/app/Gemfile$" "$work/gem.log" \
    && cmp -s "$work/fl/app/Gemfile.lock" "$root/scripts/fastlane/Gemfile.lock"; then
  ok "install_fastlane: checked bundler, frozen bundle install of the library lockfile from an empty directory"
else
  bad "install_fastlane"; cat "$work/inst.out" "$work/gem.log"
fi
n=0
irefuse() {  # irefuse LABEL PYTHON (edits lock/Gemfile.lock as s)
  n=$((n + 1)); mkpins; lockcopy
  python3 - "$work/lock/Gemfile.lock" "$2" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
exec(sys.argv[2])
open(p, "w").write(s)
PY
  if inst "r$n"; then bad "install_fastlane accepted: $1"
  elif grep -q 'bundle _' "$work/gem.log"; then bad "install_fastlane ran bundle install with: $1"
  else ok "install_fastlane refuses: $1"; fi
}
irefuse "a second source" 's = s.replace("  remote: https://rubygems.org/\n", "  remote: https://rubygems.org/\n", 1) + "\nGEM\n  remote: https://gems.example/\n  specs:\n    x (1.0)\n"'
irefuse "another remote" 's = s.replace("remote: https://rubygems.org/", "remote: https://gems.example/", 1)'
irefuse "a GIT section" 's = "GIT\n  remote: https://github.com/x/y\n  revision: 0\n  specs:\n    y (1.0)\n\n" + s'
irefuse "a locked gem with no checksum" 's = s.replace("  specs:\n", "  specs:\n    unlocked-extra (9.9.9)\n", 1)'
irefuse "a checksum that is not 64 hex" 's = re.sub(r"sha256=[0-9a-f]{64}", "sha256=abc", s, count=1)'
irefuse "a checksum line with no sha256" 's = re.sub(r" sha256=[0-9a-f]{64}", "", s, count=1)'
irefuse "another fastlane version" 's = re.sub(r"^    fastlane \([^)]*\)$", "    fastlane (0.0.1)", s, flags=re.M)'
mkpins; lockcopy; printf 'source "https://rubygems.org"\n\ngem "fastlane", ">= 0"' > "$work/lock/Gemfile"
if inst g1; then bad "an unpinned Gemfile was accepted"; else ok "install_fastlane refuses a Gemfile that does not pin FASTLANE_VERSION"; fi
mkpins "$(printf '%064d' 0)"; lockcopy
if inst g2; then bad "a bundler.gem with another sha256 was installed"; elif grep -q 'gem install' "$work/gem.log"; then bad "bundler was installed before its digest matched"; else ok "install_fastlane refuses a bundler.gem whose sha256 differs"; fi
mkpins; lockcopy; mkdir -p "$work/exists"
rc=0; inst exists || rc=$?
[[ "$rc" == 2 ]] && ok "install_fastlane refuses an existing GEMS" || bad "install_fastlane over an existing GEMS exited $rc"
# The shipped lockfile: rubygems.org only, one sha256 per locked gem.
specs="$(awk '/^GEM$/{f=1;next} /^[A-Z]/{f=0} f && /^    [^ ]/{print $1, $2}' "$root/scripts/fastlane/Gemfile.lock" | sort -u)"
sums="$(awk '/^CHECKSUMS$/{f=1;next} /^$/{f=0} f && / sha256=[0-9a-f]{64}$/{print $1, $2}' "$root/scripts/fastlane/Gemfile.lock" | sort -u)"
[[ -n "$specs" && "$specs" == "$sums" ]] && ok "scripts/fastlane/Gemfile.lock has a sha256 for each of its $(wc -l <<< "$specs") gems" || bad "scripts/fastlane/Gemfile.lock lacks checksums"

# ---------------------------------------------------------------- the workflow
python3 - "$root/.github/workflows/flutter-release.yml" "$work" > "$work/wf.out" 2>&1 <<'PY' || { bad "workflow:"; cat "$work/wf.out"; }
import re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
jobs = wf["jobs"]
inputs = wf["on"]["workflow_call"]["inputs"] if "on" in wf else wf[True]["workflow_call"]["inputs"]
problems = []
for gone in ("fastlane_android_lane", "fastlane_ios_lane"):
    if gone in inputs:
        problems.append(f"input {gone} is still accepted; no caller lane runs")
if set(jobs) != {"build", "sign-android", "upload-app-store"}:
    problems.append(f"jobs are {sorted(jobs)}")
if jobs["build"].get("permissions") != {"contents": "read"}:
    problems.append("build permissions are not contents: read")
for j, cond, runner in (("sign-android", "${{ inputs.build_android }}", "${{ inputs.android_sign_runner }}"),
                        ("upload-app-store", "${{ inputs.deploy_app_store }}", "${{ inputs.app_store_runner }}")):
    job = jobs[j]
    if job.get("needs") != "build" or job.get("if") != cond or job.get("runs-on") != runner:
        problems.append(f"{j}: needs/if/runs-on are {job.get('needs')}, {job.get('if')}, {job.get('runs-on')}")
    for s in job["steps"]:
        if str(s.get("uses", "")).startswith("actions/checkout@") and (s.get("with") or {}).get("repository") != "${{ job.workflow_repository }}":
            problems.append(f"{j} checks out the caller's repository")
        if re.search(r"\bflutter |\bbundle |\bfastlane |eval |gradle", str(s.get("run") or "")):
            problems.append(f"{j} step '{s.get('name')}' runs a build or caller tool directly")
    names = [s.get("name") for s in job["steps"]]
    if not (names.index("Check the build outputs") < names.index("Download the build output") < names.index("Verify the build output against its manifest")):
        problems.append(f"{j} does not check, download, then verify")
for j in ("sign-android", "upload-app-store"):
    s = next(s for s in jobs[j]["steps"] if s.get("name") == "Check the build outputs")
    open(f"{sys.argv[2]}/{j}.check.sh", "w").write(s["run"])
s = next(s for s in jobs["build"]["steps"] if s.get("name") == "Check the release inputs")
open(f"{sys.argv[2]}/inputs.check.sh", "w").write(s["run"])
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
[[ -s "$work/wf.out" ]] || ok "workflow: three jobs, privileged ones check, download and verify and run no caller tool"
for j in sign-android upload-app-store; do
  if ARTIFACT="flutter-release-build-9-1-0123456789abcdef" MANIFEST=x bash "$work/$j.check.sh" >/dev/null 2>&1; then ok "$j accepts its build artifact name"; else bad "$j refused its own artifact name"; fi
  for a in "flutter-android" "flutter-release-build-9-1-0123456789abcdef/../x" 'x$(id)' "flutter-release-build-9-1-0123456789ABCDEF"; do
    if ARTIFACT="$a" MANIFEST=x bash "$work/$j.check.sh" >/dev/null 2>&1; then bad "$j accepted '$a'"; else ok "$j refuses artifact name '$a'"; fi
  done
done
inputs_ok=(BUILD_ANDROID=true DEPLOY_GOOGLE_PLAY=true DEPLOY_APP_STORE=true PACKAGE_NAME=com.example.app TRACK=internal
           RELEASE_STATUS=completed BUNDLE_ID=com.example.app TEAM_ID=ABCDE12345 DESTINATION=testflight RUNNER_OS=macOS)
if env "${inputs_ok[@]}" bash "$work/inputs.check.sh" >/dev/null 2>&1; then ok "build accepts good release inputs"; else bad "build refused good release inputs"; fi
for kv in BUILD_ANDROID=false 'PACKAGE_NAME=com.x;y' 'TRACK=$(id)' RELEASE_STATUS=x 'BUNDLE_ID=a b.c' TEAM_ID=x DESTINATION=x RUNNER_OS=Linux; do
  if env "${inputs_ok[@]}" "$kv" bash "$work/inputs.check.sh" >/dev/null 2>&1; then bad "build accepted $kv"; else ok "build refuses $kv"; fi
done

exit "$fail"
