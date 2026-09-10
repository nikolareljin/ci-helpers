#!/usr/bin/env bash
# help.sh - Utilities for extracting and displaying script header documentation.
#
# Provides functions to parse and render help/usage information from standardized
# header comments in shell scripts. Supports multi-line fields and consistent output
# for script name, description, usage, parameters, examples, and more.

# The metadata fields this module understands, in render order.
_HELP_META_FIELDS="name description author created version usage parameters example exit_codes date creator"

# Usage: _help__pattern_for <field>; prints the header regex for that field.
_help__pattern_for() {
  case "$1" in
    name)        echo '^# SCRIPT:[[:space:]]*(.*)' ;;
    description) echo '^# DESCRIPTION:[[:space:]]*(.*)' ;;
    author)      echo '^# AUTHOR:[[:space:]]*(.*)' ;;
    created)     echo '^# CREATED:[[:space:]]*(.*)' ;;
    version)     echo '^# VERSION:[[:space:]]*(.*)' ;;
    usage)       echo '^# USAGE:[[:space:]]*(.*)' ;;
    parameters)  echo '^# PARAMETERS:[[:space:]]*(.*)' ;;
    example)     echo '^# EXAMPLE:[[:space:]]*(.*)' ;;
    exit_codes)  echo '^# EXIT_CODES:[[:space:]]*(.*)' ;;
    date)        echo '^# DATE:[[:space:]]*(.*)' ;;
    creator)     echo '^# CREATOR:[[:space:]]*(.*)' ;;
    *)           return 1 ;;
  esac
}

# Usage: _help__is_multiline <field>; success when the field may span lines.
_help__is_multiline() {
  case "$1" in
    parameters|usage|example|exit_codes) return 0 ;;
    *) return 1 ;;
  esac
}

# Usage: _help__meta_get <prefix> <field>; prints one collected metadata value.
_help__meta_get() {
  local _ref="${1}_${2}"
  printf '%s' "${!_ref:-}"
}

# Usage: display_help [script_file]; renders concise help.
display_help() {
  export SHLIB_HELP_SHOWN=true
  _help__render "concise" "${1:-$0}"
}

# Usage: print_help [script_file]; renders full help.
print_help() {
  export SHLIB_HELP_SHOWN=true
  _help__render "full" "${1:-$0}"
}

# Usage: show_help [script_file]; renders minimal help.
show_help() {
  export SHLIB_HELP_SHOWN=true
  _help__render "minimal" "${1:-${BASH_SOURCE[1]:-$0}}"
}

# Usage: _help__print_inline <color> <label> <value>; internal inline renderer.
_help__print_inline() {
  local color="$1" label="$2" value="$3"
  local line="${label}: ${value}"
  if declare -F print_color >/dev/null 2>&1; then
    print_color "$color" "$line"
  else
    echo "$line"
  fi
}

# Usage: _help__print_block <color> <label> <value>; internal block renderer.
_help__print_block() {
  local color="$1" label="$2" value="$3"
  if [[ -z "$value" ]]; then
    return 0
  fi
  if declare -F print_color >/dev/null 2>&1; then
    print_color "$color" "${label}:"
  else
    echo "${label}:"
  fi
  while IFS= read -r line; do
    echo "  $line"
  done <<< "$value"
}

# Usage: _help__render <mode> <script_file>; internal help rendering engine.
_help__render() {
  local mode="$1" script_file="$2"
  if [[ ! -f "$script_file" ]]; then
    log_error "Cannot find script file to read header: $script_file"
    return 1
  fi

  local pfx="_shlib_help_meta"
  get_script_metadata "$script_file" "$pfx"

  local m_name m_description m_usage m_parameters m_param_lines
  local m_example m_author m_created m_version m_exit_codes m_date m_creator
  m_name="$(_help__meta_get "$pfx" name)"
  m_description="$(_help__meta_get "$pfx" description)"
  m_usage="$(_help__meta_get "$pfx" usage)"
  m_parameters="$(_help__meta_get "$pfx" parameters)"
  m_param_lines="$(_help__meta_get "$pfx" param_lines)"
  m_example="$(_help__meta_get "$pfx" example)"
  m_author="$(_help__meta_get "$pfx" author)"
  m_created="$(_help__meta_get "$pfx" created)"
  m_version="$(_help__meta_get "$pfx" version)"
  m_exit_codes="$(_help__meta_get "$pfx" exit_codes)"
  m_date="$(_help__meta_get "$pfx" date)"
  m_creator="$(_help__meta_get "$pfx" creator)"

  local usage_text="$m_usage"
  if [[ -z "$usage_text" ]]; then
    usage_text="$(basename "$script_file") [OPTIONS]"
  fi

  if [[ "$mode" == "full" ]]; then
    _help__print_inline "cyan" "Script" "${m_name:-$(basename "$script_file")}"
  elif [[ -n "$m_name" ]]; then
    _help__print_inline "green" "Script Name" "$m_name"
  fi

  if [[ "$usage_text" == *$'\n'* ]]; then
    _help__print_block "green" "Usage" "$usage_text"
  else
    _help__print_inline "green" "Usage" "$usage_text"
  fi
  _help__print_block "white" "Description" "$m_description"

  if [[ -n "$m_parameters" ]]; then
    local params="${m_param_lines:-$m_parameters}"
    _help__print_block "white" "Parameters" "$params"
  fi

  if [[ "$mode" == "concise" || "$mode" == "minimal" ]]; then
    _help__print_block "yellow" "Example" "$m_example"
  fi

  if [[ "$mode" == "full" ]]; then
    _help__print_inline "white" "Author" "$m_author"
    _help__print_inline "white" "Created" "$m_created"
    _help__print_inline "white" "Version" "$m_version"
  fi

  if [[ "$mode" == "minimal" ]]; then
    _help__print_block "white" "Exit Codes" "$m_exit_codes"
    _help__print_inline "white" "Date" "$m_date"
    _help__print_inline "white" "Version" "$m_version"
    _help__print_inline "white" "Creator" "$m_creator"
  fi
  show_usage "$script_file"
}

# Usage: get_script_metadata <script_file> <prefix>
#
# Extracts script metadata from header comments into a set of shell variables
# named "<prefix>_<field>" -- e.g. get_script_metadata ./x.sh meta sets
# meta_name, meta_usage, meta_parameters, ... plus meta_param_lines. Read them
# back with indirect expansion:  ref="meta_usage"; echo "${!ref}"
#
# The second argument used to be the name of an associative array, filled
# through a nameref. Both are bash 4.3+ features, which made every --help path
# in this library dead on the bash 3.2 that macOS ships. A name prefix plus
# `printf -v` needs nothing newer than bash 3.1 and no eval.
get_script_metadata() {
  # Defaulted, not bare: under `set -u` a bare "$2" aborts the caller on the
  # expansion itself, before this function can return the documented exit 2.
  local script_file="${1:-}"
  local prefix="${2:-}"
  local line="" key current_field="" param_lines="" ref pattern
  local in_header=true saw_header_key=false

  # The prefix becomes half a variable name, so an empty or malformed one turns
  # every assignment below into a `printf: not a valid identifier` error and
  # leaves the caller with a half-filled set of variables to diagnose. An empty
  # prefix is worse than an error: it silently writes _name, _usage and so on.
  if [[ -z "$script_file" ]]; then
    local msg0="get_script_metadata: needs a script file"
    if declare -F log_error >/dev/null 2>&1; then log_error "$msg0"; else echo "$msg0" >&2; fi
    return 2
  fi
  if [[ -z "$prefix" || ! "$prefix" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    local msg="get_script_metadata: prefix must be a valid shell variable name, got '${prefix}'"
    if declare -F log_error >/dev/null 2>&1; then log_error "$msg"; else echo "$msg" >&2; fi
    return 2
  fi
  # Checked here rather than left to the redirection on the loop below. An
  # unreadable path there fails inside this file, so `set -e` aborts the caller
  # citing lib/help.sh and a line number instead of the path it passed in, and
  # a directory is worse still: the redirection succeeds, `read` fails without
  # assigning, and the loop condition then aborts on an unbound variable.
  # display_help guards this already; get_script_metadata is public API and is
  # called directly.
  if [[ ! -f "$script_file" || ! -r "$script_file" ]]; then
    local msg1="get_script_metadata: cannot read script file: $script_file"
    if declare -F log_error >/dev/null 2>&1; then log_error "$msg1"; else echo "$msg1" >&2; fi
    return 2
  fi

  for key in $_HELP_META_FIELDS; do
    printf -v "${prefix}_${key}" '%s' ""
  done
  printf -v "${prefix}_param_lines" '%s' ""

  while IFS= read -r line || [[ -n "$line" ]]; do
    if $in_header; then
      if [[ $line =~ ^#!/ ]]; then
        continue
      fi
      if [[ ! $line =~ ^# ]]; then
        if $saw_header_key; then
          break
        fi
        continue
      fi
      if [[ $line =~ ^#[-]{3,}$ ]]; then
        break
      fi
    fi
    local matched=0
    for key in $_HELP_META_FIELDS; do
      pattern="$(_help__pattern_for "$key")"
      if [[ $line =~ $pattern ]]; then
        matched=1
        current_field=""
        saw_header_key=true
        printf -v "${prefix}_${key}" '%s' "${BASH_REMATCH[1]}"
        if _help__is_multiline "$key"; then
          current_field="$key"
        fi
        break
      fi
    done
    if (( ! matched )); then
      # If inside a multiline field, accumulate lines
      if [[ -n "$current_field" ]]; then
        if [[ $line =~ ^#([[:space:]])(.*) ]]; then
          # Continuation line (starts with # and one space or tab). The class,
          # not `\t`: bash's ERE has no \t escape, so a tab-indented header
          # silently lost every continuation line. One character wide, because
          # the rest of the indentation is rendered as written.

          ref="${prefix}_${current_field}"
          printf -v "$ref" '%s' "${!ref}"$'\n'"${BASH_REMATCH[2]}"
        elif [[ $line =~ ^#[-]{3,}$ ]]; then
          # Separator ends header block
          current_field=""
          break
        elif [[ $line =~ ^# ]]; then
          # New header, stop accumulating
          current_field=""
        fi
      fi
    fi
    # For param_lines (indented lines under PARAMETERS only)
    if [[ "$current_field" == "parameters" ]] && [[ $line =~ ^#([[:space:]])(.*) ]]; then
      local param_line="${BASH_REMATCH[2]}"
      if [[ "$param_line" == PARAMETERS:* ]]; then
        continue
      fi
      param_lines+="${param_line}"$'\n'
    fi
  done < "$script_file"
  printf -v "${prefix}_param_lines" '%s' "${param_lines%$'\n'}"
}

# Generic usage printer and common arg parser.
show_usage() {
  local script_name; script_name="$(basename "${1:-$0}")"
  cat << EOF
Usage: $script_name [OPTIONS]

Common Options:
  -h, --help     Show this help message
  -v, --verbose  Enable verbose output
  -d, --debug    Enable debug output

Environment Variables:
  DEBUG=true     Enable debug logging

EOF
}

# Usage: parse_common_args <args...>; handles -h/-v/-d for scripts.
parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        export SHLIB_HELP_SHOWN=true
        if declare -F show_help >/dev/null 2>&1 && [[ -n "${SHLIB_CALLER_SCRIPT:-}" && -f "$SHLIB_CALLER_SCRIPT" ]]; then
          show_help "$SHLIB_CALLER_SCRIPT"
        else
          show_usage "$0"
        fi
        exit 0
        ;;
      -v|--verbose) export VERBOSE=true;;
      -d|--debug) export DEBUG=true;;
      *) break;;
    esac
    shift
  done
}
