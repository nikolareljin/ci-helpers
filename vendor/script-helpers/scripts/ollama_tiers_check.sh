#!/usr/bin/env bash
# SCRIPT: ollama_tiers_check.sh
# DESCRIPTION: Check a model tiers file (config/ollama_model_tiers.txt): every line well formed, no model bigger than the tier cell it sits in, and floors that agree with the thresholds.
# USAGE: scripts/ollama_tiers_check.sh [tiers_file]
# PARAMETERS:
#   tiers_file  The file to check (default: OLLAMA_MODEL_TIERS_FILE, else the
#               shipped config/ollama_model_tiers.txt).
#   Refused, one line on stderr each:
#   - a line that is not a threshold, type or size line, a threshold that is
#     not a whole number, a type row without four model references, a
#     malformed size line, a second line for one threshold, type or model,
#     a size line for a model no type row names, a file with no type rows,
#     a type name that is not lower-case letters, digits, - and _;
#   - a cell whose model has a size class above the cell's tier (an xlarge
#     model in a large cell);
#   - a size line whose GPU floor is outside its class: large needs at least
#     large_vram_gb and less than xlarge_vram_gb, xlarge at least
#     xlarge_vram_gb, standard less than large_vram_gb;
#   - in one type row, a higher tier's model that needs less GPU than a lower
#     tier's model of the same size class. Models of different classes are
#     never compared.
#   -h, --help  Show this help.
# EXIT_CODES:
#   0  the file passes
#   1  one or more lines refused
#   2  bad arguments or no such file
# EXAMPLE:
#   scripts/ollama_tiers_check.sh
#   scripts/ollama_tiers_check.sh /tmp/new_tiers.txt
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging help ollama_endpoint

case "${1:-}" in
  -h|--help) display_help "$0"; exit 0 ;;
esac
[[ $# -le 1 ]] || { log_error "takes at most one file"; exit 2; }
[[ -z "${1:-}" ]] || export OLLAMA_MODEL_TIERS_FILE="$1"
file="$(ollama_model_tiers_file)"
[[ -f "$file" ]] || { log_error "No model tiers file at $file"; exit 2; }

bad=0
refuse() { printf '%s: %s\n' "$file" "$*" >&2; bad=1; }
# The models with a size line, once each; CR and a byte-order mark dropped as the library does.
size_models() {
  LC_ALL=C _OEP_BOM=$'\xef\xbb\xbf' awk '{ sub(/\r$/, "") }
    NR == 1 && substr($0, 1, 3) == ENVIRON["_OEP_BOM"] { $0 = substr($0, 4) }
    $1 == "size" && NF >= 2 && !seen[$2]++ { print $2 }' "$file"
}

# Line shapes and thresholds.
while IFS= read -r msg; do refuse "$msg"; done < <(
  LC_ALL=C _OEP_BOM=$'\xef\xbb\xbf' awk '
    { sub(/\r$/, "") }
    NR == 1 && substr($0, 1, 3) == ENVIRON["_OEP_BOM"] { $0 = substr($0, 4) }
    /^[[:space:]]*(#|$)/ { next }
    $1 == "threshold" || $1 == "type" || $1 == "size" {
      # A second line for one key would silently replace the first.
      if (NF >= 2 && seen[$1, $2]++) { print "line " NR ": a second " $1 " line for " $2 "; the last one wins"; next }
    }
    $1 == "threshold" { if (NF != 3 || $3 !~ /^[0-9]+$/) print "line " NR ": threshold needs a key and a whole number of GiB"; next }
    # select lowercases the type it is given, so any other name is never reached.
    $1 == "type" && $2 !~ /^[a-z][a-z0-9_-]*$/ { print "line " NR ": type " $2 " is not lower-case letters, digits, - and _; select never reaches it"; next }
    $1 == "type" { if (NF != 6) print "line " NR ": type " $2 " needs four models (small standard large xlarge)"; next }
    $1 == "size" { if (NF != 5) print "line " NR ": size needs <model> <class> <GPU GiB> <memory GiB or ->"; next }
    { print "line " NR ": unknown kind of line \"" $1 "\"" }' "$file")

# A truncated file selects nothing.
[[ -n "$(ollama_model_tier_types)" ]] || refuse "no type rows; every select would fail"

# Every model reference and every size line, through the reader the library uses.
for type in $(ollama_model_tier_types); do
  for tier in small standard large xlarge; do
    ollama_tier_model "$type" "$tier" >/dev/null 2>&1 || refuse "type $type: no valid $tier model"
  done
done
while IFS= read -r model; do
  _ollama_ep_tiers_size "$model" >/dev/null 2>&1 || refuse "size $model: expected size <model> <small|standard|large|xlarge> <GPU GiB> <memory GiB or ->"
done < <(size_models)
[[ "$bad" -eq 0 ]] || exit 1

# A size class's GPU floor sits between its tier's threshold and the next one.
lv="$(_ollama_ep_tiers_threshold large_vram_gb)" || exit 1
xv="$(_ollama_ep_tiers_threshold xlarge_vram_gb)" || exit 1
while read -r model class gpu _; do
  case "$class" in
    standard) [[ -z "$lv" || "$gpu" -lt "$lv" ]] || refuse "size $model: a standard model needs less GPU than large_vram_gb ($lv), not $gpu" ;;
    large)
      [[ -z "$lv" || "$gpu" -ge "$lv" ]] || refuse "size $model: a large model's GPU floor is at least large_vram_gb ($lv), not $gpu"
      [[ -z "$xv" || "$gpu" -lt "$xv" ]] || refuse "size $model: a large model needs less GPU than xlarge_vram_gb ($xv), not $gpu" ;;
    xlarge) [[ -z "$xv" || "$gpu" -ge "$xv" ]] || refuse "size $model: an xlarge model's GPU floor is at least xlarge_vram_gb ($xv), not $gpu" ;;
  esac
done < <(size_models |
  while IFS= read -r m; do printf '%s %s\n' "$m" "$(_ollama_ep_tiers_size "$m")"; done)

# Each row: no model above its cell, no step down within one size class.
for type in $(ollama_model_tier_types); do
  prev_models=() prev_classes=() prev_gpus=()
  rank=0
  for tier in small standard large xlarge; do
    model="$(ollama_tier_model "$type" "$tier")"
    size="$(_ollama_ep_tiers_size "$model")"
    if [[ -n "$size" ]]; then
      read -r class gpu _ <<<"$size"
      if [[ "$(_ollama_ep_tier_rank "$class")" -gt "$rank" ]]; then
        refuse "type $type: the $tier cell names $model, of size class $class"
      fi
      i=0
      while [[ "$i" -lt "${#prev_models[@]}" ]]; do
        if [[ "${prev_classes[$i]}" == "$class" && "$gpu" -lt "${prev_gpus[$i]}" ]]; then
          refuse "type $type: $model ($tier) needs less GPU ($gpu) than ${prev_models[$i]} below it (${prev_gpus[$i]}), same class $class"
        fi
        i=$((i + 1))
      done
      prev_models+=("$model") prev_classes+=("$class") prev_gpus+=("$gpu")
    fi
    rank=$((rank + 1))
  done
done
# A size line no type row reaches is left over from a model that was replaced.
cells=" $(for type in $(ollama_model_tier_types); do _ollama_ep_tiers_get type "$type"; done | tr '\n' ' ') "
while IFS= read -r model; do
  [[ "$cells" == *" $model "* ]] || refuse "size $model: no type row names this model"
done < <(size_models)
[[ "$bad" -eq 0 ]] || exit 1
echo "ok: $file"
