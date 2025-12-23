#!/usr/bin/env bash
# SCRIPT: install_ollama_model.sh
# DESCRIPTION: Wrapper to install Ollama CLI, prepare the model index from webfarmer/ollama-get-models, select a model/size, pull it, and optionally run it.
# USAGE: ./install_ollama_model.sh [-h] [-i] [-D] [-r <repo_dir>] [-e <env_file>] [-R] [-n]
# PARAMETERS:
# -i                : install Ollama CLI
# -D                : install common dependencies (dialog, curl, jq, python3, pip3, nodejs, git, xclip)
# -r <repo_dir>     : models repo directory (default: ./ollama-get-models in current directory)
# -e <env_file>     : env file to persist model and size (default: ./.env)
# -R                : run the selected model in background after pulling
# -n                : non-interactive; use model/size from env file and only pull (no dialog)
# -h                : show help
# EXAMPLE: ./install_ollama_model.sh -i -D -R -e .env
# ----------------------------------------------------
set -euo pipefail

# Resolve script-helpers root and load modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging dialog os env json file deps ollama help

help() { display_help "$0"; }

install_cli=false
install_deps=false
repo_dir="$(pwd)/ollama-get-models"
env_file="$(pwd)/.env"
run_after=false
non_interactive=false

while getopts ":hiDr:e:Rn" opt; do
  case ${opt} in
    h) help; exit 0 ;;
    i) install_cli=true ;;
    D) install_deps=true ;;
    r) repo_dir="$OPTARG" ;;
    e) env_file="$OPTARG" ;;
    R) run_after=true ;;
    n) non_interactive=true ;;
    :) print_error "Option -$OPTARG requires an argument"; exit 1 ;;
    \?) print_error "Invalid option: -$OPTARG"; help; exit 1 ;;
  esac
done

if $install_deps; then
  print_info "Installing common dependencies..."
  install_dependencies_ai_runner
fi

if $install_cli; then
  if command -v ollama >/dev/null 2>&1; then
    print_info "ollama is already installed."
  else
    ollama_install_cli
  fi
fi

# Ensure repo_dir exists and index is ready; also sorts the index.
if ! $non_interactive; then
  JSON_FILE=$(ollama_prepare_models_index "$repo_dir")
  # Read current selections (if any)
  current_model=$(resolve_env_value "model" "" "$env_file")
  current_size=$(resolve_env_value "size" "" "$env_file")

  model=$(ollama_dialog_select_model "$JSON_FILE" "$current_model")
  size=$(ollama_dialog_select_size "$JSON_FILE" "$model" "$current_size")
  # Persist selections
  ollama_update_env "$env_file" model "$model"
  ollama_update_env "$env_file" size "$size"
  # Pull
  ollama_pull_model "$model" "$size"
else
  # Non-interactive: require model and size in env file
  model=$(resolve_env_value "model" "" "$env_file")
  size=$(resolve_env_value "size" "latest" "$env_file")
  if [[ -z "$model" ]]; then
    print_error "Non-interactive mode requires 'model' (and optionally 'size') in $env_file"
    exit 1
  fi
  # Prepare index to ensure repo clone exists (not strictly required to pull)
  if [[ ! -d "$repo_dir" ]]; then
    print_info "Cloning models repo for reference: $repo_dir"
    ollama_prepare_models_index "$repo_dir" >/dev/null || true
  fi
  ollama_pull_model "$model" "$size"
fi

if $run_after; then
  print_info "Starting model in background..."
  ollama_run_model "$model" "$size"
fi

print_success "Completed. Model: ${model}:${size}"

