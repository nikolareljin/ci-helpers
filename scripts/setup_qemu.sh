#!/usr/bin/env bash
# SCRIPT: setup_qemu.sh
# DESCRIPTION: Register QEMU user-mode emulators with the kernel's binfmt_misc
#              so docker buildx can build for other architectures, with no
#              third-party action. Runs the binfmt image pinned by tag and
#              index digest in toolchain-pins.env, as the replaced action ran
#              its default image: `docker run --rm --privileged <image>
#              --install <platforms>`. A pin without an @sha256: digest is
#              refused before anything is pulled.
# USAGE: QEMU_PLATFORMS=all bash scripts/setup_qemu.sh
# ENVIRONMENT:
#   QEMU_PLATFORMS   Platforms to install, comma-separated, or `all`
#                    (default: all, the action's default).
#   TOOLCHAIN_PINS   Pins file (default: toolchain-pins.env beside scripts/).
#   GITHUB_OUTPUT    Written when set.
# OUTPUT: platforms=<comma-separated platforms the kernel now supports>, on
#         stdout and, when GITHUB_OUTPUT is set, appended there.
# EXIT CODES:
#   0  The emulators are installed.
#   1  docker could not run the binfmt image.
#   2  No docker on PATH, no readable pins file, or a pin that is not
#      name:tag@sha256:<digest>.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="${TOOLCHAIN_PINS:-$script_dir/../toolchain-pins.env}"
platforms="${QEMU_PLATFORMS:-all}"

command -v docker >/dev/null 2>&1 || { echo "::error::docker is not on PATH." >&2; exit 2; }
[[ -r "$pins" ]] || { echo "::error::pins file not readable: $pins" >&2; exit 2; }

# KEY=value, first match; comments and blank lines are not keys.
pin() {
  awk -F= -v k="$1" '$1 == k { print $2; exit }' "$pins"
}

image="$(pin BINFMT_IMAGE)"
pinned_re='^docker\.io/tonistiigi/binfmt:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$'
if ! [[ "$image" =~ $pinned_re ]]; then
  echo "::error::BINFMT_IMAGE in $pins is '$image', not docker.io/tonistiigi/binfmt:<tag>@sha256:<digest>." >&2
  exit 2
fi
if [[ -z "$platforms" ]] || [[ "$platforms" =~ [[:space:]] ]]; then
  echo "::error::QEMU_PLATFORMS is '$platforms'; name platforms separated by commas, or 'all'." >&2
  exit 2
fi

echo "Installing QEMU emulators for $platforms from $image"
if ! docker run --rm --privileged "$image" --install "$platforms"; then
  echo "::error::docker run $image --install $platforms failed." >&2
  exit 1
fi

# The image with no arguments prints {"supported": [...], "emulators": [...]}.
supported=""
if listing="$(docker run --rm --privileged "$image" 2>/dev/null)" && command -v python3 >/dev/null 2>&1; then
  supported="$(printf '%s' "$listing" | python3 -I -c '
import json, sys
try:
    print(",".join(json.load(sys.stdin).get("supported", [])))
except ValueError:
    pass
')"
fi
[[ -n "$supported" ]] && echo "Supported platforms: $supported"
printf 'platforms=%s\n' "$supported"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'platforms=%s\n' "$supported" >> "$GITHUB_OUTPUT"
fi
