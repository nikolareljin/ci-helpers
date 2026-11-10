#!/usr/bin/env bash
# SCRIPT: setup_flutter.sh
# DESCRIPTION: Install the Flutter SDK from the official release archive, so
#              a workflow runs no third-party action for it. The release is
#              chosen from the official manifest (releases_<os>.json, which
#              carries a sha256 per archive) the way the action this replaces
#              chose it: by channel, by the runner's architecture, by exact
#              version or by an `X.Y` / `X.Y.x` prefix (newest match), or the
#              newest of the channel. Every download is checked against the
#              manifest's sha256. An empty version on the stable channel
#              installs the release pinned in toolchain-pins.env, whose
#              digest must also match the manifest's. The SDK is extracted
#              under the runner's tool cache, FLUTTER_ROOT and PUB_CACHE are
#              exported, and flutter, dart and the pub cache go on PATH.
# USAGE: FLUTTER_CHANNEL=stable FLUTTER_VERSION=3.47.9 bash scripts/setup_flutter.sh
# ENVIRONMENT:
#   FLUTTER_VERSION     Exact version, `X.Y`, `X.Y.x`, `any`, or empty (the
#                       pinned release on stable, the newest on another
#                       channel). A channel name here is read as the channel.
#   FLUTTER_CHANNEL     stable (default), beta or dev. master and main are
#                       refused: they are git clones with no digest.
#   FLUTTER_DRY_RUN     true: resolve and write the outputs, install nothing.
#   FLUTTER_INSTALL_ROOT  Where SDKs go (default $RUNNER_TOOL_CACHE/flutter,
#                       else $HOME/flutter-sdk); one directory per
#                       channel-version-arch. Cache that directory; a
#                       verified SDK there is reused when its recorded
#                       digest is the expected one.
#   FLUTTER_STORAGE_BASE_URL  The mirror Flutter itself honours (default
#                       https://storage.googleapis.com); https only.
#   RUNNER_ARCH         X64 or ARM64 (set by the runner); else from uname -m.
#   TOOLCHAIN_PINS      Pins file (default: toolchain-pins.env beside scripts/).
#   RUNNER_TEMP         Where the download goes (default: mktemp -d).
#   GITHUB_PATH, GITHUB_ENV, GITHUB_OUTPUT  Written when set.
# OUTPUT: channel, version, arch, cache_key, cache_path, flutter_root,
#         pinned (true when the pinned release was installed), on stdout
#         and, when GITHUB_OUTPUT is set, appended there. GITHUB_ENV gets
#         FLUTTER_ROOT and PUB_CACHE (unless the job set it).
# EXIT CODES:
#   0  flutter is on PATH at the chosen release (or resolved, on a dry run).
#   1  No release matches, a download or checksum failed, or the manifest's
#      digest for the pinned release is not the pinned one.
#   2  Usage error, unsupported platform, jq missing, or no pin for this
#      platform when the pinned release was asked for.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="${TOOLCHAIN_PINS:-$script_dir/../toolchain-pins.env}"
version="${FLUTTER_VERSION:-}"
channel="${FLUTTER_CHANNEL:-}"
dry_run="${FLUTTER_DRY_RUN:-false}"
base="${FLUTTER_STORAGE_BASE_URL:-https://storage.googleapis.com}"
base="${base%/}"

command -v jq >/dev/null 2>&1 || { echo "::error::jq is needed to read the Flutter release manifest and is not on PATH." >&2; exit 2; }
[[ "$base" == https://* ]] || { echo "::error::FLUTTER_STORAGE_BASE_URL '$base' is not an https URL." >&2; exit 2; }
case "$dry_run" in
  true|false) ;;
  *) echo "::error::FLUTTER_DRY_RUN is '$dry_run'; it takes true or false." >&2; exit 2 ;;
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

# A Windows path for GITHUB_PATH, GITHUB_ENV and actions/cache under Git Bash.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

# A channel name in the version is the channel, as the callers' workflows
# read it; a `v` prefix is dropped, as the action dropped it.
version="${version#v}"
case "$version" in
  stable|beta|dev|master|main)
    [[ -n "$channel" ]] || channel="$version"
    version="" ;;
esac
[[ -n "$channel" ]] || channel=stable
case "$channel" in
  stable|beta|dev) ;;
  master|main) echo "::error::FLUTTER_CHANNEL '$channel' is a git clone of flutter/flutter with no release digest; name stable, beta or dev." >&2; exit 2 ;;
  *) echo "::error::FLUTTER_CHANNEL '$channel' is not stable, beta or dev." >&2; exit 2 ;;
esac
[[ "$version" =~ ^[0-9A-Za-z.+-]*$ ]] || { echo "::error::FLUTTER_VERSION '$version' is not a version." >&2; exit 2; }

[[ -r "$pins" ]] || { echo "::error::Pins file $pins is not readable." >&2; exit 2; }
pinned_version="$(pin FLUTTER_VERSION)"
[[ "$pinned_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::FLUTTER_VERSION in $pins is '$pinned_version', not X.Y.Z." >&2; exit 2; }
if [[ -z "$version" ]]; then
  if [[ "$channel" == stable ]]; then
    version="$pinned_version"
    echo "No Flutter version given on stable: installing the release pinned in $pins, $version"
  else
    version=any
  fi
fi

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  *) echo "::error::Unsupported runner OS '$(uname -s)'; Flutter is released for Linux, macOS and Windows." >&2; exit 2 ;;
esac
case "${RUNNER_ARCH:-$(uname -m)}" in
  X64|x86_64|amd64) arch=x64 ;;
  ARM64|aarch64|arm64) arch=arm64 ;;
  *) echo "::error::Unsupported architecture '${RUNNER_ARCH:-$(uname -m)}'; Flutter is released for x64 and arm64." >&2; exit 2 ;;
esac

if [[ -n "${RUNNER_TEMP:-}" ]]; then
  dest="$(mktemp -d "${RUNNER_TEMP}/flutter.XXXXXX")"
else
  dest="$(mktemp -d)"
fi
trap 'rm -rf "$dest"' EXIT

# The official manifest for this OS: one entry per release and architecture
# (an entry without dart_sdk_arch is x64), newest first.
manifest_url="$base/flutter_infra_release/releases/releases_$os.json"
curl --proto '=https' --tlsv1.2 --retry 5 --retry-connrefused -fsSL "$manifest_url" -o "$dest/releases.json"
# The action's selection: the channel, the architecture, then the exact
# version, else the newest whose version starts with `X.Y.` for `X.Y` or
# `X.Y.x`, else (`any`) the newest.
entry="$(jq -r --arg channel "$channel" --arg arch "$arch" --arg version "$version" '
  [.releases[] | select(.channel == $channel)]
  | [.[] | select(.dart_sdk_arch == $arch or ($arch == "x64" and (has("dart_sdk_arch") | not)))]
  | map(.version |= sub("^v"; ""))
  | (if $version == "any" then .[0]
     else (map(select(.version == $version
                      or ((.version | startswith(($version | sub("\\.x$"; "")) + ".")) and .version != $version)))
           | .[0])
     end)
  | if . == null then empty
    else [.version, (.dart_sdk_arch // "x64"), .sha256, .archive, .hash] | join(" ") end' "$dest/releases.json")"
if [[ -z "$entry" ]]; then
  echo "::error::Unable to determine Flutter version for channel: $channel version: $version architecture: $arch (from $manifest_url)." >&2
  exit 1
fi
chosen="${entry%% *}"; rest="${entry#* }"
chosen_arch="${rest%% *}"; rest="${rest#* }"
manifest_sha="$(printf '%s' "${rest%% *}" | tr '[:upper:]' '[:lower:]')"; rest="${rest#* }"
archive="${rest%% *}"; hash="${rest#* }"
if [[ ${#manifest_sha} -ne 64 || -n "$(printf '%s' "$manifest_sha" | tr -d '0-9a-f')" ]]; then
  echo "::error::The manifest entry for Flutter $chosen ($channel, $chosen_arch) has no 64-hex sha256; refusing to download an unverified SDK." >&2
  exit 1
fi
# The archive is a relative path under the release tree, a zip or a tar.xz.
case "$archive" in
  *..*|/*|*" "*) echo "::error::The manifest names an archive path that leaves the release tree: '$archive'." >&2; exit 1 ;;
  *.zip|*.tar.xz) ;;
  *) echo "::error::The manifest names an archive of an unexpected form: '$archive'." >&2; exit 1 ;;
esac

# The pinned release: the manifest must agree with the pin for this platform.
pinned=false
if [[ "$channel" == stable && "$chosen" == "$pinned_version" ]]; then
  key="FLUTTER_SHA256_$(printf '%s_%s' "$os" "$chosen_arch" | tr '[:lower:]' '[:upper:]')"
  expected="$(pin "$key" | tr '[:upper:]' '[:lower:]')"
  if [[ ${#expected} -ne 64 || -n "$(printf '%s' "$expected" | tr -d '0-9a-f')" ]]; then
    echo "::error::No 64-hex sha256 pinned for Flutter $chosen on $os $chosen_arch ($key in $pins). Refusing to install the pinned release unverified; set flutter_version to another release or add the pin." >&2
    exit 2
  fi
  if [[ "$manifest_sha" != "$expected" ]]; then
    echo "::error::The manifest's sha256 for Flutter $chosen ($os $chosen_arch) is $manifest_sha; $pins pins $expected. The published release changed under its version; refusing." >&2
    exit 1
  fi
  pinned=true
else
  expected="$manifest_sha"
fi

# Where the SDK lives, as the action put it, one directory per release.
root="${FLUTTER_INSTALL_ROOT:-}"
if [[ -z "$root" ]]; then
  if [[ -n "${RUNNER_TOOL_CACHE:-}" ]]; then
    root="${RUNNER_TOOL_CACHE}"
    if command -v cygpath >/dev/null 2>&1; then root="$(cygpath -u "$root")"; fi
    root="$root/flutter"
  else
    root="$HOME/flutter-sdk"
  fi
fi
sdk_dir="$root/$channel-$chosen-$chosen_arch"
flutter_root="$sdk_dir/flutter"
cache_key="flutter-$os-$channel-$chosen-$chosen_arch-$hash"

outputs() {
  printf 'channel=%s\nversion=%s\narch=%s\ncache_key=%s\ncache_path=%s\nflutter_root=%s\npinned=%s\n' \
    "$channel" "$chosen" "$chosen_arch" "$cache_key" "$(host_path "$sdk_dir")" "$(host_path "$flutter_root")" "$pinned"
}
if [[ "$dry_run" == true ]]; then
  echo "Flutter $chosen ($channel, $chosen_arch) resolves to $archive; not installing (dry run)"
  outputs
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then outputs >> "$GITHUB_OUTPUT"; fi
  exit 0
fi

# A verified SDK from a cache restore: the recorded digest is the expected
# one and the launcher is in place. Anything else is removed and replaced.
marker="$sdk_dir/.sha256"
if [[ -x "$flutter_root/bin/flutter" && -f "$marker" && "$(cat "$marker")" == "$expected" ]]; then
  echo "Flutter $chosen ($channel, $chosen_arch) is already under $sdk_dir with the expected digest; not downloading."
else
  rm -rf "$sdk_dir"
  mkdir -p "$sdk_dir"
  file="$(basename "$archive")"
  url="$base/flutter_infra_release/releases/$archive"
  echo "Downloading $url"
  curl --proto '=https' --tlsv1.2 --retry 5 --retry-connrefused -fsSL "$url" -o "$dest/$file"
  actual="$(sha256_of "$dest/$file")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$dest/$file"
    echo "::error::Checksum mismatch for $file: expected $expected, got $actual." >&2
    exit 1
  fi
  echo "Verified $file (sha256 $actual)"
  case "$file" in
    *.zip) unzip -q -o "$dest/$file" -d "$sdk_dir" ;;
    *) tar xf "$dest/$file" -C "$sdk_dir" ;;
  esac
  rm -f "$dest/$file"
  [[ -f "$flutter_root/bin/flutter" ]] || { echo "::error::$file holds no flutter/bin/flutter." >&2; exit 1; }
  chmod +x "$flutter_root/bin/flutter"
  printf '%s\n' "$expected" > "$marker"
fi

# The pub cache, where Dart looks for it unless the job set it.
if [[ -z "${PUB_CACHE:-}" ]]; then
  if [[ "$os" == windows ]]; then PUB_CACHE="${LOCALAPPDATA:-$HOME}\\Pub\\Cache"; else PUB_CACHE="$HOME/.pub-cache"; fi
  export PUB_CACHE
  if [[ -n "${GITHUB_ENV:-}" ]]; then printf 'PUB_CACHE=%s\n' "$PUB_CACHE" >> "$GITHUB_ENV"; fi
fi
if command -v cygpath >/dev/null 2>&1; then pub_bin="$(cygpath -u "$PUB_CACHE")/bin"; else pub_bin="$PUB_CACHE/bin"; fi

PATH="$flutter_root/bin:$flutter_root/bin/cache/dart-sdk/bin:$pub_bin:$PATH"
export PATH
export FLUTTER_ROOT="$flutter_root"
if [[ -n "${GITHUB_ENV:-}" ]]; then printf 'FLUTTER_ROOT=%s\n' "$(host_path "$flutter_root")" >> "$GITHUB_ENV"; fi
if [[ -n "${GITHUB_PATH:-}" ]]; then
  { host_path "$flutter_root/bin"; host_path "$flutter_root/bin/cache/dart-sdk/bin"; host_path "$pub_bin"; } >> "$GITHUB_PATH"
fi
echo "Flutter $chosen ($channel, $chosen_arch) at $flutter_root"
outputs
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then outputs >> "$GITHUB_OUTPUT"; fi
