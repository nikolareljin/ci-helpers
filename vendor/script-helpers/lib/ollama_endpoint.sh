#!/usr/bin/env bash
# Ollama endpoint helpers for a project's start script. They answer three
# questions, in order, before anything is pulled:
#   1. Which models does the project need?
#   2. Which of them does this Ollama not have yet?
#   3. Does the machine have room for those (disk for the download, memory
#      for the largest model)?
# Models are pulled only if the answer to 3 is yes.
#
# A project lists its models in one env-style file, one NAME=model per line.
#
# Expected imports by caller (via shlib_import): logging
#
# Works on bash 3.2 and BSD tools. Safe for a caller that uses
# `set -euo pipefail`: no pipeline here can end such a caller, and no function
# reads an argument it was not given.

# --- what counts as a name, a model, a number --------------------------------

# True for a valid variable name. Checked before the name is used in
# `${!name}` (bash would run a command hidden in `x[$(cmd)]`) or in a sed
# program.
# LC_ALL=C in both rules: in other locales [A-Za-z] takes accented letters.
_ollama_ep_is_name() { local LC_ALL=C; [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

# True for a valid model reference: letters, digits and . _ - / : only, and no
# "..". Checked before the model is put into a URL or a JSON string.
# "@" is not allowed. It would mean credentials (user:secret@registry/model),
# which must not be printed or stored, or a digest (model@sha256:...), which
# cannot be sized here or matched against the names an Ollama lists.
_ollama_ep_is_model() {
  local LC_ALL=C
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]] || return 1
  # No empty part: "qwen3:" has no tag, "qwen3/" has no name after the slash.
  # Ollama calls these an invalid model name. Without this they got as far as
  # the registry and failed there with a message about the size.
  case "$1" in *..*|*//*|*:|*/|*::*|*/:*|*:/*) return 1 ;; esac
  return 0
}

# Usage: _ollama_ep_on <NAME> <on|off>; true if the setting NAME is on. The
# second argument is what an unset or empty NAME means.
# On: 1 true yes on. Off: 0 false no off never. Case does not matter.
# Any other value is a typo. It is reported and read as off, which for every
# setting here is the careful side: pull nothing, skip no check.
_ollama_ep_on() {
  local name="${1:-}" default="${2:-off}" value
  _ollama_ep_is_name "$name" || return 1
  value="$(printf '%s' "${!name:-}" | tr 'A-Z' 'a-z' | tr -d ' \t\r')" || true
  case "${value:-$default}" in
    1|true|yes|on) return 0 ;;
    0|false|no|off|never) return 1 ;;
  esac
  print_warning "${name} is neither on (1, true, yes) nor off (0, false, no): '$(_ollama_ep_said "${!name:-}")'. Read as off." >&2
  return 1
}

# Usage: _ollama_ep_remote_tier; for an Ollama on another machine, whose
# tier is not this machine's. Unless AI_MODEL_TIER names it, a stated
# OLLAMA_BUDGET_MEM_TOTAL_BYTES measures it (no GPU when
# OLLAMA_BUDGET_GPU_LARGEST_BYTES is not stated); with neither, standard.
# Call it in a subshell: it exports AI_MODEL_TIER or
# OLLAMA_BUDGET_GPU_LARGEST_BYTES.
# Returns: 0.
# Output: none.
_ollama_ep_remote_tier() {
  [[ -z "$(printf '%s' "${AI_MODEL_TIER:-}" | tr -d ' \t\r')" ]] || return 0
  if _ollama_ep_uint "${OLLAMA_BUDGET_MEM_TOTAL_BYTES:-}" >/dev/null; then
    _ollama_ep_uint "${OLLAMA_BUDGET_GPU_LARGEST_BYTES:-}" >/dev/null || export OLLAMA_BUDGET_GPU_LARGEST_BYTES=0
  else
    export AI_MODEL_TIER=standard
  fi
  return 0
}

# Usage: _ollama_ep_pull_mode; prints on, off or ask for OLLAMA_PULL_MISSING
# (default on). ask: pull only after a yes on a terminal (_ollama_ep_ask_pull).
# Anything else is said once and read as off, as _ollama_ep_on does.
_ollama_ep_pull_mode() {
  local value
  value="$(printf '%s' "${OLLAMA_PULL_MISSING:-}" | tr 'A-Z' 'a-z' | tr -d ' \t\r')" || true
  case "${value:-on}" in
    ask) printf 'ask\n' ;;
    1|true|yes|on) printf 'on\n' ;;
    0|false|no|off|never) printf 'off\n' ;;
    *)
      print_warning "OLLAMA_PULL_MISSING is neither on (1, true, yes), off (0, false, no) nor ask: '$(_ollama_ep_said "${OLLAMA_PULL_MISSING:-}")'. Read as off." >&2
      printf 'off\n'
      ;;
  esac
}

# Usage: _ollama_ep_can_ask; true when there is a person to ask: stdin and
# stderr are a terminal. A desktop launcher, a service or CI has neither.
# A function so a test can stand in for the terminal.
_ollama_ep_can_ask() {
  [[ -t 0 && -t 2 ]]
}

# Usage: _ollama_ep_ask_pull <shown url> <listing>; true on a yes. The listing
# is one "model  size" line per missing model. Asked on stderr, read from stdin,
# so a caller that captures stdout still gets the question.
_ollama_ep_ask_pull() {
  local shown="${1:-}" listing="${2:-}" answer=""
  printf 'The Ollama at %s lacks:\n%s\nPull now? [y/N] ' "$shown" "$listing" >&2
  IFS= read -r answer || answer=""
  case "$(printf '%s' "$answer" | tr 'A-Z' 'a-z' | tr -d ' \t\r')" in
    y|yes) return 0 ;;
  esac
  return 1
}

# Usage: _ollama_ep_check_overrides <models_file> [NAME...]; returns 0 when every
# model a name gets is approved, and 9 otherwise.
#
# The models file is the approved set: for each NAME, the models of its columns
# (NAME, NAME_SMALL, NAME_LARGE, NAME_XLARGE), one per role and class of machine
# (fleet model registry). A NAME set in the environment or .env to any other
# model is a manual override. It is allowed, but never silently: on a terminal
# the person is told it is not approved and asked; with no terminal, and in CI
# (CI=true, GITHUB_ACTIONS), it is refused, because nobody is there to say yes.
# A NAME the file does not name has no approved set, and is not judged.
_ollama_ep_check_overrides() {
  local _oep_file="${1:-}" _oep_name _oep_value _oep_col _oep_ok _oep_approved _oep_answer _oep_names
  [[ -n "$_oep_file" && -f "$_oep_file" ]] || return 0
  [[ $# -gt 0 ]] && shift
  if [[ $# -gt 0 ]]; then
    _oep_names="$(printf '%s\n' "$@")"
  else
    _oep_names="$(ollama_models_file_names "$_oep_file" | grep -v -E '_(SMALL|LARGE|XLARGE)(_V?RAM_GB)?$|^AI_TIER_' || true)"
  fi
  # The names come in on fd 3: stdin stays the person's, for the answer below.
  while IFS= read -r _oep_name <&3; do
    [[ -n "$_oep_name" ]] && _ollama_ep_is_name "$_oep_name" || continue
    _oep_value="$(printf '%s' "${!_oep_name:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" || true
    [[ -n "$_oep_value" ]] || continue
    _oep_approved="" _oep_ok=1
    for _oep_col in "" _SMALL _LARGE _XLARGE; do
      _oep_col="$(_ollama_ep_file_val "$_oep_file" "${_oep_name}${_oep_col}")"
      [[ -n "$_oep_col" ]] || continue
      _oep_approved="${_oep_approved:+$_oep_approved, }$_oep_col"
      # The same model however it is written: case, and an omitted :latest.
      if [[ "$(ollama_model_tagged "$_oep_col" | tr 'A-Z' 'a-z')" == "$(ollama_model_tagged "$_oep_value" | tr 'A-Z' 'a-z')" ]]; then
        _oep_ok=0
      fi
    done
    [[ -n "$_oep_approved" && "$_oep_ok" -ne 0 ]] || continue
    if [[ "${CI:-}" == "true" || -n "${GITHUB_ACTIONS:-}" ]] || ! _ollama_ep_can_ask; then
      print_error "$_oep_name=$_oep_value is not an approved model for this project (approved: $_oep_approved). An override needs a person to confirm it on a terminal; in CI or with no terminal it is refused. Remove $_oep_name from .env to use the approved model." >&2
      return 9
    fi
    printf '%s=%s is not an approved model for this project.\nApproved, by class of machine: %s\nUse it anyway (a manual override)? [y/N] ' "$_oep_name" "$_oep_value" "$_oep_approved" >&2
    IFS= read -r _oep_answer || _oep_answer=""
    case "$(printf '%s' "$_oep_answer" | tr 'A-Z' 'a-z' | tr -d ' \t\r')" in
      y|yes) print_info "Using $_oep_name=$_oep_value, an override of the approved set." >&2 ;;
      *) print_error "Not using $_oep_name=$_oep_value. Remove it from .env to use the approved model." >&2; return 9 ;;
    esac
  done 3<<<"$_oep_names"
  return 0
}

# Usage: _ollama_ep_pull_hint <url> <missing, one per line>; prints the ways
# past a refusal under ask: the exact pull commands, and the setting that pulls
# without asking. OLLAMA_HOST is named unless the address is Ollama's own
# default here, or `ollama pull` would fill another Ollama than this one.
_ollama_ep_pull_hint() {
  local url="${1:-}" missing="${2:-}" host="" cmds="" m
  case "${url#*://}" in
    127.0.0.1:11434|localhost:11434) ;;
    *) host="OLLAMA_HOST=$(_ollama_ep_shown_url "$url") " ;;
  esac
  while IFS= read -r m; do
    [[ -n "$m" ]] && cmds="${cmds}${cmds:+; }${host}ollama pull ${m}"
  done <<<"$missing"
  printf 'Pull it with: %s. Or set OLLAMA_PULL_MISSING=1 to pull without asking.' "$cmds"
}

# Usage: _ollama_ep_uint <value>; prints value as a whole number, or fails.
# At most 15 digits, because more overflows bash arithmetic. Leading zeros are
# removed, because bash reads "08" as an invalid octal number and "010" as 8.
_ollama_ep_uint() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  while [[ "${#value}" -gt 1 && "${value:0:1}" == "0" ]]; do value="${value:1}"; done
  [[ "${#value}" -le 15 ]] || return 1
  printf '%s\n' "$value"
}

# Bytes as "N.N GB". 1 GB is 10^9 bytes, the same unit `ollama list` uses, so
# the numbers in a message can be compared with it.
_ollama_ep_gb() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.1f GB", b / 1000000000 }'
}

# A URL that is safe to print. Removed:
# - user and password (user:secret@host, with or without a scheme). Everything
#   up to the last "@" before the first "/" goes, because a password may
#   contain an "@" itself; curl reads it the same way.
# - the query and fragment (?... and #...), where a token may be.
# - control characters.
_ollama_ep_shown() {
  # Backslashes are doubled, last. The logging helpers print with `echo -e`,
  # which would turn the text \033[2J into a real escape sequence.
  printf '%s' "${1:-}" | LC_ALL=C tr -d '\000-\037\177' \
    | sed -E 's|[?#].*$||; s|^([a-zA-Z][a-zA-Z0-9+.-]*://)?[^/]*@|\1|; s|\\|\\\\|g' || true
}

# A URL as it is named in a message: scheme, host and port only. Besides what
# _ollama_ep_shown removes, the path goes too: a proxy may serve an Ollama
# under a path that holds a key (https://gateway/KEY/ollama).
_ollama_ep_shown_url() {
  printf '%s' "${1:-}" | LC_ALL=C tr -d '\000-\037\177' \
    | sed -E -e 's|[?#].*$||' -e 's|^([a-zA-Z][a-zA-Z0-9+.-]*://)?[^/]*@|\1|' \
        -e '/:\/\//!s|^([^/]*)/.*$|\1|' -e 's|^([a-zA-Z][a-zA-Z0-9+.-]*://[^/]*)/.*$|\1|' \
        -e 's|\\|\\\\|g' || true
}

# Text from the other side (Ollama, curl) that is safe to print: the last
# line only, no control characters, at most 300 characters. A terminal obeys
# escape sequences in what it prints, and this text is not ours.
_ollama_ep_said() {
  # - Control characters are removed by octal range. Not all `tr` know
  #   [:print:] (busybox reads it as plain letters).
  # - Credentials in any URL (://user:secret@) are removed before the cut to 300
  #   characters. A cut in the middle of them would leave half a password.
  # - Backslashes are doubled, for the same `echo -e` as in _ollama_ep_shown.
  printf '%s' "${1:-}" | tr -d '\r' | tail -n 1 | LC_ALL=C tr -d '\000-\037\177' \
    | sed -E 's|(://)[^/@[:space:]]*@|\1|g' | cut -c1-300 | sed 's|\\|\\\\|g' || true
}

# --- the models file ---------------------------------------------------------
#
# One NAME=model per line, read like an env file. Not part of the value:
# `export ` before the name, spaces around `=`, one pair of quotes, a trailing
# ` # comment`, and a carriage return (Windows line ends).

# Usage: ollama_models_file_get <file> <NAME>; prints the value of NAME, or
# nothing. If NAME is set twice, the last line wins. Returns 2 if NAME is not
# a valid variable name.
# Returns: 0 (also when the file or NAME is absent); 2 NAME not a variable name.
# Output: stdout the value and a newline (empty line when NAME is absent; nothing when the file is missing).
ollama_models_file_get() {
  local file="${1:-}" name="${2:-}" value bom=$'\xef\xbb\xbf'
  _ollama_ep_is_name "$name" || return 2
  [[ -f "$file" ]] || return 0
  # Remove a byte-order mark (some editors add one at the start of a file).
  # With it, the first variable in the file was never found.
  value="$(sed -n -E "1s/^${bom}//; s/^[[:space:]]*(export[[:space:]]+)?${name}[[:space:]]*=[[:space:]]*//p" "$file" | tail -n 1)" || true
  value="${value%$'\r'}"
  case "$value" in
    \"*\"*) value="${value#\"}"; value="${value%%\"*}" ;;
    \'*\'*) value="${value#\'}"; value="${value%%\'*}" ;;
    *)
      value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//')" || true
      ;;
  esac
  printf '%s\n' "$value"
}

# Usage: ollama_models_file_names <file>; prints every name the file assigns,
# one per line, in file order, each once.
# Returns: 0 (also when the file is missing).
# Output: stdout one name per line.
ollama_models_file_names() {
  local file="${1:-}" bom=$'\xef\xbb\xbf'
  [[ -f "$file" ]] || return 0
  # The byte-order mark: see ollama_models_file_get.
  sed -n -E "1s/^${bom}//; "'s/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' "$file" \
    | awk '!seen[$0]++' || true
}

# Usage: ollama_model_tagged <model>; prints the model the way Ollama lists
# it: with a tag (":latest" if none is given), and without the default
# registry's host or "library/" prefix.
# Only the part after the last "/" is checked for a tag:
# "registry.example:5000/team/model" has a port, not a tag.
# Returns: 0.
# Output: stdout the tagged model; nothing for an empty argument.
ollama_model_tagged() {
  local model="${1:-}" last
  [[ -n "$model" ]] || return 0
  model="${model#registry.ollama.ai/}"
  model="${model#library/}"
  last="${model##*/}"
  case "$last" in
    *:*) printf '%s\n' "$model" ;;
    *)   printf '%s:latest\n' "$model" ;;
  esac
}

# Usage: ollama_models_required <file> [NAME...]; prints the models a start
# needs, the way Ollama lists them, one per line, each once.
#
# With no NAME: every name in the file, except the ones for other machine
# classes. A name ending in _SMALL, _LARGE or _XLARGE is the model for another
# class; a name ending in _RAM_GB or _VRAM_GB after that is a number used to
# pick the class, not a model.
# A non-blank value in the environment wins over the file. So a caller that
# has loaded its own .env gets that machine's choice.
#
# Returns 2 and prints nothing if a NAME is not a valid variable name. A list
# that stopped at the bad name would start a project with only some of its
# models.
# Returns 1 and prints nothing if a file is given and does not exist. A
# mistyped path would otherwise mean "this project needs no models", and the
# start would check nothing. Pass "" to use no file.
# Returns: 0 printed; 1 file given but missing; 2 a NAME is not a variable name.
# Output: stdout one model per line; stderr errors.
ollama_models_required() {
  # Its own variables start with _oep_: a NAME is read through ${!NAME}, and a
  # local called "name" or "value" would be read in place of the caller's.
  local _oep_file="${1:-}" _oep_name _oep_value _oep_names
  [[ $# -eq 0 ]] || shift
  if [[ -n "$_oep_file" && ! -f "$_oep_file" ]]; then
    print_error "No models file at $(_ollama_ep_said "$_oep_file")" >&2
    return 1
  fi
  if [[ $# -gt 0 ]]; then
    for _oep_name in "$@"; do
      if ! _ollama_ep_is_name "$_oep_name"; then
        print_error "Not a variable name: $(_ollama_ep_said "$_oep_name")" >&2
        return 2
      fi
    done
    _oep_names="$(printf '%s\n' "$@")"
  else
    _oep_names="$(ollama_models_file_names "$_oep_file" | grep -v -E '_(SMALL|LARGE|XLARGE)(_V?RAM_GB)?$' || true)"
  fi
  # Checked here, not per name: the names are read in a pipeline below, where
  # a refusal would end the loop and leave a list with no models in it.
  if [[ -n "$(printf '%s' "${AI_MODEL_TIER:-}" | tr -d ' \t\r')" ]] \
     && ! _ollama_ep_tier_rank "$(printf '%s' "$AI_MODEL_TIER" | tr 'A-Z' 'a-z' | tr -d ' \t\r')" >/dev/null; then
    print_error "AI_MODEL_TIER is one of small, standard, large, xlarge; not $(_ollama_ep_said "$AI_MODEL_TIER")" >&2
    return 2
  fi
  while IFS= read -r _oep_name; do
    [[ -n "$_oep_name" ]] || continue
    # This machine's column (ollama_model_for_class); a value in the
    # environment wins, trimmed: a padded value is the same model.
    _oep_value="$(ollama_model_for_class "$_oep_file" "$_oep_name")" || return 2
    [[ -n "$_oep_value" ]] || continue
    ollama_model_tagged "$_oep_value"
  done <<<"$_oep_names" | awk '!seen[tolower($0)]++'
  return 0
}

# --- what an endpoint has ----------------------------------------------------

# Usage: ollama_endpoint_models <base_url> [timeout_seconds=5]; prints the
# models that Ollama has, one per line, as it names them (with tags).
# Returns 1 when nothing answers there or what answers is not an Ollama.
# Returns: 0 an Ollama answered (also with no models); 1 no answer or not an Ollama.
# Output: stdout one model name per line.
ollama_endpoint_models() {
  local url="${1:-}" timeout="${2:-5}" body names
  url="${url%/}"
  [[ -n "$url" ]] || return 1
  body="$(curl -fsS -m "$timeout" "${url}/api/tags" 2>/dev/null | tr -d '\n\r')" || return 1
  # Any web server may answer 200. An Ollama's answer contains "models".
  grep -q '"models"[[:space:]]*:' <<<"$body" || return 1
  # In a model's entry "name" is followed by "model". A "name" elsewhere in
  # the answer (inside a nested object) is not.
  names="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,[[:space:]]*"model"' <<<"$body" || true)"
  if [[ -z "$names" ]]; then
    # An old Ollama lists "name" only: take the first key of each entry.
    names="$(grep -o '{[[:space:]]*"name"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$body" || true)"
  fi
  [[ -n "$names" ]] || return 0
  sed -E 's/^[^:]*:[[:space:]]*"//; s/".*$//' <<<"$names"
}

# Usage: ollama_models_missing <needed> <present>; both are lists, one model
# per line. Prints the needed models that are not present.
# Only a whole name matches: "qwen:7b-instruct" does not count as "qwen:7b".
# Upper and lower case are the same, as they are to Ollama ("Qwen:7B" is the
# model it lists as "qwen:7b").
# Returns: 0.
# Output: stdout the missing models, one per line.
ollama_models_missing() {
  local needed="${1:-}" present="${2:-}" model
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    grep -qixF -- "$model" <<<"$present" || printf '%s\n' "$model"
  done <<<"$needed"
  return 0
}

# --- how big, and how much room ----------------------------------------------

# Usage: ollama_registry_size_bytes <model>; prints the download size of the
# model in bytes, read from the registry's manifest.
# Returns 1 if the registry does not answer, answers with something that is
# not a model's manifest, or the model reference is not valid. Returns 2 if the
# model is on another registry host: its size is not asked for. Returns 3 if
# the registry answers that it has no such model or tag (measured: HTTP 404
# with the code MANIFEST_UNKNOWN for both). That is a name to correct, not a
# registry to wait for.
# Env: OLLAMA_REGISTRY_URL (default https://registry.ollama.ai),
# OLLAMA_REGISTRY_TIMEOUT (default 15 seconds).
#
# The size is the sum of all layers in the manifest. Layers the machine
# already has from another model are counted again, so the number can be too
# high but never too low.
# Returns: 0 printed; 1 no or bad answer, or bad reference; 2 another registry host; 3 no such model or tag.
# Output: stdout the byte count; stderr nothing on success.
ollama_registry_size_bytes() {
  local ref tag name path body first answer code
  local base="${OLLAMA_REGISTRY_URL:-https://registry.ollama.ai}"
  ref="$(ollama_model_tagged "${1:-}")"
  _ollama_ep_is_model "$ref" || return 1
  tag="${ref##*:}"
  name="${ref%:"$tag"}"
  [[ -n "$tag" && -n "$name" ]] || return 1
  # A colon left in the name is a host's port: another registry.
  [[ "$name" != *:* ]] || return 2
  first="${name%%/*}"
  case "$name" in
    */*/*) return 2 ;;
    */*)
      # host/model: a first segment with a dot is a host, not a namespace.
      case "$first" in *.*|localhost) return 2 ;; esac
      path="$name"
      ;;
    *) path="library/$name" ;;
  esac
  # The status goes on a line of its own after the body: without -f, so that
  # a 404's body can be read.
  answer="$(curl -sS -m "${OLLAMA_REGISTRY_TIMEOUT:-15}" -w '\n%{http_code}' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "${base%/}/v2/${path}/manifests/${tag}" 2>/dev/null)" || return 1
  code="${answer##*$'\n'}"
  body="$(printf '%s' "${answer%$'\n'*}" | tr -d '\n\r')" || true
  if [[ "$code" == "404" ]]; then
    # Only the registry's own "unknown" counts. Any web server says 404 for a
    # path it does not have, and a mistyped OLLAMA_REGISTRY_URL is not a
    # mistyped model.
    grep -q -E '"(MANIFEST|NAME)_UNKNOWN"' <<<"$body" || return 1
    return 3
  fi
  case "$code" in 2??) ;; *) return 1 ;; esac
  # A model's manifest has "layers". A list of manifests, or a web page that
  # contains "size", does not. Summing those would give a number that passes
  # any check.
  grep -q '"layers"[[:space:]]*:' <<<"$body" || return 1
  { grep -o '"size"[[:space:]]*:[[:space:]]*[0-9][0-9]*[^0-9.eE]' <<<"$body" || true; } \
    | awk -F: '{ gsub(/[^0-9]/, "", $2); if ($2 != "") { total += $2; n++ } }
               END { if (!n) exit 1; printf "%.0f\n", total }'
}

# Usage: ollama_models_dir; prints where an Ollama on this machine keeps its
# models, for the disk check:
# - OLLAMA_MODELS when set (Ollama's own variable for it);
# - else the directory of the Linux service, when there is one: the installer
#   sets Ollama up as a service with a user of its own, and that user's home
#   is not $HOME;
# - else ~/.ollama/models (an Ollama started by hand, and macOS).
# The directory need not exist yet: ollama_disk_free_bytes reads its nearest
# existing parent. Not for an Ollama in a container: pass Docker's data root.
# Returns: 0.
# Output: stdout the directory.
ollama_models_dir() {
  local service="${_OLLAMA_EP_SERVICE_MODELS:-/usr/share/ollama/.ollama/models}"
  if [[ -n "${OLLAMA_MODELS:-}" ]]; then
    printf '%s\n' "$OLLAMA_MODELS"
  elif [[ -d "$service" || -d "${service%/.ollama/models}" ]]; then
    # The service user's home is often closed to others (drwxr-x---): its
    # being there is enough, and the disk is read from the nearest parent.
    printf '%s\n' "$service"
  else
    printf '%s\n' "${HOME:-}/.ollama/models"
  fi
}

# Usage: ollama_disk_free_bytes <path>; prints the free bytes on the
# filesystem that holds path (or its nearest existing parent). Prints nothing
# if it cannot be read. OLLAMA_BUDGET_DISK_FREE_BYTES overrides.
# Returns: 0, also when the value cannot be read.
# Output: stdout the byte count, or nothing.
ollama_disk_free_bytes() {
  local path="${1:-.}" stated
  if stated="$(_ollama_ep_uint "${OLLAMA_BUDGET_DISK_FREE_BYTES:-}")"; then
    printf '%s\n' "$stated"
    return 0
  fi
  while [[ -n "$path" && "$path" != "/" && "$path" != "." && ! -e "$path" ]]; do
    path="$(dirname "$path")"
  done
  # "Available" is the field just before the one ending in "%". Counting
  # fields from the left fails when the filesystem's name contains a space.
  { df -Pk "${path:-/}" 2>/dev/null || true; } | awk '
    NR == 2 {
      for (i = NF; i > 1; i--) if ($i ~ /^[0-9]+%$/) {
        if ($(i - 1) ~ /^[0-9]+$/) printf "%.0f\n", $(i - 1) * 1024
        break
      }
    }'
}

# Usage: ollama_mem_total_bytes; prints the machine's memory in bytes, or
# nothing when it cannot be told. OLLAMA_BUDGET_MEM_TOTAL_BYTES overrides.
# Returns: 0, also when the value cannot be read.
# Output: stdout the byte count, or nothing.
ollama_mem_total_bytes() {
  local stated
  if stated="$(_ollama_ep_uint "${OLLAMA_BUDGET_MEM_TOTAL_BYTES:-}")"; then
    printf '%s\n' "$stated"
  elif [[ -r /proc/meminfo ]]; then
    awk '$1 == "MemTotal:" { printf "%.0f\n", $2 * 1024 }' /proc/meminfo || true
  elif command -v sysctl >/dev/null 2>&1; then
    { sysctl -n hw.memsize 2>/dev/null || true; } | awk '/^[0-9]+$/ { print }'
  fi
}

# Usage: ollama_mem_available_bytes; prints the memory a new process could
# have now, or nothing when it cannot be told.
# OLLAMA_BUDGET_MEM_AVAILABLE_BYTES overrides.
# Returns: 0, also when the value cannot be read.
# Output: stdout the byte count, or nothing.
ollama_mem_available_bytes() {
  local stated
  if stated="$(_ollama_ep_uint "${OLLAMA_BUDGET_MEM_AVAILABLE_BYTES:-}")"; then
    printf '%s\n' "$stated"
  elif [[ -r /proc/meminfo ]]; then
    awk '$1 == "MemAvailable:" { printf "%.0f\n", $2 * 1024 }' /proc/meminfo || true
  elif command -v vm_stat >/dev/null 2>&1; then
    # macOS: free and inactive pages can both be handed to a new process.
    { vm_stat 2>/dev/null || true; } | awk '
      /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) size = $i }
      /^Pages free:/ || /^Pages inactive:/ { gsub(/[^0-9]/, "", $NF); pages += $NF }
      END { if (size && pages) printf "%.0f\n", size * pages }'
  fi
}

# Usage: ollama_gpu_mem_bytes; prints the total memory of this machine's
# NVIDIA GPUs in bytes, or 0. The total, because Ollama spreads one model over
# several GPUs. OLLAMA_BUDGET_GPU_BYTES overrides. On Apple silicon the GPU
# shares the machine's memory, which ollama_mem_total_bytes already reports.
# Returns: 0.
# Output: stdout the byte count (0 with no NVIDIA GPU).
ollama_gpu_mem_bytes() {
  local stated
  if stated="$(_ollama_ep_uint "${OLLAMA_BUDGET_GPU_BYTES:-}")"; then
    printf '%s\n' "$stated"
    return 0
  fi
  # Bash arithmetic, not awk: with no tools at all this still says 0.
  local _oep_b _oep_sum=0
  while IFS= read -r _oep_b; do
    [[ -z "$_oep_b" ]] || _oep_sum=$((_oep_sum + _oep_b))
  done < <(_ollama_ep_gpu_list)
  printf '%s\n' "$_oep_sum"
}

# Which system this is: linux, macos or windows (Git Bash, MSYS2, Cygwin).
# _OLLAMA_EP_OS and _OLLAMA_EP_ARCH are test seams.
_ollama_ep_os() {
  case "${_OLLAMA_EP_OS:-$(uname -s 2>/dev/null)}" in
    Darwin|macos) echo macos ;;
    MINGW*|MSYS*|CYGWIN*|windows) echo windows ;;
    *) echo linux ;;
  esac
}

# Each discrete GPU's memory in bytes, one per line. A driver that does not
# answer counts as no GPU.
#   linux    NVIDIA from nvidia-smi; AMD from the amdgpu driver's sysfs file
#            (_OLLAMA_EP_DRM is a test seam for /sys/class/drm).
#   windows  every display adapter's dedicated memory from the registry
#            (HardwareInformation.qwMemorySize: NVIDIA, AMD and Intel, each once;
#            an older driver writes only the 32-bit HardwareInformation.MemorySize,
#            a number or 4 bytes, which is read instead).
#   macos    an Intel Mac's discrete card from system_profiler. Apple silicon
#            has none here: its GPU uses the machine's memory, counted already.
_ollama_ep_gpu_list() {
  local _oep_card _oep_bytes _oep_line
  case "$(_ollama_ep_os)" in
    windows)
      if command -v powershell.exe >/dev/null 2>&1; then
        { powershell.exe -NoProfile -NonInteractive -Command \
            "Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}\\0*' -ErrorAction SilentlyContinue | ForEach-Object { \$q = \$_.'HardwareInformation.qwMemorySize'; \$m = \$_.'HardwareInformation.MemorySize'; if (\$q) { \$q } elseif (\$m -is [byte[]]) { [BitConverter]::ToUInt32(\$m, 0) } elseif (\$m) { \$m } }" \
            2>/dev/null || true; } | tr -d '\r' | while IFS= read -r _oep_line; do
          _oep_bytes="$(_ollama_ep_uint "$_oep_line")" || continue
          [[ "$_oep_bytes" -gt 0 ]] && printf '%s\n' "$_oep_bytes"
        done
      fi
      return 0
      ;;
    macos)
      if command -v system_profiler >/dev/null 2>&1; then
        # "VRAM (Total): 8 GB" or "VRAM (Dynamic, Max): 1536 MB"; Apple silicon prints none.
        { system_profiler SPDisplaysDataType 2>/dev/null || true; } | while IFS= read -r _oep_line; do
          case "$_oep_line" in *VRAM*:*) ;; *) continue ;; esac
          _oep_line="${_oep_line##*:}"
          read -r _oep_bytes _oep_card <<<"$_oep_line"
          _oep_bytes="$(_ollama_ep_uint "$_oep_bytes")" || continue
          case "$_oep_card" in GB) printf '%s\n' "$((_oep_bytes * 1073741824))" ;; MB) printf '%s\n' "$((_oep_bytes * 1048576))" ;; esac
        done
      fi
      return 0
      ;;
  esac
  if command -v nvidia-smi >/dev/null 2>&1; then
    local _oep_mib
    while IFS= read -r _oep_mib; do
      _oep_mib="$(_ollama_ep_uint "${_oep_mib%%[!0-9]*}")" || continue
      printf '%s\n' "$((_oep_mib * 1048576))"
    done < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || true)
  fi
  for _oep_card in "${_OLLAMA_EP_DRM:-/sys/class/drm}"/card*; do
    # card0, not card0-DP-1: a connector is not a GPU.
    case "${_oep_card##*/}" in card*[!0-9]*|card) continue ;; esac
    [[ -r "$_oep_card/device/mem_info_vram_total" ]] || continue
    _oep_bytes="$(_ollama_ep_uint "$(cat "$_oep_card/device/mem_info_vram_total" 2>/dev/null)")" || continue
    printf '%s\n' "$_oep_bytes"
  done
}

# Usage: ollama_gpu_mem_largest_bytes; prints the memory of the largest single
# GPU in bytes, 0 when there is none. A model runs on one GPU, so this, not the
# sum, says which models a machine can run (two 12 GB cards are not a 24 GB
# card). OLLAMA_BUDGET_GPU_LARGEST_BYTES states it instead of measuring.
#
# Apple silicon shares the machine's memory with its GPU, and macOS lets the GPU
# use about two thirds of it: that share is its GPU for picking a class, so a
# 64 GB Mac can run what a 24 GB card can. (The budget check, which adds GPU
# memory to the machine's, does not count it a second time: ollama_gpu_mem_bytes
# stays 0 there.)
# Returns: 0.
# Output: stdout the byte count (0 with no GPU).
ollama_gpu_mem_largest_bytes() {
  local stated
  if stated="$(_ollama_ep_uint "${OLLAMA_BUDGET_GPU_LARGEST_BYTES:-}")"; then
    printf '%s\n' "$stated"
    return 0
  fi
  # hw.optional.arm64, not uname -m: a shell under Rosetta reports x86_64.
  if [[ "$(_ollama_ep_os)" == macos ]] && \
     [[ "${_OLLAMA_EP_ARCH:-$(sysctl -n hw.optional.arm64 2>/dev/null | sed 's/^1$/arm64/')}" == arm64 ]]; then
    stated="$(ollama_mem_total_bytes 2>/dev/null)" || stated=""
    if stated="$(_ollama_ep_uint "$stated")"; then
      printf '%s\n' "$((stated * 2 / 3))"
      return 0
    fi
  fi
  local _oep_b _oep_max=0
  while IFS= read -r _oep_b; do
    [[ -z "$_oep_b" || "$_oep_b" -le "$_oep_max" ]] || _oep_max="$_oep_b"
  done < <(_ollama_ep_gpu_list)
  printf '%s\n' "$_oep_max"
}

# --- which model this machine gets -------------------------------------------
#
# A models file may name a model per class of machine besides the default
# (fleet model registry, ADR-0058 in R-765):
#
#   NAME_XLARGE + NAME_XLARGE_VRAM_GB   its largest GPU has at least that much
#   NAME_LARGE  + NAME_LARGE_VRAM_GB    its largest GPU has at least that much,
#                 or AI_TIER_LARGE_RAM_GB  or the machine has that much memory
#   NAME_SMALL  + AI_TIER_SMALL_RAM_GB  the machine has less than that, in
#                                       memory and in GPU memory both
#
# Figures are whole GiB as the machine reports them (rounded down): a "32 GB"
# machine reports 31, so the registry's floors are one below the nominal size.

# The classes, from the lowest. A cap (the fallback) and AI_MODEL_TIER are one
# of these; "standard" is the default column, NAME itself.
_ollama_ep_tier_rank() {
  case "${1:-}" in small) echo 0 ;; standard) echo 1 ;; large) echo 2 ;; xlarge) echo 3 ;; *) return 1 ;; esac
}
_ollama_ep_gib() { echo $(( ${1:-0} / 1073741824 )); }

# Usage: _ollama_ep_class_rank <mem> <gpu> <small_below_ram> <large_ram>
# <large_vram> <xlarge_vram>; the one rule both pickers use (ollama_model_for_class
# with a models file's numbers, ollama_host_tier with the tiers file's). All
# whole GiB; an empty threshold never matches; empty memory is standard.
# Returns: 0.
# Output: stdout the rank (0 small .. 3 xlarge).
_ollama_ep_class_rank() {
  local mem="${1:-}" gpu="${2:-0}" small="${3:-}" lram="${4:-}" lvram="${5:-}" xvram="${6:-}"
  if [[ -z "$mem" ]]; then
    echo 1
  elif [[ -n "$xvram" && "$gpu" -ge "$xvram" ]]; then
    echo 3
  elif [[ -n "$lvram" && "$gpu" -ge "$lvram" ]] || [[ -n "$lram" && "$mem" -ge "$lram" ]]; then
    echo 2
  elif [[ -n "$small" && "$mem" -lt "$small" && "$gpu" -lt "$small" ]]; then
    # A small machine with a good GPU is not a small machine.
    echo 0
  else
    echo 1
  fi
}

# A value from the models file, or nothing (no file, no such name).
_ollama_ep_file_val() { [[ -n "${1:-}" ]] || return 0; ollama_models_file_get "$1" "$2" 2>/dev/null || true; }

# Usage: ollama_machine_figures; prints "<memory GiB>:<largest GPU GiB>", the
# two numbers the class is picked by. Memory is empty when it cannot be read
# (":0"); the colon keeps that field when the line is split.
# Returns: 0.
# Output: stdout "<mem GiB>:<gpu GiB>".
ollama_machine_figures() {
  local _oep_mem _oep_gpu
  _oep_mem="$(ollama_mem_total_bytes 2>/dev/null)" || _oep_mem=""
  _oep_gpu="$(ollama_gpu_mem_largest_bytes 2>/dev/null)" || _oep_gpu=0
  [[ -z "$_oep_mem" ]] || _oep_mem="$(_ollama_ep_gib "$_oep_mem")"
  printf '%s:%s\n' "$_oep_mem" "$(_ollama_ep_gib "${_oep_gpu:-0}")"
}

# Usage: ollama_model_for_class <models_file> NAME; prints the model this
# machine gets for NAME: the highest class column it qualifies for that names a
# model, else NAME. A non-blank NAME in the environment (from .env) wins, as
# everywhere in this module. AI_MODEL_TIER=small|standard|large|xlarge names the
# class instead of measuring; a class with no model for NAME falls to the next
# one below it (small: to the default). _OLLAMA_EP_TIER_CAP (set by
# ollama_project_ensure_models when a model does not fit) limits the class.
# Memory that cannot be read picks the default column, never a guessed class.
# Returns 2 for a NAME that is not a variable name or an AI_MODEL_TIER that is
# not a class; prints nothing when neither NAME nor a column has a value.
# Returns: 0 printed (or nothing to print); 2 bad NAME or AI_MODEL_TIER.
# Output: stdout the model; stderr errors.
ollama_model_for_class() {
  local _oep_file="${1:-}" _oep_name="${2:-}" _oep_value _oep_tier _oep_cap _oep_mem _oep_gpu
  local _oep_def _oep_small _oep_large _oep_xlarge _oep_large_vram _oep_xlarge_vram _oep_small_ram _oep_large_ram
  if ! _ollama_ep_is_name "$_oep_name"; then
    print_error "Not a variable name: $(_ollama_ep_said "$_oep_name")" >&2
    return 2
  fi
  _oep_value="$(printf '%s' "${!_oep_name:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" || true
  if [[ -n "$_oep_value" ]]; then
    printf '%s\n' "$_oep_value"
    return 0
  fi
  _oep_def="$(_ollama_ep_file_val "$_oep_file" "$_oep_name")"
  _oep_small="$(_ollama_ep_file_val "$_oep_file" "${_oep_name}_SMALL")"
  _oep_large="$(_ollama_ep_file_val "$_oep_file" "${_oep_name}_LARGE")"
  _oep_xlarge="$(_ollama_ep_file_val "$_oep_file" "${_oep_name}_XLARGE")"
  _oep_large_vram="$(_ollama_ep_uint "$(_ollama_ep_file_val "$_oep_file" "${_oep_name}_LARGE_VRAM_GB")")" || _oep_large_vram=""
  _oep_xlarge_vram="$(_ollama_ep_uint "$(_ollama_ep_file_val "$_oep_file" "${_oep_name}_XLARGE_VRAM_GB")")" || _oep_xlarge_vram=""
  _oep_small_ram="$(_ollama_ep_uint "$(_ollama_ep_file_val "$_oep_file" AI_TIER_SMALL_RAM_GB)")" || _oep_small_ram=""
  _oep_large_ram="$(_ollama_ep_uint "$(_ollama_ep_file_val "$_oep_file" AI_TIER_LARGE_RAM_GB)")" || _oep_large_ram=""

  _oep_cap="$(_ollama_ep_tier_rank "${_OLLAMA_EP_TIER_CAP:-xlarge}")" || _oep_cap=3
  _oep_tier="$(printf '%s' "${AI_MODEL_TIER:-}" | tr 'A-Z' 'a-z' | tr -d ' \t\r')" || true
  if [[ -n "$_oep_tier" ]]; then
    if ! _oep_tier="$(_ollama_ep_tier_rank "$_oep_tier")"; then
      print_error "AI_MODEL_TIER is one of small, standard, large, xlarge; not $(_ollama_ep_said "${AI_MODEL_TIER:-}")" >&2
      return 2
    fi
  else
    IFS=: read -r _oep_mem _oep_gpu <<<"$(ollama_machine_figures)"
    # A class whose column names no model cannot be reached by measuring.
    [[ -n "$_oep_xlarge" ]] || _oep_xlarge_vram=""
    [[ -n "$_oep_large" ]] || { _oep_large_vram=""; _oep_large_ram=""; }
    _oep_tier="$(_ollama_ep_class_rank "$_oep_mem" "$_oep_gpu" "$_oep_small_ram" "$_oep_large_ram" "$_oep_large_vram" "$_oep_xlarge_vram")"
  fi
  [[ "$_oep_tier" -le "$_oep_cap" ]] || _oep_tier="$_oep_cap"
  # The class's column, or the next one below it that names a model.
  [[ "$_oep_tier" -ne 3 || -n "$_oep_xlarge" ]] || _oep_tier=2
  [[ "$_oep_tier" -ne 2 || -n "$_oep_large" ]] || _oep_tier=1
  case "$_oep_tier" in
    3) _oep_value="$_oep_xlarge" ;;
    2) _oep_value="$_oep_large" ;;
    0) _oep_value="${_oep_small:-$_oep_def}" ;;
    *) _oep_value="$_oep_def" ;;
  esac
  [[ -z "$_oep_value" ]] || printf '%s\n' "$_oep_value"
  return 0
}

# Usage: ollama_budget_check <pull_bytes> <largest_model_bytes> <models_dir>
#
# Checks that the machine can download pull_bytes into models_dir and then
# load a model of largest_model_bytes. Prints what does not fit, with the
# numbers, on stderr.
#
# Returns 0 if it fits, 1 if the disk is too small, 2 if memory is too small,
# 3 if both are. Returns 4 if a size is not a whole number: then nothing was
# checked, also with OLLAMA_IGNORE_BUDGET set.
#
# - Disk: after the download, at least OLLAMA_DISK_RESERVE_GB (default 10)
#   must stay free.
# - Memory: the largest model plus OLLAMA_MEM_HEADROOM_PERCENT (default 20)
#   must fit in the machine's memory plus its GPUs' memory, because Ollama
#   splits a model between the two. If it does not fit, that is a refusal.
#   If it fits the machine but not the memory free right now, that is only a
#   warning: free memory changes from minute to minute.
# - A number that cannot be read (no df, no /proc/meminfo) is reported and
#   skipped, never guessed.
# - OLLAMA_IGNORE_BUDGET=1 turns each refusal into a warning and returns 0.
#
# The numbers are this machine's. For an Ollama on another machine, set all
# four OLLAMA_BUDGET_* variables.
# Output: stderr what does not fit, and warnings; stdout nothing.
# Returns: 0 fits (or OLLAMA_IGNORE_BUDGET=1); 1 disk; 2 memory; 3 both; 4 a size is not a whole number.
ollama_budget_check() {
  local dir="${3:-.}" pull largest reserve_gb headroom
  local free total available gpu need reserve after capacity
  local disk_short=0 mem_short=0 say=print_error shown_dir ignore=0
  # A size that is not a number is the caller's mistake. Reading it as zero
  # would approve a download that was never measured. No argument means zero.
  if ! pull="$(_ollama_ep_uint "${1:-0}")" || ! largest="$(_ollama_ep_uint "${2:-0}")"; then
    print_error "ollama_budget_check: a size in bytes is a whole number of at most 15 digits; got '$(_ollama_ep_said "${1:-}")' and '$(_ollama_ep_said "${2:-}")'." >&2
    return 4
  fi
  reserve_gb="$(_ollama_ep_uint "${OLLAMA_DISK_RESERVE_GB:-10}")" || reserve_gb=10
  headroom="$(_ollama_ep_uint "${OLLAMA_MEM_HEADROOM_PERCENT:-20}")" || headroom=20
  # A reserve or headroom larger than any machine is a typo: use the default.
  [[ "$reserve_gb" -le 100000 ]] || reserve_gb=10
  [[ "$headroom" -le 1000 ]] || headroom=20
  if _ollama_ep_on OLLAMA_IGNORE_BUDGET off; then ignore=1; say=print_warning; fi
  # The directory name comes from the caller: make it safe to print.
  shown_dir="$(_ollama_ep_said "$dir")"

  if [[ "$pull" -gt 0 ]]; then
    free="$(_ollama_ep_uint "$(ollama_disk_free_bytes "$dir")")" || free=""
    if [[ -n "$free" ]]; then
      reserve=$((reserve_gb * 1000000000))
      after=$((free - pull))
      if [[ "$after" -lt "$reserve" ]]; then
        disk_short=1
        "$say" "Not enough disk for the models: the download is $(_ollama_ep_gb "$pull"), $(_ollama_ep_gb "$free") is free at ${shown_dir}, and ${reserve_gb} GB must stay free (OLLAMA_DISK_RESERVE_GB)." >&2
      fi
    else
      print_warning "Free disk space at ${shown_dir} could not be read; the download of $(_ollama_ep_gb "$pull") was not checked against it." >&2
    fi
  fi

  if [[ "$largest" -gt 0 ]]; then
    need=$((largest * (100 + headroom) / 100))
    total="$(_ollama_ep_uint "$(ollama_mem_total_bytes)")" || total=0
    gpu="$(_ollama_ep_uint "$(ollama_gpu_mem_bytes)")" || gpu=0
    capacity=$((total + gpu))
    if [[ "$need" -le "$gpu" ]]; then
      : # The GPUs hold it, whatever the rest of the machine is.
    elif [[ "$total" -eq 0 ]]; then
      print_warning "This machine's memory could not be read; the largest model ($(_ollama_ep_gb "$largest")) was not checked against it." >&2
    elif [[ "$need" -gt "$capacity" ]]; then
      mem_short=1
      "$say" "Not enough memory for the largest model: it needs about $(_ollama_ep_gb "$need") to load, and this machine has $(_ollama_ep_gb "$total") of memory and $(_ollama_ep_gb "$gpu") on its GPUs." >&2
    else
      available="$(_ollama_ep_uint "$(ollama_mem_available_bytes)")" || available=""
      if [[ -n "$available" && "$need" -gt $((available + gpu)) ]]; then
        print_warning "The largest model needs about $(_ollama_ep_gb "$need") to load and $(_ollama_ep_gb "$available") of memory is available right now. It fits this machine, but not beside what is running." >&2
      fi
    fi
  fi

  [[ "$ignore" -eq 0 ]] || return 0
  return $((disk_short + 2 * mem_short))
}

# --- pulling what is missing, when it fits -----------------------------------

# Usage: ollama_endpoint_pull <base_url> <model>; asks that Ollama to pull the
# model and waits until it is done. It uses the HTTP API, so it works the same
# for an Ollama on this machine and one in a container, without the CLI.
#
# There is no time limit for the whole download: a large model on a slow line
# takes hours. The pull is given up only if nothing at all arrives for
# OLLAMA_PULL_STALL_SECONDS (default 600).
# Progress is printed on stderr, one line for each 10% of every layer of
# 100 MB or more, so a long download does not look like a hang.
# Returns 1 if the pull did not end in success, and prints the last thing
# Ollama said on stderr.
# Returns: 0 pulled; 1 the pull did not end in success.
# Output: stderr progress lines and the last error; stdout nothing.
ollama_endpoint_pull() {
  local url="${1:-}" model="${2:-}" verdict stall
  url="${url%/}"
  if [[ -z "$url" ]] || ! _ollama_ep_is_model "$model"; then
    print_error "Not a model reference: $(_ollama_ep_shown "$model")" >&2
    return 1
  fi
  stall="$(_ollama_ep_uint "${OLLAMA_PULL_STALL_SECONDS:-600}")" || stall=600
  # The answer is a stream: one JSON object per line, and the last line says
  # how it ended.
  # - An "error" anywhere in the stream is a failure, whatever the HTTP status.
  # - curl's own error message goes into the same stream (2>&1) and becomes the
  #   last line, so a broken transfer is not a success either.
  # - The stream is read line by line and not stored: hours of progress lines
  #   are many megabytes.
  # - The model is sent under two keys: "model" is the API's name for it, and
  #   "name" is what an older Ollama reads.
  verdict="$(curl -sS -N --speed-limit 1 --speed-time "$stall" -H 'Content-Type: application/json' \
    -d "{\"model\": \"${model}\", \"name\": \"${model}\", \"stream\": true}" "${url}/api/pull" 2>&1 \
    | awk -v model="$model" '
      function field(key,   text) {
        if (!match($0, "\"" key "\"[ \t]*:[ \t]*[0-9]+")) return -1
        text = substr($0, RSTART, RLENGTH); sub(/^.*:[ \t]*/, "", text)
        return text + 0
      }
      {
        sub(/\r$/, "")
        if ($0 == "") next
        last = $0
        if ($0 ~ /"error"[ \t]*:/) failed = 1
        total = field("total"); done = field("completed")
        if (total < 100000000 || done < 0) next
        layer = match($0, /"digest"[ \t]*:[ \t]*"[^"]*"/) ? substr($0, RSTART, RLENGTH) : "-"
        size[layer] = total
        tenth = int(done * 10 / total)
        if (!(layer in said)) {
          # First time a layer is seen: print nothing if it has not started
          # (0%) or Ollama already has all of it (100%).
          said[layer] = tenth
          if (tenth == 0 || tenth >= 10) next
        } else if (tenth <= said[layer]) next
        said[layer] = tenth
        # Printed through `cat 1>&2`, which keeps stderr as it is. Some awks
        # open /dev/stderr as a new file, which would overwrite the start of a
        # log the caller is writing to.
        # (No apostrophe may appear in this awk program: it would end the
        # shell string around it.)
        printf "  %s: %d%% of %.1f GB\n", model, tenth * 10, total / 1000000000 | "cat 1>&2"
        fflush("cat 1>&2")
      }
      END {
        if (!failed && last ~ /^[ \t]*[{][ \t]*"status"[ \t]*:[ \t]*"success"/) {
          # Ollama goes from the last progress line to verifying without ever
          # saying completed == total (measured: a real pull stopped at 90%).
          # A layer that was being counted is said to be done once the pull is.
          for (layer in said) if (said[layer] < 10) {
            printf "  %s: 100%% of %.1f GB\n", model, size[layer] / 1000000000 | "cat 1>&2"
          }
          print "ok"
        } else print "no:" last
      }')" || true
  [[ "$verdict" != "ok" ]] || return 0
  # curl prints the URL it could not reach, credentials included. Replace
  # the whole URL before the text is cut to length, so no part of it is left.
  verdict="${verdict#no:}"
  verdict="${verdict//"$url"/$(_ollama_ep_shown_url "$url")}"
  # A proxy that echoes the request path ("Cannot POST /key/ollama/api/pull")
  # would print the path, and a key in it, through the server's own words.
  local path="${url#*://}"
  if [[ "$path" == */* ]]; then path="/${path#*/}"; verdict="${verdict//"$path"/}"; fi
  verdict="$(_ollama_ep_said "$verdict")"
  print_error "The Ollama at $(_ollama_ep_shown_url "$url") did not pull ${model}: ${verdict:-no answer}" >&2
  return 1
}

# Usage: ollama_endpoint_ensure_models <base_url> <models_dir> <model>...
#
# Makes sure that Ollama has every model listed. Missing models are pulled
# only if the machine has room for all of them: nothing is pulled unless
# everything fits. A start with half its models is worse than a clear "no".
#
# models_dir is where that Ollama stores its models, for the disk check: a
# directory on this machine, or Docker's data root for an Ollama in a
# container.
#
# Returns:
#   0  every model is there (already, or after pulling)
#   1  the disk cannot take the download        (see ollama_budget_check)
#   2  memory cannot take the largest model
#   3  neither can
#   4  nothing answers at base_url as an Ollama
#   5  models are missing and OLLAMA_PULL_MISSING=0 says not to pull, or
#      OLLAMA_PULL_MISSING=ask and the answer was not yes, or there was no
#      terminal to ask on
#   6  a pull failed
#   7  the budget could not be checked: a missing model's size, or the free
#      disk space, could not be learned
#   8  an argument is not a model reference
#
# Env: OLLAMA_PULL_MISSING (on, off or ask; default on), OLLAMA_IGNORE_BUDGET, and everything
# ollama_budget_check, ollama_registry_size_bytes and ollama_endpoint_pull read.
# Output: stderr progress, refusals and pull progress; stdout nothing.
ollama_endpoint_ensure_models() {
  local url="${1:-}" dir="${2:-.}" present needed missing model size shown
  local pull_bytes=0 largest=0 unknown="" unsized="" nowhere="" status=0 ignore=0 asked
  local pull_mode listing=""
  url="${url%/}"
  # If the directory is left out, there are no models either: the only
  # argument left is the URL, and it must not be read as a model.
  if [[ $# -ge 2 ]]; then shift 2; else shift $#; fi
  shown="$(_ollama_ep_shown_url "$url")"
  needed=""
  for model in "$@"; do
    model="$(ollama_model_tagged "$model")"
    [[ -n "$model" ]] || continue
    if ! _ollama_ep_is_model "$model"; then
      print_error "Not a model reference: $(_ollama_ep_shown "$model")" >&2
      return 8
    fi
    grep -qixF -- "$model" <<<"$needed" || needed="${needed}${needed:+$'\n'}${model}"
  done
  [[ -n "$needed" ]] || return 0

  if ! present="$(ollama_endpoint_models "$url")"; then
    print_error "No Ollama answers at ${shown}." >&2
    return 4
  fi
  missing="$(ollama_models_missing "$needed" "$present")"
  [[ -n "$missing" ]] || return 0

  pull_mode="$(_ollama_ep_pull_mode)"
  if [[ "$pull_mode" == "off" ]]; then
    print_error "The Ollama at ${shown} lacks: ${missing//$'\n'/ }. Pulling is off (OLLAMA_PULL_MISSING)." >&2
    return 5
  fi
  # Read once here, and passed on as 1 or 0, so a typo is reported once.
  if _ollama_ep_on OLLAMA_IGNORE_BUDGET off; then ignore=1; fi

  # Get the size of every needed model. The missing ones add up to the
  # download. The largest of all of them must fit in memory.
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    asked=0
    size="$(ollama_registry_size_bytes "$model")" || asked=$?
    [[ "$asked" -eq 0 ]] || size=""
    if size="$(_ollama_ep_uint "$size")"; then
      [[ "$size" -le "$largest" ]] || largest="$size"
      if grep -qxF -- "$model" <<<"$missing"; then
        pull_bytes=$((pull_bytes + size))
        listing="${listing}  ${model}  $(_ollama_ep_gb "$size")"$'\n'
      fi
    elif grep -qxF -- "$model" <<<"$missing"; then
      unknown="${unknown}${model} "
      listing="${listing}  ${model}  size unknown"$'\n'
      [[ "$asked" -ne 3 ]] || nowhere="${nowhere}${model} "
    else
      unsized="${unsized}${model} "
    fi
  done <<<"$needed"

  if [[ -n "$unsized" ]]; then
    # Already present, so no download. But it may be the largest model.
    print_warning "The size of ${unsized}could not be learned from the registry; memory was not checked for it." >&2
  fi
  if [[ -n "$nowhere" && "$ignore" -eq 0 ]]; then
    # Said apart from "could not be learned": waiting or pulling by hand does
    # not help with a name that is wrong.
    # "Or none it shows": the registry answers the same for a model that is
    # private, when asked without signing in.
    print_error "The registry has no model named ${nowhere% }, or none it shows without signing in: check the name and its tag. Nothing was pulled." >&2
    return 7
  fi
  if [[ -n "$unknown" ]]; then
    if [[ "$ignore" -eq 1 ]]; then
      print_warning "The size of ${unknown}could not be learned from the registry; pulling without a disk or memory check (OLLAMA_IGNORE_BUDGET=1)." >&2
    else
      print_error "The size of ${unknown}could not be learned from the registry, so nothing says whether it fits. Pull it by hand, or set OLLAMA_IGNORE_BUDGET=1 to pull unchecked." >&2
      return 7
    fi
  fi
  if [[ "$pull_bytes" -gt 0 && "$ignore" -eq 0 ]]; then
    if ! _ollama_ep_uint "$(ollama_disk_free_bytes "$dir")" >/dev/null; then
      # Unknown free space is as bad as unknown size: refuse.
      print_error "Free disk space at $(_ollama_ep_said "$dir") could not be read, so nothing says whether $(_ollama_ep_gb "$pull_bytes") fits. State it with OLLAMA_BUDGET_DISK_FREE_BYTES, or set OLLAMA_IGNORE_BUDGET=1 to pull unchecked." >&2
      return 7
    fi
  fi

  OLLAMA_IGNORE_BUDGET="$ignore" ollama_budget_check "$pull_bytes" "$largest" "$dir" || status=$?
  if [[ "$status" -ne 0 ]]; then
    print_error "Nothing was pulled. Missing: ${missing//$'\n'/ }" >&2
    return "$status"
  fi

  # Asked only now: a question about a download that would not fit is no
  # question, and the sizes are known for the listing.
  if [[ "$pull_mode" == "ask" ]]; then
    if ! _ollama_ep_can_ask; then
      # A total is only said when every size is known (OLLAMA_IGNORE_BUDGET
      # lets an unknown one through), or it would understate the download.
      local total=""
      [[ -n "$unknown" ]] || total=" ($(_ollama_ep_gb "$pull_bytes") to download)"
      print_error "The Ollama at ${shown} lacks: ${missing//$'\n'/ }${total}. OLLAMA_PULL_MISSING=ask and there is no terminal to ask on, so nothing was pulled. Run this again from a terminal. $(_ollama_ep_pull_hint "$url" "$missing")" >&2
      return 5
    fi
    if ! _ollama_ep_ask_pull "$shown" "${listing%$'\n'}"; then
      print_error "Nothing was pulled. Missing: ${missing//$'\n'/ }. $(_ollama_ep_pull_hint "$url" "$missing")" >&2
      return 5
    fi
  fi

  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    print_info "Pulling ${model} into the Ollama at ${shown}" >&2
    ollama_endpoint_pull "$url" "$model" || return 6
  done <<<"$missing"
  return 0
}

# --- a project's own configuration -------------------------------------------
#
# Projects name the address of their Ollama in different ways: OLLAMA_URL,
# OLLAMA_BASE_URL, OLLAMA_HOST holding a URL, a name with the project's prefix.
# Some put the API path in it, and a project whose backend is in a container
# writes host.docker.internal or the compose service's name. Many keep the
# value in a .env that their start script never sources. The functions below
# turn that into what the rest of this module takes.
#
# Their own variables start with _oep_: a caller's NAME (an address variable
# called "url", a model variable called "name") is read through ${!NAME}, and
# a local of the same name would be read in its place.

# Usage: ollama_endpoint_base_url <address>; prints the base URL of the Ollama
# at an address as a project configures it:
# - "host", "host:port" or ":port" gets http://, and port 11434 when none is
#   given, as Ollama reads OLLAMA_HOST. No host is this machine (127.0.0.1),
#   and an IPv6 address without brackets gets them;
# - a URL keeps its scheme and port (none given stays none: 80 or 443, for an
#   Ollama behind a proxy), its credentials and any path a proxy serves it under;
# - the API path some projects store with it is removed when it ends the URL
#   (/api, /v1, /api/generate, /api/chat, /v1/chat/completions and the other
#   endpoints of the two APIs), with a query, a fragment and a trailing slash.
#   "/api/ollama" is a proxy's path and stays.
# Returns 1, printing nothing, for what is not an address: empty, another
# scheme, a space or a control character in it, a port that is not a number, a
# host with a character no host has, or an "@" after the first "/", "?" or
# "#". That last one is a password with such a character in it: it has to be
# percent-encoded, curl refuses the URL, and read by halves it would be
# printed.
# Returns: 0 printed; 1 not an address.
# Output: stdout the base URL.
ollama_endpoint_base_url() {
  local LC_ALL=C
  local _oep_value="${1:-}" _oep_scheme _oep_rest _oep_authority _oep_path="" _oep_hostport _oep_user="" _oep_host _oep_port=""
  _oep_value="$(printf '%s' "$_oep_value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" || true
  [[ -n "$_oep_value" ]] || return 1
  [[ "$_oep_value" != *[[:space:][:cntrl:]]* ]] || return 1
  case "$_oep_value" in
    [Hh][Tt][Tt][Pp]://*) _oep_scheme="http"; _oep_rest="${_oep_value#*://}" ;;
    [Hh][Tt][Tt][Pp][Ss]://*) _oep_scheme="https"; _oep_rest="${_oep_value#*://}" ;;
    *://*) return 1 ;;
    # "http:" and "http:/host": a URL that lost its slashes, not a host called http.
    [Hh][Tt][Tt][Pp]:*|[Hh][Tt][Tt][Pp][Ss]:*) return 1 ;;
    *) _oep_scheme=""; _oep_rest="$_oep_value" ;;
  esac
  case "$_oep_rest" in *[/?#]*@*) return 1 ;; esac
  _oep_rest="${_oep_rest%%[?#]*}"
  _oep_authority="${_oep_rest%%/*}"
  [[ "$_oep_rest" != */* ]] || _oep_path="/${_oep_rest#*/}"
  _oep_hostport="$_oep_authority"
  if [[ "$_oep_authority" == *@* ]]; then
    _oep_user="${_oep_authority%@*}@"
    _oep_hostport="${_oep_authority##*@}"
  fi
  case "$_oep_hostport" in
    \[*\]:*) _oep_host="${_oep_hostport%%\]*}]"; _oep_port="${_oep_hostport##*\]:}" ;;
    \[*\]) _oep_host="$_oep_hostport" ;;
    \[*|*\]*) return 1 ;;
    *:*:*) _oep_host="[${_oep_hostport}]" ;;
    *:*) _oep_host="${_oep_hostport%%:*}"; _oep_port="${_oep_hostport##*:}" ;;
    *) _oep_host="$_oep_hostport" ;;
  esac
  [[ -z "$_oep_port" || ( "$_oep_port" =~ ^[0-9]+$ && "${#_oep_port}" -le 5 && "$_oep_port" -ge 1 && "$_oep_port" -le 65535 ) ]] || return 1
  if [[ -z "$_oep_host" ]]; then
    # ":11434" and "http://:11434": the port of this machine, as Ollama reads it.
    [[ -n "$_oep_port" ]] || return 1
    _oep_host="127.0.0.1"
  fi
  case "$_oep_host" in
    \[*\]) [[ "$_oep_host" =~ ^\[[0-9A-Fa-f:.]+(%[A-Za-z0-9._-]+)?\]$ ]] || return 1 ;;
    *) [[ "$_oep_host" =~ ^[A-Za-z0-9._-]+$ ]] || return 1 ;;
  esac
  if [[ -z "$_oep_scheme" ]]; then
    _oep_scheme="http"
    [[ -n "$_oep_port" ]] || _oep_port="11434"
  fi
  # The API path is not part of the base, when it is what the URL ends with.
  # An API path is removed however it was written: /v1, /api/v1, /api/v1/chat/completions.
  local _oep_before=""
  while [[ "$_oep_path" != "$_oep_before" ]]; do
    _oep_before="$_oep_path"
    _oep_path="$(printf '%s' "$_oep_path" | sed -E 's#/+$##; s#/(api(/(generate|chat|tags|embed|embeddings|pull|push|show|version|ps|create|copy|delete))?|v1(/(chat/completions|completions|embeddings|models))?)$##; s#/+$##')" || true
  done
  printf '%s://%s%s%s%s\n' "$_oep_scheme" "$_oep_user" "$_oep_host" "${_oep_port:+:$_oep_port}" "$_oep_path"
}

# Usage: _ollama_ep_host <url>; prints the host of a URL, in lower case,
# without credentials, port, brackets or a trailing dot. The path is cut
# first: an "@" in it is not the end of credentials.
_ollama_ep_host() {
  local _oep_rest="${1:-}"
  _oep_rest="${_oep_rest#*://}"
  _oep_rest="${_oep_rest%%[/?#]*}"
  _oep_rest="${_oep_rest##*@}"
  case "$_oep_rest" in
    \[*) _oep_rest="${_oep_rest#\[}"; _oep_rest="${_oep_rest%%\]*}" ;;
    *) _oep_rest="${_oep_rest%%:*}" ;;
  esac
  _oep_rest="${_oep_rest%.}"
  printf '%s\n' "$_oep_rest" | tr 'A-Z' 'a-z'
}

# True inside a container (Docker writes /.dockerenv).
# Docker and Podman leave a marker file; Kubernetes sets a variable in every
# pod. _OLLAMA_EP_DOCKERENV is a test seam: when set, it alone decides.
_ollama_ep_in_container() {
  if [[ -n "${_OLLAMA_EP_DOCKERENV:-}" ]]; then [[ -e "$_OLLAMA_EP_DOCKERENV" ]]; return; fi
  [[ -e /.dockerenv || -e /run/.containerenv || -n "${KUBERNETES_SERVICE_HOST:-}" ]]
}

# Usage: ollama_endpoint_is_local <url>; returns 0 when the URL points at this
# machine, so that this machine's disk and memory are the ones a pull would
# use: a loopback name or address, 0.0.0.0, this host's name, one of its own
# addresses, and Docker's names for the host (host.docker.internal,
# gateway.docker.internal) when this is not a container itself. Inside one,
# those names are another machine: the host, with a disk this shell cannot see.
# Returns 1 for anything else, a name that only resolves to this machine
# included: read as another machine, nothing is pulled into it unasked, which
# is the safe way to be wrong.
# Output: none.
# Returns: 0 this machine; 1 anything else.
ollama_endpoint_is_local() {
  local LC_ALL=C
  local _oep_host _oep_own
  _oep_host="$(_ollama_ep_host "${1:-}")"
  [[ -n "$_oep_host" ]] || return 1
  case "$_oep_host" in
    localhost|*.localhost|::1|0.0.0.0|::) return 0 ;;
    host.docker.internal|gateway.docker.internal)
      if _ollama_ep_in_container; then return 1; fi
      return 0
      ;;
  esac
  # Loopback as an address, also written as IPv4 inside IPv6.
  [[ ! "$_oep_host" =~ ^(::ffff:)?127\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  [[ ! "$_oep_host" =~ ^::ffff:7f[0-9a-f]{2}:[0-9a-f]{1,4}$ ]] || return 0
  _oep_own="$(hostname 2>/dev/null | tr 'A-Z' 'a-z')" || _oep_own=""
  if [[ -n "$_oep_own" ]] && [[ "$_oep_host" == "$_oep_own" || "$_oep_host" == "${_oep_own%%.*}" ]]; then
    return 0
  fi
  # This machine's own addresses, from every tool there is. Collected first
  # and searched after: `grep -q` leaves a pipeline early, and under pipefail
  # the tools it cut off would make a found address read as not found.
  _oep_own="$({
    ip -o addr 2>/dev/null | awk '{ print $4 }' || true
    ifconfig 2>/dev/null | awk '$1 == "inet" || $1 == "inet6" { print $2 }' || true
  } | sed -E 's#/.*$##; s#%.*$##; s#^addr:##' | tr 'A-Z' 'a-z')" || true
  grep -qxF -- "$_oep_host" <<<"$_oep_own"
}

# Usage: _ollama_ep_probe_image; prints an image already on this machine that
# has a shell with wget or curl: OLLAMA_REACH_IMAGE when set, else the first of
# busybox, alpine, curlimages/curl that is there. Prints nothing when none is.
# Nothing is pulled: a start check must not download an image unasked.
_ollama_ep_probe_image() {
  local _oep_repo _oep_ref
  if [[ -n "${OLLAMA_REACH_IMAGE:-}" ]]; then
    printf '%s\n' "$OLLAMA_REACH_IMAGE"
    return 0
  fi
  for _oep_repo in busybox alpine curlimages/curl; do
    _oep_ref="$(docker image ls --format '{{.Repository}}:{{.Tag}}' "$_oep_repo" 2>/dev/null \
      | grep -v '<none>' | sed -n 1p)" || _oep_ref=""
    if [[ -n "$_oep_ref" ]]; then
      printf '%s\n' "$_oep_ref"
      return 0
    fi
  done
  return 0
}

# Usage: ollama_endpoint_container_reach <url> [network]; for a project whose
# containers call this machine's Ollama at <url> (as the container writes it,
# e.g. http://host.docker.internal:11434). Returns 0 when a container can
# reach it.
# The answer on 127.0.0.1 proves nothing for a container: an Ollama that
# listens on loopback only is not on Docker's networks, unless a forwarder
# puts it there, and a forwarder onto the default bridge does not reach a
# compose project's own network.
# 1. When an image with a shell and wget or curl is already on this machine
#    (_ollama_ep_probe_image; nothing is pulled), a throwaway container on
#    [network] asks <url>/api/tags, with host.docker.internal mapped to the
#    host as compose's host-gateway maps it. This is the check that counts.
#    With no [network], the default bridge. When [network] does not exist yet
#    (before the first start), a new network made for the probe and removed
#    after: the default bridge may pass where a compose network does not.
# 2. Otherwise the Docker bridge's gateway is asked from this machine, from
#    127.0.0.1, with the URL as written (--connect-to). It says that it was
#    not checked from the project's network.
# Returns 0, checking nothing, when <url> is another machine (the container
# reaches it as the host does) and with no Docker or none answering (compose
# says so itself). Step 2 also checks nothing when the bridge's gateway is not
# one of this machine's addresses (Docker Desktop, a VM, rootless Docker, a
# remote DOCKER_HOST), and says so.
# Returns 4 when no Ollama answers from a container, 9 when <url> is not an
# address.
# Output: stderr notes and errors; stdout nothing.
# Returns: 0 reachable or not checkable; 4 no Ollama answers from a container; 9 not an address.
ollama_endpoint_container_reach() {
  local LC_ALL=C
  local _oep_url _oep_net="${2:-}" _oep_gw _oep_body _oep_image _oep_host _oep_where
  local _oep_probe_net="" _oep_tmpnet="" _oep_why="no image to probe from is here: set OLLAMA_REACH_IMAGE"
  if ! _oep_url="$(ollama_endpoint_base_url "${1:-}")"; then
    print_error "Not the address of an Ollama: $(_ollama_ep_shown_url "${1:-}")" >&2
    return 9
  fi
  ollama_endpoint_is_local "$_oep_url" || return 0
  command -v docker >/dev/null 2>&1 || return 0
  _oep_where="Docker's default bridge"
  [[ -z "$_oep_net" ]] || _oep_where="network $(_ollama_ep_said "$_oep_net")"

  # A loopback name in <url> is the container itself, seen from a container:
  # only the bridge probe below reads it as the host, as before.
  _oep_host="$(_ollama_ep_host "$_oep_url")"
  case "$_oep_host" in
    localhost|*.localhost|::1|127.*|::ffff:127.*|0.0.0.0|::) _oep_image="" ;;
    *) _oep_image="$(_ollama_ep_probe_image)" ;;
  esac
  if [[ -n "$_oep_image" ]]; then
    _oep_probe_net="$_oep_net"
    if [[ -n "$_oep_net" ]] && ! docker network inspect "$_oep_net" >/dev/null 2>&1; then
      # Before the first start the project's network does not exist yet. The
      # default bridge is not the same test: a forwarder or a firewall rule
      # may cover docker0 and not a compose network. A new network, removed
      # after, is what compose will make.
      # Labelled, so one left by an interrupted run is removed by the next
      # (prune removes only networks no container uses).
      docker network prune -f --filter label=script-helpers.ollama-reach-probe >/dev/null 2>&1 || true
      _oep_probe_net="ollama-reach-probe-$$-${RANDOM}"
      if docker network create --label script-helpers.ollama-reach-probe "$_oep_probe_net" >/dev/null 2>&1; then
        _oep_tmpnet="$_oep_probe_net"
        _oep_where="a new network ($(_ollama_ep_said "$_oep_net") does not exist yet)"
      else
        _oep_probe_net=""
        _oep_where="Docker's default bridge (network $(_ollama_ep_said "$_oep_net") does not exist yet)"
      fi
    fi
    # The URL is an argument of the shell, never part of its program. The
    # marker line tells "the container ran and nothing answered" from "the
    # container did not run" (an old Docker without --pull=never, an image
    # without sh), which falls back to step 2.
    # shellcheck disable=SC2016  # expanded by the container's shell
    _oep_body="$(docker run --rm --pull=never ${_oep_probe_net:+--network "$_oep_probe_net"} \
      --add-host host.docker.internal:host-gateway --entrypoint sh "$_oep_image" \
      -c 'echo ollama-reach-probe; { wget -q -T 5 -O- "$1" 2>/dev/null || curl -fsS -m 5 "$1" 2>/dev/null; } | tr -d "\r\n"' \
      probe "${_oep_url}/api/tags" 2>/dev/null)" || true
    [[ -z "$_oep_tmpnet" ]] || docker network rm "$_oep_tmpnet" >/dev/null 2>&1 || true
    if grep -q '^ollama-reach-probe' <<<"$_oep_body"; then
      if grep -q '"models"[[:space:]]*:' <<<"$_oep_body"; then
        return 0
      fi
      print_error "A container on ${_oep_where} cannot reach this machine's Ollama at $(_ollama_ep_shown_url "$_oep_url")." >&2
      print_error "An Ollama that listens on 127.0.0.1 only needs a forwarder onto Docker's networks, compose networks included (NikOS installs one with the engine), or OLLAMA_HOST=0.0.0.0 behind a firewall; or run the project without Docker." >&2
      return 4
    fi
    _oep_why="the probe container on image $(_ollama_ep_said "$_oep_image") did not run"
  fi

  # The first IPv4 gateway of the default bridge: host-gateway is that address
  # unless the daemon sets host-gateway-ip.
  _oep_gw="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sed -n 1p)" || _oep_gw=""
  [[ -n "$_oep_gw" ]] || return 0
  # Only a bridge on this machine can be asked from here. Docker Desktop, a
  # VM (Colima, OrbStack), rootless Docker and a remote DOCKER_HOST keep theirs
  # elsewhere, and their containers reach the host by other means.
  if ! ollama_endpoint_is_local "http://${_oep_gw}"; then
    print_info "Not checked whether a container reaches this machine's Ollama: Docker's bridge (${_oep_gw}) is not on this machine (Docker Desktop, a VM, rootless Docker or a remote DOCKER_HOST), and ${_oep_why}." >&2
    return 0
  fi
  # The URL as written, connected to the gateway instead (--connect-to): its
  # scheme, credentials, proxy path, port and TLS name stay what the container
  # sends. From 127.0.0.1, not from the host's own bridge address: a request
  # with that address as its source is dropped on some hosts while containers
  # are answered.
  _oep_body="$(curl -sS -m 5 --interface 127.0.0.1 --connect-to "::${_oep_gw}:" "${_oep_url}/api/tags" 2>/dev/null | tr -d '\n\r')" || _oep_body=""
  # Any web server may answer 200. An Ollama's answer contains "models".
  if ! grep -q '"models"[[:space:]]*:' <<<"$_oep_body"; then
    print_error "A container cannot reach this machine's Ollama: it is not on the Docker bridge (${_oep_gw}, at $(_ollama_ep_shown_url "$_oep_url"))." >&2
    print_error "An Ollama that listens on 127.0.0.1 only needs a forwarder onto the bridge (NikOS installs one with the engine); or run the project without Docker." >&2
    return 4
  fi
  print_info "Docker's default bridge reaches this machine's Ollama; not checked from the project's network (${_oep_why})." >&2
  return 0
}

# Usage: ollama_env_file_export <file> NAME...; exports each NAME from an
# env-style file, unless the environment already has a value for it that is
# not blank (a blank one is no choice, and the file's is used). The file is
# read as ollama_models_file_get reads one, as data: it is never sourced, so a
# value with a "$", a backquote or a space in it is only a value. A file that
# is not there exports nothing.
# Returns 2, exporting nothing, when a NAME is not a variable name.
# Returns: 0 done (also with no file); 2 a NAME is not a variable name; 9 a read-only variable could not be set.
# Output: stderr errors.
ollama_env_file_export() {
  local _oep_file="${1:-}" _oep_name _oep_value
  [[ $# -eq 0 ]] || shift
  for _oep_name in "$@"; do
    if ! _ollama_ep_is_name "$_oep_name"; then
      print_error "Not a variable name: $(_ollama_ep_said "$_oep_name")" >&2
      return 2
    fi
  done
  [[ -f "$_oep_file" ]] || return 0
  for _oep_name in "$@"; do
    _oep_value="$(printf '%s' "${!_oep_name:-}" | tr -d ' \t\r\n')" || true
    [[ -z "$_oep_value" ]] || continue
    _oep_value="$(ollama_models_file_get "$_oep_file" "$_oep_name")" || true
    [[ -n "$_oep_value" ]] || continue
    # A caller that holds the variable read-only and blank would keep its
    # blank: the file's setting would be read as "not set", silently.
    if ! export "$_oep_name=$_oep_value" 2>/dev/null; then
      print_error "$_oep_name is set in $(_ollama_ep_said "$_oep_file") and cannot be set here: the caller holds it read-only." >&2
      return 9
    fi
  done
  return 0
}

# What a start check reads from a project's .env besides the models and the
# address.
_ollama_ep_settings() {
  printf '%s' "OLLAMA_MODE OLLAMA_PORT OLLAMA_HOST_PORT OLLAMA_PULL_MISSING OLLAMA_IGNORE_BUDGET OLLAMA_DISK_RESERVE_GB OLLAMA_MEM_HEADROOM_PERCENT OLLAMA_PULL_STALL_SECONDS OLLAMA_REGISTRY_URL OLLAMA_REGISTRY_TIMEOUT OLLAMA_MODELS OLLAMA_BUDGET_DISK_FREE_BYTES OLLAMA_BUDGET_MEM_TOTAL_BYTES OLLAMA_BUDGET_MEM_AVAILABLE_BYTES OLLAMA_BUDGET_GPU_BYTES OLLAMA_BUDGET_GPU_LARGEST_BYTES AI_MODEL_TIER"
}

# Where Docker keeps its data on this machine: the disk an Ollama in a
# container fills. OLLAMA_MODELS when the project states it.
_ollama_ep_docker_models_dir() {
  local _oep_root=""
  if [[ -n "${OLLAMA_MODELS:-}" ]]; then
    printf '%s\n' "$OLLAMA_MODELS"
    return 0
  fi
  _oep_root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null | sed -n 1p)" || _oep_root=""
  case "$_oep_root" in /*) ;; *) _oep_root="/var/lib/docker" ;; esac
  printf '%s\n' "$_oep_root"
}

# Usage: ollama_project_ensure_models <models_file> [env_file] [NAME...]
#
# The whole start check for a project, from its own configuration:
#   ollama_project_ensure_models ai-models.env .env || exit $?
#
# 1. Reads the project's .env (env_file; "" for none, and a file that is not
#    there yet is no .env) as data, never sourcing it: the model names, the
#    address, OLLAMA_MODE and the settings of this module. A value in the
#    environment that is not blank wins.
# 2. The models are those of ollama_models_required <models_file> [NAME...];
#    pass "" for the file to take the NAMEs from the environment and .env alone.
# 3. The address is the first of the variables in OLLAMA_URL_VARS that has a
#    value (default: OLLAMA_URL, OLLAMA_BASE_URL, OLLAMA_HOST), made a base URL
#    by ollama_endpoint_base_url; http://127.0.0.1:11434 when none has. On the
#    host, Docker's name for the host (host.docker.internal) is this machine.
# 4. OLLAMA_MODE says where that Ollama, or whatever answers for it, runs. A
#    project sets it in .env; it is not guessed when it is set:
#      local   an Ollama on this machine. Its models are in ollama_models_dir,
#              and this machine's disk and memory are what a pull is checked
#              against. An address that is not this machine is a mistake (9).
#      docker  an Ollama in a container on this machine. The address a
#              container uses for it (http://ollama:11434, a compose service)
#              does not resolve from a start script, so it is read as this
#              machine, at the port in OLLAMA_PORT or OLLAMA_HOST_PORT when
#              one is set and at the address's own port otherwise. Its models
#              are on Docker's disk (OLLAMA_MODELS, else Docker's data root).
#      remote  an API on another machine: an Ollama, or anything else the
#              project talks to (a hosted API in production). Nothing is
#              measured here and nothing is pulled unless OLLAMA_PULL_MISSING
#              is set on. If it answers as an Ollama, the models it lacks are
#              a refusal (5); if it does not, there is nothing to check and
#              the start goes on (0).
#    Not set (or "auto"): local when the address is this machine
#    (ollama_endpoint_is_local), otherwise as remote, except that nothing
#    answering stays a refusal (4).
# 5. A pull into another machine, asked for with OLLAMA_PULL_MISSING, needs
#    that machine's figures stated (OLLAMA_BUDGET_DISK_FREE_BYTES and
#    OLLAMA_BUDGET_MEM_TOTAL_BYTES) or OLLAMA_IGNORE_BUDGET: without them it
#    is a refusal (7), not a check against this machine. This machine's free
#    memory and GPU are never counted for it.
#
# Returns what ollama_endpoint_ensure_models returns, and 9 for the project's
# configuration: a models file that is not there, a NAME or an entry of
# OLLAMA_URL_VARS that is not a variable name, an address that is not one, an
# OLLAMA_MODE that is not one of the three, or one the address contradicts.
# Nothing it reads from .env is left in the caller's environment.
# Runs in a subshell: it changes nothing in the caller's environment.
# Output: stderr progress and refusals; stdout nothing.
# Returns: 0-8 as ollama_endpoint_ensure_models; 9 bad configuration.
ollama_project_ensure_models() (
  # The caller's IFS must not split the lists below: a caller in "strict mode"
  # has it set to newline and tab, and the names came out as one word.
  local IFS=$' \t\n'
  local _oep_file="${1:-}" _oep_env="${2:-}" _oep_url="" _oep_name _oep_value _oep_models _oep_names
  local _oep_mode _oep_where _oep_dir _oep_host _oep_port="" _oep_present _oep_missing
  local _oep_unasked=0 _oep_status=0 _oep_ignore=0
  local _oep_vars="${OLLAMA_URL_VARS:-OLLAMA_URL OLLAMA_BASE_URL OLLAMA_HOST}"
  local -a _oep_list=()
  if [[ $# -ge 2 ]]; then shift 2; else shift $#; fi
  # Lists below are split into words; none may be read as a file pattern.
  set -f
  # No file and no names would check nothing and return 0: a start that
  # believes its models are there.
  if [[ -z "$_oep_file" && $# -eq 0 ]]; then
    print_error "No models file and no names: name the models file, or the variables that hold the models (ollama_project_ensure_models \"\" .env OLLAMA_MODEL)." >&2
    exit 9
  fi

  # OLLAMA_URL_VARS may itself be in the project's .env.
  if [[ -n "$_oep_env" ]]; then
    ollama_env_file_export "$_oep_env" OLLAMA_URL_VARS || exit 9
    _oep_vars="${OLLAMA_URL_VARS:-OLLAMA_URL OLLAMA_BASE_URL OLLAMA_HOST}"
  fi
  for _oep_name in $_oep_vars; do
    if ! _ollama_ep_is_name "$_oep_name"; then
      print_error "OLLAMA_URL_VARS names something that is not a variable: $(_ollama_ep_said "$_oep_name")" >&2
      exit 9
    fi
  done

  if [[ -n "$_oep_env" ]]; then
    if [[ $# -gt 0 ]]; then
      _oep_names="$*"
    else
      _oep_names="$(ollama_models_file_names "$_oep_file" | tr '\n' ' ')" || _oep_names=""
    fi
    # shellcheck disable=SC2046,SC2086  # lists of names, one per word
    ollama_env_file_export "$_oep_env" $(_ollama_ep_settings) $_oep_vars $_oep_names || exit 9
  fi

  # A model the project's .env names outside the approved set is asked about,
  # or refused with nobody to ask (CI).
  _ollama_ep_check_overrides "$_oep_file" "$@" || exit 9
  _oep_models="$(ollama_models_required "$_oep_file" "$@")" || exit 9
  [[ -n "$_oep_models" ]] || exit 0
  # One model per line. Split on lines, not on words: "small:3b embed" as one
  # value is one reference that is not valid, not two models.
  while IFS= read -r _oep_value; do
    [[ -z "$_oep_value" ]] || _oep_list+=("$_oep_value")
  done <<<"$_oep_models"

  for _oep_name in $_oep_vars; do
    _oep_value="$(printf '%s' "${!_oep_name:-}" | tr -d ' \t\r\n')" || true
    [[ -n "$_oep_value" ]] || continue
    if ! _oep_url="$(ollama_endpoint_base_url "${!_oep_name}")"; then
      # The value is not shown. It could not be read as an address, so what
      # it is instead is not known: a password with a slash in it, or a key
      # that was meant for another variable.
      print_error "${_oep_name} is not the address of an Ollama. It is a host, host:port or an http(s) URL; a password in it must be percent-encoded." >&2
      exit 9
    fi
    break
  done
  [[ -n "$_oep_url" ]] || _oep_url="${_OLLAMA_EP_DEFAULT_URL:-http://127.0.0.1:11434}"

  # Trimmed at the ends only: "lo cal" is a typo, not local. The value is not
  # repeated in the message; it may be anything that was meant for another
  # variable.
  _oep_mode="$(printf '%s' "${OLLAMA_MODE:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr 'A-Z' 'a-z')" || true
  case "$_oep_mode" in
    ""|auto) _oep_mode="auto" ;;
    local|host) _oep_mode="local" ;;
    docker|container) _oep_mode="docker" ;;
    remote|api|external) _oep_mode="remote" ;;
    *)
      print_error "OLLAMA_MODE is not local (an Ollama on this machine), docker (one in a container here) or remote (an API on another machine)." >&2
      exit 9
      ;;
  esac

  # Written for a container to find the host. A start script is on the host
  # (unless this is a container itself, where the name is the right one).
  _oep_host="$(_ollama_ep_host "$_oep_url")"
  if ! _ollama_ep_in_container; then
    case "$_oep_host" in
      host.docker.internal|gateway.docker.internal)
        _oep_url="$(printf '%s' "$_oep_url" | sed -E 's#(://([^/@]*@)?)(\[[^]/]*\]|[^/:@]+)#\1127.0.0.1#')" || true
        ;;
    esac
  fi

  case "$_oep_mode" in
    docker)
      if ! ollama_endpoint_is_local "$_oep_url" && ! _ollama_ep_in_container; then
        # On the host, the name a container calls it by (one label: a compose
        # service) is this machine, at the port the project publishes. Any
        # other name or address is another machine, and docker is the wrong
        # word for it. Inside a container the name is the right one as it is.
        if [[ "$_oep_host" == *.* || "$_oep_host" == *:* || "$_oep_host" =~ ^[0-9]+$ ]]; then
          print_error "OLLAMA_MODE is docker, and $(_ollama_ep_shown_url "$_oep_url") is another machine. A container here is named by its compose service name, or by localhost at its published port; use remote for an Ollama elsewhere." >&2
          exit 9
        fi
        for _oep_name in OLLAMA_PORT OLLAMA_HOST_PORT; do
          _oep_value="$(printf '%s' "${!_oep_name:-}" | tr -d ' \t\r\n')" || true
          [[ -n "$_oep_value" ]] || continue
          # A typo here would send the pull to whatever listens on the
          # address's own port: on many machines, the native Ollama.
          if ! _oep_port="$(_ollama_ep_uint "$_oep_value")" || [[ "$_oep_port" -lt 1 || "$_oep_port" -gt 65535 ]]; then
            print_error "$_oep_name is not a port number (1 to 65535)." >&2
            exit 9
          fi
          break
        done
        _oep_url="$(printf '%s' "$_oep_url" | sed -E 's#(://([^/@]*@)?)(\[[^]/]*\]|[^/:@]+)#\1127.0.0.1#')" || true
        if [[ -n "$_oep_port" ]]; then
          _oep_url="$(printf '%s' "$_oep_url" | sed -E "s#(://([^/@]*@)?127\\.0\\.0\\.1)(:[0-9]+)?#\\1:${_oep_port}#")" || true
        fi
      fi
      _oep_where="here"
      _oep_dir="$(_ollama_ep_docker_models_dir)"
      ;;
    local)
      if ! ollama_endpoint_is_local "$_oep_url"; then
        print_error "OLLAMA_MODE is local, and $(_ollama_ep_shown_url "$_oep_url") is not this machine. Use docker for an Ollama in a container here, or remote for one elsewhere." >&2
        exit 9
      fi
      _oep_where="here"
      _oep_dir="$(ollama_models_dir)"
      ;;
    remote)
      _oep_where="elsewhere"
      ;;
    *)
      if ollama_endpoint_is_local "$_oep_url"; then
        _oep_where="here"
        _oep_dir="$(ollama_models_dir)"
      else
        _oep_where="elsewhere"
      fi
      ;;
  esac

  # Another machine's Ollama: this machine's memory and GPU are not its own, so
  # they do not pick its class. AI_MODEL_TIER names it, or its stated memory
  # (OLLAMA_BUDGET_MEM_TOTAL_BYTES, with OLLAMA_BUDGET_GPU_LARGEST_BYTES or no
  # GPU) measures it; with neither, the default column.
  if [[ "$_oep_where" == "elsewhere" && -z "$(printf '%s' "${AI_MODEL_TIER:-}" | tr -d ' \t\r')" ]]; then
    _ollama_ep_remote_tier
    _oep_value="$(ollama_models_required "$_oep_file" "$@")" || exit 9
    if [[ "$_oep_value" != "$_oep_models" ]]; then
      _oep_models="$_oep_value"
      _oep_list=()
      while IFS= read -r _oep_value; do
        [[ -z "$_oep_value" ]] || _oep_list+=("$_oep_value")
      done <<<"$_oep_models"
    fi
  fi

  if [[ "$_oep_where" == "elsewhere" ]]; then
    # Not a directory on this machine. The disk is read only if a pull was
    # asked for, and then the stated figures are what counts.
    _oep_dir="/"
    if ! _oep_present="$(ollama_endpoint_models "$_oep_url")"; then
      if [[ "$_oep_mode" == "remote" ]]; then
        # A hosted API that is not an Ollama, or one that is not up: neither
        # is something a start script on this machine can check or mend.
        print_info "OLLAMA_MODE is remote and $(_ollama_ep_shown_url "$_oep_url") does not answer as an Ollama: its models are not checked from here." >&2
        exit 0
      fi
      # Stop here (4). Asked again it might answer, and the pull that followed
      # would go into another machine, measured against this one's disk.
      print_error "No Ollama answers at $(_ollama_ep_shown_url "$_oep_url")." >&2
      _oep_status=4
    else
      _oep_missing="$(ollama_models_missing "$_oep_models" "$_oep_present")"
      _oep_value="$(printf '%s' "${OLLAMA_PULL_MISSING:-}" | tr -d ' \t\r\n')" || true
      if [[ -z "$_oep_value" ]]; then
        _oep_unasked=1
        export OLLAMA_PULL_MISSING=0
      elif [[ -n "$_oep_missing" && "$(_ollama_ep_pull_mode 2>/dev/null)" != "off" ]]; then
        # A pull into another machine was asked for. Said once here, so a typo
        # in the setting that would waive the check is not swallowed.
        if _ollama_ep_on OLLAMA_IGNORE_BUDGET off; then _oep_ignore=1; fi
        if [[ "$_oep_ignore" -eq 0 ]]; then
          if ! _ollama_ep_uint "${OLLAMA_BUDGET_DISK_FREE_BYTES:-}" >/dev/null || ! _ollama_ep_uint "${OLLAMA_BUDGET_MEM_TOTAL_BYTES:-}" >/dev/null; then
            # Its disk and memory were not stated. What would be read is this
            # machine's: the wrong one.
            print_error "That Ollama is another machine and lacks: ${_oep_missing//$'\n'/ }. Its free disk and its memory are not known here: state them (OLLAMA_BUDGET_DISK_FREE_BYTES, OLLAMA_BUDGET_MEM_TOTAL_BYTES), or set OLLAMA_IGNORE_BUDGET=1 to pull unchecked. Nothing was pulled." >&2
            exit 7
          fi
          # Nothing of this machine is counted for that one: not its GPU, and
          # not what is free in its memory right now.
          _ollama_ep_uint "${OLLAMA_BUDGET_GPU_BYTES:-}" >/dev/null || export OLLAMA_BUDGET_GPU_BYTES=0
          _ollama_ep_uint "${OLLAMA_BUDGET_MEM_AVAILABLE_BYTES:-}" >/dev/null || export OLLAMA_BUDGET_MEM_AVAILABLE_BYTES="$OLLAMA_BUDGET_MEM_TOTAL_BYTES"
        fi
      fi
    fi
  fi

  if [[ "$_oep_status" -eq 0 ]]; then
    ollama_endpoint_ensure_models "$_oep_url" "$_oep_dir" "${_oep_list[@]}" || _oep_status=$?
    # A model above the default column that the disk or memory refuses (1-3)
    # falls back one column (xlarge, large, standard) and is checked again. The
    # default column is the floor: when it does not fit, the start stops.
    while [[ "$_oep_status" -ge 1 && "$_oep_status" -le 3 ]]; do
      case "${_OLLAMA_EP_TIER_CAP:-xlarge}" in
        xlarge) _OLLAMA_EP_TIER_CAP=large ;;
        large) _OLLAMA_EP_TIER_CAP=standard ;;
        *) break ;;
      esac
      export _OLLAMA_EP_TIER_CAP
      _oep_value="$(ollama_models_required "$_oep_file" "$@")" || break
      [[ "$_oep_value" != "$_oep_models" ]] || continue
      print_warning "Falling back one class of model ($_OLLAMA_EP_TIER_CAP): ${_oep_value//$'\n'/ }" >&2
      _oep_models="$_oep_value"
      _oep_list=()
      while IFS= read -r _oep_value; do
        [[ -z "$_oep_value" ]] || _oep_list+=("$_oep_value")
      done <<<"$_oep_models"
      _oep_status=0
      ollama_endpoint_ensure_models "$_oep_url" "$_oep_dir" "${_oep_list[@]}" || _oep_status=$?
    done
  fi
  if [[ "$_oep_status" -eq 4 && "$_oep_mode" == "auto" ]]; then
    # A name of one word that is not this machine is most often a compose
    # service: it resolves inside that network and nowhere else.
    _oep_host="$(_ollama_ep_host "$_oep_url")"
    if [[ "$_oep_host" != *.* && "$_oep_host" != *:* ]] && ! ollama_endpoint_is_local "$_oep_url"; then
      print_error "If '$(_ollama_ep_said "$_oep_host")' is a compose service, its name resolves only inside that network. Set OLLAMA_MODE=docker (with OLLAMA_PORT when the published port differs), or give the address published on this machine." >&2
    fi
  fi
  if [[ "$_oep_status" -eq 5 && "$_oep_unasked" -eq 1 ]]; then
    print_error "That Ollama is another machine, so nothing is pulled from here: the disk and memory read here are not its own. Pull the models there, or set OLLAMA_PULL_MISSING=1 with OLLAMA_IGNORE_BUDGET=1 to pull from here unchecked." >&2
  fi
  exit "$_oep_status"
)

# --- which Ollama a project uses: the host's, or its optional container -----
#
# The machine's one Ollama is the default and preferred. A project may ship an
# optional Ollama container in a compose override (docker-ollama.yml) for a
# machine where Ollama cannot run on the host; it is used only when the owner
# sets OLLAMA_RUNTIME=container, and never chosen here by itself. Its models
# volume is external, so `docker compose down -v` never removes it.

# Usage: _ollama_ep_setting <NAME> <env_file>; prints NAME from the
# environment, else from env_file (read as data). Blank is not set.
_ollama_ep_setting() {
  local _oep_value
  _oep_value="$(printf '%s' "${!1:-}" | tr -d ' \t\r\n')" || true
  if [[ -n "$_oep_value" ]]; then
    printf '%s' "${!1}"
    return 0
  fi
  ollama_models_file_get "${2:-}" "$1" 2>/dev/null | tr -d '\n' || true
}

# Usage: _ollama_ep_abs <root> <path>; a path relative to root made absolute.
_ollama_ep_abs() {
  case "${2:-}" in
    /*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "${1%/}/$2" ;;
  esac
}

# Usage: ollama_runtime [env_file]; prints host or container: OLLAMA_RUNTIME
# from the environment, else from env_file, else host. Returns 9 for any other
# value, which is named with the two it may be.
# Returns: 0 printed; 9 an unknown value.
# Output: stdout host|container; stderr the error.
ollama_runtime() {
  local _oep_value
  _oep_value="$(_ollama_ep_setting OLLAMA_RUNTIME "${1:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" || true
  case "${_oep_value:-host}" in
    host|container) printf '%s\n' "${_oep_value:-host}" ;;
    *)
      print_error "OLLAMA_RUNTIME=$(_ollama_ep_said "$_oep_value") is not a runtime: use host (the machine's Ollama, the default) or container (the project's optional Ollama in docker-ollama.yml)." >&2
      return 9
      ;;
  esac
}

# Usage: _ollama_ep_project_paths <root> <compose> <override>; sets
# _oep_compose and _oep_override (absolute) in the caller. The override
# defaults to docker-ollama.yml next to the main file. Returns 9 when a path
# holds COMPOSE_PATH_SEPARATOR: COMPOSE_FILE would split it in two.
_ollama_ep_project_paths() {
  local _oep_sep="${COMPOSE_PATH_SEPARATOR:-:}" _oep_p
  _oep_compose="$(_ollama_ep_abs "$1" "${2:-docker-compose.yml}")"
  if [[ -n "${3:-}" ]]; then
    _oep_override="$(_ollama_ep_abs "$1" "$3")"
  else
    _oep_override="$(dirname "$_oep_compose")/docker-ollama.yml"
  fi
  for _oep_p in "$_oep_compose" "$_oep_override"; do
    if [[ "$_oep_p" == *"$_oep_sep"* ]]; then
      print_error "$(_ollama_ep_said "$_oep_p") has '${_oep_sep}' in it, which COMPOSE_FILE reads as two files: move the project, or set COMPOSE_PATH_SEPARATOR." >&2
      return 9
    fi
  done
}

# Usage: ollama_project_compose_files <root> [--compose FILE] [--override FILE] [--by-runtime] [--env-file FILE]
# Prints the COMPOSE_FILE value for a project's compose call: the main file
# (default <root>/docker-compose.yml) and the optional Ollama override
# (default docker-ollama.yml next to it) when that file is there, joined by
# COMPOSE_PATH_SEPARATOR (default ":"). Paths are absolute.
# The override is included whatever OLLAMA_RUNTIME says, so a stop also stops
# a container started earlier in the other mode. With --by-runtime it is
# included only with OLLAMA_RUNTIME=container (from the environment or the
# env file, default <root>/.env), for the other verbs.
# Returns 9 for an unknown option or, with --by-runtime, an unknown runtime.
# Returns: 0 printed; 9 unknown option or runtime.
# Output: stdout the COMPOSE_FILE value; stderr errors.
ollama_project_compose_files() {
  local _oep_root="${1:-}" _oep_compose="" _oep_override="" _oep_c="" _oep_o="" _oep_env="" _oep_by=0 _oep_rt
  if [[ -z "$_oep_root" || ! -d "$_oep_root" ]]; then
    print_error "ollama_project_compose_files: the first argument is the project's root directory." >&2
    return 9
  fi
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --compose|--override|--env-file)
        if [[ $# -lt 2 ]]; then
          print_error "ollama_project_compose_files: $1 needs a value." >&2
          return 9
        fi
        case "$1" in
          --compose) _oep_c="$2" ;;
          --override) _oep_o="$2" ;;
          *) _oep_env="$2" ;;
        esac
        shift 2
        ;;
      --by-runtime) _oep_by=1; shift ;;
      *) print_error "ollama_project_compose_files: unknown option $(_ollama_ep_said "$1")" >&2; return 9 ;;
    esac
  done
  _ollama_ep_project_paths "$_oep_root" "$_oep_c" "$_oep_o" || return 9
  if [[ "$_oep_by" -eq 1 ]]; then
    _oep_rt="$(ollama_runtime "$(_ollama_ep_abs "$_oep_root" "${_oep_env:-.env}")")" || return 9
    if [[ "$_oep_rt" != "container" ]]; then
      printf '%s\n' "$_oep_compose"
      return 0
    fi
  fi
  if [[ -f "$_oep_override" ]]; then
    printf '%s%s%s\n' "$_oep_compose" "${COMPOSE_PATH_SEPARATOR:-:}" "$_oep_override"
  else
    printf '%s\n' "$_oep_compose"
  fi
}

# Usage: _ollama_ep_compose_network <compose_file> <env_file>; prints the
# default network compose gives the project (<project>_default): the project
# name is COMPOSE_PROJECT_NAME, else the main file's directory, normalised as
# compose does it.
_ollama_ep_compose_network() {
  local _oep_name
  _oep_name="$(_ollama_ep_setting COMPOSE_PROJECT_NAME "${2:-}")"
  [[ -n "$_oep_name" ]] || _oep_name="$(basename "$(dirname "${1:-.}")")"
  _oep_name="$(printf '%s' "$_oep_name" | tr 'A-Z' 'a-z' | LC_ALL=C tr -cd 'a-z0-9_-')" || true
  [[ -z "$_oep_name" ]] || printf '%s_default\n' "$_oep_name"
}

# Usage: ollama_project_prepare <root> --mode docker|local --url-var NAME --volume NAME [option...]
#
# The whole "which Ollama, and does it have the models" step of a project's
# start, in one call that is not a subshell (it exports what compose and the
# app read):
#   ollama_project_prepare "$ROOT" --mode docker --url-var OLLAMA_BASE_URL \
#     --volume myapp_ollama_data --model-var OLLAMA_MODEL --standard-tier || exit $?
#
#   --mode docker|local   where the app runs: in a container, or on this machine
#   --url-var NAME        the variable the app reads the Ollama address from;
#                         exported with the address it must use. Repeat for
#                         older names the app also reads: in host mode the
#                         first one set is used; only the first is exported
#   --volume NAME         the external models volume of the optional container
#   --url-suffix PATH     the API path the app keeps in the address
#                         (/api/generate); added to the addresses made here
#                         (the defaults and --container-url), never to a
#                         value read from the environment or the env file
#   --compose FILE        the main compose file (docker-compose.yml)
#   --override FILE       the optional Ollama override (docker-ollama.yml next
#                         to the main file)
#   --env-file FILE       the project's settings (.env)
#   --models-file FILE    the approved models (ai-models.env)
#   --model-var NAME      a variable the app reads a model from; repeat for
#                         more. Exported (environment, else env file, else
#                         models file). None: every name in the models file.
#   --standard-tier       the app reads that one variable, not the per-class
#                         columns: AI_MODEL_TIER=standard, so the check asks
#                         for the model the app will use
#   --skip-var NAME       when that variable is 1, nothing is checked; the
#                         compose files, the address and the volume are still
#                         set up
#   --port-var NAME       the container's published port (OLLAMA_CONTAINER_PORT,
#                         default 11435)
#   --container-url URL   the address the app uses for the container
#                         (http://ollama:11434), with --mode docker
#   --network NAME        the network the app's container is on, for the reach
#                         check (default <project>_default once it exists)
#   --no-container-pull   the container publishes no port and has no egress:
#                         it is not started or checked here; its models come
#                         with the volume
#
# OLLAMA_RUNTIME (environment, else env file; default host):
#   host       COMPOSE_FILE is the main file. The address is <url-var>, else
#              http://host.docker.internal:11434 (docker) or
#              http://127.0.0.1:11434 (local). An address naming the
#              container's service is refused (9): it runs only with
#              OLLAMA_RUNTIME=container. The models are checked
#              (ollama_project_ensure_models); with --mode docker, then
#              ollama_endpoint_container_reach from the project's network.
#              The check runs with OLLAMA_MODE=local when the address is this
#              machine, whatever OLLAMA_MODE says.
#   container  COMPOSE_FILE is main:override. The volume is created when it is
#              missing, `docker compose up -d ollama` is run, and the models are
#              checked on 127.0.0.1:<port> with OLLAMA_MODE=docker. The address
#              is --container-url (docker) or http://127.0.0.1:<port> (local).
# OLLAMA_PULL_MISSING defaults to ask for an Ollama on this machine only.
#
# Returns 0; what ollama_project_ensure_models returns (1-8); 4 also when the
# container does not answer or (host, --mode docker) a container cannot reach
# the host's Ollama. A host-mode 4 for this machine's Ollama names the host's
# Ollama first and OLLAMA_RUNTIME=container second; 9 for the call or
# the configuration (an unknown option, OLLAMA_RUNTIME, an address that is
# not one or names the container in host mode, a port, a missing override, a
# compose path holding COMPOSE_PATH_SEPARATOR);
# 10 when Docker is needed for the container and fails (absent, the volume,
# compose up).
# Output: exports COMPOSE_FILE and the --url-var/--model-var variables; stderr progress and errors.
# Returns: 0 ready; 1-8 as ollama_project_ensure_models; 4 container unreachable; 9 bad call or configuration; 10 Docker failed.
ollama_project_prepare() {
  local IFS=$' \t\n'
  local _oep_root="${1:-}" _oep_mode="" _oep_var="" _oep_suffix="" _oep_vol="" _oep_c="" _oep_o=""
  local _oep_env="" _oep_mf="" _oep_tier=0 _oep_skip="" _oep_pvar="OLLAMA_CONTAINER_PORT"
  local _oep_curl="http://ollama:11434" _oep_net="" _oep_nopull=0 _oep_compose _oep_override
  local _oep_rt _oep_url _oep_base _oep_host _oep_svc _oep_port _oep_value _oep_name _oep_rc=0 _oep_i
  local _oep_local=0 _oep_waited=0
  local -a _oep_vars=() _oep_dc=() _oep_uvars=()
  if [[ -z "$_oep_root" || ! -d "$_oep_root" ]]; then
    print_error "ollama_project_prepare: the first argument is the project's root directory." >&2
    return 9
  fi
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode|--url-var|--url-suffix|--volume|--compose|--override|--env-file|--models-file|--model-var|--skip-var|--port-var|--container-url|--network)
        if [[ $# -lt 2 ]]; then
          print_error "ollama_project_prepare: $1 needs a value." >&2
          return 9
        fi
        case "$1" in
          --mode) _oep_mode="$2" ;;
          --url-var) if [[ -z "$_oep_var" ]]; then _oep_var="$2"; else _oep_uvars+=("$2"); fi ;;
          --url-suffix) _oep_suffix="$2" ;;
          --volume) _oep_vol="$2" ;;
          --compose) _oep_c="$2" ;;
          --override) _oep_o="$2" ;;
          --env-file) _oep_env="$2" ;;
          --models-file) _oep_mf="$2" ;;
          --model-var) _oep_vars+=("$2") ;;
          --skip-var) _oep_skip="$2" ;;
          --port-var) _oep_pvar="$2" ;;
          --container-url) _oep_curl="$2" ;;
          --network) _oep_net="$2" ;;
        esac
        shift 2
        ;;
      --standard-tier) _oep_tier=1; shift ;;
      --no-container-pull) _oep_nopull=1; shift ;;
      *) print_error "ollama_project_prepare: unknown option $(_ollama_ep_said "$1")" >&2; return 9 ;;
    esac
  done
  case "$_oep_mode" in
    docker|local) ;;
    *) print_error "ollama_project_prepare: --mode is docker (the app runs in a container) or local (on this machine)." >&2; return 9 ;;
  esac
  for _oep_name in "$_oep_var" "$_oep_pvar" ${_oep_skip:+"$_oep_skip"} ${_oep_vars[@]+"${_oep_vars[@]}"} ${_oep_uvars[@]+"${_oep_uvars[@]}"}; do
    if ! _ollama_ep_is_name "$_oep_name"; then
      print_error "ollama_project_prepare: not a variable name: $(_ollama_ep_said "$_oep_name") (--url-var is required)." >&2
      return 9
    fi
  done
  # Docker's rule for a volume name: two characters at least.
  if ! [[ "$_oep_vol" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]]; then
    print_error "ollama_project_prepare: --volume names the external models volume (two or more of letters, digits, _ . -)." >&2
    return 9
  fi
  case "$_oep_suffix" in ""|/*) ;; *) _oep_suffix="/$_oep_suffix" ;; esac
  _oep_env="$(_ollama_ep_abs "$_oep_root" "${_oep_env:-.env}")"
  _oep_mf="$(_ollama_ep_abs "$_oep_root" "${_oep_mf:-ai-models.env}")"
  _ollama_ep_project_paths "$_oep_root" "$_oep_c" "$_oep_o" || return 9
  if ! ollama_endpoint_base_url "$_oep_curl" >/dev/null; then
    print_error "ollama_project_prepare: --container-url is not the address of an Ollama." >&2
    return 9
  fi

  _oep_rt="$(ollama_runtime "$_oep_env")" || return 9
  export OLLAMA_RUNTIME="$_oep_rt"

  # The model the app reads: the environment, else .env, else the models file.
  for _oep_name in ${_oep_vars[@]+"${_oep_vars[@]}"}; do
    ollama_env_file_export "$_oep_env" "$_oep_name" || return 9
    ollama_env_file_export "$_oep_mf" "$_oep_name" || return 9
  done
  if [[ "$_oep_tier" -eq 1 ]]; then
    _oep_value="$(_ollama_ep_setting AI_MODEL_TIER "$_oep_env" | tr -d ' \t\r')" || true
    if [[ -n "$_oep_value" && "$_oep_value" != "standard" ]]; then
      print_warning "AI_MODEL_TIER=$(_ollama_ep_said "$_oep_value") is not used: the app reads ${_oep_vars[*]:-its model variable} only." >&2
    fi
    export AI_MODEL_TIER=standard
  fi
  _oep_value=""
  [[ -z "$_oep_skip" ]] || _oep_value="$(_ollama_ep_setting "$_oep_skip" "$_oep_env" | tr -d ' \t\r')"
  [[ "$_oep_value" == "1" ]] || _oep_skip=""
  _oep_svc="$(_ollama_ep_host "$_oep_curl")"

  if [[ "$_oep_rt" == "host" ]]; then
    # The first --url-var that is set, from the environment, else the env file.
    for _oep_name in "$_oep_var" ${_oep_uvars[@]+"${_oep_uvars[@]}"}; do
      _oep_url="$(_ollama_ep_setting "$_oep_name" "$_oep_env")"
      [[ -z "$(printf '%s' "$_oep_url" | tr -d ' \t\r')" ]] || break
    done
    if [[ -z "$(printf '%s' "$_oep_url" | tr -d ' \t\r')" ]]; then
      if [[ "$_oep_mode" == "docker" ]]; then
        _oep_url="http://host.docker.internal:11434${_oep_suffix}"
      else
        _oep_url="http://127.0.0.1:11434${_oep_suffix}"
      fi
    fi
    if ! _oep_base="$(ollama_endpoint_base_url "$_oep_url")"; then
      print_error "$_oep_var is not the address of an Ollama. It is a host, host:port or an http(s) URL; a password in it must be percent-encoded." >&2
      return 9
    fi
    _oep_host="$(_ollama_ep_host "$_oep_base")"
    if [[ -n "$_oep_svc" && "$_oep_host" == "$_oep_svc" ]]; then
      print_error "$_oep_var=$(_ollama_ep_shown_url "$_oep_url") names the ${_oep_svc} container, which runs only with OLLAMA_RUNTIME=container." >&2
      if [[ "$_oep_mode" == "docker" ]]; then
        print_error "Fix: remove that setting from .env or the environment (the default is the host's Ollama, http://host.docker.internal:11434${_oep_suffix}), or set OLLAMA_RUNTIME=container only if Ollama cannot run on this host." >&2
      else
        print_error "Fix: remove that setting from .env or the environment (the default is the host's Ollama, http://127.0.0.1:11434${_oep_suffix}), or set OLLAMA_RUNTIME=container only if Ollama cannot run on this host." >&2
      fi
      return 9
    fi
    # An app on this machine cannot resolve Docker's name for it.
    if [[ "$_oep_mode" == "local" ]] && ! _ollama_ep_in_container; then
      case "$_oep_host" in
        host.docker.internal|gateway.docker.internal)
          _oep_url="$(printf '%s' "$_oep_url" | sed -E 's#(://([^/@]*@)?)?(host|gateway)\.docker\.internal#\1127.0.0.1#')" || true
          ;;
      esac
    fi
    export COMPOSE_FILE="$_oep_compose"
    export "$_oep_var=$_oep_url"
    if [[ -n "$_oep_skip" ]]; then
      print_info "${_oep_skip}=1: the Ollama check is skipped." >&2
      return 0
    fi
    # Docker's names for the host are this machine, seen from the host.
    if ollama_endpoint_is_local "$_oep_base"; then _oep_local=1; fi
    ( export OLLAMA_URL_VARS=_OLLAMA_EP_PREPARE_URL _OLLAMA_EP_PREPARE_URL="$_oep_url"
      if [[ "$_oep_local" -eq 1 ]]; then
        # Host mode: an OLLAMA_MODE=docker left from a container setup would
        # measure a pull against Docker's disk instead of the host's.
        export OLLAMA_MODE=local
        [[ -n "$(_ollama_ep_setting OLLAMA_PULL_MISSING "$_oep_env")" ]] || export OLLAMA_PULL_MISSING=ask
      fi
      ollama_project_ensure_models "$_oep_mf" "$_oep_env" ${_oep_vars[@]+"${_oep_vars[@]}"} ) || _oep_rc=$?
    if [[ "$_oep_rc" -eq 4 && "$_oep_local" -eq 0 ]]; then
      print_error "No Ollama answers at $(_ollama_ep_shown_url "$_oep_url") (${_oep_var}): start it there, or remove ${_oep_var} to use this machine's Ollama." >&2
    elif [[ "$_oep_rc" -eq 4 ]]; then
      print_error "The host's Ollama does not answer. Start it, or install it: the host's Ollama is the default and preferred." >&2
      print_error "Only if Ollama cannot run on this host: set OLLAMA_RUNTIME=container in $(_ollama_ep_said "$(basename "$_oep_env")") to use the optional Ollama in Docker ($(basename "$_oep_override"))." >&2
    fi
    [[ "$_oep_rc" -eq 0 ]] || return "$_oep_rc"
    [[ "$_oep_mode" == "docker" ]] || return 0
    [[ -n "$_oep_net" ]] || _oep_net="$(_ollama_ep_compose_network "$_oep_compose" "$_oep_env")"
    ollama_endpoint_container_reach "$_oep_url" "$_oep_net"
    return
  fi

  # OLLAMA_RUNTIME=container: the owner chose the optional container.
  if [[ ! -f "$_oep_override" ]]; then
    print_error "OLLAMA_RUNTIME=container, and there is no $(_ollama_ep_said "$_oep_override"): this project has no optional Ollama container. Use the host's Ollama (delete OLLAMA_RUNTIME)." >&2
    return 9
  fi
  _oep_value="$(_ollama_ep_setting "$_oep_pvar" "$_oep_env" | tr -d ' \t\r')" || true
  if [[ -z "$_oep_value" ]]; then
    _oep_port=11435
  elif ! _oep_port="$(_ollama_ep_uint "$_oep_value")" || [[ "$_oep_port" -lt 1 || "$_oep_port" -gt 65535 ]]; then
    print_error "$_oep_pvar is not a port number (1 to 65535)." >&2
    return 9
  fi
  if [[ "$_oep_port" -eq 11434 ]]; then
    print_error "$_oep_pvar=11434 is the host Ollama's port: give the container another (default 11435)." >&2
    return 9
  fi
  export "$_oep_pvar=$_oep_port"
  export COMPOSE_FILE="${_oep_compose}${COMPOSE_PATH_SEPARATOR:-:}${_oep_override}"
  if [[ "$_oep_mode" == "docker" ]]; then
    _oep_url="${_oep_curl%/}${_oep_suffix}"
  else
    _oep_url="http://127.0.0.1:${_oep_port}${_oep_suffix}"
  fi
  export "$_oep_var=$_oep_url"

  if ! command -v docker >/dev/null 2>&1; then
    print_error "OLLAMA_RUNTIME=container needs Docker, and there is no docker command. Install Docker, or use the host's Ollama (delete OLLAMA_RUNTIME)." >&2
    return 10
  fi
  # External: compose does not create it, and `down -v` never removes it.
  # Created before the skip: compose needs it either way.
  if ! docker volume inspect "$_oep_vol" >/dev/null 2>&1 && ! docker volume create "$_oep_vol" >/dev/null; then
    print_error "Could not create the Docker volume $_oep_vol." >&2
    return 10
  fi
  if [[ -n "$_oep_skip" ]]; then
    print_info "${_oep_skip}=1: the Ollama check is skipped." >&2
    return 0
  fi
  if [[ "$_oep_nopull" -eq 1 ]]; then
    print_warning "OLLAMA_RUNTIME=container: the models are not checked. That container publishes no port and cannot pull; put the models in volume $_oep_vol." >&2
    return 0
  fi

  if declare -F docker_compose >/dev/null 2>&1; then _oep_dc=(docker_compose); else _oep_dc=(docker compose); fi
  [[ ! -f "$_oep_env" ]] || _oep_dc+=(--env-file "$_oep_env")
  if ! "${_oep_dc[@]}" up -d ollama; then
    print_error "The ollama container did not start (docker compose up -d ollama, with $(_ollama_ep_said "$(basename "$_oep_override")"))." >&2
    return 10
  fi
  _oep_i="$(_ollama_ep_uint "${OLLAMA_CONTAINER_WAIT_SECONDS:-60}" 2>/dev/null)" || _oep_i=60
  _oep_waited=$SECONDS
  until curl -fsS -m 2 "http://127.0.0.1:${_oep_port}/api/tags" >/dev/null 2>&1; do
    if (( SECONDS - _oep_waited >= _oep_i )); then
      print_error "The ollama container does not answer on 127.0.0.1:${_oep_port} after ${_oep_i} s (docker compose logs ollama)." >&2
      return 4
    fi
    sleep 1
  done
  ( export OLLAMA_URL_VARS=_OLLAMA_EP_PREPARE_URL _OLLAMA_EP_PREPARE_URL="$_oep_url" \
      OLLAMA_MODE=docker OLLAMA_PORT="$_oep_port" OLLAMA_HOST_PORT="$_oep_port"
    [[ -n "$(_ollama_ep_setting OLLAMA_PULL_MISSING "$_oep_env")" ]] || export OLLAMA_PULL_MISSING=ask
    ollama_project_ensure_models "$_oep_mf" "$_oep_env" ${_oep_vars[@]+"${_oep_vars[@]}"} )
}

# --- a model by type of work and tier of host --------------------------------
#
# A project names, per role, the type of work (general, reasoning, classify,
# extract, vision, embed, code, ...) and, optionally, a default model. The
# approved model for each type and tier of host is data shipped with this
# library (config/ollama_model_tiers.txt, generated). ai_model_resolve picks
# between that and the project's own model, asks once on a terminal, and
# remembers the answer in the project's .env.

# This library's root, found when the module is sourced: the data file is
# under it whether or not helpers.sh loaded the module.
_OLLAMA_EP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || _OLLAMA_EP_ROOT=""

# Usage: ollama_model_tiers_file; prints the path of the type x tier data
# file: OLLAMA_MODEL_TIERS_FILE, else config/ollama_model_tiers.txt here.
# Returns: 0.
# Output: stdout the path and a newline (the file may not exist).
ollama_model_tiers_file() {
  printf '%s\n' "${OLLAMA_MODEL_TIERS_FILE:-${_OLLAMA_EP_ROOT}/config/ollama_model_tiers.txt}"
}

# Usage: _ollama_ep_tiers_get <kind> <key>; prints the fields after
# "<kind> <key>" in the data file (the last such line wins), or nothing.
# Returns: 0 (also when the file or the line is missing).
# Output: stdout the fields, space-separated, and a newline; nothing when absent.
_ollama_ep_tiers_get() {
  local file
  file="$(ollama_model_tiers_file)"
  [[ -f "$file" ]] || return 0
  # A byte-order mark before the first line is dropped (bytes from the
  # environment, as in _ollama_ep_env_set).
  LC_ALL=C _OEP_BOM=$'\xef\xbb\xbf' awk -v k="${1:-}" -v n="${2:-}" '
    { sub(/\r$/, "") }
    NR == 1 && substr($0, 1, 3) == ENVIRON["_OEP_BOM"] { $0 = substr($0, 4) }
    $1 == k && $2 == n { line = ""; for (i = 3; i <= NF; i++) line = line (i > 3 ? " " : "") $i; found = line }
    END { if (found != "") print found }' "$file" 2>/dev/null || true
}

# Usage: _ollama_ep_tiers_has <kind> <key>; true when the data file has a
# "<kind> <key>" line, with or without fields after it.
# Returns: 0 present; 1 absent or no file.
_ollama_ep_tiers_has() {
  local file
  file="$(ollama_model_tiers_file)"
  [[ -f "$file" ]] || return 1
  LC_ALL=C _OEP_BOM=$'\xef\xbb\xbf' awk -v k="${1:-}" -v n="${2:-}" '
    { sub(/\r$/, "") }
    NR == 1 && substr($0, 1, 3) == ENVIRON["_OEP_BOM"] { $0 = substr($0, 4) }
    $1 == k && $2 == n { found = 1 }
    END { exit found ? 0 : 1 }' "$file" 2>/dev/null
}

# Usage: ollama_model_tier_types; prints every type the data file names, one
# per line, in file order.
# Returns: 0 (also when the file is missing).
# Output: stdout one type per line.
ollama_model_tier_types() {
  local file
  file="$(ollama_model_tiers_file)"
  [[ -f "$file" ]] || return 0
  LC_ALL=C _OEP_BOM=$'\xef\xbb\xbf' awk '{ sub(/\r$/, "") }
    NR == 1 && substr($0, 1, 3) == ENVIRON["_OEP_BOM"] { $0 = substr($0, 4) }
    $1 == "type" && NF >= 3 && !seen[$2]++ { print $2 }' "$file" 2>/dev/null || true
}

# Usage: ollama_host_tier; prints this host's tier: small, standard, large or
# xlarge. AI_MODEL_TIER names it instead of measuring (any case, spaces
# ignored). Otherwise memory and the largest GPU (ollama_machine_figures, so
# OLLAMA_BUDGET_MEM_TOTAL_BYTES and OLLAMA_BUDGET_GPU_LARGEST_BYTES state them)
# are compared with the data file's thresholds. Memory that cannot be read is
# standard, never a guessed tier.
# Returns: 0 printed; 2 no data file to measure against (AI_MODEL_TIER unset),
# or a threshold in it that is not a whole number;
# 3 AI_MODEL_TIER is not a tier.
# Output: stdout the tier and a newline; stderr errors.
ollama_host_tier() {
  local _oep_tier _oep_mem _oep_gpu _oep_small _oep_lram _oep_lvram _oep_xvram
  _oep_tier="$(printf '%s' "${AI_MODEL_TIER:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' \t\r')" || true
  if [[ -n "$_oep_tier" ]]; then
    if ! _ollama_ep_tier_rank "$_oep_tier" >/dev/null; then
      print_error "AI_MODEL_TIER is one of small, standard, large, xlarge; not '$(_ollama_ep_said "${AI_MODEL_TIER:-}")'" >&2
      return 3
    fi
    printf '%s\n' "$_oep_tier"
    return 0
  fi
  if [[ ! -f "$(ollama_model_tiers_file)" ]]; then
    print_error "No model tiers file at $(_ollama_ep_said "$(ollama_model_tiers_file)") (OLLAMA_MODEL_TIERS_FILE)." >&2
    return 2
  fi
  _oep_small="$(_ollama_ep_tiers_threshold small_below_ram_gb)" || return 2
  _oep_lram="$(_ollama_ep_tiers_threshold large_ram_gb)" || return 2
  _oep_lvram="$(_ollama_ep_tiers_threshold large_vram_gb)" || return 2
  _oep_xvram="$(_ollama_ep_tiers_threshold xlarge_vram_gb)" || return 2
  IFS=: read -r _oep_mem _oep_gpu <<<"$(ollama_machine_figures)"
  case "$(_ollama_ep_class_rank "$_oep_mem" "$_oep_gpu" "$_oep_small" "$_oep_lram" "$_oep_lvram" "$_oep_xvram")" in
    0) _oep_tier=small ;;
    2) _oep_tier=large ;;
    3) _oep_tier=xlarge ;;
    *) _oep_tier=standard ;;
  esac
  printf '%s\n' "$_oep_tier"
}

# Usage: _ollama_ep_tiers_threshold <key>; prints a threshold of the data
# file in whole GiB, or nothing when the file has no such line (it then never
# matches). A value that is not a whole number is an error: read as missing,
# it would measure every host as a lower tier without a word.
# Returns: 0; 1 the value is not a whole number.
# Output: stdout the number and a newline, or nothing; stderr the error.
_ollama_ep_tiers_threshold() {
  local raw
  raw="$(_ollama_ep_tiers_get threshold "${1:-}")"
  [[ -n "$raw" ]] || return 0
  if ! _ollama_ep_uint "$raw"; then
    print_error "The model tiers file $(_ollama_ep_said "$(ollama_model_tiers_file)") has threshold ${1:-} '$(_ollama_ep_said "$raw")', not a whole number of GiB." >&2
    return 1
  fi
}

# Usage: _ollama_ep_tiers_size <model>; prints the model's size line as
# "<class> <gpu GiB> <ram GiB or ->", or nothing when the file has none.
# Returns: 0; 1 the line is malformed (error on stderr).
_ollama_ep_tiers_size() {
  local raw class gpu ram extra
  raw="$(_ollama_ep_tiers_get size "${1:-}")"
  # "size <model>" with no fields is malformed, not absent.
  [[ -n "$raw" ]] || _ollama_ep_tiers_has size "${1:-}" || return 0
  read -r class gpu ram extra <<<"$raw"
  # Leading zeros removed: bash reads "019" as a bad octal number.
  gpu="$(_ollama_ep_uint "${gpu:-}")" || gpu="bad"
  [[ "${ram:-}" == - ]] || ram="$(_ollama_ep_uint "${ram:-}")" || ram="bad"
  if ! _ollama_ep_tier_rank "${class:-}" >/dev/null || [[ -n "$extra" || "$gpu" == bad || "$ram" == bad ]]; then
    print_error "The model tiers file $(_ollama_ep_said "$(ollama_model_tiers_file)") has 'size ${1:-} $(_ollama_ep_said "$raw")'; expected: size <model> <small|standard|large|xlarge> <GPU GiB> <memory GiB or ->." >&2
    return 1
  fi
  printf '%s %s %s\n' "$class" "$gpu" "$ram"
}

# Usage: ollama_tier_model <type> [tier]; prints the approved model for the
# type on that tier (default: ollama_host_tier).
# When the tier is measured (no tier argument, no AI_MODEL_TIER), a model with
# a size line must fit this host: its largest GPU at least <GPU GiB>, or memory
# at least <memory GiB> ("-": GPU only). A model that does not fit falls to
# the next lower tier's model for the type, until one fits or small is
# reached. A stated tier is used as stated, and so is the standard tier given
# when memory cannot be read.
# Returns: 0 printed; 2 a type the data file does not name, a type row
# without a valid model for the tier, a malformed size line, or a missing
# data file; 3 a bad AI_MODEL_TIER or tier argument.
# Output: stdout the model and a newline; stderr errors.
ollama_tier_model() {
  local _oep_type="${1:-}" _oep_tier="${2:-}" _oep_row _oep_rank _oep_model _oep_measured=0
  local _oep_size _oep_class _oep_gpu_need _oep_ram_need _oep_mem _oep_gpu
  _oep_type="$(printf '%s' "$_oep_type" | tr '[:upper:]' '[:lower:]')" || true
  if [[ ! -f "$(ollama_model_tiers_file)" ]]; then
    print_error "No model tiers file at $(_ollama_ep_said "$(ollama_model_tiers_file)") (OLLAMA_MODEL_TIERS_FILE)." >&2
    return 2
  fi
  if [[ -z "$_oep_tier" ]]; then
    [[ -n "$(printf '%s' "${AI_MODEL_TIER:-}" | tr -d ' \t\r')" ]] || _oep_measured=1
    _oep_tier="$(ollama_host_tier)" || return $?
  fi
  if [[ "$_oep_measured" -eq 1 ]]; then
    IFS=: read -r _oep_mem _oep_gpu <<<"$(ollama_machine_figures)"
    # Memory that cannot be read gives standard by rule, not by measure: no floor.
    [[ -n "$_oep_mem" ]] || _oep_measured=0
  fi
  if ! _oep_rank="$(_ollama_ep_tier_rank "$_oep_tier")"; then
    print_error "A tier is one of small, standard, large, xlarge; not '$(_ollama_ep_said "$_oep_tier")'" >&2
    return 3
  fi
  _oep_row=""
  [[ ! "$_oep_type" =~ ^[a-z][a-z0-9_-]*$ ]] || _oep_row="$(_ollama_ep_tiers_get type "$_oep_type")"
  if [[ -z "$_oep_row" ]]; then
    print_error "Unknown model type '$(_ollama_ep_said "$_oep_type")'. Known: $(ollama_model_tier_types | tr '\n' ' ' | sed 's/ $//')." >&2
    return 2
  fi
  while :; do
    _oep_model="$(printf '%s\n' "$_oep_row" | awk -v i=$((_oep_rank + 1)) '{ print $i }')" || _oep_model=""
    if [[ -z "$_oep_model" ]] || ! _ollama_ep_is_model "$_oep_model"; then
      print_error "The model tiers file has no valid $_oep_tier model for type $_oep_type." >&2
      return 2
    fi
    [[ "$_oep_measured" -eq 1 && "$_oep_rank" -gt 0 ]] || break
    _oep_size="$(_ollama_ep_tiers_size "$_oep_model")" || return 2
    [[ -n "$_oep_size" ]] || break
    read -r _oep_class _oep_gpu_need _oep_ram_need <<<"$_oep_size"
    [[ "${_oep_gpu:-0}" -lt "$_oep_gpu_need" ]] || break
    [[ "$_oep_ram_need" == - || "$_oep_mem" -lt "$_oep_ram_need" ]] || break
    _oep_rank=$((_oep_rank - 1))
    case "$_oep_rank" in 0) _oep_tier=small ;; 1) _oep_tier=standard ;; 2) _oep_tier=large ;; esac
  done
  printf '%s\n' "$_oep_model"
}

# Usage: _ollama_ep_env_set <file> <NAME> <value> [<NAME> <value>...]; sets
# each NAME=value in an env file in one write: an existing line is replaced in
# place (later duplicates of it dropped, an "export " kept), otherwise one is
# added. A symlink loop is refused. Other lines,
# comments and a byte-order mark are kept; in a file with Windows line ends the
# written lines get them too. The new content goes to a temporary file next to
# the target (a symlink is followed) that is then moved over it, so a reader
# never sees half a file and an interrupted run leaves the old one. A new file
# is created readable by its owner only, as a .env may hold secrets; an
# existing one keeps its mode.
# Two cases are written in place instead: the directory is not writable (the
# file is), or the file has more than one hard link (a move would split them).
# The full new content is built in a temporary file under TMPDIR (else /tmp) first, then
# copied over the target in one write and read back; the target keeps its
# inode, mode and owner, and every hard link sees the new content.
# Two runs writing the same file at once take turns (_ollama_ep_env_lock).
# Returns: 0 written; 1 a NAME is not a variable name, or the file could not be
# created, read or written.
# Output: none on stdout.
_ollama_ep_env_set() {
  local lock rc=0
  lock="$(_ollama_ep_env_lock "${1:-}")" || lock=""
  _ollama_ep_env_set_now "$@" || rc=$?
  _ollama_ep_env_unlock "$lock"
  return "$rc"
}

# Usage: _ollama_ep_env_lock <file>; takes a lock for writing the file, so two
# runs storing answers at once (two ./start, two roles) do not each write the
# file as they read it and drop the other's lines. The lock is a symlink whose
# target is the owner's pid ($$, the script's shell): ln -s creates it with its
# owner in one step, on every system (no flock on macOS). It sits next to the
# file's real path, or under TMPDIR (else /tmp), keyed on that real path, when
# the directory is not writable. A lock whose owner is gone (a run killed by
# INT, TERM or KILL) is taken over at once; no trap is set, so a caller's own
# traps are left alone. A live owner is waited on for up to about 30 seconds,
# then the write goes ahead without the lock.
# Returns: 0 locked; 1 no lock (the caller writes without one).
# Output: stdout the lock path, for _ollama_ep_env_unlock.
_ollama_ep_env_lock() {
  local target="${1:-}" hops=0 link dir real lock tries=0 d owner moved
  [[ -n "$target" ]] || return 1
  while [[ -L "$target" && "$hops" -le 40 ]]; do
    hops=$((hops + 1))
    link="$(readlink "$target")" || return 1
    case "$link" in /*) target="$link" ;; *) target="$(dirname "$target")/$link" ;; esac
  done
  dir="$(dirname "$target")"
  # No such directory: nothing can be written there, so nothing to lock.
  real="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  [[ -n "$real" ]] || return 1
  if [[ -w "$real" ]]; then
    lock="$real/.$(basename "$target").lock"
  else
    lock=""
    for d in "${TMPDIR:-}" /tmp; do
      [[ -n "$d" && -d "$d" && -w "$d" ]] || continue
      # The same file by any path (relative, absolute, a symlinked directory)
      # is the same lock.
      lock="${d%/}/.env-lock.$(printf '%s' "$real/$(basename "$target")" | cksum | awk '{ print $1 }')"
      break
    done
    [[ -n "$lock" ]] || return 1
  fi
  while :; do
    # Something else at that path (a file, a directory) is not ours to remove,
    # and ln -s onto a directory would make a link inside it, not a lock.
    [[ -L "$lock" || ! -e "$lock" ]] || return 1
    ! ln -s "$$" "$lock" 2>/dev/null || break
    owner="$(readlink "$lock" 2>/dev/null)" || owner=""
    if [[ -n "$owner" && ! "$owner" =~ ^[0-9]+$ ]] || { [[ "$owner" =~ ^[0-9]+$ ]] && ! _ollama_ep_pid_alive "$owner"; }; then
      # The owner is gone. Two waiters may both see that: each renames the
      # lock to a name of its own (rename is atomic, so one of them gets it),
      # and only removes what it got if that is still the dead owner's lock.
      moved="$lock.$$.$RANDOM"
      if mv "$lock" "$moved" 2>/dev/null; then
        if [[ "$(readlink "$moved" 2>/dev/null)" == "$owner" ]]; then
          rm -f "$moved"
        else
          # A live lock taken by mistake: put it back unless a new one is there.
          ln -s "$(readlink "$moved" 2>/dev/null)" "$lock" 2>/dev/null || true
          rm -f "$moved"
        fi
      fi
      continue
    fi
    tries=$((tries + 1))
    [[ "$tries" -lt 300 ]] || return 1
    sleep 0.1
  done
  printf '%s\n' "$lock"
}

# Usage: _ollama_ep_pid_alive <pid>; true while that process exists, also when
# another user owns it (kill -0 then fails with EPERM): /proc, else ps -p.
# Returns: 0 alive; 1 gone. Output: none.
_ollama_ep_pid_alive() {
  kill -0 "${1:-}" 2>/dev/null && return 0
  [[ ! -d "/proc/${1:-}" ]] || return 0
  ps -p "${1:-}" >/dev/null 2>&1
}

# Usage: _ollama_ep_env_unlock <lock>; removes the lock if this shell still
# owns it. Returns: 0. Output: none.
_ollama_ep_env_unlock() {
  [[ -n "${1:-}" ]] || return 0
  [[ "$(readlink "$1" 2>/dev/null)" != "$$" ]] || rm -f "$1" 2>/dev/null || true
  return 0
}

# Usage: _ollama_ep_env_set_now <file> <NAME> <value>...; the write of
# _ollama_ep_env_set, without the lock. Same returns and output.
_ollama_ep_env_set_now() {
  local file="${1:-}" target link hops dir tmpf oldf src inplace names="" values=""
  shift || return 1
  [[ -n "$file" && $# -ge 2 && $(($# % 2)) -eq 0 ]] || return 1
  while [[ $# -ge 2 ]]; do
    _ollama_ep_is_name "$1" || return 1
    case "$2" in *$'\n'*|*$'\r'*) return 1 ;; esac
    names="${names}${1}"$'\n'
    values="${values}${2}"$'\n'
    shift 2
  done
  target="$file" hops=0
  while [[ -L "$target" ]]; do
    # A symlink loop (a -> b -> a) would otherwise never end.
    hops=$((hops + 1))
    [[ "$hops" -le 40 ]] || return 1
    link="$(readlink "$target")" || return 1
    case "$link" in
      /*) target="$link" ;;
      *)  target="$(dirname "$target")/$link" ;;
    esac
  done
  dir="$(dirname "$target")"
  inplace=0
  if [[ -f "$target" ]] && { [[ ! -w "$dir" ]] || [[ "$(_ollama_ep_links "$target")" -gt 1 ]]; }; then
    [[ -w "$target" ]] || return 1
    inplace=1
    tmpf="$(_ollama_ep_tmpfile .env-set)" || return 1
  else
    tmpf="$(mktemp "$dir/.$(basename "$target").XXXXXX" 2>/dev/null)" || return 1
  fi
  if [[ "$inplace" -eq 1 ]]; then
    # The temporary file stays mode 600 (it may hold secrets, under TMPDIR);
    # the target keeps its own mode, as it is not replaced.
    src="$target"
  elif [[ -e "$target" ]]; then
    # cp -p first: the temporary file takes the target's mode.
    cp -p "$target" "$tmpf" 2>/dev/null || { rm -f "$tmpf"; return 1; }
    src="$target"
  else
    src=/dev/null
    chmod 600 "$tmpf" || { rm -f "$tmpf"; return 1; }
    : >"$tmpf"
  fi
  # ENVIRON, not -v: awk -v would read backslashes in a value as escapes.
  # LC_ALL=C: bytes, so the byte-order mark is matched the same by every awk.
  if ! LC_ALL=C _OEP_NAMES="$names" _OEP_VALUES="$values" _OEP_BOM=$'\xef\xbb\xbf' awk '
      BEGIN {
        n = split(ENVIRON["_OEP_NAMES"], name, "\n") - 1
        split(ENVIRON["_OEP_VALUES"], val, "\n")
        # From the environment: sprintf("%c", 239) is not that byte in every awk.
        bom = ENVIRON["_OEP_BOM"]; eol = ""
      }
      {
        line = $0; prefix = ""
        if (NR == 1 && substr(line, 1, 3) == bom) { prefix = bom; line = substr(line, 4) }
        cr = (line ~ /\r$/) ? "\r" : ""
        if (cr != "") eol = "\r"
        for (i = 1; i <= n; i++) {
          if (line ~ ("^[ \t]*(export[ \t]+)?" name[i] "[ \t]*=")) {
            # An "export " the line had is kept.
            ex = (line ~ /^[ \t]*export[ \t]/) ? "export " : ""
            # Line 1 (the only one with a prefix) is never a duplicate.
            if (!(i in done)) print prefix ex name[i] "=" val[i] cr
            done[i] = 1
            next
          }
        }
        print $0
      }
      END { for (i = 1; i <= n; i++) if (!(i in done)) print name[i] "=" val[i] eol }' \
      "$src" >"$tmpf" 2>/dev/null </dev/null; then
    rm -f "$tmpf"
    return 1
  fi
  if [[ "$inplace" -eq 1 ]]; then
    # One write of the whole content, then read back. A failed write puts the
    # old content back, as far as the file can still be written.
    oldf="$(_ollama_ep_tmpfile .env-old)" || { rm -f "$tmpf"; return 1; }
    cat "$target" >"$oldf" 2>/dev/null || { rm -f "$tmpf" "$oldf"; return 1; }
    if ! cat "$tmpf" >"$target" 2>/dev/null || ! cmp -s "$tmpf" "$target"; then
      cat "$oldf" >"$target" 2>/dev/null || true
      rm -f "$tmpf" "$oldf"
      return 1
    fi
    rm -f "$tmpf" "$oldf"
    return 0
  fi
  mv -f "$tmpf" "$target" || { rm -f "$tmpf"; return 1; }
}

# Usage: _ollama_ep_tmpfile <prefix>; creates an empty mode-600 file under
# TMPDIR, or under /tmp when TMPDIR is unset or cannot be written.
# Returns: 0 created; 1 neither place could be written.
# Output: stdout the path; nothing on stderr.
_ollama_ep_tmpfile() {
  local d
  for d in "${TMPDIR:-}" /tmp; do
    [[ -n "$d" ]] || continue
    mktemp "${d%/}/${1:-.tmp}.XXXXXX" 2>/dev/null && return 0
  done
  return 1
}

# Usage: _ollama_ep_links <file>; prints the file's hard link count (GNU or BSD
# stat), 1 when it cannot be read.
# Returns: 0.
# Output: stdout the count.
_ollama_ep_links() {
  local n
  n="$(stat -c %h "${1:-}" 2>/dev/null || stat -f %l "${1:-}" 2>/dev/null)" || n=""
  [[ "$n" =~ ^[0-9]+$ ]] || n=1
  printf '%s\n' "$n"
}

# Usage: _ollama_ep_same_model <a> <b>; the same model however it is written:
# case, and an omitted :latest.
# Returns: 0 the same; 1 different.
# Output: none.
_ollama_ep_same_model() {
  [[ "$(ollama_model_tagged "${1:-}" | tr '[:upper:]' '[:lower:]')" == "$(ollama_model_tagged "${2:-}" | tr '[:upper:]' '[:lower:]')" ]]
}

# Usage: _ollama_ep_in_ci; true in CI: CI set to anything but false or 0, or
# GITHUB_ACTIONS set. Nobody is asked there, even with a terminal attached.
# Returns: 0 in CI; 1 not.
# Output: none.
_ollama_ep_in_ci() {
  local ci
  [[ -z "${GITHUB_ACTIONS:-}" ]] || return 0
  ci="$(printf '%s' "${CI:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' \t\r')" || ci=""
  [[ -n "$ci" && "$ci" != "false" && "$ci" != "0" ]]
}

# Usage: _ollama_ep_env_private <file>; true when an answer may be stored in
# the file: it is outside a git work tree, or git ignores it. A tracked or
# not-ignored .env would carry one machine's answer into the repository.
# Returns: 0 may store; 1 inside a work tree and not ignored.
# Output: none.
_ollama_ep_env_private() {
  local file="${1:-}" dir
  command -v git >/dev/null 2>&1 || return 0
  dir="$(dirname "$file")"
  [[ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] || return 0
  git -C "$dir" check-ignore -q -- "$(basename "$file")" 2>/dev/null
}

# Usage: ai_model_resolve <type> <ollama_url> [env_file] [NAME] [default_model]
#
# Prints, on stdout and alone, the model the project uses for one role. All
# messages go to stderr, so `model="$(ai_model_resolve ...)"` captures it.
#
#   Y  the approved model for <type> on this host's tier (ollama_tier_model;
#      a lower tier's when this host is under the model's size-line floor)
#   X  the project's model: NAME from the environment, else from env_file,
#      else default_model
#
# - NAME_CHOICE in env_file with no NAME_CHOICE_FOR line: a choice set by
#   hand. It is used as it is, never asked about, whatever X and Y are.
# - X empty or the same as Y: Y.
# - X differs, on a terminal (stdin and stderr; never in CI): asks "pull X or
#   use Y?" once. The answer is stored in env_file as NAME_CHOICE=<model>,
#   with NAME_CHOICE_FOR=<Y> and NAME_CHOICE_PROJECT=<X> (the two models it
#   was asked about), in one write. It is asked again when Y changes, or X
#   changes (an answer of X no longer matches X; an answer of Y no longer
#   matches NAME_CHOICE_PROJECT). An answer of Y stored before
#   NAME_CHOICE_PROJECT existed is asked about once more on a terminal, then
#   stored with it; with no terminal it is used as before.
#   With no NAME the keys are AI_MODEL_<TYPE>_CHOICE(_FOR, _PROJECT); with no
#   env_file nothing is stored. Nor is it stored, with a warning, when env_file is in a
#   git work tree and not git-ignored.
# - X differs, no terminal: Y if that Ollama has it, else X if it has it, else
#   stop (12), naming both and pulling nothing.
# The chosen model is then pulled if missing, after the disk and memory check
# (ollama_endpoint_ensure_models). OLLAMA_PULL_MISSING: 1 pulls without asking,
# 0 never pulls, ask (the default here) asks on a terminal and pulls nothing
# without one. A model chosen on the terminal is pulled without a second
# question unless OLLAMA_PULL_MISSING=0. In CI, ask pulls nothing. No model
# is ever removed.
#
# The tier of an Ollama on another machine is not this machine's: there it is
# AI_MODEL_TIER, else measured from OLLAMA_BUDGET_MEM_TOTAL_BYTES if stated,
# else standard.
#
# Returns:
#   0    a model was chosen and that Ollama has it
#   1-8  as ollama_endpoint_ensure_models (4: no Ollama answers; 5: missing
#        and not pulled under OLLAMA_PULL_MISSING)
#   10   bad arguments: more than five, unknown type, NAME not a variable
#        name, a model that is not a model reference, no data file, a
#        threshold in it that is not a whole number or a malformed size line, env_file
#        not readable or not writable
#   11   AI_MODEL_TIER is not small, standard, large or xlarge
#   12   no terminal, the two differ, and that Ollama has neither
# Output: stdout the model and a newline; stderr the question, progress and errors.
# A subshell on purpose: the variables it sets stay inside.
# shellcheck disable=SC2030,SC2031
ai_model_resolve() (
  # NAME is read before any local exists: a caller's variable named like one
  # of the locals below (or IFS) would otherwise be shadowed by it.
  if [[ -n "${4:-}" ]] && _ollama_ep_is_name "$4"; then _OEP_X_ENV="${!4-}"; else _OEP_X_ENV=""; fi
  local IFS=$' \t\n'
  local _oep_type="${1:-}" _oep_url="${2:-}" _oep_env="${3:-}" _oep_name="${4:-}" _oep_default="${5:-}"
  local _oep_tier _oep_y _oep_x _oep_key _oep_choice _oep_for _oep_was _oep_valid _oep_can _oep_pick="" _oep_dir _oep_present
  local _oep_asked=0 _oep_listed=0 _oep_answer _oep_tries _oep_status=0 _oep_shown _oep_pm _oep_xsrc="your env"
  _oep_url="${_oep_url%/}"
  if [[ -z "$_oep_type" || -z "$_oep_url" ]]; then
    print_error "ai_model_resolve needs a model type and an Ollama address." >&2
    exit 10
  fi
  if [[ $# -gt 5 ]]; then
    print_error "ai_model_resolve takes at most 5 arguments (type, address, env file, NAME, default model); got $#." >&2
    exit 10
  fi
  if [[ -n "$_oep_name" ]] && ! _ollama_ep_is_name "$_oep_name"; then
    print_error "Not a variable name: $(_ollama_ep_said "$_oep_name")" >&2
    exit 10
  fi
  if [[ -n "$_oep_env" && -e "$_oep_env" && ! -r "$_oep_env" ]]; then
    print_error "Cannot read $(_ollama_ep_said "$_oep_env")." >&2
    exit 10
  fi
  _oep_shown="$(_ollama_ep_shown_url "$_oep_url")"

  # Another machine's Ollama: its tier is not this machine's.
  ollama_endpoint_is_local "$_oep_url" || _ollama_ep_remote_tier
  _oep_tier="$(ollama_host_tier)" || { _oep_status=$?; [[ "$_oep_status" -eq 3 ]] && exit 11; exit 10; }
  # No tier argument: a measured tier also checks the model's size line.
  _oep_y="$(ollama_tier_model "$_oep_type")" || exit 10
  # Under a model's floor the pick is a lower tier's; messages name that tier.
  while [[ "$_oep_tier" != small && "$(ollama_tier_model "$_oep_type" "$_oep_tier" 2>/dev/null)" != "$_oep_y" ]]; do
    case "$_oep_tier" in xlarge) _oep_tier=large ;; large) _oep_tier=standard ;; *) _oep_tier=small ;; esac
  done

  _oep_x=""
  if [[ -n "$_oep_name" ]]; then
    _oep_x="$(printf '%s' "$_OEP_X_ENV" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" || true
    [[ -n "$_oep_x" || -z "$_oep_env" ]] || _oep_x="$(ollama_models_file_get "$_oep_env" "$_oep_name")"
  fi
  if [[ -z "$_oep_x" ]]; then
    _oep_x="$(printf '%s' "$_oep_default" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    _oep_xsrc="project default"
  fi
  if [[ -n "$_oep_x" ]] && ! _ollama_ep_is_model "$_oep_x"; then
    print_error "Not a model reference: $(_ollama_ep_shown "$_oep_x")" >&2
    exit 10
  fi

  if [[ -n "$_oep_name" ]]; then
    _oep_key="${_oep_name}_CHOICE"
  else
    _oep_key="AI_MODEL_$(printf '%s' "$_oep_type" | tr '[:lower:]-' '[:upper:]_')_CHOICE"
  fi

  _oep_choice="" _oep_for="" _oep_was=""
  if [[ -n "$_oep_env" ]]; then
    _oep_choice="$(ollama_models_file_get "$_oep_env" "$_oep_key")"
    _oep_for="$(ollama_models_file_get "$_oep_env" "${_oep_key}_FOR")"
    _oep_was="$(ollama_models_file_get "$_oep_env" "${_oep_key}_PROJECT")"
  fi
  if [[ -n "$_oep_choice" && -z "$_oep_for" ]]; then
    if ! _ollama_ep_is_model "$_oep_choice"; then
      print_error "$_oep_key in $(_ollama_ep_said "$_oep_env") is not a model reference: $(_ollama_ep_shown "$_oep_choice")" >&2
      exit 10
    fi
    _oep_pick="$_oep_choice"
    print_info "Using $_oep_pick for $_oep_type, set by hand ($_oep_key in $(_ollama_ep_said "$_oep_env"))." >&2
  elif [[ -z "$_oep_x" ]] || _ollama_ep_same_model "$_oep_x" "$_oep_y"; then
    _oep_pick="$_oep_y"
  else
    # Whether the stored answer still holds: 1 yes, 0 no, 2 it is the tier's
    # model and the file predates ${_oep_key}_PROJECT (unknown project model).
    _oep_valid=0
    if [[ -n "$_oep_choice" && -n "$_oep_for" ]] && _ollama_ep_same_model "$_oep_for" "$_oep_y"; then
      if _ollama_ep_same_model "$_oep_choice" "$_oep_x"; then
        _oep_valid=1
      elif _ollama_ep_same_model "$_oep_choice" "$_oep_y"; then
        if [[ -z "$_oep_was" ]]; then
          _oep_valid=2
        elif _ollama_ep_same_model "$_oep_was" "$_oep_x"; then
          _oep_valid=1
        fi
      fi
    fi
    _oep_can=0
    if ! _ollama_ep_in_ci && _ollama_ep_can_ask; then _oep_can=1; fi
    if [[ "$_oep_valid" -eq 1 || ( "$_oep_valid" -eq 2 && "$_oep_can" -eq 0 ) ]]; then
      _oep_pick="$_oep_choice"
      print_info "Using $_oep_pick for $_oep_type, as answered before ($_oep_key in $(_ollama_ep_said "$_oep_env"))." >&2
    elif [[ "$_oep_can" -eq 1 ]]; then
      printf 'Model for %s: %s has %s; the approved model for this host'"'"'s tier (%s) is %s.\n  1) pull %s (%s)\n  2) use %s (approved for this tier)\nChoose [1/2, default 2]: ' \
        "$_oep_type" "$_oep_xsrc" "$_oep_x" "$_oep_tier" "$_oep_y" "$_oep_x" "$_oep_xsrc" "$_oep_y" >&2
      # 1 or 2; empty or end of input is the default, 2. Anything else is
      # asked again, up to three times, then the default.
      _oep_tries=0
      while [[ -z "$_oep_pick" ]]; do
        IFS= read -r _oep_answer || _oep_answer=""
        case "$(printf '%s' "$_oep_answer" | tr '[:upper:]' '[:lower:]' | tr -d ' \t\r')" in
          1) _oep_pick="$_oep_x" ;;
          2|"") _oep_pick="$_oep_y" ;;
          *)
            _oep_tries=$((_oep_tries + 1))
            if [[ "$_oep_tries" -ge 3 ]]; then
              _oep_pick="$_oep_y"
              print_warning "No valid answer: using $_oep_y." >&2
            else
              printf 'Please answer 1 or 2 [default 2]: ' >&2
            fi
            ;;
        esac
      done
      _oep_asked=1
      if [[ -n "$_oep_env" ]] && ! _ollama_ep_env_private "$_oep_env"; then
        print_warning "Not stored: $(_ollama_ep_said "$_oep_env") is in a git work tree and not git-ignored. Add it to .gitignore to be asked only once." >&2
      elif [[ -n "$_oep_env" ]]; then
        # One write: a choice stored without its _FOR line would read as set by hand.
        if ! _ollama_ep_env_set "$_oep_env" "$_oep_key" "$_oep_pick" "${_oep_key}_FOR" "$_oep_y" "${_oep_key}_PROJECT" "$_oep_x"; then
          print_error "Could not store the answer in $(_ollama_ep_said "$_oep_env")." >&2
          exit 10
        fi
        print_info "Stored $_oep_key=$_oep_pick in $(_ollama_ep_said "$_oep_env"); asked again if the approved model or the project's model changes." >&2
      fi
    else
      if ! _oep_present="$(ollama_endpoint_models "$_oep_url")"; then
        print_error "No Ollama answers at ${_oep_shown}." >&2
        exit 4
      fi
      # Either pick is already there: no second listing, nothing to pull.
      _oep_listed=1
      if [[ -z "$(ollama_models_missing "$(ollama_model_tagged "$_oep_y")" "$_oep_present")" ]]; then
        _oep_pick="$_oep_y"
      elif [[ -z "$(ollama_models_missing "$(ollama_model_tagged "$_oep_x")" "$_oep_present")" ]]; then
        _oep_pick="$_oep_x"
      else
        print_error "No terminal to ask, and the Ollama at ${_oep_shown} has neither ${_oep_x} (${_oep_xsrc}) nor ${_oep_y} (approved for the ${_oep_tier} tier) for ${_oep_type}. Nothing was pulled. Pull one of them, or run this from a terminal." >&2
        exit 12
      fi
    fi
  fi

  if ollama_endpoint_is_local "$_oep_url"; then _oep_dir="$(ollama_models_dir)"; else _oep_dir="/"; fi
  if [[ "$_oep_listed" -eq 1 ]]; then
    : # Present in the listing just read.
  elif [[ "$_oep_asked" -eq 1 && "$(_ollama_ep_pull_mode 2>/dev/null)" != "off" ]]; then
    # The person has just chosen this model: no second question.
    OLLAMA_PULL_MISSING=1 ollama_endpoint_ensure_models "$_oep_url" "$_oep_dir" "$_oep_pick" || _oep_status=$?
  else
    # Read by name: a direct read pairs, for shellcheck, with every export of it
    # in the other subshell functions here.
    _oep_pm=OLLAMA_PULL_MISSING
    _oep_pm="$(printf '%s' "${!_oep_pm:-}" | tr -d ' \t\r')" || true
    # In CI nobody answers a pull question, even with a terminal attached.
    if _ollama_ep_in_ci && [[ "$(OLLAMA_PULL_MISSING="${_oep_pm:-ask}" _ollama_ep_pull_mode 2>/dev/null)" == "ask" ]]; then
      _oep_pm=0
    fi
    OLLAMA_PULL_MISSING="${_oep_pm:-ask}" ollama_endpoint_ensure_models "$_oep_url" "$_oep_dir" "$_oep_pick" || _oep_status=$?
  fi
  [[ "$_oep_status" -eq 0 ]] || exit "$_oep_status"
  printf '%s\n' "$_oep_pick"
)
