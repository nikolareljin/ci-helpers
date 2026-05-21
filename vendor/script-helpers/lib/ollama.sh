#!/usr/bin/env bash
# Ollama helpers: install CLI, prepare models index, select and pull models.
# Mirrors logic used in ai-runner/include.sh and integrates with script-helpers modules.

# Expected imports by caller (via shlib_import): logging, os, dialog, file, json, env (python optional)

# Usage: _ollama_default_repo_url; prints default models repo URL.
_ollama_default_repo_url() {
  echo "https://github.com/webfarmer/ollama-get-models.git"
}

_ollama_project_root() {
  if [[ -n "${ROOT_DIR:-}" ]]; then
    echo "$ROOT_DIR"
    return 0
  fi
  if command -v get_project_root >/dev/null 2>&1; then
    get_project_root
    return 0
  fi
  pwd
}

_ollama_python_deps_ok() {
  local python_cmd
  python_cmd="$(_ollama_resolve_python_cmd)" || return 1
  "$python_cmd" - <<'PY'
try:
    # beautifulsoup4 installs as 'bs4'
    import bs4  # noqa: F401
    import requests  # noqa: F401
except ImportError:
    raise SystemExit(1)
PY
}

_ollama_ensure_python_deps() {
  local python_cmd
  if _ollama_python_deps_ok; then
    return 0
  fi
  python_cmd="$(_ollama_resolve_python_cmd)" || {
    print_error "Python 3 not found; install python3 and try again."
    return 1
  }
  if command -v apt-get >/dev/null 2>&1; then
    print_info "Installing Python deps via apt (python3-bs4, python3-requests)..."
    if ! run_with_optional_sudo true apt-get update; then
      print_warning "apt-get update failed; attempting install with existing package lists."
    fi
    if ! run_with_optional_sudo true apt-get install -y python3-bs4 python3-requests; then
      print_warning "Failed to install Python deps via apt (python3-bs4, python3-requests); falling back to pip."
      if ! _ollama_install_python_deps_pip "$python_cmd"; then
        return 1
      fi
    fi
  else
    if ! _ollama_install_python_deps_pip "$python_cmd"; then
      return 1
    fi
  fi
  if ! _ollama_python_deps_ok; then
    print_error "Python deps are still missing after installation attempt."
    return 1
  fi
  return 0
}

_ollama_install_python_deps_pip() {
  local python_cmd="$1"
  local -a pip_args=("--upgrade")
  if ! "$python_cmd" -m pip --version >/dev/null 2>&1; then
    print_error "pip not available for python3. Install python3-pip or use a system package manager."
    return 1
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    pip_args+=("--user")
  fi
  print_warning "Installing Python deps via pip; prefer system packages to avoid conflicts."
  print_info "Installing Python deps for models index (beautifulsoup4, requests)..."
  if ! "$python_cmd" -m pip install "${pip_args[@]}" beautifulsoup4 requests; then
    print_error "Failed to install Python deps via pip (beautifulsoup4, requests)."
    return 1
  fi
  return 0
}

_ollama_is_valid_models_json() {
  local json_path="$1"
  jq -e '(type == "array" and length > 0)
        or (type == "object" and has("models") and (.models | type == "array" and length > 0))' \
     "$json_path" >/dev/null 2>&1
}

_ollama_resolve_python_cmd() {
  # Prefer shared python module if available, otherwise fall back locally.
  local python_cmd
  if command -v python_resolve_3 >/dev/null 2>&1; then
    python_cmd="$(python_resolve_3 "" 3 8)" && {
      echo "$python_cmd"
      return 0
    }
  fi
  if command -v shlib_import >/dev/null 2>&1; then
    shlib_import python >/dev/null 2>&1 || true
    if command -v python_resolve_3 >/dev/null 2>&1; then
      python_cmd="$(python_resolve_3 "" 3 8)" && {
        echo "$python_cmd"
        return 0
      }
    fi
  fi
  if command -v python3 >/dev/null 2>&1 && python3 - <<'PY'
import sys
raise SystemExit(0 if (sys.version_info[0] == 3 and sys.version_info[1] >= 8) else 1)
PY
  then
    echo "python3"
    return 0
  fi
  if command -v python >/dev/null 2>&1 && python - <<'PY'
import sys
raise SystemExit(0 if (sys.version_info[0] == 3 and sys.version_info[1] >= 8) else 1)
PY
  then
    echo "python"
    return 0
  fi
  return 1
}

# Install Ollama CLI for supported OSes.
ollama_install_cli() {
  local os; os=$(get_os)
  case "$os" in
    linux)
      print_info "Installing Ollama CLI on Linux..."
      curl -fsSL https://ollama.com/install.sh | sh
      ;;
    mac)
      print_info "Installing Ollama CLI on macOS..."
      if command -v brew >/dev/null 2>&1; then
        brew install ollama/tap/ollama
      else
        print_error "Homebrew not found; install Homebrew or Ollama manually."
        return 1
      fi
      ;;
    windows)
      print_error "Ollama installation is not supported in this shell on Windows."
      return 1
      ;;
    *)
      print_error "Unsupported OS for Ollama installation."
      return 1
      ;;
  esac
}

# Ensure repo with models index exists and is up to date; generate JSON index.
# Args:
#   $1 - target directory (default: ./ollama-get-models)
#   $2 - repo URL (default: webfarmer/ollama-get-models)
# Returns: print path to models JSON on success
ollama_prepare_models_index() {
  local repo_dir="${1:-ollama-get-models}"
  local repo_url="${2:-$(_ollama_default_repo_url)}"
  local json_path
  local skip_generate
  local python_cmd
  json_path="$repo_dir/code/ollama_models.json"

  if [[ -d "$repo_dir/.git" ]]; then
    print_info "Updating models repo: $repo_dir"
    if [[ -n "${OLLAMA_MODELS_REPO_REF:-}" ]]; then
      (cd "$repo_dir" && git fetch --tags --prune) || {
        print_warning "git fetch failed; continuing with existing index if present."
      }
    else
      (cd "$repo_dir" && git pull --ff-only) || {
        print_warning "git pull failed; continuing with existing index if present."
      }
    fi
  elif [[ -d "$repo_dir" ]]; then
    print_warning "$repo_dir exists but is not a git repo. Using as-is."
  else
    print_info "Cloning models repo: $repo_url -> $repo_dir"
    git clone "$repo_url" "$repo_dir" || {
      print_error "Failed to clone $repo_url"
      return 1
    }
  fi

  if [[ -n "${OLLAMA_MODELS_REPO_REF:-}" ]]; then
    (cd "$repo_dir" && git checkout --detach "$OLLAMA_MODELS_REPO_REF") || {
      print_error "Failed to checkout OLLAMA_MODELS_REPO_REF=$OLLAMA_MODELS_REPO_REF"
      return 1
    }
  else
    print_warning "OLLAMA_MODELS_REPO_REF not set; executing unpinned repo scripts."
  fi

  if [[ -f "$json_path" ]]; then
    if _ollama_is_valid_models_json "$json_path"; then
      print_info "Using existing models index: $json_path"
      skip_generate=true
    else
      print_warning "Existing models index is invalid; regenerating."
      skip_generate=false
    fi
  else
    skip_generate=false
  fi

  if [[ "$skip_generate" != "true" ]]; then
    # Generate the models JSON via provided script
    if [[ -f "$repo_dir/get_ollama_models.py" ]]; then
      _ollama_ensure_python_deps || return 1
      python_cmd="$(_ollama_resolve_python_cmd)" || return 1
      (cd "$repo_dir" && "$python_cmd" get_ollama_models.py) || {
        if [[ -f "$json_path" ]]; then
          if _ollama_is_valid_models_json "$json_path"; then
            print_warning "Model index generation failed; using existing JSON."
          else
            print_error "Model index generation failed and JSON is invalid."
            return 1
          fi
        else
          print_error "Failed to generate models index via Python script."
          return 1
        fi
      }
    else
      print_warning "get_ollama_models.py not found in $repo_dir; expecting prebuilt index."
    fi
  fi

  if [[ ! -f "$json_path" ]]; then
    print_error "Models JSON not found at: $json_path"
    return 1
  fi
  # Sort deterministically by name
  jq -S 'sort_by(.name)' "$json_path" >"$json_path.tmp" && mv "$json_path.tmp" "$json_path"
  echo "$json_path"
}

# Return path to models JSON for a repo directory (does not generate)
ollama_models_json_path() {
  local repo_dir="${1:-ollama-get-models}"
  echo "$repo_dir/code/ollama_models.json"
}

# List model names from JSON index
ollama_list_models() {
  local json_file="$1"
  if [[ ! -f "$json_file" ]]; then
    print_error "Models JSON not found: $json_file" >&2
    return 1
  fi
  jq -r '.[].name' "$json_file"
}

ollama_model_menu_cache_path() {
  local json_file="$1"
  local base_dir base_name

  base_dir="$(dirname "$json_file")"
  base_name="$(basename "$json_file" .json)"
  printf '%s/%s.model-menu.cache.tsv\n' "$base_dir" "$base_name"
}

ollama_model_menu_cache_is_fresh() {
  local cache_file="$1"
  local max_age_seconds="${2:-1800}"
  local now_ts mtime age

  if [[ ! -f "$cache_file" ]] || [[ ! -r "$cache_file" ]] || [[ ! -s "$cache_file" ]]; then
    return 1
  fi

  now_ts="$(date +%s)"
  if mtime="$(stat -c %Y "$cache_file" 2>/dev/null)"; then
    :
  elif mtime="$(stat -f %m "$cache_file" 2>/dev/null)"; then
    :
  else
    return 1
  fi

  age=$(( now_ts - mtime ))
  if (( age < 0 )); then
    return 1
  fi
  [[ $age -le $max_age_seconds ]]
}

ollama_prepare_model_menu_cache() {
  local json_file="$1"
  local cache_file="${2:-}"
  local cache_dir tmp_file

  if [[ ! -f "$json_file" ]]; then
    print_error "Models JSON not found: $json_file" >&2
    return 1
  fi

  if [[ -z "$cache_file" ]]; then
    cache_file="$(ollama_model_menu_cache_path "$json_file")"
  fi

  cache_dir="$(dirname "$cache_file")"
  if ! mkdir -p "$cache_dir"; then
    print_error "Failed to create Ollama model menu cache directory: $cache_dir" >&2
    return 1
  fi
  tmp_file="$(mktemp "${cache_file}.tmp.XXXXXX")" || return 1

  jq -r '
    map(select(.name | contains("/") | not) | . + { slug: .name })
    | sort_by(.slug | ascii_downcase)
    | .[]
    | [
        .slug,
        .name,
        ((.sizes // []) | join(", ")),
        ((.description // "") | gsub("[[:space:]]+"; " "))
      ]
    | @tsv
  ' "$json_file" > "$tmp_file" || {
    rm -f "$tmp_file"
    return 1
  }

  if [[ ! -s "$tmp_file" ]]; then
    rm -f "$tmp_file"
    print_error "Generated empty Ollama model menu cache: $cache_file" >&2
    return 1
  fi

  if ! mv "$tmp_file" "$cache_file"; then
    print_error "Failed to move temporary Ollama model menu cache '$tmp_file' to '$cache_file'" >&2
    rm -f "$tmp_file"
    return 1
  fi

  printf '%s\n' "$cache_file"
}

# Use dialog to select a model; preselect current_model if provided.
# Prints selected model name to stdout.
ollama_dialog_select_model() {
  local json_file="$1"; local current_model="${2:-}"
  if [[ ! -f "$json_file" ]]; then
    print_error "Models JSON not found: $json_file" >&2
    return 1
  fi

  dialog_init; check_if_dialog_installed >/dev/null 2>&1 || { print_error "Dialog is not installed. Please install it and try again." >&2; return 1; }

  local selected default_tag=""
  local menu_height total_count value=""
  local idx=0 tag model_name slug summary sizes desc cache_file
  local -a menu_items=()
  local -A model_lookup=()
  menu_height=18

  if [[ -n "${OLLAMA_MODEL_MENU_CACHE_FILE:-}" ]]; then
    cache_file="$OLLAMA_MODEL_MENU_CACHE_FILE"
  else
    cache_file="$(ollama_model_menu_cache_path "$json_file")"
  fi

  if [[ ! -s "$cache_file" ]] || ! ollama_model_menu_cache_is_fresh "$cache_file"; then
    cache_file="$(ollama_prepare_model_menu_cache "$json_file" "$cache_file")" || return 1
  fi

  while IFS=$'	' read -r slug model_name sizes desc; do
    idx=$((idx + 1))
    tag=$(printf '%04d' "$idx")
    summary="${slug}"
    if [[ -n "$sizes" ]]; then
      summary="${summary} | sizes: ${sizes}"
    else
      summary="${summary} | sizes: latest"
    fi
    if [[ -n "$desc" ]]; then
      summary="${summary} | ${desc}"
    fi
    summary="${summary:0:140}"
    menu_items+=("$tag" "$summary")
    model_lookup["$tag"]="$model_name"
    if [[ "$model_name" == "$current_model" ]]; then
      default_tag="$tag"
    fi
  done < "$cache_file"

  total_count="$idx"
  if [[ $total_count -eq 0 ]]; then
    print_error "No selectable Ollama models found in cache: $cache_file" >&2
    return 1
  fi
  value="Browse official Ollama library models. Showing ${total_count} indexed models."
  if [[ -n "$current_model" ]]; then
    value="${value} Current selection: ${current_model}."
  fi

  if [[ -n "$default_tag" ]]; then
    if ! selected=$(dialog --stdout --default-item "$default_tag" --menu "$value" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$menu_height" "${menu_items[@]}"); then
      print_error "No model selected." >&2
      return 1
    fi
  else
    if ! selected=$(dialog --stdout --menu "$value" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$menu_height" "${menu_items[@]}"); then
      print_error "No model selected." >&2
      return 1
    fi
  fi

  if [[ -z "$selected" || -z "${model_lookup[$selected]:-}" ]]; then
    print_error "No model selected." >&2
    return 1
  fi

  echo "${model_lookup[$selected]}"
}

# Use dialog to select size for a given model. If none available, returns 'latest'.
ollama_dialog_select_size() {
  local json_file="$1"; local model="$2"; local current_size="${3:-}"
  if [[ ! -f "$json_file" ]]; then
    print_error "Models JSON not found: $json_file" >&2
    return 1
  fi

  local sizes; sizes=$(jq -r --arg m "$model" '.[] | select(.name == $m) | .sizes[]?' "$json_file")
  if [[ -z "$sizes" ]]; then
    print_warning "No sizes listed for $model; using 'latest'." >&2
    echo "latest"
    return 0
  fi

  dialog_init
  if ! check_if_dialog_installed >/dev/null 2>&1; then
    print_error "Dialog is required but not installed." >&2
    return 1
  fi
  local -a menu_items=()
  local -a dialog_args=(--stdout --menu "Select a size for: $model" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 10)
  local s has_default=""
  for s in $sizes; do
    menu_items+=("$s" "$s")
    if [[ -n "$current_size" && "$s" == "$current_size" ]]; then
      has_default=1
    fi
  done
  if [[ -n "$has_default" ]]; then
    dialog_args=(--stdout --default-item "$current_size" --menu "Select a size for: $model" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 10)
  fi

  local selected status=0
  if selected=$(dialog "${dialog_args[@]}" "${menu_items[@]}"); then
    :
  else
    status=$?
    if [[ $status -eq 1 || $status -eq 255 ]]; then
      return 2
    fi
    return "$status"
  fi
  if [[ -z "$selected" ]]; then
    return 2
  fi
  echo "$selected"
}

# Build Ollama model reference. Omits tag when size is empty/latest.
ollama_model_ref() {
  local model_name="$1"
  local model_size="${2:-latest}"
  if [[ -z "$model_size" || "$model_size" == "latest" ]]; then
    echo "$model_name"
  else
    echo "${model_name}:${model_size}"
  fi
}

# Backward-compatible alias used by older scripts.
ollama_model_ref_safe() {
  ollama_model_ref "$@"
}

# Resolve runtime mode from env/override: local|docker.
ollama_runtime_type() {
  local env_file="$1"
  local runtime_override="${2:-}"
  local runtime

  if [[ -n "$runtime_override" ]]; then
    runtime="$runtime_override"
  else
    runtime="$(resolve_env_value "ollama_runtime" "local" "$env_file")"
  fi

  runtime="$(echo "$runtime" | tr '[:upper:]' '[:lower:]')"
  if [[ "$runtime" != "local" && "$runtime" != "docker" ]]; then
    print_warning "Invalid ollama_runtime '$runtime'; defaulting to 'local'."
    runtime="local"
  fi

  echo "$runtime"
}

ollama_runtime_scheme() {
  local env_file="$1"
  resolve_env_value "ollama_scheme" "http" "$env_file"
}

ollama_runtime_host() {
  local env_file="$1"
  resolve_env_value "ollama_host" "localhost" "$env_file"
}

ollama_runtime_port() {
  local env_file="$1"
  resolve_env_value "ollama_port" "11434" "$env_file"
}

ollama_runtime_build_base_url() {
  local env_file="$1"
  local scheme host port base

  scheme="$(ollama_runtime_scheme "$env_file")"
  host="$(ollama_runtime_host "$env_file")"
  port="$(ollama_runtime_port "$env_file")"

  host="${host%/}"
  if [[ "$host" == *"://"* ]]; then
    base="$host"
  else
    base="${scheme}://${host}"
  fi

  if [[ ! "$base" =~ :[0-9]+$ ]]; then
    base="${base}:${port}"
  fi

  echo "${base%/}"
}

ollama_runtime_sync_env_url() {
  local env_file="$1"
  local base_url

  base_url="$(ollama_runtime_build_base_url "$env_file")"
  if [[ -n "$env_file" ]]; then
    ollama_update_env "$env_file" ollama_url "$base_url"
  fi
  echo "$base_url"
}

ollama_runtime_api_base_url() {
  local env_file="$1"
  local base_url
  local host_value

  host_value="$(resolve_env_value "ollama_host" "" "$env_file")"
  if [[ -n "$host_value" ]]; then
    base_url="$(ollama_runtime_build_base_url "$env_file")"
  else
    base_url="$(resolve_env_value "ollama_url" "" "$env_file")"
  fi
  if [[ -z "$base_url" ]]; then
    local website
    website="$(resolve_env_value "website" "http://localhost:11434/api/generate" "$env_file")"
    # Normalize legacy website endpoint values back to base URL.
    base_url="${website%%#*}"
    base_url="${base_url%%\?*}"
    base_url="${base_url%%/api/generate/}"
    base_url="${base_url%%/api/generate}"
  fi

  base_url="${base_url%/}"
  if [[ -z "$base_url" ]]; then
    base_url="http://localhost:11434"
  fi

  echo "$base_url"
}

ollama_runtime_generate_endpoint() {
  local env_file="$1"
  echo "$(ollama_runtime_api_base_url "$env_file")/api/generate"
}

ollama_runtime_container_name() {
  local env_file="$1"
  resolve_env_value "ollama_docker_container" "ai-runner-ollama" "$env_file"
}

ollama_runtime_image() {
  local env_file="$1"
  resolve_env_value "ollama_docker_image" "ollama/ollama:latest" "$env_file"
}

ollama_runtime_data_dir() {
  local env_file="$1"
  local data_dir
  local project_root

  data_dir="$(resolve_env_value "ollama_data_dir" "./models/ollama-data" "$env_file")"
  if [[ "$data_dir" != /* ]]; then
    project_root="$(_ollama_project_root)"
    data_dir="$project_root/$data_dir"
  fi

  if ! create_directory "$data_dir" >/dev/null; then
    print_error "Failed to create Ollama data directory: ${data_dir}"
    return 1
  fi
  (cd "$data_dir" && pwd)
}

ollama_runtime_local_models_dir() {
  local env_file="$1"
  local shared_store local_models_dir data_dir project_root

  shared_store="$(resolve_env_value "ollama_shared_model_store" "1" "$env_file")"
  shared_store="$(echo "$shared_store" | tr '[:upper:]' '[:lower:]')"
  if [[ "$shared_store" == "1" || "$shared_store" == "true" || "$shared_store" == "yes" ]]; then
    data_dir="$(ollama_runtime_data_dir "$env_file")" || return 1
    local_models_dir="${data_dir}/models"
  else
    local_models_dir="$(resolve_env_value "ollama_local_models_dir" "${OLLAMA_MODELS:-$HOME/.ollama/models}" "$env_file")"
  fi

  if [[ "$local_models_dir" != /* ]]; then
    project_root="$(_ollama_project_root)"
    local_models_dir="$project_root/$local_models_dir"
  fi
  if ! create_directory "$local_models_dir" >/dev/null; then
    print_error "Failed to create Ollama models directory: ${local_models_dir}"
    return 1
  fi
  (cd "$local_models_dir" && pwd)
}

ollama_runtime_local_env_assignment() {
  local env_file="$1"
  local local_models_dir
  local_models_dir="$(ollama_runtime_local_models_dir "$env_file")" || return 1
  printf 'OLLAMA_MODELS=%s\n' "$local_models_dir"
}

ollama_runtime_local_cmd() {
  local env_file="$1"
  shift
  local local_env
  local_env="$(ollama_runtime_local_env_assignment "$env_file")" || return 1
  env "$local_env" ollama "$@"
}

ollama_runtime_host_port() {
  local base_url="$1"
  if [[ "$base_url" =~ :([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "11434"
  fi
}

ollama_runtime_ensure_docker_container() {
  local env_file="$1"
  local container image data_dir base_url host_port

  if ! command -v docker >/dev/null 2>&1; then
    print_error "Docker runtime selected but 'docker' CLI is not available."
    return 1
  fi

  if ! docker info >/dev/null 2>&1; then
    print_error "Docker runtime selected but Docker daemon is not reachable."
    return 1
  fi

  container="$(ollama_runtime_container_name "$env_file")"
  image="$(ollama_runtime_image "$env_file")"
  data_dir="$(ollama_runtime_data_dir "$env_file")"
  base_url="$(ollama_runtime_api_base_url "$env_file")"
  host_port="$(ollama_runtime_host_port "$base_url")"

  if docker ps --filter "name=^/${container}$" --filter "status=running" -q | grep -q .; then
    return 0
  fi

  if docker ps -a --filter "name=^/${container}$" -q | grep -q .; then
    print_info "Starting Docker Ollama container: ${container}"
    if ! docker start "$container" >/dev/null; then
      print_error "Failed to start Docker Ollama container: ${container}"
      return 1
    fi
    return 0
  fi

  print_info "Creating Docker Ollama container '${container}' from ${image}"
  print_info "Mounting model data: ${data_dir} -> /root/.ollama"
  if ! docker run -d \
    --name "$container" \
    -p "${host_port}:11434" \
    -v "${data_dir}:/root/.ollama" \
    "$image" >/dev/null; then
    print_error "Failed to create and start Docker Ollama container: ${container}"
    return 1
  fi

  return 0
}

ollama_runtime_ensure_ready() {
  local runtime="$1"
  local env_file="$2"

  if [[ "$runtime" == "docker" ]]; then
    ollama_runtime_ensure_docker_container "$env_file"
  fi
}

_ollama_dialog_pull_command() {
  local title="$1"
  local model_ref="$2"
  shift 2

  if [[ ! -t 2 ]] || ! declare -F check_if_dialog_installed >/dev/null 2>&1; then
    "$@"
    return $?
  fi
  if ! check_if_dialog_installed >/dev/null 2>&1; then
    "$@"
    return $?
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    "$@"
    return $?
  fi
  if ! python3 - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 6) else 1)
PY
  then
    "$@"
    return $?
  fi

  local log_file gauge_height gauge_width rc=0
  if ! log_file="$(mktemp -t ollama-pull.XXXXXX 2>/dev/null)"; then
    if ! log_file="$(mktemp "/tmp/ollama-pull.XXXXXX" 2>/dev/null)"; then
      echo "Failed to create temporary log file for ollama dialog; running without dialog." >&2
      "$@"
      return $?
    fi
  fi
  gauge_height="$DIALOG_HEIGHT"
  gauge_width="$DIALOG_WIDTH"
  (( gauge_height > 15 )) && gauge_height=15
  (( gauge_height < 10 )) && gauge_height=10
  (( gauge_width > 90 )) && gauge_width=90
  (( gauge_width < 60 )) && gauge_width=60

  if (
    local pid dialog_rc=0 pull_rc=0

    _ollama_dialog_pull_cleanup() {
      if [[ -n "${pid:-}" ]] && kill -0 "$pid" >/dev/null 2>&1; then
        # Avoid killing by process group here: in non-interactive shells the
        # pull process can share a PGID with this script or the dialog UI.
        kill "$pid" >/dev/null 2>&1 || true
        sleep 0.5
        if kill -0 "$pid" >/dev/null 2>&1; then
          kill -KILL "$pid" >/dev/null 2>&1 || true
        fi
        wait "$pid" >/dev/null 2>&1 || true
      fi
      rm -f "$log_file"
    }

    trap _ollama_dialog_pull_cleanup EXIT

    "$@" >"$log_file" 2>&1 &
    pid=$!

    if (
      printf 'XXX
0
Preparing model download...
XXX
'

      while kill -0 "$pid" >/dev/null 2>&1; do
        python3 - "$log_file" "$model_ref" <<'PY2'
import re
import sys
from pathlib import Path

TAIL_BYTES = 65536


def read_tail(path: Path, max_bytes: int) -> str:
    if not path.exists():
        return ""
    with path.open('rb') as handle:
        handle.seek(0, 2)
        size = handle.tell()
        handle.seek(max(size - max_bytes, 0))
        data = handle.read()
    return data.decode(errors='ignore')


log_path = Path(sys.argv[1])
text = read_tail(log_path, TAIL_BYTES)
text = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', text)
text = text.replace('\r', '\n')
lines = [line.strip() for line in text.splitlines() if line.strip()]
line = lines[-1] if lines else ''
model_ref = sys.argv[2]
percent = 0
message = f'Model: {model_ref}\nPreparing model download...'

for candidate in reversed(lines):
    if 'pulling ' in candidate or 'verifying ' in candidate or 'writing manifest' in candidate or 'success' in candidate or 'pulling manifest' in candidate:
        line = candidate
        break

normalized = re.sub(r'[^ -~]+', ' ', line)
normalized = re.sub(r'\s+', ' ', normalized).strip()
match = re.search(r'(pulling|verifying)\s+([^:]+):\s*(\d{1,3})%.*?(\d+(?:\.\d+)?\s*[KMGTP]?B)\s*/\s*(\d+(?:\.\d+)?\s*[KMGTP]?B)\s+(\d+(?:\.\d+)?\s*[KMGTP]?B/s)\s+(.+)$', normalized)
if match:
    action, layer, pct, cur, total, speed, eta = match.groups()
    percent = max(0, min(100, int(pct)))
    message = f'Model: {model_ref}\nLayer: {layer}\nProgress: {pct}% ({cur} / {total}) | {speed} | ETA: {eta}'
else:
    match = re.search(r'(pulling|verifying)\s+([^:]+):\s*(\d{1,3})%.*?(\d+(?:\.\d+)?\s*[KMGTP]?B)\s*/\s*(\d+(?:\.\d+)?\s*[KMGTP]?B)', normalized)
    if match:
        action, layer, pct, cur, total = match.groups()
        percent = max(0, min(100, int(pct)))
        message = f'Model: {model_ref}\nLayer: {layer}\nProgress: {pct}% ({cur} / {total})'
    elif 'pulling manifest' in normalized:
        percent = 1
        message = f'Model: {model_ref}\nPreparing model download...\nPulling manifest'
    elif 'writing manifest' in normalized:
        percent = 98
        message = f'Model: {model_ref}\nFinalizing model download...\nWriting manifest'
    elif 'success' in normalized:
        percent = 100
        message = f'Model: {model_ref}\nModel download completed.'
    elif normalized:
        message = f'Model: {model_ref}\n{normalized[:140]}'

print('XXX')
print(percent)
print(message)
print('XXX')
PY2
        sleep 0.5
      done
    ) | dialog --no-shadow --title "$title" --gauge "Preparing model download..." "$gauge_height" "$gauge_width" 0; then
      dialog_rc=0
    else
      dialog_rc=$?
    fi
    if [[ $dialog_rc -ne 0 ]]; then
      exit "$dialog_rc"
    fi

    wait "$pid"
    pull_rc=$?
    if [[ $pull_rc -ne 0 ]]; then
      print_error "Ollama pull failed." >&2
      if [[ -s "$log_file" ]]; then
        python3 - "$log_file" <<'PY4' >&2
import re
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
text = log_path.read_text(errors='ignore') if log_path.exists() else ""
text = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', text)
text = text.replace('\r', '\n')
lines = [line.strip() for line in text.splitlines() if line.strip()]
if lines:
    print(lines[-1])
PY4
      fi
    fi
    exit "$pull_rc"
  ); then
    rc=0
  else
    rc=$?
  fi
  return "$rc"
}

ollama_runtime_pull_model() {
  local runtime="$1"
  local env_file="$2"
  local model="$3"
  local size="${4:-latest}"
  local model_ref

  model_ref="$(ollama_model_ref "$model" "$size")"
  if [[ "$runtime" == "docker" ]]; then
    local container
    ollama_runtime_ensure_docker_container "$env_file" || return 1
    container="$(ollama_runtime_container_name "$env_file")"
    print_info "Pulling model in Docker: ${model_ref}"
    _ollama_dialog_pull_command "Downloading Model" "$model_ref" docker exec "$container" ollama pull "$model_ref"
    return $?
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    print_error "ollama CLI not found; install it or set ollama_runtime=docker."
    return 1
  fi

  local local_env
  local_env="$(ollama_runtime_local_env_assignment "$env_file")" || return 1

  print_info "Pulling model locally: ${model_ref}"
  _ollama_dialog_pull_command "Downloading Model" "$model_ref" env "$local_env" ollama pull "$model_ref"
}

ollama_runtime_supports_export() {
  local runtime="$1"
  local env_file="$2"
  local out=""
  local rc=0

  if [[ "$runtime" == "docker" ]]; then
    local container
    ollama_runtime_ensure_docker_container "$env_file" || return 1
    container="$(ollama_runtime_container_name "$env_file")"
    out="$(docker exec "$container" ollama export --help 2>&1)" || rc=$?
  else
    if ! command -v ollama >/dev/null 2>&1; then
      return 1
    fi
    out="$(ollama_runtime_local_cmd "$env_file" export --help 2>&1)" || rc=$?
  fi

  if [[ "$out" == *"unknown command"* ]] || [[ "$out" == *"is not a command"* ]]; then
    return 1
  fi
  if [[ $rc -eq 0 ]]; then
    return 0
  fi
  if [[ "$out" == *"Usage:"* && "$out" == *"export"* ]]; then
    return 0
  fi

  return 1
}

ollama_runtime_export_model() {
  local runtime="$1"
  local env_file="$2"
  local model_ref="$3"
  local output_path="$4"

  if ! create_directory "$(dirname "$output_path")" >/dev/null; then
    print_error "Failed to create export output directory: $(dirname "$output_path")"
    return 1
  fi

  if [[ "$runtime" == "docker" ]]; then
    local container
    ollama_runtime_ensure_docker_container "$env_file" || return 1
    container="$(ollama_runtime_container_name "$env_file")"
    print_info "Exporting ${model_ref} from Docker to ${output_path}"
    if ! docker exec "$container" ollama export "$model_ref" > "$output_path"; then
      rm -f "$output_path"
      return 1
    fi
    return 0
  fi

  print_info "Exporting ${model_ref} locally to ${output_path}"
  if ! ollama_runtime_local_cmd "$env_file" export "$model_ref" > "$output_path"; then
    rm -f "$output_path"
    return 1
  fi
  return 0
}

ollama_runtime_run_model() {
  local runtime="$1"
  local env_file="$2"
  local model="$3"
  local size="${4:-latest}"

  if [[ "$runtime" == "docker" ]]; then
    print_info "Docker runtime selected; model serve is handled by container API."
    return 0
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    print_warning "ollama CLI not found; skipping local 'ollama run'."
    return 0
  fi

  local model_ref
  local models_dir
  model_ref="$(ollama_model_ref "$model" "$size")"
  models_dir="$(ollama_runtime_local_models_dir "$env_file")" || return 1
  OLLAMA_MODELS="$models_dir" nohup ollama run "$model_ref" >/dev/null 2>&1 &
}

ollama_runtime_ps() {
  local runtime="$1"
  local env_file="$2"
  if [[ "$runtime" == "docker" ]]; then
    local container
    container="$(ollama_runtime_container_name "$env_file")"
    if command -v docker >/dev/null 2>&1; then
      print_info "Docker container status:"
      docker ps --filter "name=^/${container}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
    fi
  else
    if command -v ollama >/dev/null 2>&1; then
      ollama_runtime_local_cmd "$env_file" ps || true
    fi
  fi
}

# Pull a model: ollama pull "name:size"
ollama_pull_model() {
  local model="$1"; local size="${2:-latest}"
  local model_ref
  if ! command -v ollama >/dev/null 2>&1; then
    print_error "ollama CLI not found; install it first."
    return 1
  fi
  model_ref="$(ollama_model_ref "$model" "$size")"
  print_info "Pulling model: ${model_ref}"
  ollama pull "$model_ref"
}

# Run a model in background: ollama run name:size &
ollama_run_model() {
  local model="$1"; local size="${2:-latest}"
  local model_ref
  if ! command -v ollama >/dev/null 2>&1; then
    print_error "ollama CLI not found; install it first."
    return 1
  fi
  model_ref="$(ollama_model_ref "$model" "$size")"
  print_info "Running model: ${model_ref}"
  nohup ollama run "$model_ref" >/dev/null 2>&1 &
}

# Update key=value in .env (create or replace line); portable sed/awk approach.
ollama_update_env() {
  local env_file="${1:-.env}" key="$2" value="$3"
  if [[ -z "$key" ]]; then
    print_error "env key is required"
    return 1
  fi
  touch "$env_file"
  if grep -qE "^${key}=" "$env_file"; then
    # Replace line
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k{$0=k"="v} {print}' "$env_file" >"$env_file.tmp" && mv "$env_file.tmp" "$env_file"
  else
    printf "%s=%s\n" "$key" "$value" >>"$env_file"
  fi
}

# Orchestrated flow: ensure index, pick model+size, optionally persist to .env, then pull.
# Args:
#   $1 - repo_dir (default: ollama-get-models)
#   $2 - env_file to update (optional)
# Side effects: updates env_file with model/size if provided.
ollama_install_model_flow() {
  local repo_dir="${1:-ollama-get-models}" env_file="${2:-}"
  local json_file model size size_rc
  json_file=$(ollama_prepare_models_index "$repo_dir") || return 1

  # Read current selections from env (if provided)
  local current_model current_size
  if [[ -n "$env_file" && -f "$env_file" ]]; then
    current_model=$(resolve_env_value "model" "" "$env_file")
    current_size=$(resolve_env_value "size" "" "$env_file")
  fi

  while true; do
    model=$(ollama_dialog_select_model "$json_file" "$current_model") || return $?
    if size=$(ollama_dialog_select_size "$json_file" "$model" "$current_size"); then
      break
    else
      size_rc=$?
      if [[ $size_rc -eq 2 ]]; then
        current_model="$model"
        continue
      fi
      return "$size_rc"
    fi
  done

  if [[ -n "$env_file" ]]; then
    ollama_update_env "$env_file" model "$model"
    ollama_update_env "$env_file" size "$size"
  fi

  ollama_pull_model "$model" "$size"
}
