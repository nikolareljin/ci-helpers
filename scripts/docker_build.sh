#!/usr/bin/env bash
# SCRIPT: docker_build.sh
# DESCRIPTION: Run `docker buildx build` from environment variables that carry
#              what the replaced build-push action took as inputs, with no
#              third-party action. Every input reaches the command as one
#              argument each, never spliced into shell text. A build secret
#              goes to BuildKit as `--secret id=<id>,env=<variable>` with the
#              value in this process's environment only: not in an argument,
#              not in a build-arg, not in the image's history. Build-arg
#              values are masked in the printed command. The digest and image
#              id come from buildx's metadata and iid files.
# USAGE: TAGS=ghcr.io/o/r:1.0 PUSH=true bash scripts/docker_build.sh
# ENVIRONMENT:
#   CONTEXT            Build context path (default: .).
#   DOCKERFILE         Dockerfile path, as --file takes it (empty: default).
#   PLATFORMS          Platforms, comma- or newline-separated (optional).
#   TAGS               Image tags, comma- or newline-separated (optional).
#   LABELS             Image labels, one per line (optional).
#   BUILD_ARGS         ARG=VALUE pairs, one per line (optional).
#   BUILD_SECRETS      id=value pairs, one per line; each is passed by
#                      environment as --secret id=<id>,env=... (optional). A
#                      value with line breaks (a PEM key, JSON) is written as
#                      id=base64:<base64 of the value> and decoded here. No
#                      part of a line is printed; an error names the line
#                      number, and under Actions every value is masked.
#   BUILD_SECRET_ENVS  id=VARIABLE pairs, one per line; the secret is read from
#                      that variable of this environment (optional).
#   PUSH, LOAD         true or false (default: false).
#   PULL, NO_CACHE     true or false (default: false).
#   CACHE_FROM         --cache-from values, one per line (optional).
#   CACHE_TO           --cache-to values, one per line (optional).
#   OUTPUTS            --output values, one per line (optional).
#   TARGET             Build stage to stop at (optional).
#   PROVENANCE         Provenance attestation: empty (the default below),
#                      `true`, `false`, or attributes such as `mode=max`.
#   SBOM               SBOM attestation: empty (none), `true`, `false`, or
#                      attributes.
#   REPOSITORY_PRIVATE true when the repository is private: an empty
#                      PROVENANCE then means `mode=min,inline-only=true`, as the
#                      action set it; otherwise `mode=max`. No provenance is
#                      added when the image is loaded into the docker engine.
#   BUILDER            Builder name (default: the current one).
#   RUNNER_TEMP        Where the iid and metadata files go (default: mktemp -d).
#   GITHUB_OUTPUT      Written when set.
# OUTPUT: imageid=<image id>, digest=<manifest digest> and
#         metadata_file=<path to buildx's metadata JSON>, on stdout and, when
#         GITHUB_OUTPUT is set, appended there.
# EXIT CODES:
#   0  The build ran; with PUSH=true the digest is known.
#   1  docker buildx build failed, or the pushed image has no digest.
#   2  No docker or no buildx plugin on PATH, a true/false value that is
#      neither, a secret id that is not [A-Za-z0-9._-]+ or is repeated, a
#      secret line without `=`, a base64 value that does not decode, or a
#      secret variable that is unset.
# ----------------------------------------------------
set -euo pipefail

context="${CONTEXT:-.}"
dockerfile="${DOCKERFILE:-}"
target="${TARGET:-}"
provenance="${PROVENANCE:-}"
sbom="${SBOM:-}"
builder="${BUILDER:-}"

command -v docker >/dev/null 2>&1 || { echo "::error::docker is not on PATH." >&2; exit 2; }
if ! docker buildx version >/dev/null 2>&1; then
  echo "::error::docker buildx is not installed; run scripts/setup_buildx.sh first." >&2
  exit 2
fi

# true/false only; anything else is a typo, not a no.
bool() {
  local name="$1" value="${2:-false}"
  case "$value" in
    true|false) printf '%s\n' "$value" ;;
    "") echo false ;;
    *) echo "::error::$name is '$value', not true or false." >&2; exit 2 ;;
  esac
}
push="$(bool PUSH "${PUSH:-}")"
load="$(bool LOAD "${LOAD:-}")"
pull="$(bool PULL "${PULL:-}")"
no_cache="$(bool NO_CACHE "${NO_CACHE:-}")"
private="$(bool REPOSITORY_PRIVATE "${REPOSITORY_PRIVATE:-}")"

# One value per line; a comma also separates where the action split on it.
each_line() {
  printf '%s\n' "$1" | while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && printf '%s\n' "$line"
  done
  return 0
}
each_item() {
  each_line "$(printf '%s' "$1" | tr ',' '\n')"
}

if [[ -n "${RUNNER_TEMP:-}" ]]; then
  work="$(mktemp -d "${RUNNER_TEMP}/docker-build.XXXXXX")"
else
  work="$(mktemp -d)"
fi
iidfile="$work/iidfile"
metadata="$work/metadata.json"

args=(buildx build)
shown=(docker buildx build)
# add <arg>...: to the command and to what is printed.
add() { args+=("$@"); shown+=("$@"); }

[[ -n "$builder" ]] && add --builder "$builder"
[[ -n "$dockerfile" ]] && add --file "$dockerfile"
[[ -n "$target" ]] && add --target "$target"

while IFS= read -r v; do
  # The pair is on the command line, as the action put it; the value is
  # masked in the printed command only.
  args+=(--build-arg "$v"); shown+=(--build-arg "${v%%=*}=***")
done < <(each_line "${BUILD_ARGS:-}")
while IFS= read -r v; do add --cache-from "$v"; done < <(each_line "${CACHE_FROM:-}")
while IFS= read -r v; do add --cache-to "$v"; done < <(each_line "${CACHE_TO:-}")
while IFS= read -r v; do add --label "$v"; done < <(each_line "${LABELS:-}")
while IFS= read -r v; do add --output "$v"; done < <(each_line "${OUTPUTS:-}")
while IFS= read -r v; do add --tag "$v"; done < <(each_item "${TAGS:-}")

platform_list="$(each_item "${PLATFORMS:-}" | paste -sd, -)"
[[ -n "$platform_list" ]] && add --platform "$platform_list"

# Secrets: the value is exported under a name of this script's own and
# BuildKit reads it from the environment, so neither argv nor the image
# history nor this log carries it. No part of a BUILD_SECRETS line is ever
# printed: an error names the line number only, and under Actions every
# value is masked before it is looked at.
mask() {
  # One ::add-mask:: per line of the value: the runner masks line by line.
  [[ "${GITHUB_ACTIONS:-}" == true ]] || return 0
  printf '%s\n' "$1" | while IFS= read -r part; do
    [[ -n "$part" ]] && printf '::add-mask::%s\n' "$part"
  done
  return 0
}
id_re='^[A-Za-z0-9._-]+$'
seen_ids=" "
# secret_id <list> <line number> <id>: refuse an id that is not a name or
# that was given before; say where, never what.
secret_id() {
  local list="$1" n="$2" id="$3"
  [[ "$id" =~ $id_re ]] || { echo "::error::$list line $n: the id is not [A-Za-z0-9._-]+." >&2; exit 2; }
  case "$seen_ids" in
    *" $id "*) echo "::error::$list line $n repeats an id given before." >&2; exit 2 ;;
  esac
  seen_ids="$seen_ids$id "
}
n=0
count=0
while IFS= read -r line; do
  count=$((count + 1))
  mask "${line#*=}"
  [[ "$line" == *=* ]] || { echo "::error::BUILD_SECRETS line $count has no '='. One id=value per line; a value with line breaks goes as id=base64:<base64 of the value>." >&2; exit 2; }
  id="${line%%=*}"
  value="${line#*=}"
  secret_id BUILD_SECRETS "$count" "$id"
  if [[ "$value" == base64:* ]]; then
    mask "${value#base64:}"
    if ! value="$(printf '%s' "${value#base64:}" | openssl base64 -d -A 2>/dev/null)" || [[ -z "$value" ]]; then
      echo "::error::BUILD_SECRETS line $count: the value after base64: does not decode." >&2
      exit 2
    fi
    mask "$value"
  fi
  n=$((n + 1))
  export "CI_HELPERS_SECRET_$n=$value"
  args+=(--secret "id=$id,env=CI_HELPERS_SECRET_$n"); shown+=(--secret "id=***,env=CI_HELPERS_SECRET_$n")
done < <(each_line "${BUILD_SECRETS:-}")
unset value
count=0
while IFS= read -r line; do
  count=$((count + 1))
  [[ "$line" == *=* ]] || { echo "::error::BUILD_SECRET_ENVS line $count has no '='. One id=VARIABLE per line." >&2; exit 2; }
  id="${line%%=*}"
  var="${line#*=}"
  secret_id BUILD_SECRET_ENVS "$count" "$id"
  [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "::error::BUILD_SECRET_ENVS line $count: what follows '=' is not a variable name." >&2; exit 2; }
  [[ -n "${!var+x}" ]] || { echo "::error::BUILD_SECRET_ENVS line $count: the named variable is not set." >&2; exit 2; }
  args+=(--secret "id=$id,env=$var"); shown+=(--secret "id=***,env=$var")
done < <(each_line "${BUILD_SECRET_ENVS:-}")

# Attestations, as the action chose them. No provenance by default when the
# image goes to the docker engine, which cannot store it.
builder_id=""
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  builder_id="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT:-1}"
fi
to_docker=false
if [[ "$load" == true ]] || each_line "${OUTPUTS:-}" | grep -q -E '(^|,)type=docker(,|$)'; then
  to_docker=true
fi
with_builder_id() {
  if [[ -n "$builder_id" && "$1" != *builder-id=* ]]; then
    printf '%s,builder-id=%s\n' "$1" "$builder_id"
  else
    printf '%s\n' "$1"
  fi
}
case "$provenance" in
  "")
    if [[ "$to_docker" == false ]]; then
      if [[ "$private" == true ]]; then
        add --attest "$(with_builder_id "type=provenance,mode=min,inline-only=true")"
      else
        add --attest "$(with_builder_id "type=provenance,mode=max")"
      fi
    fi ;;
  false) add --provenance=false ;;
  true)
    if [[ -n "$builder_id" ]]; then
      add --attest "type=provenance,builder-id=$builder_id"
    else
      add --provenance=true
    fi ;;
  *) add --attest "$(with_builder_id "type=provenance,$provenance")" ;;
esac
case "$sbom" in
  "") ;;
  true) add --sbom=true ;;
  false) add --sbom=false ;;
  *) add --attest "type=sbom,$sbom" ;;
esac

[[ "$load" == true ]] && add --load
[[ "$push" == true ]] && add --push
[[ "$pull" == true ]] && add --pull
[[ "$no_cache" == true ]] && add --no-cache
add --iidfile "$iidfile" --metadata-file "$metadata"
add -- "$context"

printf '%s ' "${shown[@]}"; echo
if ! docker "${args[@]}"; then
  echo "::error::docker buildx build failed." >&2
  exit 1
fi

imageid=""
[[ -s "$iidfile" ]] && imageid="$(tr -d '[:space:]' < "$iidfile")"
digest=""
if [[ -s "$metadata" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    digest="$(python3 -I -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("containerimage.digest", ""))
except ValueError:
    pass
' "$metadata")"
  else
    digest="$(sed -n '/"containerimage\.digest"/{ s/.*"containerimage\.digest": *"\([^"]*\)".*/\1/p; q; }' "$metadata")"
  fi
fi
if [[ "$push" == true && -z "$digest" ]]; then
  echo "::error::the image was pushed but buildx wrote no containerimage.digest to $metadata." >&2
  exit 1
fi
[[ -n "$imageid" ]] && echo "Image id: $imageid"
[[ -n "$digest" ]] && echo "Digest: $digest"
printf 'imageid=%s\ndigest=%s\nmetadata_file=%s\n' "$imageid" "$digest" "$metadata"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'imageid=%s\ndigest=%s\nmetadata_file=%s\n' "$imageid" "$digest" "$metadata" >> "$GITHUB_OUTPUT"
fi
