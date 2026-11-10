#!/usr/bin/env bash
# SCRIPT: setup_flutter_test.sh
# DESCRIPTION: scripts/setup_flutter.sh resolves channel, version and
#              architecture from the release manifest the way the replaced
#              action did, installs the pinned release when no version is
#              given on stable and refuses when the manifest's digest for it
#              is not the pin, checks every download against the manifest's
#              sha256, refuses the git-only channels, reuses a verified SDK,
#              resolves without installing on a dry run, and writes PATH,
#              env and outputs. curl and uname are stubs; the manifests and
#              archives are fixtures built here; nothing is downloaded.
#              Runs under bash 3.2 (macOS runners).
# USAGE: bash tests/setup_flutter_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/setup_flutter.sh"
pins="$root/toolchain-pins.env"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# The shipped pins file: a release and a 64-hex digest for each hosted
# platform the workflows run on.
shipped="$(awk -F= '$1 == "FLUTTER_VERSION" { print $2 }' "$pins")"
[[ "$shipped" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL FLUTTER_VERSION is '$shipped'"; fail=1; }
for k in LINUX_X64 MACOS_X64 MACOS_ARM64 WINDOWS_X64; do
  d="$(awk -F= -v k="FLUTTER_SHA256_$k" '$1 == k { print $2 }' "$pins")"
  [[ "$d" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL FLUTTER_SHA256_$k is '$d', not 64 hex"; fail=1; }
done

# Fixture archives: flutter/bin/flutter that prints its version.
mkdir -p "$work/files/stable/linux" "$work/files/stable/macos" "$work/files/stable/windows" "$work/files/beta/linux" "$work/src"
# archive <relative path> <version>
archive() {
  local dir
  dir="$work/src/$(basename "$1")"
  mkdir -p "$dir/flutter/bin"
  printf '#!/usr/bin/env bash\necho "Flutter %s"\n' "$2" > "$dir/flutter/bin/flutter"
  chmod +x "$dir/flutter/bin/flutter"
  case "$1" in
    *.zip) (cd "$dir" && zip -q -r "$work/files/$1" flutter) ;;
    *) tar -C "$dir" -cJf "$work/files/$1" flutter ;;
  esac
}
archive stable/linux/flutter_linux_3.47.9-stable.tar.xz 3.47.9
archive stable/linux/flutter_linux_3.47.8-stable.tar.xz 3.47.8
archive stable/linux/flutter_linux_3.46.1-stable.tar.xz 3.46.1
archive stable/linux/flutter_linux_3.3.0-stable.tar.xz 3.3.0
archive beta/linux/flutter_linux_3.50.0-0.4.pre-beta.tar.xz 3.50.0-0.4.pre
archive stable/macos/flutter_macos_arm64_3.47.9-stable.zip 3.47.9
archive stable/macos/flutter_macos_3.47.9-stable.zip 3.47.9
archive stable/windows/flutter_windows_3.47.9-stable.zip 3.47.9
archive stable/windows/flutter_windows_3.47.8-stable.zip 3.47.8
sha() { sha256sum < "$1" | awk '{ print $1 }'; }
# One sha256 is wrong on purpose: the manifest lies about 3.46.1.
cat > "$work/files/releases_linux.json" <<EOF
{"base_url": "https://storage.googleapis.com/flutter_infra_release/releases",
 "current_release": {"beta": "bbb", "stable": "aaa"},
 "releases": [
  {"hash": "bbb", "channel": "beta", "version": "3.50.0-0.4.pre", "dart_sdk_arch": "x64", "archive": "beta/linux/flutter_linux_3.50.0-0.4.pre-beta.tar.xz", "sha256": "$(sha "$work/files/beta/linux/flutter_linux_3.50.0-0.4.pre-beta.tar.xz")"},
  {"hash": "aaa", "channel": "stable", "version": "3.47.9", "dart_sdk_arch": "x64", "archive": "stable/linux/flutter_linux_3.47.9-stable.tar.xz", "sha256": "$(sha "$work/files/stable/linux/flutter_linux_3.47.9-stable.tar.xz")"},
  {"hash": "888", "channel": "stable", "version": "3.47.8", "dart_sdk_arch": "x64", "archive": "stable/linux/flutter_linux_3.47.8-stable.tar.xz", "sha256": "$(sha "$work/files/stable/linux/flutter_linux_3.47.8-stable.tar.xz")"},
  {"hash": "461", "channel": "stable", "version": "3.46.1", "dart_sdk_arch": "x64", "archive": "stable/linux/flutter_linux_3.46.1-stable.tar.xz", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"},
  {"hash": "330", "channel": "stable", "version": "v3.3.0", "archive": "stable/linux/flutter_linux_3.3.0-stable.tar.xz", "sha256": "$(sha "$work/files/stable/linux/flutter_linux_3.3.0-stable.tar.xz")"},
  {"hash": "arm", "channel": "stable", "version": "3.47.9", "dart_sdk_arch": "arm64", "archive": "stable/linux/flutter_linux_arm64_3.47.9-stable.tar.xz", "sha256": "$(sha "$work/files/stable/linux/flutter_linux_3.47.9-stable.tar.xz")"}
 ]}
EOF
cat > "$work/files/releases_macos.json" <<EOF
{"base_url": "https://storage.googleapis.com/flutter_infra_release/releases",
 "current_release": {"stable": "aaa"},
 "releases": [
  {"hash": "aaa", "channel": "stable", "version": "3.47.9", "dart_sdk_arch": "x64", "archive": "stable/macos/flutter_macos_3.47.9-stable.zip", "sha256": "$(sha "$work/files/stable/macos/flutter_macos_3.47.9-stable.zip")"},
  {"hash": "aaa", "channel": "stable", "version": "3.47.9", "dart_sdk_arch": "arm64", "archive": "stable/macos/flutter_macos_arm64_3.47.9-stable.zip", "sha256": "$(sha "$work/files/stable/macos/flutter_macos_arm64_3.47.9-stable.zip")"}
 ]}
EOF
cat > "$work/files/releases_windows.json" <<EOF
{"base_url": "https://storage.googleapis.com/flutter_infra_release/releases",
 "current_release": {"stable": "aaa"},
 "releases": [
  {"hash": "aaa", "channel": "stable", "version": "3.47.9", "dart_sdk_arch": "x64", "archive": "stable/windows/flutter_windows_3.47.9-stable.zip", "sha256": "$(sha "$work/files/stable/windows/flutter_windows_3.47.9-stable.zip")"},
  {"hash": "888", "channel": "stable", "version": "3.47.8", "dart_sdk_arch": "x64", "archive": "stable/windows/flutter_windows_3.47.8-stable.zip", "sha256": "$(sha "$work/files/stable/windows/flutter_windows_3.47.8-stable.zip")"},
  {"hash": "evil", "channel": "beta", "version": "3.50.0-0.4.pre", "dart_sdk_arch": "x64", "archive": "../../../etc/flutter.zip", "sha256": "$(sha "$work/files/stable/windows/flutter_windows_3.47.8-stable.zip")"}
 ]}
EOF

# Test pins: the linux and macOS arm64 digests are the fixtures'; the macOS
# x64 one disagrees with the manifest; Windows has none.
cat > "$work/pins.env" <<EOF
FLUTTER_VERSION=3.47.9
FLUTTER_SHA256_LINUX_X64=$(sha "$work/files/stable/linux/flutter_linux_3.47.9-stable.tar.xz")
FLUTTER_SHA256_MACOS_X64=1111111111111111111111111111111111111111111111111111111111111111
FLUTTER_SHA256_MACOS_ARM64=$(sha "$work/files/stable/macos/flutter_macos_arm64_3.47.9-stable.zip")
EOF

# Stubs: curl serves files/<path under the releases URL>; uname answers from
# the environment so the platform mapping is exercised on one machine.
mkdir -p "$work/stub"
cat > "$work/stub/curl" <<'STUB'
#!/usr/bin/env bash
url=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
printf '%s\n' "$url" >> "$STUB_LOG"
rel="${url#https://storage.googleapis.com/flutter_infra_release/releases/}"
[ -f "$STUB_FILES/$rel" ] || { echo "curl: (22) not found: $url" >&2; exit 22; }
cp "$STUB_FILES/$rel" "$out"
STUB
cat > "$work/stub/uname" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -s) echo "${STUB_UNAME_S:-Linux}" ;;
  -m) echo "${STUB_UNAME_M:-x86_64}" ;;
  *) echo Linux ;;
esac
STUB
chmod +x "$work/stub/curl" "$work/stub/uname"

# run <name> <rc> <FLUTTER_VERSION> [FLUTTER_CHANNEL] [RUNNER_ARCH]
run() {
  local name="$1" want="$2" rc=0
  rm -rf "${work:?}/gh"; mkdir -p "$work/gh"; : > "$work/log"
  PATH="$work/stub:$PATH" STUB_LOG="$work/log" STUB_FILES="$work/files" \
    FLUTTER_VERSION="$3" FLUTTER_CHANNEL="${4-}" RUNNER_ARCH="${5-X64}" \
    FLUTTER_INSTALL_ROOT="$work/sdk" RUNNER_TOOL_CACHE="$work/unused" \
    TOOLCHAIN_PINS="${TEST_PINS:-$work/pins.env}" RUNNER_TEMP="$work" HOME="$work/home" \
    GITHUB_PATH="$work/gh/path" GITHUB_ENV="$work/gh/env" GITHUB_OUTPUT="$work/gh/out" \
    "$BASH" "$script" > "$work/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 1
  fi
}
says() {
  grep -qF -- "$1" "$work/out" || { echo "FAIL $name: no '$1' in output:"; cat "$work/out"; fail=1; }
}
fetched() {
  grep -qxF -- "https://storage.googleapis.com/flutter_infra_release/releases/$1" "$work/log" || { echo "FAIL $name: curl was not asked for $1:"; cat "$work/log"; fail=1; }
}
not_fetched() {
  grep -q -- "$1" "$work/log" && { echo "FAIL $name: $1 was downloaded"; fail=1; }
  return 0
}
output() {
  grep -q "^$1=$2$" "$work/gh/out" || { echo "FAIL $name: output $1 is not '$2':"; cat "$work/gh/out"; fail=1; }
}
# installed <channel> <version> <arch> <os>: env, PATH and the launcher.
installed() {
  local sdk="$work/sdk/$1-$2-$3"
  output channel "$1"; output version "$2"; output arch "$3"
  output flutter_root "$sdk/flutter"; output cache_path "$sdk"
  grep -q "^FLUTTER_ROOT=$sdk/flutter$" "$work/gh/env" || { echo "FAIL $name: FLUTTER_ROOT not in GITHUB_ENV:"; cat "$work/gh/env"; fail=1; }
  grep -qxF "$sdk/flutter/bin" "$work/gh/path" || { echo "FAIL $name: flutter/bin not on GITHUB_PATH:"; cat "$work/gh/path"; fail=1; }
  grep -qxF "$sdk/flutter/bin/cache/dart-sdk/bin" "$work/gh/path" || { echo "FAIL $name: dart-sdk/bin not on GITHUB_PATH"; fail=1; }
  [[ "$("$sdk/flutter/bin/flutter")" == "Flutter $2" ]] || { echo "FAIL $name: the launcher under $sdk reports '$("$sdk/flutter/bin/flutter")'"; fail=1; }
  [[ -f "$sdk/.sha256" ]] || { echo "FAIL $name: no digest marker under $sdk"; fail=1; }
}

name="no version on stable installs the pinned release"
run "$name" 0 "" && installed stable 3.47.9 x64 && output pinned true \
  && output cache_key flutter-linux-stable-3.47.9-x64-aaa \
  && fetched releases_linux.json && fetched stable/linux/flutter_linux_3.47.9-stable.tar.xz \
  && says "installing the release pinned in $work/pins.env, 3.47.9" && says "Verified flutter_linux_3.47.9-stable.tar.xz"
grep -q "^PUB_CACHE=$work/home/.pub-cache$" "$work/gh/env" || { echo "FAIL $name: PUB_CACHE not in GITHUB_ENV:"; cat "$work/gh/env"; fail=1; }
grep -qxF "$work/home/.pub-cache/bin" "$work/gh/path" || { echo "FAIL $name: pub cache bin not on GITHUB_PATH"; fail=1; }
[[ -z "$(ls -d "$work"/flutter.* 2>/dev/null)" ]] || { echo "FAIL $name: the download directory was kept"; fail=1; }

name="a verified SDK is reused without a download"
run "$name" 0 "" && installed stable 3.47.9 x64 && not_fetched flutter_linux && says "already under"

name="an SDK whose recorded digest is not the expected one is replaced"
printf 'deadbeef\n' > "$work/sdk/stable-3.47.9-x64/.sha256"
run "$name" 0 "" && installed stable 3.47.9 x64 && fetched stable/linux/flutter_linux_3.47.9-stable.tar.xz

name="a job's own PUB_CACHE is kept"
rm -rf "${work:?}/gh"; mkdir -p "$work/gh"; : > "$work/log"
PUB_CACHE="$work/pub" PATH="$work/stub:$PATH" STUB_LOG="$work/log" STUB_FILES="$work/files" FLUTTER_VERSION="" \
  FLUTTER_INSTALL_ROOT="$work/sdk" TOOLCHAIN_PINS="$work/pins.env" RUNNER_TEMP="$work" HOME="$work/home" \
  GITHUB_PATH="$work/gh/path" GITHUB_ENV="$work/gh/env" "$BASH" "$script" > "$work/out" 2>&1 || { echo "FAIL $name: exit $?"; cat "$work/out"; fail=1; }
grep -q "PUB_CACHE" "$work/gh/env" && { echo "FAIL $name: PUB_CACHE written to GITHUB_ENV"; fail=1; }
grep -qxF "$work/pub/bin" "$work/gh/path" || { echo "FAIL $name: the job's pub cache bin is not on GITHUB_PATH"; cat "$work/gh/path"; fail=1; }

name="an exact version is checked against the manifest's sha256"
run "$name" 0 3.47.8 && installed stable 3.47.8 x64 && output pinned false \
  && output cache_key flutter-linux-stable-3.47.8-x64-888 && fetched stable/linux/flutter_linux_3.47.8-stable.tar.xz
[[ -d "$work/sdk/stable-3.47.9-x64" ]] || { echo "FAIL $name: another release's SDK was removed"; fail=1; }

name="X.Y and X.Y.x pick the newest matching release"
run "$name" 0 3.47 && installed stable 3.47.9 x64
run "$name" 0 3.47.x && installed stable 3.47.9 x64
# 3.46 resolves to 3.46.1, whose manifest digest is wrong on purpose.
run "$name" 1 3.46 && says "Checksum mismatch for flutter_linux_3.46.1-stable.tar.xz"

name="a download whose sha256 is not the manifest's is refused and removed"
run "$name" 1 3.46.1 && says "Checksum mismatch for flutter_linux_3.46.1-stable.tar.xz: expected 0000000000000000000000000000000000000000000000000000000000000000"
[[ -e "$work/sdk/stable-3.46.1-x64/flutter" ]] && { echo "FAIL $name: the SDK directory holds an unverified SDK"; fail=1; }
[[ -z "$(ls -d "$work"/flutter.* 2>/dev/null)" ]] || { echo "FAIL $name: the download directory was kept"; fail=1; }

name="a v prefix in the manifest or the request is dropped"
run "$name" 0 3.3.0 && installed stable 3.3.0 x64
run "$name" 0 v3.3.0 && installed stable 3.3.0 x64

name="an entry without dart_sdk_arch is x64 and not arm64"
run "$name" 1 3.3.0 "" ARM64 && says "Unable to determine Flutter version for channel: stable version: 3.3.0 architecture: arm64"

name="a version the manifest lacks"
run "$name" 1 3.99 && not_fetched flutter_linux && says "Unable to determine Flutter version for channel: stable version: 3.99 architecture: x64"

name="a channel without a version installs its newest release"
run "$name" 0 "" beta && installed beta 3.50.0-0.4.pre x64 && output pinned false

name="a channel name as the version is the channel; a given channel wins"
run "$name" 0 beta && installed beta 3.50.0-0.4.pre x64
run "$name" 0 stable beta && installed beta 3.50.0-0.4.pre x64
run "$name" 0 stable && installed stable 3.47.9 x64 && output pinned true

name="master and main are refused"
run "$name" 2 "" master && not_fetched releases && says "FLUTTER_CHANNEL 'master' is a git clone"
run "$name" 2 main && not_fetched releases && says "FLUTTER_CHANNEL 'main' is a git clone"

name="another channel is refused"
run "$name" 2 "" nightly && not_fetched releases && says "FLUTTER_CHANNEL 'nightly' is not stable, beta or dev"

name="a version that is not one"
run "$name" 2 "3.47; rm -rf /" && not_fetched releases && says "is not a version"

name="an http mirror is refused"
FLUTTER_STORAGE_BASE_URL=http://mirror.example run "$name" 2 "" && not_fetched releases && says "is not an https URL"

name="a dry run resolves and installs nothing"
rm -rf "${work:?}/sdk"
FLUTTER_DRY_RUN=true run "$name" 0 "" && output version 3.47.9 && output cache_key flutter-linux-stable-3.47.9-x64-aaa \
  && output cache_path "$work/sdk/stable-3.47.9-x64" && output pinned true && not_fetched flutter_linux && says "not installing (dry run)"
[[ -e "$work/sdk" ]] && { echo "FAIL $name: the dry run created $work/sdk"; fail=1; }
[[ -s "$work/gh/path" || -s "$work/gh/env" ]] && { echo "FAIL $name: the dry run wrote PATH or env"; fail=1; }
FLUTTER_DRY_RUN=maybe run "$name" 2 "" && says "FLUTTER_DRY_RUN is 'maybe'"

name="the pinned release whose manifest digest is not the pin is refused"
STUB_UNAME_S=Darwin run "$name" 1 "" && not_fetched flutter_macos \
  && says "The manifest's sha256 for Flutter 3.47.9 (macos x64) is" && says "pins 1111111111111111111111111111111111111111111111111111111111111111"

name="macOS arm64 picks the arm64 archive, a zip"
STUB_UNAME_S=Darwin run "$name" 0 "" "" ARM64 && installed stable 3.47.9 arm64 && output pinned true \
  && fetched releases_macos.json && fetched stable/macos/flutter_macos_arm64_3.47.9-stable.zip
STUB_UNAME_S=Darwin STUB_UNAME_M=arm64 run "$name" 0 "" "" "" && installed stable 3.47.9 arm64

name="the pinned release with no pin for the platform is refused"
STUB_UNAME_S=MINGW64_NT-10.0 run "$name" 2 "" && not_fetched flutter_windows \
  && says "No 64-hex sha256 pinned for Flutter 3.47.9 on windows x64 (FLUTTER_SHA256_WINDOWS_X64"

name="Windows: another release installs from the manifest's digest, with the Windows pub cache"
STUB_UNAME_S=MINGW64_NT-10.0 LOCALAPPDATA='C:\Users\r\AppData\Local' run "$name" 0 3.47.8 && installed stable 3.47.8 x64 \
  && fetched releases_windows.json && fetched stable/windows/flutter_windows_3.47.8-stable.zip
grep -q '^PUB_CACHE=C:\\Users\\r\\AppData\\Local\\Pub\\Cache$' "$work/gh/env" || { echo "FAIL $name: Windows PUB_CACHE:"; cat "$work/gh/env"; fail=1; }

name="an archive path that leaves the release tree is refused"
STUB_UNAME_S=MINGW64_NT-10.0 run "$name" 1 "" beta && not_fetched etc && says "leaves the release tree: '../../../etc/flutter.zip'"

name="another OS is refused"
STUB_UNAME_S=FreeBSD run "$name" 2 "" && not_fetched releases && says "Unsupported runner OS 'FreeBSD'"

name="an architecture that is neither is refused"
run "$name" 2 "" "" s390x && not_fetched releases && says "Unsupported architecture 's390x'"

name="a pins file without FLUTTER_VERSION"
printf 'RUSTUP_VERSION=1.0.0\n' > "$work/bare.env"
TEST_PINS="$work/bare.env" run "$name" 2 "" && not_fetched releases && says "FLUTTER_VERSION in $work/bare.env is ''"
TEST_PINS="$work/none.env" run "$name" 2 "" && says "Pins file $work/none.env is not readable"

name="the tool cache is the default root"
rm -rf "${work:?}/gh"; mkdir -p "$work/gh"; : > "$work/log"
PATH="$work/stub:$PATH" STUB_LOG="$work/log" STUB_FILES="$work/files" FLUTTER_VERSION="" FLUTTER_DRY_RUN=true \
  RUNNER_TOOL_CACHE="$work/toolcache" TOOLCHAIN_PINS="$work/pins.env" RUNNER_TEMP="$work" HOME="$work/home" \
  GITHUB_OUTPUT="$work/gh/out" "$BASH" "$script" > "$work/out" 2>&1 || { echo "FAIL $name: exit $?"; cat "$work/out"; fail=1; }
output cache_path "$work/toolcache/flutter/stable-3.47.9-x64"

[[ "$fail" = 0 ]] && echo "ok: setup_flutter resolves as the action did, pins the default release, checks every download, refuses git channels and reuses a verified SDK"
exit "$fail"
