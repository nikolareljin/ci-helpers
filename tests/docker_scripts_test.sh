#!/usr/bin/env bash
# SCRIPT: docker_scripts_test.sh
# DESCRIPTION: The four scripts behind docker-multiarch.yml build the docker
#              command lines the replaced actions built: setup_qemu.sh runs
#              the binfmt image pinned by digest and refuses an unpinned one;
#              setup_buildx.sh creates a docker-container builder on the
#              pinned BuildKit image and refuses a runner without buildx;
#              docker_login.sh hands the password to docker on stdin, never
#              in argv, and refuses an empty credential or an ECR host;
#              docker_build.sh passes every input as its own argument, keeps a
#              build secret out of argv and out of the printed command, and
#              reads the digest from the metadata file. A stub docker records
#              its argv, stdin and environment; nothing is pulled or built.
# USAGE: bash tests/docker_scripts_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# The stub: every call appends its argv to STUB_LOG, stdin to STUB_STDIN and
# the CI_HELPERS_SECRET_* and STUB_VAR_* variables it sees to STUB_ENV.
# STUB_FAIL names a subcommand that exits 1. A `buildx build` writes the
# iid and metadata files it is given (STUB_DIGEST, empty for none).
mkdir -p "$work/stub"
cat > "$work/stub/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_LOG"
if [[ ! -t 0 ]]; then cat >> "$STUB_STDIN"; fi
env | grep -E '^(CI_HELPERS_SECRET_|STUB_VAR_)' >> "$STUB_ENV" || true
sub="$1"; [[ "$1" == buildx ]] && sub="buildx $2"
if [[ "$sub" == "${STUB_FAIL:-}" ]]; then echo "stub: $sub failed" >&2; exit 1; fi
case "$sub" in
  "buildx version") echo "github.com/docker/buildx v0.0.0-stub" ;;
  "buildx inspect") printf 'Name: x\nDriver: docker-container\nPlatforms: linux/amd64, linux/arm64\n' ;;
  "buildx build")
    prev=""
    for a in "$@"; do
      case "$prev" in
        --iidfile) echo "sha256:1111111111111111111111111111111111111111111111111111111111111111" > "$a" ;;
        --metadata-file) printf '{"containerimage.digest": "%s", "image.name": "x"}\n' "${STUB_DIGEST-sha256:2222222222222222222222222222222222222222222222222222222222222222}" > "$a" ;;
      esac
      prev="$a"
    done ;;
  run)
    # binfmt with no arguments lists the platforms it supports.
    if [[ "${*: -1}" == *@sha256:* ]]; then echo '{"supported": ["linux/amd64", "linux/arm64"], "emulators": []}'; fi ;;
esac
STUB
chmod +x "$work/stub/docker"

cat > "$work/pins.env" <<'EOF'
# test pins
BINFMT_IMAGE=docker.io/tonistiigi/binfmt:qemu-v1.0.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BUILDKIT_IMAGE=docker.io/moby/buildkit:v1.0.0@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
cat > "$work/unpinned.env" <<'EOF'
BINFMT_IMAGE=docker.io/tonistiigi/binfmt:latest
BUILDKIT_IMAGE=docker.io/moby/buildkit:buildx-stable-1
EOF

# run <name> <expected rc> <script> [args...]; the caller sets the environment.
run() {
  local name="$1" want="$2" script="$3" rc=0; shift 3
  rm -rf "${work:?}/gh"; mkdir -p "$work/gh"
  : > "$work/log"; : > "$work/stdin"; : > "$work/env"
  PATH="$work/stub:$PATH" STUB_LOG="$work/log" STUB_STDIN="$work/stdin" STUB_ENV="$work/env" \
    TOOLCHAIN_PINS="${PINS:-$work/pins.env}" RUNNER_TEMP="$work" GITHUB_OUTPUT="$work/gh/out" \
    bash "$root/scripts/$script" "$@" > "$work/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 1
  fi
  return 0
}
# called <argv line>: the stub saw exactly this call
called() {
  grep -qxF -- "$1" "$work/log" || { echo "FAIL $name: docker was not called with '$1':"; cat "$work/log"; fail=1; }
}
not_called() {
  if grep -qF -- "$1" "$work/log"; then echo "FAIL $name: docker was called with '$1'"; cat "$work/log"; fail=1; fi
}
says() {
  grep -qF -- "$1" "$work/out" || { echo "FAIL $name: no '$1' in output:"; cat "$work/out"; fail=1; }
}
output_has() {
  grep -qxF -- "$1" "$work/gh/out" || { echo "FAIL $name: GITHUB_OUTPUT lacks '$1':"; cat "$work/gh/out"; fail=1; }
}
# build_args: the one `buildx build` argv line
build_args() { grep '^buildx build ' "$work/log"; }
build_has() {
  build_args | grep -qF -- "$1" || { echo "FAIL $name: build argv lacks '$1':"; build_args; fail=1; }
}
build_lacks() {
  if build_args | grep -qF -- "$1"; then echo "FAIL $name: build argv holds '$1':"; build_args; fail=1; fi
}

binfmt="docker.io/tonistiigi/binfmt:qemu-v1.0.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
buildkit="docker.io/moby/buildkit:v1.0.0@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ---- setup_qemu.sh ----
name="qemu installs the pinned image for the given platforms"
if QEMU_PLATFORMS=linux/amd64,linux/arm64 run "$name" 0 setup_qemu.sh; then
  called "run --rm --privileged $binfmt --install linux/amd64,linux/arm64"
  output_has "platforms=linux/amd64,linux/arm64"
fi

name="qemu defaults to all platforms, as the action did"
run "$name" 0 setup_qemu.sh && called "run --rm --privileged $binfmt --install all"

name="qemu refuses a pin without a digest and pulls nothing"
PINS="$work/unpinned.env" run "$name" 2 setup_qemu.sh && says "not docker.io/tonistiigi/binfmt:<tag>@sha256:<digest>"
[[ -s "$work/log" ]] && { echo "FAIL $name: docker was called"; fail=1; }

name="qemu refuses platforms with whitespace"
QEMU_PLATFORMS="linux/amd64 linux/arm64" run "$name" 2 setup_qemu.sh && not_called "run"

name="qemu fails when docker run fails"
STUB_FAIL=run run "$name" 1 setup_qemu.sh && says "--install all failed"

# ---- setup_buildx.sh ----
name="buildx creates a docker-container builder on the pinned BuildKit image"
if BUILDX_NAME=b1 run "$name" 0 setup_buildx.sh; then
  called "buildx create --name b1 --driver docker-container --driver-opt image=$buildkit --bootstrap --use"
  output_has "name=b1"
  output_has "driver=docker-container"
  output_has "platforms=linux/amd64,linux/arm64"
fi

name="buildx names the builder when none is given"
if run "$name" 0 setup_buildx.sh; then
  grep -q '^buildx create --name builder-' "$work/log" || { echo "FAIL $name: no generated name:"; cat "$work/log"; fail=1; }
fi

name="buildx passes driver options, a config file and daemon flags"
printf '[registry."127.0.0.1:5000"]\n  http = true\n' > "$work/buildkitd.toml"
if BUILDX_NAME=b2 BUILDX_DRIVER_OPTS=$'network=host\nenv.X=1' BUILDKITD_CONFIG="$work/buildkitd.toml" BUILDKITD_FLAGS="--debug" run "$name" 0 setup_buildx.sh; then
  called "buildx create --name b2 --driver docker-container --driver-opt image=$buildkit --driver-opt network=host --driver-opt env.X=1 --buildkitd-config $work/buildkitd.toml --buildkitd-flags --debug --bootstrap --use"
fi

name="buildx refuses a config file that is not there"
BUILDX_NAME=b3 BUILDKITD_CONFIG="$work/none.toml" run "$name" 2 setup_buildx.sh && not_called "buildx create"

name="buildx refuses a pin without a digest"
PINS="$work/unpinned.env" BUILDX_NAME=b4 run "$name" 2 setup_buildx.sh && not_called "buildx create"

name="buildx refuses a runner without the plugin, with the fix"
STUB_FAIL="buildx version" run "$name" 2 setup_buildx.sh && says "docker-buildx-plugin"

name="buildx fails when create fails"
STUB_FAIL="buildx create" BUILDX_NAME=b5 run "$name" 1 setup_buildx.sh && says "docker buildx create failed"

name="buildx --remove removes the named builder"
BUILDX_NAME=b1 run "$name" 0 setup_buildx.sh --remove && called "buildx rm b1"

name="buildx --remove needs a name"
run "$name" 2 setup_buildx.sh --remove && not_called "buildx rm"

# ---- docker_login.sh ----
name="login hands the password on stdin, not in argv"
if REGISTRY=ghcr.io REGISTRY_USERNAME=octocat REGISTRY_PASSWORD='s3cr3t-token' run "$name" 0 docker_login.sh; then
  called "login --username octocat --password-stdin ghcr.io"
  [[ "$(cat "$work/stdin")" == "s3cr3t-token" ]] || { echo "FAIL $name: stdin was '$(cat "$work/stdin")'"; fail=1; }
  if grep -qF 's3cr3t-token' "$work/log" "$work/out"; then echo "FAIL $name: the password is in argv or the log"; fail=1; fi
fi

name="login with no registry is Docker Hub"
REGISTRY='' REGISTRY_USERNAME=u REGISTRY_PASSWORD=p run "$name" 0 docker_login.sh && called "login --username u --password-stdin"

name="login refuses an empty password without calling docker"
REGISTRY=ghcr.io REGISTRY_USERNAME=u REGISTRY_PASSWORD='' run "$name" 2 docker_login.sh && says "REGISTRY_PASSWORD is empty"
[[ -s "$work/log" ]] && { echo "FAIL $name: docker was called"; fail=1; }

name="login refuses an empty username"
REGISTRY=ghcr.io REGISTRY_USERNAME='' REGISTRY_PASSWORD=p run "$name" 2 docker_login.sh && says "REGISTRY_USERNAME is empty"

name="login refuses an ECR host and names the fix"
REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com REGISTRY_USERNAME=AKIA REGISTRY_PASSWORD=p run "$name" 2 docker_login.sh && says "aws ecr get-login-password"
[[ -s "$work/log" ]] && { echo "FAIL $name: docker was called"; fail=1; }

name="login refuses a registry with whitespace"
REGISTRY="ghcr.io x" REGISTRY_USERNAME=u REGISTRY_PASSWORD=p run "$name" 2 docker_login.sh && not_called login

name="login fails when docker login fails"
STUB_FAIL=login REGISTRY=ghcr.io REGISTRY_USERNAME=u REGISTRY_PASSWORD=p run "$name" 1 docker_login.sh && says "docker login ghcr.io as u failed"

name="logout logs out of the registry"
REGISTRY=ghcr.io run "$name" 0 docker_login.sh --logout && called "logout ghcr.io"

name="logout with no registry is Docker Hub"
REGISTRY='' run "$name" 0 docker_login.sh --logout && called "logout"

# ---- docker_build.sh ----
name="build passes every input as the action did and pushes"
if CONTEXT=./app DOCKERFILE=docker/Dockerfile PLATFORMS=linux/amd64,linux/arm64 \
   TAGS=$'ghcr.io/o/r:1.2.3,ghcr.io/o/r:latest' LABELS=$'org.opencontainers.image.source=https://example.test/r\nb=2' \
   BUILD_ARGS=$'VERSION=1.2.3\nEMPTY=' PUSH=true CACHE_FROM=type=gha CACHE_TO=type=gha,mode=max TARGET=runtime \
   BUILDER=b1 GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=2 \
   run "$name" 0 docker_build.sh; then
  build_has " --builder b1 "
  build_has " --file docker/Dockerfile "
  build_has " --target runtime "
  build_has " --build-arg VERSION=1.2.3 --build-arg EMPTY= "
  build_has " --cache-from type=gha --cache-to type=gha,mode=max "
  build_has " --label org.opencontainers.image.source=https://example.test/r --label b=2 "
  build_has " --tag ghcr.io/o/r:1.2.3 --tag ghcr.io/o/r:latest "
  build_has " --platform linux/amd64,linux/arm64 "
  build_has " --attest type=provenance,mode=max,builder-id=https://github.com/o/r/actions/runs/7/attempts/2 "
  build_has " --push "
  build_lacks " --load"
  build_lacks " --sbom"
  build_args | grep -qE -- ' -- \./app$' || { echo "FAIL $name: context is not the last argument:"; build_args; fail=1; }
  output_has "digest=sha256:2222222222222222222222222222222222222222222222222222222222222222"
  output_has "imageid=sha256:1111111111111111111111111111111111111111111111111111111111111111"
  grep -q '^metadata_file=' "$work/gh/out" || { echo "FAIL $name: no metadata_file output"; fail=1; }
  # The build-arg value is on the command line (as before) but not in the log.
  grep -q -- '--build-arg VERSION=\*\*\*' "$work/out" || { echo "FAIL $name: the printed command does not mask the build-arg:"; cat "$work/out"; fail=1; }
  if grep -q 'VERSION=1.2.3' "$work/out"; then echo "FAIL $name: the build-arg value is in the log"; fail=1; fi
fi

name="build secret goes by environment, never argv, never the log"
if TAGS=t BUILD_SECRETS=$'npm_token=hunter2-value\nother.id=x' PUSH=false run "$name" 0 docker_build.sh; then
  build_has " --secret id=npm_token,env=CI_HELPERS_SECRET_1 --secret id=other.id,env=CI_HELPERS_SECRET_2 "
  if grep -q 'hunter2-value' "$work/log" "$work/out"; then echo "FAIL $name: the secret value is in argv or the log"; fail=1; fi
  build_lacks "--build-arg"
  grep -qxF 'CI_HELPERS_SECRET_1=hunter2-value' "$work/env" || { echo "FAIL $name: docker did not see the secret in its environment:"; cat "$work/env"; fail=1; }
fi

name="build secret from a named variable"
if TAGS=t BUILD_SECRET_ENVS=$'gh=STUB_VAR_GH' STUB_VAR_GH=tok-value run "$name" 0 docker_build.sh; then
  build_has " --secret id=gh,env=STUB_VAR_GH "
  if grep -q 'tok-value' "$work/log" "$work/out"; then echo "FAIL $name: the secret value is in argv or the log"; fail=1; fi
fi

name="build secret from an unset variable is refused"
TAGS=t BUILD_SECRET_ENVS=$'gh=STUB_VAR_NOPE' run "$name" 2 docker_build.sh && not_called "buildx build"

name="build secret id with a comma is refused"
TAGS=t BUILD_SECRETS='a,b=1' run "$name" 2 docker_build.sh && says "not [A-Za-z0-9._-]+"
not_called "buildx build"

name="build secret id given twice is refused"
TAGS=t BUILD_SECRETS=$'a=1\na=2' run "$name" 2 docker_build.sh && says "given twice"

name="build secret line without = is refused"
TAGS=t BUILD_SECRETS='justid' run "$name" 2 docker_build.sh && says "without '='"

name="private repository gets the action's minimal provenance"
if TAGS=t REPOSITORY_PRIVATE=true run "$name" 0 docker_build.sh; then
  build_has " --attest type=provenance,mode=min,inline-only=true "
fi

name="provenance false, true and attributes"
TAGS=t PROVENANCE=false run "$name" 0 docker_build.sh && build_has " --provenance=false "
TAGS=t PROVENANCE=true GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=7 run "$name" 0 docker_build.sh \
  && build_has " --attest type=provenance,builder-id=https://github.com/o/r/actions/runs/7/attempts/1 "
TAGS=t PROVENANCE=mode=min run "$name" 0 docker_build.sh && build_has " --attest type=provenance,mode=min "

name="sbom true, false and attributes"
TAGS=t SBOM=true run "$name" 0 docker_build.sh && build_has " --sbom=true "
TAGS=t SBOM=false run "$name" 0 docker_build.sh && build_has " --sbom=false "
TAGS=t SBOM=generator=x run "$name" 0 docker_build.sh && build_has " --attest type=sbom,generator=x "

name="an image loaded into the engine gets no default provenance"
if TAGS=t LOAD=true run "$name" 0 docker_build.sh; then
  build_has " --load "
  build_lacks "provenance"
fi
if TAGS=t OUTPUTS='type=docker,dest=/tmp/x.tar' run "$name" 0 docker_build.sh; then
  build_has " --output type=docker,dest=/tmp/x.tar "
  build_lacks "provenance"
fi

name="outputs, pull and no-cache"
if TAGS=t OUTPUTS=$'type=oci,dest=/tmp/img.tar\ntype=cacheonly' PULL=true NO_CACHE=true run "$name" 0 docker_build.sh; then
  build_has " --output type=oci,dest=/tmp/img.tar --output type=cacheonly "
  build_has " --pull --no-cache "
fi

name="a pushed image without a digest fails"
STUB_DIGEST='' TAGS=t PUSH=true run "$name" 1 docker_build.sh && says "no containerimage.digest"

name="a build that is not pushed may have no digest"
if STUB_DIGEST='' TAGS=t run "$name" 0 docker_build.sh; then
  output_has "digest="
fi

name="a true/false input with another value is refused"
TAGS=t PUSH=yes run "$name" 2 docker_build.sh && says "not true or false"
not_called "buildx build"

name="the build failing fails"
STUB_FAIL="buildx build" TAGS=t run "$name" 1 docker_build.sh && says "docker buildx build failed"

name="build refuses a runner without buildx"
STUB_FAIL="buildx version" TAGS=t run "$name" 2 docker_build.sh && says "setup_buildx.sh"

name="a tag or platform list with spaces around separators is trimmed"
if TAGS=$'a:1, a:2\n a:3 ' PLATFORMS=$'linux/amd64\n linux/arm64' run "$name" 0 docker_build.sh; then
  build_has " --tag a:1 --tag a:2 --tag a:3 "
  build_has " --platform linux/amd64,linux/arm64 "
fi

[[ "$fail" = 0 ]] && echo "ok: the docker scripts build the command lines the actions built, keep the credential and the secrets out of argv, and refuse an unpinned image"
exit "$fail"
