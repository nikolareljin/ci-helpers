#!/usr/bin/env bash
# SCRIPT: setup_godot.sh
# DESCRIPTION: Install the Godot editor from the official release archive, so
#              a workflow runs no third-party action for it. The archive for
#              the requested release, variant and platform is downloaded from
#              github.com/godotengine/godot-builds and run only after its
#              sha256 matches toolchain-pins.env; a release the pins file does
#              not list is refused before anything is downloaded. The version
#              is read as the action this replaces read it: a full semantic
#              version (`4.3.0`, `4.4.0-beta1`), where `4.3.0` names the
#              `4.3-stable` release; `global.json` reads the version from the
#              project's global.json (msbuild-sdks / Godot.NET.Sdk). The
#              editor is extracted under GODOT_INSTALL_DIR, linked as `godot`
#              in GODOT_BIN_DIR, and that directory goes on PATH; GODOT and
#              GODOT4 name the link, as the action set them. No export
#              templates: the callers never had them installed. Nothing
#              extracted is trusted across runs: the install directory is
#              rebuilt every run from an archive whose sha256 matched the
#              pin in this run, whether it was downloaded now or kept in
#              GODOT_ARCHIVE_DIR by a cache restore.
# USAGE: GODOT_VERSION=4.3.0 bash scripts/setup_godot.sh
# ENVIRONMENT:
#   GODOT_VERSION      Semantic version (required), or `global.json`.
#   GODOT_USE_DOTNET   true for the .NET build (default false).
#   GODOT_ARCHIVE_DIR  Where the downloaded archive is kept (optional). An
#                      archive already there is used only after its sha256
#                      matches the pin; otherwise it is deleted and
#                      downloaded again. Cache this directory, saved right
#                      after this script, never after a caller's step.
#   GODOT_INSTALL_DIR  Where the archive is extracted (default $HOME/godot);
#                      removed and rebuilt every run, never cached.
#   GODOT_BIN_DIR      Where the `godot` link goes (default $HOME/bin); its
#                      godot, godot.exe, godot_console.exe and GodotSharp
#                      entries are replaced, the rest of the directory is
#                      left alone.
#   GITHUB_WORKSPACE   Where global.json is read from (default: cwd).
#   RUNNER_ARCH        X64 or ARM64 (set by the runner); else from uname -m.
#   TOOLCHAIN_PINS     Pins file (default: toolchain-pins.env beside scripts/).
#   RUNNER_TEMP        Where a download goes without GODOT_ARCHIVE_DIR
#                      (default: mktemp -d).
#   GITHUB_PATH, GITHUB_ENV, GITHUB_OUTPUT  Written when set.
# OUTPUT: godot_version=<release, e.g. 4.3-stable>, godot_bin=<the link;
#         on Windows the console wrapper, godot_console.exe>, on stdout
#         and, when GITHUB_OUTPUT is set, appended there. GITHUB_ENV gets
#         GODOT and GODOT4, the same path.
# EXIT CODES:
#   0  godot is on PATH at the requested release.
#   1  Download or checksum failed, the archive holds no editor, or the
#      installed editor does not run or reports another release.
#   2  Usage error, unsupported platform, or no pin for this release.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="${TOOLCHAIN_PINS:-$script_dir/../toolchain-pins.env}"
version="${GODOT_VERSION:-}"
use_dotnet="${GODOT_USE_DOTNET:-false}"
install_dir="${GODOT_INSTALL_DIR:-$HOME/godot}"
bin_dir="${GODOT_BIN_DIR:-$HOME/bin}"
archive_dir="${GODOT_ARCHIVE_DIR:-}"

case "$use_dotnet" in
  true|false) ;;
  *) echo "::error::GODOT_USE_DOTNET is '$use_dotnet'; it takes true or false." >&2; exit 2 ;;
esac

# KEY=value, first match; comments and blank lines are not keys.
pin() {
  awk -F= -v k="$1" '$1 == k { print $2; exit }' "$pins"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | awk '{ print $1 }'
  else
    echo "::error::Neither sha256sum nor shasum is available to verify a download." >&2
    exit 1
  fi
}

# A Windows path for GITHUB_PATH and GITHUB_ENV when running under Git Bash.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

# As the action: `global.json` reads msbuild-sdks / Godot.NET.Sdk.
if [[ "$version" == "global.json" ]]; then
  file="${GITHUB_WORKSPACE:-.}/global.json"
  [[ -f "$file" ]] || { echo "::error::GODOT_VERSION is global.json and $file does not exist." >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "::error::jq is needed to read $file and is not on PATH." >&2; exit 2; }
  version="$(jq -r '."msbuild-sdks"."Godot.NET.Sdk" // empty' "$file")"
  [[ -n "$version" ]] || { echo "::error::$file has no msbuild-sdks / Godot.NET.Sdk entry." >&2; exit 2; }
  echo "Using Godot $version from global.json"
fi

[[ -n "$version" ]] || { echo "::error::GODOT_VERSION is empty; name a release such as 4.3.0." >&2; exit 2; }
# No empty identifier: `4.3.0-..` would otherwise name the stable release.
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
if [[ ! "$version" =~ $semver ]]; then
  echo "::error::GODOT_VERSION '$version' is not a full semantic version such as 4.3.0 or 4.4.0-beta1 (write 4.3.0, not 4.3)." >&2
  exit 2
fi
major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"; label="${BASH_REMATCH[5]}"
# The release tag as godot-builds names it: 4.3.0 is 4.3-stable, 4.3.1 is
# 4.3.1-stable, 4.4.0-beta.1 is 4.4-beta1.
release="$major.$minor"
[[ "$patch" == 0 ]] || release="$release.$patch"
label="${label//./}"
if [[ -n "$label" ]]; then release="$release-$label"; else release="$release-stable"; fi

# The archive suffix per platform, as the action chose it.
case "${RUNNER_ARCH:-$(uname -m)}" in
  X64|x86_64|amd64) arch=x86_64 ;;
  ARM64|aarch64|arm64) arch=arm64 ;;
  *) echo "::error::Unsupported architecture '${RUNNER_ARCH:-$(uname -m)}'; Godot is pinned for x86_64 and arm64." >&2; exit 2 ;;
esac
os="$(uname -s)"
case "$os" in
  Linux)
    os=linux
    if [[ "$use_dotnet" == true ]]; then suffix="mono_linux_$arch"; else suffix="linux.$arch"; fi ;;
  Darwin)
    os=macos
    if [[ "$use_dotnet" == true ]]; then suffix="mono_macos.universal"; else suffix="macos.universal"; fi ;;
  MINGW*|MSYS*|CYGWIN*)
    os=windows
    if [[ "$arch" == x86_64 ]]; then win=win64; else win=windows_arm64; fi
    if [[ "$use_dotnet" == true ]]; then suffix="mono_$win"; else suffix="$win.exe"; fi ;;
  *) echo "::error::Unsupported runner OS '$os'; Godot is pinned for Linux, macOS and Windows." >&2; exit 2 ;;
esac
name="Godot_v${release}_${suffix}"
file="$name.zip"
url="https://github.com/godotengine/godot-builds/releases/download/${release}/${file}"

[[ -r "$pins" ]] || { echo "::error::Pins file $pins is not readable." >&2; exit 2; }
key="GODOT_SHA256_$(printf '%s_%s' "$release" "$suffix" | tr '[:lower:].-' '[:upper:]__')"
expected="$(pin "$key" | tr '[:upper:]' '[:lower:]')"
if [[ ${#expected} -ne 64 || -n "$(printf '%s' "$expected" | tr -d '0-9a-f')" ]]; then
  # The releases pinned for this platform and variant, so the message says
  # what would work.
  tail="_$(printf '%s' "$suffix" | tr '[:lower:].-' '[:upper:]__')"
  pinned="$(awk -F= -v t="$tail" '$1 ~ /^GODOT_SHA256_/ && substr($1, length($1) - length(t) + 1) == t {
      r = substr($1, 14, length($1) - 13 - length(t)); if (r ~ /^[0-9]+_[0-9]+(_[0-9]+)?_[A-Z0-9]+$/) print r }' "$pins" \
    | tr '[:upper:]' '[:lower:]' | sed 's/_\([a-z]\)/-\1/; s/_/./g' | tr '\n' ' ')"
  pinned="${pinned% }"
  echo "::error::No sha256 pinned for Godot $release ($file; $key in $pins). Pinned for this platform: ${pinned:-none}. Refusing to download an unverified editor." >&2
  exit 2
fi

# The old install and its links go first, so a refusal below leaves no
# editor of another release on PATH. Only this script's entries in the bin
# directory are removed; the action emptied the whole directory.
[[ -n "$install_dir" && "$install_dir" != "/" && "$install_dir" != "$HOME" ]] || { echo "::error::GODOT_INSTALL_DIR '$install_dir' is not a directory of its own." >&2; exit 2; }
[[ -n "$bin_dir" && "$bin_dir" != "/" && "$bin_dir" != "$HOME" ]] || { echo "::error::GODOT_BIN_DIR '$bin_dir' is not a directory of its own." >&2; exit 2; }
rm -rf "$install_dir" "$bin_dir/godot" "$bin_dir/godot.exe" "$bin_dir/godot_console.exe" "$bin_dir/GodotSharp"

# The archive: one kept in GODOT_ARCHIVE_DIR by a cache restore is used only
# after its sha256 matches the pin in this run; a cache entry is written by
# a job, so nothing in it is trusted on its own. Anything else is deleted
# and the archive is downloaded again, then checked the same way.
if [[ -n "$archive_dir" ]]; then
  mkdir -p "$archive_dir"
  dest="$archive_dir"
  # Archives of other releases do not accumulate in the cache.
  find "$archive_dir" -maxdepth 1 -type f -name 'Godot_v*.zip' ! -name "$file" -exec rm -f {} +
else
  if [[ -n "${RUNNER_TEMP:-}" ]]; then
    dest="$(mktemp -d "${RUNNER_TEMP}/godot.XXXXXX")"
  else
    dest="$(mktemp -d)"
  fi
  trap 'rm -rf "$dest"' EXIT
fi
archive_path="$dest/$file"
if [[ -f "$archive_path" ]]; then
  actual="$(sha256_of "$archive_path")"
  if [[ "$actual" == "$expected" ]]; then
    echo "Using the cached archive $archive_path (sha256 $actual matches the pin)"
  else
    echo "::warning::The cached archive $archive_path has sha256 $actual, not the pinned $expected; deleting it and downloading again."
    rm -f "$archive_path"
  fi
fi
if [[ ! -f "$archive_path" ]]; then
  echo "Downloading $url"
  curl --proto '=https' --tlsv1.2 --retry 5 --retry-connrefused -fsSL "$url" -o "$archive_path"
  actual="$(sha256_of "$archive_path")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$archive_path"
    echo "::error::Checksum mismatch for $file: expected $expected, got $actual." >&2
    exit 1
  fi
  echo "Verified $file (sha256 $actual)"
fi

# The verified archive is extracted fresh; nothing extracted by an earlier
# run is reused.
mkdir -p "$install_dir"
unzip -q -o "$archive_path" -d "$install_dir"
[[ -n "$archive_dir" ]] || rm -f "$archive_path"
find_editor() {
  case "$os" in
    linux)   find "$install_dir" -type f -name "Godot_v*linux*.$arch" 2>/dev/null ;;
    macos)
      if [[ "$use_dotnet" == true ]]; then app=Godot_mono.app; else app=Godot.app; fi
      [[ -f "$install_dir/$app/Contents/MacOS/Godot" ]] && printf '%s\n' "$install_dir/$app/Contents/MacOS/Godot" ;;
    windows) find "$install_dir" -type f -name "Godot_v*_$win.exe" 2>/dev/null ;;
  esac
  return 0
}
editor="$(find_editor)"
count="$(printf '%s' "$editor" | grep -c . || true)"
if [[ "$count" != 1 ]]; then
  echo "::error::$file holds $count Godot editors for $suffix under $install_dir; expected one." >&2
  [[ -z "$editor" ]] || printf '%s\n' "$editor" >&2
  exit 1
fi
chmod +x "$editor"

# A link named `godot` on PATH, as the action made it: a hard link on Linux
# and Windows, a symlink on macOS (a hard link to the binary inside the
# bundle is killed by the kernel). On Windows the editor is a GUI program
# whose output never reaches a step log; the release ships a console
# wrapper beside it that runs the editor of the same name minus `_console`
# and relays stdout and the exit code, so it is linked as
# `godot_console.exe` beside `godot.exe`, and GODOT names the wrapper. The
# .NET build looks for GodotSharp beside the executable, so that directory
# is linked beside the hard link too.
mkdir -p "$bin_dir"
alias_path="$bin_dir/godot"
check_path="$alias_path"
case "$os" in
  macos) ln -s "$editor" "$alias_path" ;;
  linux) ln "$editor" "$alias_path" 2>/dev/null || cp "$editor" "$alias_path" ;;
  windows)
    alias_path="$bin_dir/godot.exe"
    check_path="$alias_path"
    ln "$editor" "$alias_path" 2>/dev/null || cp "$editor" "$alias_path"
    wrapper="${editor%.exe}_console.exe"
    if [[ -f "$wrapper" ]]; then
      check_path="$bin_dir/godot_console.exe"
      ln "$wrapper" "$check_path" 2>/dev/null || cp "$wrapper" "$check_path"
    fi ;;
esac
if [[ "$use_dotnet" == true && "$os" != macos ]]; then
  sharp="$(find "$install_dir" -type d -name GodotSharp | head -n 1)"
  [[ -n "$sharp" ]] || { echo "::error::$file holds no GodotSharp directory; is it the .NET build?" >&2; exit 1; }
  # Git Bash copies the directory when it cannot symlink; either serves.
  ln -s "$sharp" "$bin_dir/GodotSharp" 2>/dev/null || cp -R "$sharp" "$bin_dir/GodotSharp"
fi

# The editor runs and is the release asked for: `--version` prints
# `4.3.stable.official.<hash>` (`4.3.stable.mono.official.<hash>` for .NET).
reported="$("$check_path" --version 2>&1 | tail -n 1 | tr -d '\r')" || reported=""
want="$(printf '%s' "$release" | tr '-' '.')"
if [[ "$reported" != "$want".* ]]; then
  echo "::error::$check_path --version reports '$reported', not $want.*; the installed editor is not Godot $release." >&2
  exit 1
fi
echo "Godot $reported at $check_path"

PATH="$bin_dir:$PATH"
export PATH
if [[ -n "${GITHUB_PATH:-}" ]]; then host_path "$bin_dir" >> "$GITHUB_PATH"; fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'GODOT=%s\nGODOT4=%s\n' "$(host_path "$check_path")" "$(host_path "$check_path")" >> "$GITHUB_ENV"
fi
printf 'godot_version=%s\ngodot_bin=%s\n' "$release" "$check_path"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'godot_version=%s\ngodot_bin=%s\n' "$release" "$(host_path "$check_path")" >> "$GITHUB_OUTPUT"
fi
