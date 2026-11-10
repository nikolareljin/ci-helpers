#!/usr/bin/env bash
# SCRIPT: unity_test.sh
# DESCRIPTION: Run a Unity project's EditMode and PlayMode tests in the
#              unityci/editor image, as the replaced game-ci/unity-test-runner
#              action ran them, with no third-party action. The image is
#              pinned by tag and index digest in toolchain-pins.env, one line
#              per editor version (UNITY_EDITOR_IMAGE_<version, dots as _>);
#              a version without a line is refused with the line to add. The
#              editor version is read from ProjectSettings/ProjectVersion.txt
#              as the action read it, unless UNITY_VERSION names one.
#
#              The container runs scripts/unity_container.sh: activate with
#              the serial, run each test platform, write NUnit XML and the
#              editor log under ARTIFACTS_PATH. It sees the project
#              directory, the artifacts directory and CodeCoverage, each at
#              its workspace path under /github/workspace, and nothing else
#              of the workspace or of this library: the directory this
#              script runs from is never mounted. The licence secrets reach the
#              container as `--env NAME` (the value comes from this process's
#              environment, never from an argument); a Personal licence file
#              (UNITY_LICENSE) is turned into its serial here with bash
#              builtins and a pipe, as the action did. The activation log
#              stays in the container and is printed, redacted, only when
#              activation fails.
#
#              `--return-license`, in an always() step, returns the licence a
#              test run activated: a second container on the same image and
#              the same home directory. Nothing to return exits 0.
# USAGE: bash scripts/unity_test.sh                  # activate and test
#        bash scripts/unity_test.sh --return-license   # afterwards, always()
# ENVIRONMENT:
#   PROJECT_PATH       Directory holding Assets/ and ProjectSettings/, relative
#                      to GITHUB_WORKSPACE (default: .).
#   UNITY_VERSION      `auto` (default) reads ProjectVersion.txt; else a
#                      version such as 6000.0.23f1.
#   TEST_MODE          all (default, as the action), editmode or playmode.
#                      `all` runs playmode, editmode and a combining pass.
#   ARTIFACTS_PATH     Where results and logs go, relative to the workspace
#                      (default: artifacts).
#   COVERAGE_ENABLED   true (default) or false: -enableCodeCoverage and the
#                      coverage options, or neither.
#   COVERAGE_OPTIONS   -coverageOptions value (default: the action's).
#   CUSTOM_PARAMETERS  Extra editor arguments, split on whitespace.
#   UNITY_LICENSE      Contents of a Personal .ulf; its serial is derived.
#   UNITY_SERIAL       A serial, instead of UNITY_LICENSE.
#   UNITY_EMAIL, UNITY_PASSWORD
#                      The Unity account; both are needed.
#   TOOLCHAIN_PINS     Pins file (default: toolchain-pins.env beside scripts/).
#   GITHUB_WORKSPACE   The checkout (default: the current directory).
#   RUNNER_TEMP        Where the home directory, the blank project and the
#                      container script copy go (default: mktemp -d).
#   GITHUB_OUTPUT      Written when set.
#   An input of the action that has no equivalent here (CUSTOM_IMAGE,
#   PACKAGE_MODE, UNITY_LICENSING_SERVER, SSH_AGENT, ...) is refused when set.
# OUTPUT: artifactsPath=<ARTIFACTS_PATH>, coveragePath=CodeCoverage and
#         image=<pinned image> on stdout and, when GITHUB_OUTPUT is set,
#         appended there. artifactsPath is written before the editor runs, so
#         a failing run still uploads its results.
# EXIT CODES:
#   0  Every test passed, or the licence was returned (or there was none).
#   2  Some tests failed (the editor's own code); the results are written.
#   3  The editor reported a failure other than a failing test.
#   4  Refused before anything ran: bad input, no docker, a non-Linux runner,
#      no ProjectVersion.txt, no pin for the version, a pin that is not
#      docker.io/unityci/editor:<tag for the version>@sha256:<digest>, a
#      missing credential, or an unsupported input set.
#   *  Any other code the editor or docker exited with, as it came.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="${TOOLCHAIN_PINS:-$script_dir/../toolchain-pins.env}"
workspace="${GITHUB_WORKSPACE:-$PWD}"
mode="test"
case "${1:-}" in
  "") ;;
  --return-license) mode="return" ;;
  *) echo "::error::unknown argument '$1'; the only flag is --return-license." >&2; exit 4 ;;
esac

refuse() { echo "::error::$*" >&2; exit 4; }

command -v docker >/dev/null 2>&1 || refuse "docker is not on PATH."
[[ "$(uname -s)" == Linux ]] || refuse "the editor runs in the ubuntu image on a Linux runner with docker; the replaced action had the same limit."

if [[ -n "${RUNNER_TEMP:-}" ]]; then
  work="${RUNNER_TEMP}/ci-helpers-unity"
else
  work="$(mktemp -d)"
fi
mkdir -p "$work"
chmod 0700 "$work"
home="$work/home"
blank="$work/BlankProject"
steps="$work/steps"
marker="$work/activated"
image_file="$work/image"

# The container script, copied so the mount holds that one file.
mkdir -p "$steps"
install -m 0755 "$script_dir/unity_container.sh" "$steps/unity_container.sh"

# The pins file is read before the env variables with the same names are
# relied on; KEY=value, first match; comments and blank lines are not keys.
pin() {
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$pins"
}

# run_container <image> <step> <argv...>: docker run with the common flags,
# the home directory, the blank project and the container script, printing
# the command first. Secrets are `--env NAME`, read by docker from this
# environment.
run_container() {
  local image="$1" step="$2"; shift 2
  local cmd=(docker run --rm --shm-size=1025m --workdir /github/workspace
             --security-opt no-new-privileges
             --cap-drop NET_RAW --cap-drop MKNOD --cap-drop SYS_CHROOT
             --cap-drop SETFCAP --cap-drop AUDIT_WRITE
             --cidfile "$work/cid"
             --env "CI_HELPERS_UNITY_STEP=$step"
             --env UNITY_EMAIL --env UNITY_PASSWORD
             --volume "$home:/root"
             --volume "$blank:/BlankProject"
             --volume "$steps:/steps:ro"
             "$@"
             "$image" /bin/bash /steps/unity_container.sh)
  rm -f "$work/cid"
  printf '%s ' "${cmd[@]}"; echo
  "${cmd[@]}"
}

if [[ "$mode" == return ]]; then
  if [[ ! -f "$marker" ]]; then
    echo "No licence was activated by this run; nothing to return."
    exit 0
  fi
  [[ -n "${UNITY_EMAIL:-}" && -n "${UNITY_PASSWORD:-}" ]] || refuse "UNITY_EMAIL and UNITY_PASSWORD are needed to return the licence."
  # Recorded by the test run in a directory no container sees; checked
  # against the pin shape again all the same.
  image="$(head -n 1 "$image_file" 2>/dev/null || true)"
  [[ "$image" =~ ^docker\.io/unityci/editor:ubuntu-[0-9]+\.[0-9]+\.[0-9]+[a-z][0-9]+-(linux-il2cpp|base)-[0-9]+(\.[0-9]+)*@sha256:[0-9a-f]{64}$ ]] \
    || refuse "no pinned image recorded by the test run in $image_file; cannot return the licence."
  # A cancelled or timed-out test step kills the docker client, not the
  # container: --rm only removes it once it exits. Stop it before a second
  # editor opens the same home directory.
  left="$(head -n 1 "$work/cid" 2>/dev/null || true)"
  if [[ "$left" =~ ^[0-9a-f]{64}$ ]]; then
    docker rm -f "$left" >/dev/null 2>&1 || true
  fi
  echo "Returning the licence activated by this run"
  rc=0
  run_container "$image" return || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "::warning::returning the licence failed (exit $rc); a Pro or Plus seat may stay in use until Unity's servers release it."
  else
    rm -f "$marker"
  fi
  exit 0
fi

# ---- inputs, as the action read them ----
unsupported=(
  CUSTOM_IMAGE:customImage PACKAGE_MODE:packageMode SCOPED_REGISTRY_URL:scopedRegistryUrl
  REGISTRY_SCOPES:registryScopes SSH_AGENT:sshAgent SSH_PUBLIC_KEYS_DIRECTORY_PATH:sshPublicKeysDirectoryPath
  GIT_PRIVATE_TOKEN:gitPrivateToken USE_HOST_NETWORK:useHostNetwork CHOWN_FILES_TO:chownFilesTo
  RUN_AS_HOST_USER:runAsHostUser DOCKER_CPU_LIMIT:dockerCpuLimit DOCKER_MEMORY_LIMIT:dockerMemoryLimit
  DOCKER_ISOLATION_MODE:dockerIsolationMode UNITY_LICENSING_SERVER:unityLicensingServer
  CONTAINER_REGISTRY_REPOSITORY:containerRegistryRepository
  CONTAINER_REGISTRY_IMAGE_VERSION:containerRegistryImageVersion CHECK_NAME:checkName
)
for pair in "${unsupported[@]}"; do
  var="${pair%%:*}"
  if [[ -n "${!var:-}" ]]; then
    refuse "$var is set; the action's input ${pair#*:} has no equivalent in this script. Unset it."
  fi
done

# A workspace-relative directory: not absolute, no `..` segment, no newline,
# a trailing slash dropped; as the action's folder-name check meant it.
rel_dir() {
  local name="$1" value="$2"
  [[ "$value" != *$'\n'* ]] || refuse "$name must be one line."
  value="${value%/}"
  value="${value#./}"
  [[ -n "$value" ]] || value=.
  [[ "$value" == . ]] && { printf '.\n'; return 0; }
  [[ "$value" != /* ]] || refuse "$name must be relative to the workspace, not '$value'."
  case "/$value/" in
    */../*) refuse "$name must not contain '..': '$value'." ;;
    */./*) refuse "$name must not contain a '.' segment: '$value'." ;;
  esac
  printf '%s\n' "$value"
}
# The project controls its tree, so a path reaches the editor only when it
# is plain and no component of it is a symlink: a link to /, to the runner's
# home or to RUNNER_TEMP (where this library's copy lives) would otherwise
# hand the container that directory.
plain_re='^[A-Za-z0-9._~@+ -]+(/[A-Za-z0-9._~@+ -]+)*$'
no_symlinks() {
  local rel="$1" walk="$workspace" part parts
  [[ "$rel" == . ]] && return 0
  [[ "$rel" =~ $plain_re ]] || refuse "'$rel' is not a plain relative path (letters, digits, . _ ~ @ + - and spaces, with / between)."
  IFS=/ read -r -a parts <<< "$rel"
  for part in "${parts[@]}"; do
    walk="$walk/$part"
    [[ -L "$walk" ]] && refuse "'$walk' is a symlink; the container mounts only real directories of the workspace."
  done
  return 0
}
project_path="$(rel_dir PROJECT_PATH "${PROJECT_PATH:-.}")"
artifacts_path="$(rel_dir ARTIFACTS_PATH "${ARTIFACTS_PATH:-artifacts}")"
no_symlinks "$project_path"
no_symlinks "$artifacts_path"
[[ -d "$workspace/$project_path" ]] || refuse "PROJECT_PATH '$project_path' is not a directory under $workspace."

test_mode="${TEST_MODE:-all}"
case "$test_mode" in
  all) platforms="playmode;editmode;COMBINE_RESULTS" ;;
  editmode|playmode) platforms="$test_mode" ;;
  standalone) refuse "TEST_MODE standalone needs the action's player build scripts, which this script does not carry; use all, editmode or playmode." ;;
  *) refuse "TEST_MODE must be all, editmode or playmode, not '$test_mode'." ;;
esac

coverage_enabled="${COVERAGE_ENABLED:-true}"
case "$coverage_enabled" in
  true|false) ;;
  *) refuse "COVERAGE_ENABLED is '$coverage_enabled', not true or false." ;;
esac
coverage_options="${COVERAGE_OPTIONS:-generateAdditionalMetrics;generateHtmlReport;generateBadgeReport;dontClear}"
custom_parameters="${CUSTOM_PARAMETERS:-}"

# The version: ProjectVersion.txt as the action read it, or UNITY_VERSION.
version_re='^[0-9]+\.[0-9]+\.[0-9]+[a-z][0-9]+$'
version="${UNITY_VERSION:-auto}"
if [[ "$version" == auto ]]; then
  pv="$workspace/$project_path/ProjectSettings/ProjectVersion.txt"
  [[ -f "$pv" ]] || refuse "no $pv; set PROJECT_PATH to the directory holding ProjectSettings/, or UNITY_VERSION."
  version="$(sed -n 's/^m_EditorVersion: *\([0-9][0-9.]*[A-Za-z][0-9]*\).*/\1/p' "$pv" | head -n 1)"
  [[ -n "$version" ]] || refuse "no m_EditorVersion line in $pv."
fi
[[ "$version" =~ $version_re ]] || refuse "the editor version '$version' is not <year>.<minor>.<patch><letter><build>, such as 6000.0.23f1."

# The image tag the action built for a Linux runner: linux-il2cpp from Unity
# 2019.3, base before it; rolling image version 3.
major="${version%%.*}"; rest="${version#*.}"; minor="${rest%%.*}"
if (( major > 2019 || (major == 2019 && minor >= 3) )); then suffix=linux-il2cpp; else suffix=base; fi
tag="ubuntu-${version}-${suffix}-3"
key="UNITY_EDITOR_IMAGE_${version//./_}"
[[ -r "$pins" ]] || refuse "pins file not readable: $pins"
image="$(pin "$key")"
pinned_re="^docker\.io/unityci/editor:ubuntu-${version//./\\.}-${suffix}-[0-9]+(\.[0-9]+)*@sha256:[0-9a-f]{64}$"
if [[ -z "$image" ]]; then
  {
    echo "::error::Unity ${version} has no image pin. Resolve the digest of docker.io/unityci/editor:${tag} from two sources, for example"
    echo "  docker buildx imagetools inspect docker.io/unityci/editor:${tag} --format '{{.Manifest.Digest}}'"
    echo "and Docker Hub's tag page, and when they agree add this line to toolchain-pins.env in a pull request:"
    echo "  ${key}=docker.io/unityci/editor:${tag}@sha256:<digest>"
  } >&2
  exit 4
fi
if ! [[ "$image" =~ $pinned_re ]]; then
  refuse "$key in $pins is '$image', not docker.io/unityci/editor:ubuntu-${version}-${suffix}-<n>@sha256:<digest>."
fi

# ---- the licence: a serial, given or derived from the .ulf ----
[[ -n "${UNITY_EMAIL:-}" && -n "${UNITY_PASSWORD:-}" ]] || refuse "UNITY_EMAIL and UNITY_PASSWORD are needed with either licence kind."
serial="${UNITY_SERIAL:-}"
if [[ -z "$serial" ]]; then
  [[ -n "${UNITY_LICENSE:-}" ]] || refuse "neither UNITY_SERIAL nor UNITY_LICENSE is set; nothing can activate."
  # <DeveloperData Value="base64"/>: the serial after a 4-byte prefix, as the
  # action decoded it. The value goes to base64 on a pipe, not as an argument.
  lic="$UNITY_LICENSE"
  [[ "$lic" == *'<DeveloperData Value="'* ]] || refuse "UNITY_LICENSE holds no <DeveloperData Value=...> element; paste the whole .ulf file."
  enc="${lic#*<DeveloperData Value=\"}"
  enc="${enc%%\"*}"
  serial="$(printf '%s' "$enc" | base64 -d 2>/dev/null | tail -c +5 | tr -d '\000\r\n' || true)"
  [[ ${#serial} -eq 27 ]] || refuse "the serial in UNITY_LICENSE is not 27 characters; the file may be truncated or from another activation."
fi
[[ "$serial" != *$'\n'* && "$serial" != *' '* ]] || refuse "UNITY_SERIAL must be one word."
export UNITY_SERIAL="$serial"
# Not relied on: the value is in no argument. The editor prints the serial
# with its last four characters as XXXX, so that form is masked too.
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "::add-mask::${serial}"
  echo "::add-mask::${serial:0:${#serial}-4}XXXX"
fi

# ---- the mounts: the project, the results and the coverage, nothing else ----
# Each at its workspace path, so the container's paths read as the action's
# did. A destination inside another is a nested mount, which docker orders.
# A mount is checked again here (CodeCoverage is not an input) and must
# resolve under the workspace and outside RUNNER_TEMP.
mounts=()
seen=" "
ws_real="$(realpath -e "$workspace")" || refuse "GITHUB_WORKSPACE '$workspace' does not resolve."
temp_real=""
[[ -n "${RUNNER_TEMP:-}" && -d "${RUNNER_TEMP}" ]] && temp_real="$(realpath -e "$RUNNER_TEMP")"
mount_dir() {
  local rel="$1" dest="/github/workspace/$1" host="$workspace/$1" real
  [[ "$rel" == . ]] && { dest=/github/workspace; host="$workspace"; }
  case "$seen" in *" $dest "*) return 0 ;; esac
  seen="$seen$dest "
  no_symlinks "$rel"
  mkdir -p "$host"
  real="$(realpath -e "$host")" || refuse "'$host' does not resolve."
  [[ "$real" == "$ws_real" || "$real" == "$ws_real/"* ]] || refuse "'$host' resolves to '$real', outside the workspace."
  [[ -z "$temp_real" || ( "$real" != "$temp_real" && "$real" != "$temp_real/"* ) ]] || refuse "'$host' resolves into RUNNER_TEMP; refused."
  mounts+=(--volume "$real:$dest")
}
mount_dir "$project_path"
mount_dir "$artifacts_path"
[[ "$coverage_enabled" == true ]] && mount_dir CodeCoverage

# ---- outputs first: a failing run still uploads its results ----
printf 'artifactsPath=%s\ncoveragePath=CodeCoverage\nimage=%s\n' "$artifacts_path" "$image"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'artifactsPath=%s\ncoveragePath=CodeCoverage\nimage=%s\n' "$artifacts_path" "$image" >> "$GITHUB_OUTPUT"
fi

# ---- the home directory and the blank project the activation opens ----
mkdir -p "$home" "$blank/Assets" "$blank/Packages" "$blank/ProjectSettings"
chmod 0700 "$home"
printf 'm_EditorVersion: %s\n' "$version" > "$blank/ProjectSettings/ProjectVersion.txt"
printf '{\n  "dependencies": {}\n}\n' > "$blank/Packages/manifest.json"
printf '%s\n' "$image" > "$image_file"

# The action gave the container every core and 95% of memory.
resources=()
if command -v nproc >/dev/null 2>&1; then resources+=("--cpus=$(nproc)"); fi
if [[ -r /proc/meminfo ]]; then
  mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
  [[ "$mem_kb" =~ ^[0-9]+$ ]] && resources+=("--memory=$(( mem_kb / 1024 * 95 / 100 ))m")
fi

export TEST_PLATFORMS="$platforms" UNITY_VERSION="$version" PROJECT_PATH="$project_path" \
       ARTIFACTS_PATH="$artifacts_path" COVERAGE_ENABLED="$coverage_enabled" \
       COVERAGE_OPTIONS="$coverage_options" COVERAGE_RESULTS_PATH=CodeCoverage \
       CUSTOM_PARAMETERS="$custom_parameters" \
       UNITY_ACTIVATION_RETRY_DELAY="${UNITY_ACTIVATION_RETRY_DELAY:-15}"

echo "Unity ${version}: ${test_mode} tests of ${project_path} in ${image}"
: > "$marker"
rc=0
run_container "$image" test \
  --env UNITY_SERIAL \
  --env TEST_PLATFORMS --env UNITY_VERSION --env PROJECT_PATH --env ARTIFACTS_PATH \
  --env COVERAGE_ENABLED --env COVERAGE_OPTIONS --env COVERAGE_RESULTS_PATH \
  --env CUSTOM_PARAMETERS --env UNITY_ACTIVATION_RETRY_DELAY \
  --env GITHUB_WORKSPACE=/github/workspace \
  "${mounts[@]}" \
  ${resources[@]+"${resources[@]}"} || rc=$?

case "$rc" in
  0) echo "Every test passed. Results: ${artifacts_path}/" ;;
  2) echo "::error::some tests failed; the NUnit XML and the editor log are under ${artifacts_path}/." >&2 ;;
  3) echo "::error::the editor reported a failure other than a failing test (exit 3); read ${artifacts_path}/*.log." >&2 ;;
  125|126|127) echo "::error::docker could not run ${image} (exit $rc)." >&2 ;;
  *) echo "::error::the editor run exited $rc; read ${artifacts_path}/*.log." >&2 ;;
esac
exit "$rc"
