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

# Install the Ollama CLI: the pinned release, checked against its SHA-256
# (ollama_install in lib/ollama_install.sh; Homebrew on macOS). Returns what
# ollama_install returns, 1 for any failure here.
ollama_install_cli() {
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/ollama_install.sh"
  ollama_install "$@" || return 1
}

# Ensure repo with models index exists and is up to date; generate JSON index.
# Args:
#   $1 - target directory (default: ./ollama-get-models)
#   $2 - repo URL (default: webfarmer/ollama-get-models)
# Returns: print path to models JSON on success
#
# Callers capture stdout as the path (json_file="$(ollama_prepare_models_index)"),
# so the path is the ONLY thing printed there. Progress, warnings, git and the
# generator's own output all go to stderr: on stdout they became part of the
# "path" and every later step failed on a file that does not exist.
ollama_prepare_models_index() {
  local repo_dir="${1:-ollama-get-models}"
  _ollama_prepare_models_index_work "$@" >&2 || return 1
  echo "$repo_dir/code/ollama_models.json"
}

# Internal: the work behind ollama_prepare_models_index; its stdout is not the
# result and is sent to stderr by the caller.
_ollama_prepare_models_index_work() {
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
  # Sort deterministically by name, in whichever of the two shapes the
  # validator accepts. A failed sort leaves the index as it was and fails:
  # it used to leave a stray .tmp behind and still report success.
  if ! jq -S 'if type == "array" then sort_by(.name) else .models |= sort_by(.name) end' \
      "$json_path" >"$json_path.tmp"; then
    rm -f "$json_path.tmp"
    print_error "Failed to sort models index: $json_path"
    return 1
  fi
  # Replaced only when sorting changed it. The menu cache is rebuilt whenever
  # the index is newer than it, and an index rewritten on every call was
  # always newer: the cache was never reused.
  if cmp -s "$json_path.tmp" "$json_path"; then
    rm -f "$json_path.tmp"
  else
    mv "$json_path.tmp" "$json_path" || { rm -f "$json_path.tmp"; return 1; }
  fi
}

# Return path to models JSON for a repo directory (does not generate)
ollama_models_json_path() {
  local repo_dir="${1:-ollama-get-models}"
  echo "$repo_dir/code/ollama_models.json"
}

# The index is an array of models, or an object holding one under "models":
# _ollama_is_valid_models_json accepts both, so every reader takes both. A
# function, not a variable: a shell that has the functions without the
# variable (export -f) would run a jq program that starts with a pipe.
# It starts with `plain`, true for text without a control character: a name
# or a size with a line break in it would come out of jq as two.
_ollama_jq_models() {
  printf '%s' 'def plain: explode | all(.[]; . >= 32 and . != 127); (if type == "array" then . else (.models // []) end)'
}

# What the index names ends up in a command line and in the .env that
# ollama_install_model_flow writes and load_env sources. So only what can be a
# model reference is offered, by the rule lib/ollama_endpoint.sh has for one
# (_ollama_ep_is_model; tests/dialog_capture_test.sh holds the two together):
# letters, digits and . _ - / : only, starting with a letter or a digit, and no
# empty part (no "..", "//", "::", "/:", ":/", no ":" or "/" at the end).
# - The pattern is written here and not kept in a variable: matched against a
#   variable that is not set, [[ =~ ]] is true for everything.
# - LC_ALL=C: in other locales [A-Za-z] takes accented letters, and with
#   nocasematch a dotless i.
_ollama_is_model_ref() {
  local LC_ALL=C
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]] || return 1
  case "$1" in *..*|*//*|*:|*/|*::*|*/:*|*:/*) return 1 ;; esac
  return 0
}

# The same for a size, which becomes the tag: no "/" and no ":".
_ollama_is_model_tag() {
  local LC_ALL=C
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  case "$1" in *..*) return 1 ;; esac
  return 0
}

# True when a model reference carries its tag: a colon after the last slash
# (before it, a colon is a registry's port).
_ollama_ref_has_tag() { local last="${1##*/}"; [[ "$last" == *:* ]]; }

# What may be handed to `ollama pull` or `ollama run` as the model: one word
# that starts with a letter or a digit. Wider than _ollama_is_model_ref on
# purpose (a caller may pass name@sha256:...), and enough to keep an empty
# name, an option ("-x") and a second argument out of the command.
_ollama_ref_is_arg() {
  local LC_ALL=C
  [[ "${1:-}" =~ ^[A-Za-z0-9][^[:space:][:cntrl:]]*$ ]]
}

# Usage: _ollama_ref_checked <reference>; says so and returns 1 when the
# reference may not go into a command. The value is not printed: it is not a
# reference, and what it is instead is not known.
_ollama_ref_checked() {
  if _ollama_ref_is_arg "${1:-}"; then return 0; fi
  print_error "Not a model reference (it has to start with a letter or a digit, and have no space or control character in it); nothing was run." >&2
  return 1
}

# Usage: _ollama_index_id <index file>; prints the index as one line that is
# the same however the path was spelled: its directory as the system resolves
# it, and the file name. "idx/models.json" named from two directories is two
# indexes, and "./x.json", "x.json" and the full path are one. A line break in
# the path becomes a space, so the answer stays one line.
_ollama_index_id() {
  local file="${1:-}" dir id nl=$'\n' cr=$'\r'
  dir="$(dirname -- "$file")"
  if dir="$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P)"; then :; else dir="$(dirname -- "$file")"; fi
  id="${dir%/}/$(basename -- "$file")"
  id="${id//$nl/ }"
  printf '%s' "${id//$cr/ }"
}

# List model names from JSON index
ollama_list_models() {
  local json_file="$1"
  if [[ ! -f "$json_file" ]]; then
    print_error "Models JSON not found: $json_file" >&2
    return 1
  fi
  # Only names that can be a model reference, as the menu offers them. An
  # entry that is not an object, or has no name, is passed over.
  local names name out="" nl=$'\n'
  names="$(jq -r "$(_ollama_jq_models)"' | .[] | objects | .name | strings | select(plain)' "$json_file")" || return 1
  while IFS= read -r name; do
    if _ollama_is_model_ref "$name"; then out="${out}${out:+$nl}${name}"; fi
  done <<<"$names"
  [[ -n "$out" ]] || return 0
  # A reader that has what it wants and leaves (`ollama_list_models x | head
  # -n 1`) is not a failure of this function, also for a caller with pipefail.
  # bash writes a line at a time, so the reader can be gone before the last
  # one. Written in a subshell: SIGPIPE then ends the subshell and not the
  # function, and a write that failed on a pipe or a socket is not reported.
  # A write that fails anywhere else (a full disk) still is.
  if (printf '%s\n' "$out") 2>/dev/null; then return 0; fi
  if [[ -p /dev/stdout || -S /dev/stdout ]]; then return 0; fi
  print_error "Could not write the model names" >&2
  return 1
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

  # jq takes the entries apart; what may be offered is decided here, by the
  # one rule (_ollama_is_model_ref, _ollama_is_model_tag).
  # - Between jq and the loop the fields are separated by the unit separator
  #   and the sizes by the record separator. Tab would not do: it is
  #   whitespace to `read`, so an empty sizes field vanished and the
  #   description was read as the sizes.
  # - A name or a size with a control character in it is dropped in jq, so
  #   neither separator can come from the index. Control characters in a
  #   description become spaces.
  # - An entry that is not an object, or has no name, is passed over. It used
  #   to end the menu with a jq error.
  local rows name raw_sizes desc size sizes count=0
  local -a size_list
  rows="$(jq -r "$(_ollama_jq_models)"'
    | map(select(type == "object" and (.name | type) == "string" and (.name | plain)))
    | sort_by(.name | ascii_downcase)
    | .[]
    | [
        .name,
        ((if (.sizes | type) == "array" then .sizes else [] end)
          | map(select(type == "string" and plain)) | join("\u001e")),
        ((.description // "") | tostring | gsub("[[:space:][:cntrl:]]+"; " "))
      ]
    | join("\u001f")
  ' "$json_file")" || {
    rm -f "$tmp_file"
    return 1
  }

  {
    # The index this cache was made from (_ollama_index_id). A cache path may
    # be given by the caller (OLLAMA_MODEL_MENU_CACHE_FILE): the same path
    # with another index is another menu. The reader skips every line that
    # starts with "#": the path after the tab can pass for a model reference
    # ("dir/models.json" does), so the rule alone does not keep it out.
    printf '#index\t%s\n' "$(_ollama_index_id "$json_file")"
    while IFS=$'\037' read -r name raw_sizes desc; do
      _ollama_is_model_ref "$name" || continue
      sizes=""
      IFS=$'\036' read -r -a size_list <<<"$raw_sizes" || true
      for size in "${size_list[@]+"${size_list[@]}"}"; do
        if _ollama_is_model_tag "$size"; then sizes="${sizes}${sizes:+, }${size}"; fi
      done
      # A name that carries its tag has no size to choose (the size menu is
      # not shown for it), so its listed sizes are not shown either.
      if _ollama_ref_has_tag "$name"; then sizes="in the name"; fi
      # No column is empty but the last: see above.
      printf '%s\t%s\t%s\t%s\n' "$name" "$name" "${sizes:-latest}" "$desc"
      count=$((count + 1))
    done <<<"$rows"
  } >"$tmp_file" || {
    rm -f "$tmp_file"
    return 1
  }

  if [[ "$count" -eq 0 ]]; then
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
  # Indexed by the integer $idx, not by the zero-padded $tag. As an array
  # subscript "0010" is an arithmetic expression read as octal, so tag-keyed
  # lookups collided from the tenth model on.
  local -a model_lookup=()
  menu_height=18

  if [[ -n "${OLLAMA_MODEL_MENU_CACHE_FILE:-}" ]]; then
    cache_file="$OLLAMA_MODEL_MENU_CACHE_FILE"
  else
    cache_file="$(ollama_model_menu_cache_path "$json_file")"
  fi

  # Rebuilt unless the cache was made from this index, is newer than it, has
  # no empty column and is not old:
  # - an index that changed (a refresh, an entry added by hand) used to keep
  #   its old menu for half an hour;
  # - only a version that lost an empty column in reading wrote one, and its
  #   rows would be read wrongly here too;
  # - a cache path the caller gave may have been filled from another index.
  local made_from=""
  if [[ -s "$cache_file" ]]; then IFS= read -r made_from <"$cache_file" || true; fi
  if [[ "$made_from" != "#index"$'\t'"$(_ollama_index_id "$json_file")" ]] || [[ ! "$cache_file" -nt "$json_file" ]] \
      || grep -q "$(printf '\t\t')" "$cache_file" || ! ollama_model_menu_cache_is_fresh "$cache_file"; then
    cache_file="$(ollama_prepare_model_menu_cache "$json_file" "$cache_file")" || return 1
  fi

  # Case does not tell two models apart (Ollama reads "Qwen3" as "qwen3"), so
  # the current model is found whichever way it was written. Of two names that
  # differ only by case, the one written the same way wins.
  local nocase_was_on=0 exact_found=0
  if shopt -q nocasematch; then nocase_was_on=1; fi
  shopt -s nocasematch
  while IFS=$'	' read -r slug model_name sizes desc; do
    # A cache is a file: a row written by an older version, or by hand, is
    # held to the same rule as the index. A line that starts with "#" is not
    # a row: the first one names the index.
    [[ "$slug" != "#"* ]] || continue
    _ollama_is_model_ref "$model_name" || continue
    idx=$((idx + 1))
    tag=$(printf '%04d' "$idx")
    summary="${slug} | sizes: ${sizes:-latest}"
    if [[ -n "$desc" ]]; then
      summary="${summary} | ${desc}"
    fi
    summary="${summary:0:140}"
    menu_items+=("$tag" "$summary")
    model_lookup[$idx]="$model_name"
    # `[ = ]` compares exactly; `[[ == ]]` follows nocasematch.
    if [ "$model_name" = "$current_model" ]; then
      default_tag="$tag"
      exact_found=1
    elif [[ "$exact_found" -eq 0 && -z "$default_tag" && "$model_name" == "$current_model" ]]; then
      default_tag="$tag"
    fi
  done < "$cache_file"
  [[ "$nocase_was_on" -eq 1 ]] || shopt -u nocasematch

  total_count="$idx"
  if [[ $total_count -eq 0 ]]; then
    print_error "No selectable Ollama models found in cache: $cache_file" >&2
    return 1
  fi
  value="Browse the indexed Ollama models. Showing ${total_count}."
  if [[ -n "$current_model" ]]; then
    value="${value} Current selection: ${current_model}."
  fi

  if [[ -n "$default_tag" ]]; then
    if ! selected=$(dialog_capture --default-item "$default_tag" --menu "$value" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$menu_height" "${menu_items[@]}"); then
      print_error "No model selected." >&2
      return 1
    fi
  else
    if ! selected=$(dialog_capture --menu "$value" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$menu_height" "${menu_items[@]}"); then
      print_error "No model selected." >&2
      return 1
    fi
  fi

  # dialog echoes back the padded tag; 10# forces base ten so the padding is
  # not mistaken for an octal literal.
  local selected_idx=""
  [[ "$selected" =~ ^[0-9]+$ ]] && selected_idx=$((10#$selected))

  if [[ -z "$selected" || -z "$selected_idx" || -z "${model_lookup[$selected_idx]:-}" ]]; then
    print_error "No model selected." >&2
    return 1
  fi

  echo "${model_lookup[$selected_idx]}"
}

# Use dialog to select size for a given model. If none available, returns 'latest'.
ollama_dialog_select_size() {
  local json_file="$1"; local model="$2"; local current_size="${3:-}"
  if [[ ! -f "$json_file" ]]; then
    print_error "Models JSON not found: $json_file" >&2
    return 1
  fi

  # A name that carries its tag is the whole reference: there is no size to
  # choose, and one chosen here would be recorded and never pulled.
  if _ollama_ref_has_tag "$model"; then
    echo "latest"
    return 0
  fi

  # Only what can be a tag (_ollama_is_model_tag): a size goes into a command
  # line and into .env. A jq that fails is an error, not "no sizes": it used
  # to answer "latest" for an index it could not read.
  # An array: a string split by `for s in $sizes` was one item for a caller
  # whose IFS has no space (IFS=$'\n\t').
  local raw_sizes s
  local -a sizes=()
  if ! raw_sizes="$(jq -r --arg m "$model" "$(_ollama_jq_models)"'
      | .[] | objects | select(.name == $m) | .sizes
      | if type == "array" then .[] else empty end | strings | select(plain)' "$json_file")"; then
    print_error "Could not read the sizes of $model from: $json_file" >&2
    return 1
  fi
  while IFS= read -r s; do
    if _ollama_is_model_tag "$s"; then sizes+=("$s"); fi
  done <<<"$raw_sizes"
  if [[ ${#sizes[@]} -eq 0 ]]; then
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
  local -a dialog_args=(--menu "Select a size for: $model" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 10)
  local has_default=""
  for s in "${sizes[@]}"; do
    menu_items+=("$s" "$s")
    if [[ -n "$current_size" && "$s" == "$current_size" ]]; then
      has_default=1
    fi
  done
  if [[ -n "$has_default" ]]; then
    dialog_args=(--default-item "$current_size" --menu "Select a size for: $model" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 10)
  fi

  local selected status=0
  if selected=$(dialog_capture "${dialog_args[@]}" "${menu_items[@]}"); then
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

# Build Ollama model reference. Omits tag when size is empty/latest, and when
# the name carries a tag already (an index may list hf.co/org/model:Q4_K_M):
# a second tag is not a reference.
ollama_model_ref() {
  local model_name="$1"
  local model_size="${2:-latest}"
  if [[ -z "$model_size" || "$model_size" == "latest" ]] || _ollama_ref_has_tag "$model_name"; then
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
    # stderr: the caller captures stdout as the runtime name.
    print_warning "Invalid ollama_runtime '$runtime'; defaulting to 'local'." >&2
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
  # stdout is the address and nothing else: callers capture it. An address
  # ollama_update_env will not write (a "$" or "&" in a password) is still the
  # address for this run; it is only not saved.
  if [[ -n "$env_file" ]]; then
    if ! ollama_update_env "$env_file" ollama_url "$base_url"; then
      print_warning "ollama_url was not saved to ${env_file}; the address is used for this run only." >&2
    fi
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

    # The command below runs in the background, and a background job inherits this

    # trap: signalled, it would delete the log file it is still writing to.

    trap 'if [[ ${BASHPID-$$} == "$$" ]]; then _ollama_dialog_pull_cleanup; fi' EXIT

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
    ) | dialog_gauge --no-shadow --title "$title" --gauge "Preparing model download..." "$gauge_height" "$gauge_width" 0; then
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
  _ollama_ref_checked "$model_ref" || return 1
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

  _ollama_ref_checked "$model_ref" || return 1
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
  _ollama_ref_checked "$model_ref" || return 1
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
  _ollama_ref_checked "$model_ref" || return 1
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
  _ollama_ref_checked "$model_ref" || return 1
  print_info "Running model: ${model_ref}"
  nohup ollama run "$model_ref" >/dev/null 2>&1 &
}

# A key ollama_update_env writes: a letter or an underscore, then letters,
# digits, underscores and dots. In the C locale, where [A-Za-z] has no accented
# letters. A dot is kept because keys with one are written today. bash does not
# take such a line as an assignment: load_env prints "command not found" for it
# and loads the rest, and a caller running with `set -e` ends there.
_ollama_env_key_ok() {
  local LC_ALL=C
  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]]
}

# Update key=value in .env (create or replace line); portable sed/awk approach.
# Its messages go to stderr: ollama_runtime_sync_env_url calls it and is
# captured.
#
# The key is compared literally (a regex test found "a.b" in "aXb=" and then
# the literal replace wrote nothing), values travel through ENVIRON (awk -v
# turned backslashes into escapes), a newline is refused (it would add a line
# to a file that load_env sources), and a replaced file keeps its mode (a 0600
# .env holding a token came back 0644) and, when it is a symlink, stays one.
ollama_update_env() {
  local env_file="${1:-.env}" key="${2:-}" value="${3:-}"
  if [[ -z "$key" ]]; then
    print_error "env key is required" >&2
    return 1
  fi
  case "$key$value" in
    *$'\n'*|*$'\r'*)
      print_error "env key and value must not contain a newline or carriage return" >&2
      return 1
      ;;
  esac
  # The file is one that load_env sources. A line "key=value" runs what is in
  # the value when it holds a shell operator, a substitution or a second word
  # ("model=two words" runs `words`), and an unclosed quote stops the whole
  # file from loading. A backslash at the end joins the next line to this
  # one, and a comment line after it then runs. Such a value is refused, not
  # written.
  # Still written as given, as before, though load_env reads them changed: a
  # backslash inside the value (a\b loads as ab) and a tilde at its start
  # (~/x loads as the home directory's x).
  if ! _ollama_env_key_ok "$key"; then
    print_error "env key is not a name: nothing was written" >&2
    return 1
  fi
  case "$value" in
    *[[:space:]\;\&\|\$\`\(\)\<\>\'\"]*|*\\)
      print_error "the value for ${key} has a space, a quote or a shell operator in it, or ends in a backslash; ${env_file} is sourced, so it was not written" >&2
      return 1
      ;;
  esac
  touch "$env_file" || return 1
  if _OLLAMA_ENV_KEY="$key" awk 'BEGIN{FS="="; k=ENVIRON["_OLLAMA_ENV_KEY"]} $1==k{found=1; exit} END{exit !found}' "$env_file"; then
    # Replace line
    local tmp
    tmp="$(mktemp "${env_file}.XXXXXX")" || return 1
    if ! _OLLAMA_ENV_KEY="$key" _OLLAMA_ENV_VALUE="$value" \
        awk 'BEGIN{FS=OFS="="; k=ENVIRON["_OLLAMA_ENV_KEY"]; v=ENVIRON["_OLLAMA_ENV_VALUE"]} $1==k{$0=k"="v} {print}' \
        "$env_file" >"$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    # Written back through the path rather than mv'd over it, as hub_write_env
    # does: mv replaced a symlinked .env with a regular file, and copying the
    # mode read off the link made that file 0777. `cat >` follows the link and
    # keeps the inode, so the link, the target and its mode all stay.
    cat "$tmp" >"$env_file" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
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
  # Empty, not unset: a first run has no env file, and under `set -u` the menu
  # call below ended the caller on an unbound variable.
  local current_model="" current_size=""
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
