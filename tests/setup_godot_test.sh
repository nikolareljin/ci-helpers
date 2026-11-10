#!/usr/bin/env bash
# SCRIPT: setup_godot_test.sh
# DESCRIPTION: scripts/setup_godot.sh names the release archive the replaced
#              action named for each version, variant, OS and architecture,
#              refuses a release the pins file does not list before any
#              download, refuses a download whose sha256 is not the pinned
#              one, links the one editor the archive holds, reuses a cached
#              archive only after its sha256 matches and rebuilds the
#              install from it every run, and writes PATH, env and outputs. curl and
#              uname are stubs; the archives are fixtures built here;
#              nothing is downloaded. Runs under bash 3.2 (macOS runners).
# USAGE: bash tests/setup_godot_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/setup_godot.sh"
pins="$root/toolchain-pins.env"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# The shipped pins file: the godot.yml default (4.3.0, the 4.3-stable
# release) is pinned for both variants on the three hosted platforms, and
# every Godot digest is 64 hex.
for k in LINUX_X86_64 MONO_LINUX_X86_64 MACOS_UNIVERSAL MONO_MACOS_UNIVERSAL WIN64_EXE MONO_WIN64; do
  d="$(awk -F= -v k="GODOT_SHA256_4_3_STABLE_$k" '$1 == k { print $2 }' "$pins")"
  [[ "$d" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL GODOT_SHA256_4_3_STABLE_$k is '$d', not 64 hex"; fail=1; }
done
while IFS='=' read -r k v; do
  [[ "$v" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL $k is '$v', not 64 hex"; fail=1; }
done < <(grep '^GODOT_SHA256_' "$pins")
default="$(awk '/^      godot_version:/ { f = 1; next } f && /^        default:/ { gsub(/[" ]/, "", $2); print $2; exit } f && /^      [a-z]/ { exit }' "$root/.github/workflows/godot.yml")"
[[ "$default" == 4.3.0 ]] || { echo "FAIL godot.yml's default godot_version is '$default'; this test pins 4.3.0"; fail=1; }

# Fixture archives, laid out as the release zips are: an editor that prints
# its version, in a mono directory beside GodotSharp for the .NET build.
mkdir -p "$work/files" "$work/src"
editor_script() {
  # shellcheck disable=SC2016  # the $@ is for the editor stub, not this shell
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = --version ]; then echo "%s"; exit 0; fi\necho "godot" "$@"\n' "$1"
}
# zip <name> <entry>=<reported version>...  builds files/<name>.zip
mkzip() {
  local name="$1"; shift
  local dir="$work/src/$name"
  mkdir -p "$dir"
  local e
  for e in "$@"; do
    mkdir -p "$dir/$(dirname "${e%%=*}")"
    case "${e%%=*}" in
      *GodotSharp.dll) printf 'dll\n' > "$dir/${e%%=*}" ;;
      *) editor_script "${e#*=}" > "$dir/${e%%=*}"; chmod +x "$dir/${e%%=*}" ;;
    esac
  done
  (cd "$dir" && zip -q -r "$work/files/$name.zip" .)
}
mkzip Godot_v4.3-stable_linux.x86_64 "Godot_v4.3-stable_linux.x86_64=4.3.stable.official.77dcf97d8"
mkzip Godot_v4.3-stable_mono_linux_x86_64 \
  "Godot_v4.3-stable_mono_linux_x86_64/Godot_v4.3-stable_mono_linux.x86_64=4.3.stable.mono.official.77dcf97d8" \
  "Godot_v4.3-stable_mono_linux_x86_64/GodotSharp/Api/Debug/GodotSharp.dll=x"
mkzip Godot_v4.3-stable_macos.universal "Godot.app/Contents/MacOS/Godot=4.3.stable.official.77dcf97d8"
mkzip Godot_v4.3-stable_win64.exe "Godot_v4.3-stable_win64.exe=4.3.stable.official.77dcf97d8"
mkzip Godot_v4.7.2-stable_linux.x86_64 "Godot_v4.7.2-stable_linux.x86_64=4.7.2.stable.official.abcdef123"
# Two editors, and the wrong release.
mkzip Godot_v4.6.3-stable_linux.x86_64 "Godot_v4.6.3-stable_linux.x86_64=4.6.3.stable.official.1" "extra/Godot_v4.6.3-stable_linux.x86_64=4.6.3.stable.official.1"
mkzip Godot_v4.6.2-stable_linux.x86_64 "Godot_v4.6.2-stable_linux.x86_64=4.6.1.stable.official.1"
sha() { sha256sum < "$1" | awk '{ print $1 }'; }

# A pins file whose digests are the fixtures', with one wrong on purpose.
cat > "$work/pins.env" <<EOF
# test pins
GODOT_SHA256_4_3_STABLE_LINUX_X86_64=$(sha "$work/files/Godot_v4.3-stable_linux.x86_64.zip")
GODOT_SHA256_4_3_STABLE_MONO_LINUX_X86_64=$(sha "$work/files/Godot_v4.3-stable_mono_linux_x86_64.zip")
GODOT_SHA256_4_3_STABLE_MACOS_UNIVERSAL=$(sha "$work/files/Godot_v4.3-stable_macos.universal.zip")
GODOT_SHA256_4_3_STABLE_WIN64_EXE=$(sha "$work/files/Godot_v4.3-stable_win64.exe.zip")
GODOT_SHA256_4_7_2_STABLE_LINUX_X86_64=0000000000000000000000000000000000000000000000000000000000000000
GODOT_SHA256_4_6_3_STABLE_LINUX_X86_64=$(sha "$work/files/Godot_v4.6.3-stable_linux.x86_64.zip")
GODOT_SHA256_4_6_2_STABLE_LINUX_X86_64=$(sha "$work/files/Godot_v4.6.2-stable_linux.x86_64.zip")
GODOT_SHA256_4_6_1_STABLE_LINUX_X86_64=not-a-digest
EOF

# Stubs: curl serves files/<basename of the URL>; uname answers from the
# environment so the platform mapping is exercised on one machine.
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
f="$STUB_FILES/$(basename "$url")"
[ -f "$f" ] || { echo "curl: (22) not found: $url" >&2; exit 22; }
cp "$f" "$out"
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

# run <name> <rc> <GODOT_VERSION> [GODOT_USE_DOTNET] [RUNNER_ARCH]; ARCHIVE_DIR
# in the environment is passed as GODOT_ARCHIVE_DIR.
run() {
  local name="$1" want="$2" rc=0
  rm -rf "${work:?}/gh"; mkdir -p "$work/gh"; : > "$work/log"
  PATH="$work/stub:$PATH" STUB_LOG="$work/log" STUB_FILES="$work/files" \
    GODOT_VERSION="$3" GODOT_USE_DOTNET="${4-false}" RUNNER_ARCH="${5-X64}" \
    GODOT_INSTALL_DIR="$work/install" GODOT_BIN_DIR="$work/bin" GODOT_ARCHIVE_DIR="${ARCHIVE_DIR:-}" \
    TOOLCHAIN_PINS="${TEST_PINS:-$work/pins.env}" RUNNER_TEMP="$work" GITHUB_WORKSPACE="$work/ws" \
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
  grep -qxF -- "$1" "$work/log" || { echo "FAIL $name: curl was not asked for $1:"; cat "$work/log"; fail=1; }
}
no_download() {
  [[ -s "$work/log" ]] && { echo "FAIL $name: something was downloaded:"; cat "$work/log"; fail=1; }
  return 0
}
installed() {
  grep -q "^godot_version=$1$" "$work/gh/out" || { echo "FAIL $name: godot_version output is not $1:"; cat "$work/gh/out"; fail=1; }
  grep -q "^godot_bin=$work/bin/godot$" "$work/gh/out" || { echo "FAIL $name: godot_bin output:"; cat "$work/gh/out"; fail=1; }
  grep -qxF "$work/bin" "$work/gh/path" || { echo "FAIL $name: $work/bin not appended to GITHUB_PATH"; fail=1; }
  grep -q "^GODOT=$work/bin/godot$" "$work/gh/env" || { echo "FAIL $name: GODOT not in GITHUB_ENV:"; cat "$work/gh/env"; fail=1; }
  grep -q "^GODOT4=$work/bin/godot$" "$work/gh/env" || { echo "FAIL $name: GODOT4 not in GITHUB_ENV"; fail=1; }
  [[ "$("$work/bin/godot" --version)" == "$2" ]] || { echo "FAIL $name: bin/godot --version is '$("$work/bin/godot" --version)'"; fail=1; }
}

name="4.3.0 is the 4.3-stable linux x86_64 archive"
rm -rf "${work:?}/install" "${work:?}/bin"
run "$name" 0 4.3.0 && installed 4.3-stable 4.3.stable.official.77dcf97d8 \
  && fetched https://github.com/godotengine/godot-builds/releases/download/4.3-stable/Godot_v4.3-stable_linux.x86_64.zip \
  && says "Verified Godot_v4.3-stable_linux.x86_64.zip"
[[ -f "$work/install/Godot_v4.3-stable_linux.x86_64" ]] || { echo "FAIL $name: the editor is not under the install dir"; fail=1; }
[[ -z "$(ls -d "$work"/godot.* 2>/dev/null)" ]] || { echo "FAIL $name: the download directory was kept"; fail=1; }

name="without an archive directory every run downloads"
run "$name" 0 4.3.0 && installed 4.3-stable 4.3.stable.official.77dcf97d8 \
  && fetched https://github.com/godotengine/godot-builds/releases/download/4.3-stable/Godot_v4.3-stable_linux.x86_64.zip

# A cache restore puts the archive in GODOT_ARCHIVE_DIR. It is used only after
# its sha256 matches the pin in this run, and the install is rebuilt from it
# every run: nothing extracted earlier, however it got there, survives.
name="with an archive directory the archive is kept, verified"
ARCHIVE_DIR="$work/archive" run "$name" 0 4.3.0 && installed 4.3-stable 4.3.stable.official.77dcf97d8 \
  && fetched https://github.com/godotengine/godot-builds/releases/download/4.3-stable/Godot_v4.3-stable_linux.x86_64.zip
[[ -f "$work/archive/Godot_v4.3-stable_linux.x86_64.zip" ]] || { echo "FAIL $name: the archive is not kept in the archive directory"; fail=1; }

name="a cached archive whose sha256 matches is used without a download, and the install is rebuilt from it"
editor_script 9.9.9.evil > "$work/install/Godot_v4.3-stable_linux.x86_64"
printf 'evil\n' > "$work/install/planted"
ARCHIVE_DIR="$work/archive" run "$name" 0 4.3.0 && installed 4.3-stable 4.3.stable.official.77dcf97d8 \
  && no_download && says "Using the cached archive $work/archive/Godot_v4.3-stable_linux.x86_64.zip"
[[ -e "$work/install/planted" ]] && { echo "FAIL $name: the install directory was not rebuilt"; fail=1; }

name="a cached archive whose sha256 does not match is deleted and downloaded again"
printf 'tampered\n' >> "$work/archive/Godot_v4.3-stable_linux.x86_64.zip"
ARCHIVE_DIR="$work/archive" run "$name" 0 4.3.0 && installed 4.3-stable 4.3.stable.official.77dcf97d8 \
  && fetched https://github.com/godotengine/godot-builds/releases/download/4.3-stable/Godot_v4.3-stable_linux.x86_64.zip \
  && says "::warning::The cached archive $work/archive/Godot_v4.3-stable_linux.x86_64.zip has sha256" && says "deleting it and downloading again"
[[ "$(sha "$work/archive/Godot_v4.3-stable_linux.x86_64.zip")" == "$(sha "$work/files/Godot_v4.3-stable_linux.x86_64.zip")" ]] \
  || { echo "FAIL $name: the archive directory still holds the tampered archive"; fail=1; }

name="a cached archive of another release is removed, and a wrong download leaves none"
ARCHIVE_DIR="$work/archive" run "$name" 1 4.7.2 && says "Checksum mismatch for Godot_v4.7.2-stable_linux.x86_64.zip"
[[ -z "$(ls "$work/archive")" ]] || { echo "FAIL $name: the archive directory is not empty:"; ls "$work/archive"; fail=1; }
[[ -e "$work/bin/godot" ]] && { echo "FAIL $name: a godot link was left after the refusal"; fail=1; }

name="the .NET build links GodotSharp beside the editor"
run "$name" 0 4.3.0 true && installed 4.3-stable 4.3.stable.mono.official.77dcf97d8 \
  && fetched https://github.com/godotengine/godot-builds/releases/download/4.3-stable/Godot_v4.3-stable_mono_linux_x86_64.zip
[[ -d "$work/bin/GodotSharp/Api/Debug" ]] || { echo "FAIL $name: bin/GodotSharp is not linked"; fail=1; }
[[ -e "$work/install/Godot_v4.3-stable_linux.x86_64" ]] && { echo "FAIL $name: the previous install was not removed"; fail=1; }

name="a download whose sha256 is not the pin is refused and removed"
run "$name" 1 4.7.2 && says "Checksum mismatch for Godot_v4.7.2-stable_linux.x86_64.zip" \
  && fetched https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip
[[ -z "$(ls -d "$work"/godot.* 2>/dev/null)" ]] || { echo "FAIL $name: the download directory was kept"; ls -d "$work"/godot.*; fail=1; }
[[ -e "$work/bin/godot" ]] && { echo "FAIL $name: a godot link was left after the refusal"; fail=1; }

name="a release the pins file does not list is refused before any download"
run "$name" 2 4.4.0 && no_download && says "No sha256 pinned for Godot 4.4-stable (Godot_v4.4-stable_linux.x86_64.zip; GODOT_SHA256_4_4_STABLE_LINUX_X86_64" \
  && says "Pinned for this platform: 4.3-stable 4.7.2-stable 4.6.3-stable 4.6.2-stable"

name="a pin that is not 64 hex is no pin"
run "$name" 2 4.6.1 && no_download && says "No sha256 pinned for Godot 4.6.1-stable"

name="a pre-release label: 4.4.0-beta.1 is 4.4-beta1"
run "$name" 2 4.4.0-beta.1 && no_download && says "No sha256 pinned for Godot 4.4-beta1 (Godot_v4.4-beta1_linux.x86_64.zip"

name="a patch release keeps its patch: 4.7.2 is 4.7.2-stable"
run "$name" 1 4.7.2 && says "Godot_v4.7.2-stable_linux.x86_64.zip"

name="an archive with two editors is refused"
run "$name" 1 4.6.3 && says "holds 2 Godot editors"

name="an editor that reports another release is refused"
run "$name" 1 4.6.2 && says "reports '4.6.1.stable.official.1', not 4.6.2.stable.*"

name="a two-part version is refused with the fix"
run "$name" 2 4.3 && no_download && says "'4.3' is not a full semantic version such as 4.3.0 or 4.4.0-beta1 (write 4.3.0, not 4.3)"
run "$name" 2 "4.3.0; rm -rf /" && no_download && says "is not a full semantic version"
run "$name" 2 v4.3.0 && no_download && says "is not a full semantic version"

name="an empty version is refused"
run "$name" 2 "" && no_download && says "GODOT_VERSION is empty"

name="GODOT_USE_DOTNET takes true or false"
run "$name" 2 4.3.0 maybe && no_download && says "GODOT_USE_DOTNET is 'maybe'"

name="global.json names the version"
mkdir -p "$work/ws"
printf '{"sdk": {"version": "8.0.100"}, "msbuild-sdks": {"Godot.NET.Sdk": "4.3.0"}}\n' > "$work/ws/global.json"
run "$name" 0 global.json && says "Using Godot 4.3.0 from global.json" && installed 4.3-stable 4.3.stable.official.77dcf97d8
printf '{"sdk": {"version": "8.0.100"}}\n' > "$work/ws/global.json"
run "$name" 2 global.json && says "has no msbuild-sdks / Godot.NET.Sdk entry"
rm -rf "$work/ws"
run "$name" 2 global.json && says "global.json does not exist"

name="arm64 Linux asks for the linux.arm64 archive"
run "$name" 2 4.3.0 false ARM64 && no_download && says "Godot_v4.3-stable_linux.arm64.zip; GODOT_SHA256_4_3_STABLE_LINUX_ARM64"
STUB_UNAME_M=aarch64 run "$name" 2 4.3.0 false "" && says "Godot_v4.3-stable_linux.arm64.zip"
run "$name" 2 4.3.0 true ARM64 && says "Godot_v4.3-stable_mono_linux_arm64.zip"

name="an architecture that is neither is refused"
run "$name" 2 4.3.0 false s390x && no_download && says "Unsupported architecture 's390x'"

name="macOS asks for the universal archive and symlinks the bundle's editor"
STUB_UNAME_S=Darwin run "$name" 0 4.3.0 && installed 4.3-stable 4.3.stable.official.77dcf97d8 \
  && fetched https://github.com/godotengine/godot-builds/releases/download/4.3-stable/Godot_v4.3-stable_macos.universal.zip
[[ -L "$work/bin/godot" ]] || { echo "FAIL $name: bin/godot is not a symlink on macOS"; fail=1; }
STUB_UNAME_S=Darwin run "$name" 2 4.3.0 true ARM64 && no_download && says "Godot_v4.3-stable_mono_macos.universal.zip"

name="Windows asks for win64.exe, windows_arm64.exe and the mono variants, and links godot.exe"
STUB_UNAME_S=MINGW64_NT-10.0 run "$name" 0 4.3.0 \
  && fetched https://github.com/godotengine/godot-builds/releases/download/4.3-stable/Godot_v4.3-stable_win64.exe.zip
[[ -x "$work/bin/godot.exe" && -x "$work/bin/godot" ]] || { echo "FAIL $name: no bin/godot.exe and bin/godot"; ls -la "$work/bin"; fail=1; }
grep -q "^godot_bin=$work/bin/godot.exe$" "$work/gh/out" || { echo "FAIL $name: godot_bin output:"; cat "$work/gh/out"; fail=1; }
STUB_UNAME_S=MINGW64_NT-10.0 run "$name" 2 4.3.0 true && says "Godot_v4.3-stable_mono_win64.zip"
STUB_UNAME_S=MINGW64_NT-10.0 run "$name" 2 4.3.0 false ARM64 && says "Godot_v4.3-stable_windows_arm64.exe.zip"
STUB_UNAME_S=MINGW64_NT-10.0 run "$name" 2 4.3.0 true ARM64 && says "Godot_v4.3-stable_mono_windows_arm64.zip"

name="another OS is refused"
STUB_UNAME_S=FreeBSD run "$name" 2 4.3.0 && no_download && says "Unsupported runner OS 'FreeBSD'"

name="other entries of the bin directory are left alone"
mkdir -p "$work/bin"; printf '#!/usr/bin/env bash\n' > "$work/bin/mine"
run "$name" 0 4.3.0 && installed 4.3-stable 4.3.stable.official.77dcf97d8
[[ -f "$work/bin/mine" ]] || { echo "FAIL $name: bin/mine was removed"; fail=1; }

name="an install or bin directory that is HOME or / is refused"
rm -rf "${work:?}/gh"; mkdir -p "$work/gh"
rc=0; GODOT_VERSION=4.3.0 GODOT_INSTALL_DIR="$HOME" GODOT_BIN_DIR="$work/bin" TOOLCHAIN_PINS="$work/pins.env" PATH="$work/stub:$PATH" STUB_LOG="$work/log" STUB_FILES="$work/files" "$BASH" "$script" > "$work/out" 2>&1 || rc=$?
if [[ "$rc" != 2 ]] || ! grep -q "GODOT_INSTALL_DIR '$HOME' is not a directory of its own" "$work/out"; then echo "FAIL $name: exit $rc"; cat "$work/out"; fail=1; fi
rc=0; GODOT_VERSION=4.3.0 GODOT_INSTALL_DIR="$work/install" GODOT_BIN_DIR=/ TOOLCHAIN_PINS="$work/pins.env" PATH="$work/stub:$PATH" STUB_LOG="$work/log" STUB_FILES="$work/files" "$BASH" "$script" > "$work/out" 2>&1 || rc=$?
if [[ "$rc" != 2 ]] || ! grep -q "GODOT_BIN_DIR '/' is not a directory of its own" "$work/out"; then echo "FAIL $name: exit $rc"; cat "$work/out"; fail=1; fi

name="a missing pins file"
TEST_PINS="$work/none.env" run "$name" 2 4.3.0 && no_download && says "Pins file $work/none.env is not readable"

[[ "$fail" = 0 ]] && echo "ok: setup_godot names the action's archives, refuses an unpinned release or a wrong digest, links the editor, and rebuilds the install from a verified archive every run"
exit "$fail"
