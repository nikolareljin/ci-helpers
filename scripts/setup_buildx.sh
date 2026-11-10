#!/usr/bin/env bash
# SCRIPT: setup_buildx.sh
# DESCRIPTION: Create and select a docker-container buildx builder with the
#              buildx the runner ships, with no third-party action. The
#              BuildKit image the builder runs is the one pinned by tag and
#              index digest in toolchain-pins.env, not the floating default.
#              A runner without the buildx plugin is refused with a message;
#              nothing is downloaded. `--remove` deletes the builder again.
# USAGE: bash scripts/setup_buildx.sh [--remove]
# PARAMETERS:
#   --remove     Remove the builder named BUILDX_NAME instead of creating one.
#   -h, --help   Show this help message.
# ENVIRONMENT:
#   BUILDX_NAME         Builder name (default: builder-<run id>-<random>).
#   BUILDX_DRIVER_OPTS  Extra driver options, one per line (e.g. network=host).
#   BUILDKITD_CONFIG    A buildkitd config file to hand the builder (optional).
#   BUILDKITD_FLAGS     Flags for the BuildKit daemon, one line (optional).
#   TOOLCHAIN_PINS      Pins file (default: toolchain-pins.env beside scripts/).
#   GITHUB_OUTPUT       Written when set.
# OUTPUT: name=<builder>, driver=docker-container and platforms=<what the
#         builder reports>, on stdout and, when GITHUB_OUTPUT is set,
#         appended there.
# EXIT CODES:
#   0  The builder exists, is bootstrapped and is the current one.
#   1  docker buildx create, inspect or rm failed.
#   2  No docker or no buildx plugin on PATH, no readable pins file, a pin
#      that is not name:tag@sha256:<digest>, or a usage error.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="${TOOLCHAIN_PINS:-$script_dir/../toolchain-pins.env}"
name="${BUILDX_NAME:-}"
driver_opts="${BUILDX_DRIVER_OPTS:-}"
config="${BUILDKITD_CONFIG:-}"
flags="${BUILDKITD_FLAGS:-}"
remove=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove) remove=true; shift ;;
    -h|--help) grep '^#[^!]' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "::error::docker is not on PATH." >&2; exit 2; }
if ! docker buildx version >/dev/null 2>&1; then
  echo "::error::docker buildx is not installed. GitHub-hosted runners ship it; on a self-hosted runner install the docker-buildx-plugin package (or a buildx release under ~/.docker/cli-plugins) before this step." >&2
  exit 2
fi

if [[ "$remove" == true ]]; then
  [[ -n "$name" ]] || { echo "::error::--remove needs BUILDX_NAME." >&2; exit 2; }
  if docker buildx rm "$name"; then
    echo "Removed builder $name"
    exit 0
  fi
  echo "::error::docker buildx rm $name failed." >&2
  exit 1
fi

[[ -r "$pins" ]] || { echo "::error::pins file not readable: $pins" >&2; exit 2; }

# KEY=value, first match; comments and blank lines are not keys.
pin() {
  awk -F= -v k="$1" '$1 == k { print $2; exit }' "$pins"
}

image="$(pin BUILDKIT_IMAGE)"
pinned_re='^docker\.io/moby/buildkit:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$'
if ! [[ "$image" =~ $pinned_re ]]; then
  echo "::error::BUILDKIT_IMAGE in $pins is '$image', not docker.io/moby/buildkit:<tag>@sha256:<digest>." >&2
  exit 2
fi
if [[ -n "$config" && ! -r "$config" ]]; then
  echo "::error::BUILDKITD_CONFIG is not a readable file: $config" >&2
  exit 2
fi

if [[ -z "$name" ]]; then
  name="builder-${GITHUB_RUN_ID:-local}-$RANDOM$RANDOM"
fi

args=(buildx create --name "$name" --driver docker-container --driver-opt "image=$image")
while IFS= read -r opt; do
  [[ -n "$opt" ]] || continue
  args+=(--driver-opt "$opt")
done <<< "$driver_opts"
if [[ -n "$config" ]]; then
  args+=(--buildkitd-config "$config")
fi
if [[ -n "$flags" ]]; then
  args+=(--buildkitd-flags "$flags")
fi
args+=(--bootstrap --use)

echo "Creating builder $name with $image"
if ! docker "${args[@]}"; then
  echo "::error::docker buildx create failed for builder $name." >&2
  exit 1
fi

# awk reads the whole report: an early exit would close the pipe under
# docker, which then dies with SIGPIPE and pipefail makes that the status.
platforms="$(docker buildx inspect "$name" | awk -F': *' '/^Platforms:/ && !seen { print $2; seen = 1 }' | tr -d ' ')"
echo "Builder $name is ready; platforms: ${platforms:-unknown}"
printf 'name=%s\ndriver=docker-container\nplatforms=%s\n' "$name" "$platforms"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'name=%s\ndriver=docker-container\nplatforms=%s\n' "$name" "$platforms" >> "$GITHUB_OUTPUT"
fi
