#!/usr/bin/env bash
# SCRIPT: ollama_models.sh
# DESCRIPTION: The models this machine gets from a models file (ai-models.env), by its class (memory, largest GPU), for callers that cannot source the library (an Ansible task, a Makefile).
# USAGE: scripts/ollama_models.sh class [models_file]
#        scripts/ollama_models.sh pick <models_file> [NAME...]
#        scripts/ollama_models.sh ensure <models_file> <ollama_url> [NAME...]
# PARAMETERS:
#   class   Print this machine's memory and largest GPU in GiB and, given a models
#           file, the model each NAME gets.
#   pick    Print the models this machine gets, one per line: every NAME in the file,
#           or only the NAMEs given. A NAME set in the environment wins.
#   ensure  Pull the picked models into the Ollama at <ollama_url> when missing, after
#           the disk and memory check (OLLAMA_PULL_MISSING decides: 1 pull, 0 never,
#           ask on a terminal). A model above the default column that does not fit
#           falls back one column.
#   AI_MODEL_TIER=small|standard|large|xlarge names the class instead of measuring.
#   -h, --help  Show this help.
# EXIT_CODES:
#   0  done; with ensure, every model is there
#   2  bad arguments, a NAME that is not a variable name, or a bad AI_MODEL_TIER
#   1-9 with ensure: as ollama_project_ensure_models (docs/local-models.md)
# EXAMPLE:
#   scripts/ollama_models.sh class ai-models.env
#   OLLAMA_PULL_MISSING=1 scripts/ollama_models.sh ensure ai-models.env http://127.0.0.1:11434 OLLAMA_CODE_MODEL
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging help ollama_endpoint

cmd="${1:-}"
[[ $# -eq 0 ]] || shift
case "$cmd" in
  -h|--help|"") display_help "$0"; [[ -n "$cmd" ]] && exit 0 || exit 2 ;;
  class)
    file="${1:-}"
    IFS=: read -r mem gpu <<<"$(ollama_machine_figures)"
    echo "memory_gib=${mem:-unknown} largest_gpu_gib=${gpu}"
    if [[ -n "$file" ]]; then
      [[ -f "$file" ]] || { log_error "No models file at $file"; exit 2; }
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        echo "$name=$(ollama_model_for_class "$file" "$name")"
      done < <(ollama_models_file_names "$file" | grep -v -E '_(SMALL|LARGE|XLARGE)(_V?RAM_GB)?$|^AI_TIER_' || true)
    fi
    ;;
  pick)
    [[ -n "${1:-}" ]] || { log_error "pick needs a models file"; exit 2; }
    file="$1"; shift
    [[ -f "$file" ]] || { log_error "No models file at $file"; exit 2; }
    ollama_models_required "$file" "$@"
    ;;
  ensure)
    [[ -n "${1:-}" && -n "${2:-}" ]] || { log_error "ensure needs a models file and an Ollama address"; exit 2; }
    file="$1" url="$2"; shift 2
    [[ -f "$file" ]] || { log_error "No models file at $file"; exit 2; }
    # The address is this call's, not one from the environment or a .env.
    export OLLAMA_SCRIPT_URL="$url" OLLAMA_URL_VARS=OLLAMA_SCRIPT_URL
    ollama_project_ensure_models "$file" "" "$@"
    ;;
  *) log_error "unknown command: $cmd (class, pick, ensure)"; exit 2 ;;
esac
