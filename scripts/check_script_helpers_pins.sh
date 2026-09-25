#!/usr/bin/env bash
# SCRIPT: check_script_helpers_pins.sh
# DESCRIPTION: Refuse a tree where a workflow pins a different script-helpers commit than the vendored copy.
# USAGE: ./scripts/check_script_helpers_pins.sh [--repo <dir>] [-h|--help]
# PARAMETERS:
#   --repo <dir>  Repository to check (default: the current directory).
#   -h, --help    Show this help message.
# EXIT_CODES:
#   0  Every workflow pin matches the vendored ref.
#   1  At least one pin does not; each is named on stderr.
#   2  Bad arguments, or the vendored ref could not be read.
# ----------------------------------------------------
#
# Two things name a script-helpers commit in this repository: vendor/.script-helpers-ref,
# and a `ref:` on every workflow that checks the library out at runtime. Nothing
# related them, and they drifted every time -- release-tag-gate.yml still carries
# a comment recording a pin at 0.28.0 against a vendored tree at 0.32.0, and this
# check was written after finding four versions at once: eleven workflows at
# 0.35.0, wp-build.yml at 0.36.0, laravel.yml at 0.38.0, vendored 0.35.0.
#
# The consequence is not academic. A preset running an older copy of a script
# than the one this repository tests against is a difference nothing reports:
# both are green, and the behaviour differs only in the case the newer version
# fixed.
set -euo pipefail

REPO_DIR="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || { echo "[ERROR] --repo requires a value" >&2; exit 2; }
            REPO_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[ERROR] unknown argument: $1" >&2; exit 2 ;;
  esac
done

cd "$REPO_DIR"
ref_file="vendor/.script-helpers-ref"
sha_file="vendor/.script-helpers-sha"
for f in "$ref_file" "$sha_file"; do
  [[ -f "$f" ]] || { echo "[ERROR] $f does not exist; nothing to compare pins against" >&2; exit 2; }
done

# Two files record what was vendored: the tag in .script-helpers-ref and the
# commit in .script-helpers-sha. Both are compared, because each catches what
# the other cannot -- a pin whose comment was edited without its SHA reads as
# correct against the tag, and a pin updated to the right commit with a stale
# comment misleads every human who reads it.
#
# Both comparisons are offline. Resolving a tag over the network would make this
# a gate that cannot run without one, and those get switched off.
vendored_tag="$(tr -d '[:space:]' < "$ref_file")"
vendored_sha="$(grep -oE '[0-9a-f]{40}' "$sha_file" | head -1 || true)"
[[ -n "$vendored_tag" ]] || { echo "[ERROR] $ref_file is empty" >&2; exit 2; }
[[ -n "$vendored_sha" ]] || { echo "[ERROR] no 40-character commit in $sha_file" >&2; exit 2; }

failed=0
checked=0
while IFS= read -r file; do
  # The `ref:` belongs to the `with:` block under a `repository:` line, so each
  # candidate is confirmed by looking back a few lines rather than by position.
  while IFS= read -r ln; do
    line="$(sed -n "${ln}p" "$file")"
    lo=$(( ln > 12 ? ln - 12 : 1 ))
    sed -n "${lo},${ln}p" "$file" | grep -q 'repository: nikolareljin/script-helpers' || continue
    checked=$((checked + 1))
    sha="$(grep -oE '[0-9a-f]{40}' <<<"$line" | head -1)"
    tag="$(sed -E 's/.*#[[:space:]]*//' <<<"$line" | tr -d '[:space:]')"
    if [[ "$sha" != "$vendored_sha" ]]; then
      echo "[ERROR] ${file}:${ln} checks out ${sha:0:12}, vendored copy is ${vendored_sha:0:12}" >&2
      failed=1
    fi
    if [[ "$tag" != "$vendored_tag" ]]; then
      echo "[ERROR] ${file}:${ln} is commented ${tag:-<none>}, vendored copy is ${vendored_tag}" >&2
      failed=1
    fi
  done < <(grep -nE '^[[:space:]]*ref: [0-9a-f]{40}' "$file" | cut -d: -f1)
done < <(find .github/workflows -name '*.yml' | sort)

# Zero pins examined comes first, and not only because it is the more basic
# failure: the uniqueness check below pipes through `grep .`, which exits 1 on
# empty input, and under `pipefail` that ended the script before this guard
# could run. The guard against checking nothing was itself unreachable when
# nothing was checked.
if (( checked == 0 )); then
  echo "[ERROR] no script-helpers pins were found; this check is not reading the workflows" >&2
  exit 1
fi

if (( failed )); then
  echo "[ERROR] run ./scripts/sync_script_helpers.sh --ref <tag> and update the workflow pins together" >&2
  exit 1
fi
echo "[INFO] ${checked} script-helpers pin(s) all match the vendored ref ${vendored_tag} (${vendored_sha:0:12})"
