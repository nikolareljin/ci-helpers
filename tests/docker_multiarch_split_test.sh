#!/usr/bin/env bash
# SCRIPT: docker_multiarch_split_test.sh
# DESCRIPTION: docker-multiarch.yml builds the caller's image into an OCI
#              layout in a `build` job with no registry token, and a `push`
#              job that holds the token checks out nothing of the caller's.
#              The push job's verify step (scripts/artifact_parts.sh, with
#              the path pattern the workflow passes) refuses a changed, added
#              or missing file, a symlink, a traversal or an injected
#              manifest line, and joins split blobs. docker_push_oci.sh
#              refuses a blob whose name is not its sha256, a file that is
#              not part of an OCI layout, an index with other than one
#              manifest, and an image name or tag that is not one; it pushes
#              every tag with the layout's digest. skopeo is stubbed.
# USAGE: bash tests/docker_multiarch_split_test.sh
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows/docker-multiarch.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# --- the workflow shape -----------------------------------------------------
python3 - "$wf" > "$work/re" <<'PY' || fail=1
import re, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
jobs = d["jobs"]
bad = 0
def text(j): return yaml.safe_dump(j)
def err(m):
    global bad
    print(f"FAIL {m}", file=sys.stderr); bad = 1
if set(jobs) != {"build", "push"}:
    err(f"jobs are {sorted(jobs)}, not build and push")
b, p = jobs["build"], jobs["push"]
if "secrets." in text(b):
    err("the build job reads a secret")
if b.get("permissions") != {"contents": "read"}:
    err("the build job's permissions are not contents: read")
if "secrets.registry_token" not in text(p):
    err("the push job does not hold registry_token")
if p.get("permissions") != {"packages": "write"}:
    err("the push job's permissions are not packages: write only")
if p.get("runs-on") != "${{ inputs.push_runner }}":
    err("the push job does not run on push_runner")
for s in p["steps"]:
    if str(s.get("uses", "")).startswith("actions/checkout") and "repository" not in (s.get("with") or {}):
        err("the push job checks out the caller's repository")
    if "docker_build.sh" in str(s.get("run", "")):
        err("the push job builds")
outs = d.get("on", d.get(True))["workflow_call"]["outputs"]
if "jobs.push.outputs.image_digest" not in outs["image_digest"]["value"]:
    err("image_digest does not come from the push job")
v = [s for s in p["steps"] if s.get("name") == "Verify the image layout against the build manifest"]
m = re.search(r'artifact_parts\.sh" verify "\$RUNNER_TEMP/docker-multiarch-in" "\$list" \'([^\']+)\'', v[0]["run"]) if v else None
if not m:
    err("the push job does not verify the layout with artifact_parts.sh")
    sys.exit(1)
print(m.group(1))
sys.exit(bad)
PY
if (( fail == 0 )); then ok "build holds no secret; push holds the token, checks out nothing of the caller's"; fi
re_paths="$(cat "$work/re" 2>/dev/null || true)"

# --- an OCI layout fixture ----------------------------------------------------
blob() {  # blob <dir> <content file> -> prints digest hex
  local h; h="$(sha256sum < "$2" | cut -d' ' -f1)"
  mkdir -p "$1/blobs/sha256"; cp "$2" "$1/blobs/sha256/$h"; echo "$h"
}
mk_layout() {  # mk_layout <dir> [big]
  local d="$1" c l m
  mkdir -p "$d"
  printf '{"imageLayoutVersion":"1.0.0"}' > "$d/oci-layout"
  echo '{"config":1}' > "$work/c.json"; c="$(blob "$d" "$work/c.json")"
  if [[ "${2:-}" == big ]]; then head -c 70000000 /dev/urandom > "$work/l.bin"; else echo layer > "$work/l.bin"; fi
  l="$(blob "$d" "$work/l.bin")"
  printf '{"schemaVersion":2,"config":{"digest":"sha256:%s"},"layers":[{"digest":"sha256:%s"}]}' "$c" "$l" > "$work/m.json"
  m="$(blob "$d" "$work/m.json")"
  printf '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:%s","size":1}]}' "$m" > "$d/index.json"
  echo "sha256:$m" > "$work/digest.$(basename "$d")"
}
mk_layout "$work/layout"
manifest_of() { (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum -- "$f"; done); }

# --- the push job's verify step -----------------------------------------------
verify() {  # verify <tamper>
  rm -rf "$work/in"; cp -R "$work/layout" "$work/in"
  local m; m="$(manifest_of "$work/layout")"
  case "$1" in
    change) echo x >> "$work/in/index.json" ;;
    add) echo x > "$work/in/extra" ;;
    remove) rm "$work/in/oci-layout" ;;
    link) ln -s /etc/passwd "$work/in/blobs/sha256/passwd" ;;
    traverse) m="$m"$'\n'"$(sha256sum < /etc/hostname | cut -d' ' -f1)  ./blobs/../../../etc/hostname" ;;
    notblob) echo x > "$work/in/blobs/sha256/x.sh"; m="$(manifest_of "$work/in")" ;;
    inject) m="$m"$'\n'"\$(id)" ;;
    empty) m="" ;;
  esac
  printf '%s\n' "$m" > "$work/list"
  bash "$root/scripts/artifact_parts.sh" verify "$work/in" "$work/list" "$re_paths" > "$work/log" 2>&1
}
if verify ""; then ok "verify accepts the layout as built"; else bad "verify refused the layout as built"; sed 's/^/     /' "$work/log"; fi
for t in change add remove link traverse notblob inject empty; do
  if verify "$t"; then bad "verify accepted: $t"; else ok "verify refuses: $t"; fi
done

# A blob over 60 MiB leaves as parts and comes back whole, under its digest.
mk_layout "$work/big" big
bash "$root/scripts/artifact_parts.sh" split "$work/big"
parts="$(find "$work/big" -name '*.split-*' | wc -l)"
manifest_of "$work/big" > "$work/list"
rm -rf "$work/in"; cp -R "$work/big" "$work/in"
if (( parts == 2 )) && bash "$root/scripts/artifact_parts.sh" verify "$work/in" "$work/list" "$re_paths" > "$work/log" 2>&1 \
    && [[ -z "$(find "$work/in" -name '*.split-*')" ]] \
    && [[ -z "$(cd "$work/in/blobs/sha256" && for f in *; do [[ "$(sha256sum < "$f" | cut -d' ' -f1)" == "$f" ]] || echo "$f"; done)" ]]; then
  ok "a blob over 60 MiB leaves as parts and is joined back under its digest"
else bad "big blob (parts=$parts)"; sed 's/^/     /' "$work/log"; fi
# A gap in the parts is refused.
rm -rf "$work/in"; cp -R "$work/big" "$work/in"
gap="$(find "$work/in" -name '*.split-001')"; mv "$gap" "${gap%.split-001}.split-002"
manifest_of "$work/in" > "$work/list"
if bash "$root/scripts/artifact_parts.sh" verify "$work/in" "$work/list" "$re_paths" > "$work/log" 2>&1; then
  bad "verify joined parts with a gap"; else ok "verify refuses parts with a gap"; fi

# --- docker_push_oci.sh --------------------------------------------------------
mkdir -p "$work/bin"
cat > "$work/bin/skopeo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SKOPEO_LOG"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --digestfile) df="$2"; shift 2 ;;
    oci:*) src="${1#oci:}"; shift ;;
    *) shift ;;
  esac
done
if [[ -n "${SKOPEO_DIGEST:-}" ]]; then echo "$SKOPEO_DIGEST" > "$df"
else python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifests"][0]["digest"])' "$src/index.json" > "$df"; fi
SH
chmod +x "$work/bin/skopeo"
export SKOPEO_LOG="$work/skopeo.log"
push() {  # push <layout> <image> <tags>
  : > "$SKOPEO_LOG"
  env PATH="$work/bin:$PATH" LAYOUT="$1" IMAGE="$2" TAGS="$3" GITHUB_OUTPUT="$work/out" \
    REGISTRY_PASSWORD=pw-must-not-show HOME="$work" bash "$root/scripts/docker_push_oci.sh" > "$work/log" 2>&1
}
rm -f "$work/out"
rc=0; push "$work/layout" ghcr.io/owner/repo "1.2.3,latest" || rc=$?
want="$(cat "$work/digest.layout")"
if (( rc == 0 )) && grep -qx "digest=$want" "$work/out" && [[ "$(wc -l < "$SKOPEO_LOG")" == 2 ]] \
    && grep -q -- "--all --preserve-digests" "$SKOPEO_LOG" && grep -q "docker://ghcr.io/owner/repo:latest" "$SKOPEO_LOG" \
    && ! grep -q pw-must-not-show "$SKOPEO_LOG"; then
  ok "pushes every tag with --all --preserve-digests and outputs the layout's digest"
else bad "push (rc=$rc)"; sed 's/^/     /' "$work/log"; fi
rc=0; SKOPEO_DIGEST="sha256:$(printf '0%.0s' {1..64})" push "$work/layout" ghcr.io/owner/repo 1.2.3 || rc=$?
if (( rc == 1 )); then ok "refuses a registry digest that is not the layout's"; else bad "digest mismatch (rc=$rc)"; fi
# shellcheck disable=SC2016  # literal $(id) is the point
for img in "ghcr.io/Owner/repo" "ghcr.io/o/r;id" 'ghcr.io/o/$(id)' "-oops/x" $'ghcr.io/o/r\nx' "repo"; do
  rc=0; push "$work/layout" "$img" 1.2.3 || rc=$?
  if (( rc == 2 )) && [[ ! -s "$SKOPEO_LOG" ]]; then ok "refuses image name '${img//$'\n'/\\n}'"; else bad "image '$img' (rc=$rc)"; fi
done
# shellcheck disable=SC2016
for tag in "1.2.3;id" '$(id)' "-x" ".x" "a/b" "" $'1.2.3\n;id'; do
  rc=0; push "$work/layout" ghcr.io/o/r "$tag" || rc=$?
  if (( rc == 2 )) && [[ ! -s "$SKOPEO_LOG" ]]; then ok "refuses tag '${tag//$'\n'/\\n}'"; else bad "tag '$tag' (rc=$rc)"; fi
done
tamper() {  # tamper <how> -> rc of a push of a tampered copy
  rm -rf "$work/t"; cp -R "$work/layout" "$work/t"
  local b; b="$(find "$work/t/blobs/sha256" -type f | head -1)"
  case "$1" in
    blob) echo x >> "$b" ;;
    extra) echo x > "$work/t/run.sh" ;;
    link) ln -s /etc/passwd "$work/t/blobs/sha256/$(printf 'a%.0s' {1..64})" ;;
    two) python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["manifests"]*=2; json.dump(d,open(p,"w"))' "$work/t/index.json" ;;
    badref) python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["manifests"][0]["digest"]="sha256:../../x"; json.dump(d,open(p,"w"))' "$work/t/index.json" ;;
    missing) python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["manifests"][0]["digest"]="sha256:"+"b"*64; json.dump(d,open(p,"w"))' "$work/t/index.json" ;;
    version) printf '{"imageLayoutVersion":"9"}' > "$work/t/oci-layout" ;;
  esac
  local rc=0; push "$work/t" ghcr.io/o/r 1.2.3 || rc=$?
  echo "$rc"
}
for t in blob extra link two badref missing version; do
  rc="$(tamper "$t")"
  if [[ "$rc" == 1 && ! -s "$SKOPEO_LOG" ]]; then ok "push refuses a layout with: $t"; else bad "push accepted or misreported: $t (rc=$rc)"; sed 's/^/     /' "$work/log"; fi
done
mkdir -p "$work/a:b"; cp -R "$work/layout/." "$work/a:b/"
rc=0; push "$work/a:b" ghcr.io/o/r 1.2.3 || rc=$?
if (( rc == 1 )) && [[ ! -s "$SKOPEO_LOG" ]]; then ok "refuses a layout path holding ':'"; else bad "layout path with ':' (rc=$rc)"; fi

exit "$fail"
