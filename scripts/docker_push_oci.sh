#!/usr/bin/env bash
# SCRIPT: docker_push_oci.sh
# DESCRIPTION: Push an OCI image layout, as `docker buildx build --output
#              type=oci,tar=false` writes it, to a registry with skopeo,
#              every platform and attestation with its digest kept. Runs no
#              build: the layout is data. Before anything is pushed, the
#              layout must hold `oci-layout`, an `index.json` naming exactly
#              one manifest, and under blobs/sha256 only files whose name is
#              the sha256 of their content. Credentials are the docker
#              config docker_login.sh wrote; none is read here.
# USAGE: LAYOUT=dir IMAGE=ghcr.io/o/r TAGS=1.2.3,latest bash scripts/docker_push_oci.sh
# ENVIRONMENT:
#   LAYOUT         The OCI layout directory (required).
#   IMAGE          Image name without tag (required). Lowered first: a
#                  GitHub owner is mixed case (${{ github.repository }}),
#                  a registry repository is not.
#   TAGS           Tags, comma-separated (required).
#   DOCKER_CONFIG  Directory holding config.json (default: ~/.docker).
#   GITHUB_OUTPUT  Receives digest=<sha256:...> and image=<lowered IMAGE>.
# OUTPUT: digest=<manifest digest> on stdout and in GITHUB_OUTPUT.
# EXIT CODES:
#   0  Pushed under every tag, with the layout's digest.
#   1  The layout is not as described, a push failed, or the registry
#      reports another digest.
#   2  No skopeo or python3, or an IMAGE or tag that is not a valid name.
# ----------------------------------------------------
set -euo pipefail
export LC_ALL=C

fail() { echo "::error::$*" >&2; exit 1; }

layout="${LAYOUT:-}"
image="${IMAGE:-}"
image="$(printf '%s' "$image" | tr '[:upper:]' '[:lower:]')"
command -v skopeo >/dev/null 2>&1 || { echo "::error::skopeo is not on PATH; the push job needs it (preinstalled on GitHub's Ubuntu runners)." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "::error::python3 is not on PATH." >&2; exit 2; }

name_re='^[a-z0-9]+([._-][a-z0-9]+)*(\.[a-z0-9]+([._-][a-z0-9]+)*)*(:[0-9]{1,5})?(/[a-z0-9]+([._-]{1,2}[a-z0-9]+)*)+$'
tag_re='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
[[ "$image" =~ $name_re ]] || { echo "::error::IMAGE '$image' is not a registry/name." >&2; exit 2; }
[[ "${TAGS:-}" != *$'\n'* && "${TAGS:-}" != *$'\r'* ]] || { echo "::error::TAGS holds a line break." >&2; exit 2; }
tags=()
IFS=',' read -r -a raw <<< "${TAGS:-}"
for t in ${raw[@]+"${raw[@]}"}; do
  [[ "$t" =~ $tag_re ]] || { echo "::error::tag '$t' is not a valid image tag." >&2; exit 2; }
  tags+=("$t")
done
(( ${#tags[@]} > 0 )) || { echo "::error::TAGS is empty." >&2; exit 2; }

[[ -n "$layout" && -d "$layout" && ! -L "$layout" ]] || fail "LAYOUT '$layout' is not a directory."
[[ "$layout" != *:* ]] || fail "LAYOUT '$layout' holds a ':', which skopeo reads as a reference."
layout="$(realpath -e -- "$layout")"
[[ -z "$(find "$layout" -mindepth 1 ! -type f ! -type d -print -quit)" ]] || fail "the layout holds a symlink or special file."

# Every blob is content-addressed: its name is its sha256.
bad="$(cd "$layout" && find . -regextype posix-extended -mindepth 1 -type f ! -path './oci-layout' ! -path './index.json' \
  ! -regex '\./blobs/sha256/[0-9a-f]{64}' -print -quit)"
[[ -z "$bad" ]] || fail "the layout holds a file that is not oci-layout, index.json or a blob: $bad"
while IFS= read -r -d '' blob; do
  [[ "$(sha256sum < "$blob" | cut -d' ' -f1)" == "${blob##*/}" ]] || fail "blob ${blob##*/} does not match its name."
done < <(find "$layout/blobs/sha256" -type f -print0 2>/dev/null)

digest="$(python3 -I - "$layout" <<'PY'
import json, os, re, sys
root = sys.argv[1]
try:
    if json.load(open(os.path.join(root, "oci-layout"))).get("imageLayoutVersion") != "1.0.0":
        sys.exit("oci-layout is not imageLayoutVersion 1.0.0")
    idx = json.load(open(os.path.join(root, "index.json")))
except (OSError, ValueError, AttributeError) as e:
    sys.exit(f"oci-layout or index.json unreadable: {e}")
m = idx.get("manifests") if isinstance(idx, dict) else None
if not isinstance(m, list) or len(m) != 1 or not isinstance(m[0], dict):
    sys.exit("index.json does not name exactly one manifest")
d = m[0].get("digest", "")
if not isinstance(d, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", d):
    sys.exit("index.json's manifest digest is not sha256:<64 hex>")
if not os.path.isfile(os.path.join(root, "blobs", "sha256", d[7:])):
    sys.exit("index.json names a manifest that is not in blobs/sha256")
print(d)
PY
)" || fail "the layout's index is not usable."

authfile="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
auth=()
[[ -f "$authfile" ]] && auth=(--authfile "$authfile")
dfile="$(mktemp)"
trap 'rm -f -- "$dfile"' EXIT
for t in "${tags[@]}"; do
  echo "Pushing ${image}:${t}"
  skopeo copy --all --preserve-digests --retry-times 3 ${auth[@]+"${auth[@]}"} \
    --digestfile "$dfile" "oci:${layout}" "docker://${image}:${t}" \
    || fail "skopeo copy to ${image}:${t} failed."
  [[ "$(tr -d '[:space:]' < "$dfile")" == "$digest" ]] \
    || fail "the registry reports digest $(tr -d '[:space:]' < "$dfile") for ${image}:${t}, not $digest."
done
echo "Digest: $digest"
echo "digest=$digest"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  { echo "digest=$digest"; echo "image=$image"; } >> "$GITHUB_OUTPUT"
fi
