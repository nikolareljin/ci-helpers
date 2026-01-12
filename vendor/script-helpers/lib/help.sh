#!/usr/bin/env bash
# help.sh - Utilities for extracting and displaying script header documentation.
#
# Provides functions to parse and render help/usage information from standardized
# header comments in shell scripts. Supports multi-line fields and consistent output
# for script name, description, usage, parameters, examples, and more.

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

  declare -A meta
  get_script_metadata "$script_file" meta

  local usage_text="${meta[usage]}"
  if [[ -z "$usage_text" ]]; then
    usage_text="$(basename "$script_file") [OPTIONS]"
  fi

  if [[ "$mode" == "full" ]]; then
    _help__print_inline "cyan" "Script" "${meta[name]:-$(basename "$script_file")}"
  elif [[ -n "${meta[name]}" ]]; then
    _help__print_inline "green" "Script Name" "${meta[name]}"
  fi

  if [[ "$usage_text" == *$'\n'* ]]; then
    _help__print_block "green" "Usage" "$usage_text"
  else
    _help__print_inline "green" "Usage" "$usage_text"
  fi
  _help__print_block "white" "Description" "${meta[description]}"

  if [[ -n "${meta[parameters]}" ]]; then
    local params="${meta[param_lines]:-${meta[parameters]}}"
    _help__print_block "white" "Parameters" "$params"
  fi

  if [[ "$mode" == "concise" || "$mode" == "minimal" ]]; then
    _help__print_block "yellow" "Example" "${meta[example]}"
  fi

  if [[ "$mode" == "full" ]]; then
    _help__print_inline "white" "Author" "${meta[author]}"
    _help__print_inline "white" "Created" "${meta[created]}"
    _help__print_inline "white" "Version" "${meta[version]}"
  fi

  if [[ "$mode" == "minimal" ]]; then
    _help__print_block "white" "Exit Codes" "${meta[exit_codes]}"
    _help__print_inline "white" "Date" "${meta[date]}"
    _help__print_inline "white" "Version" "${meta[version]}"
    _help__print_inline "white" "Creator" "${meta[creator]}"
  fi
  show_usage "$script_file"
}

# Shared logic: extract script metadata from header comments into an associative array
get_script_metadata() {
  local script_file="$1"
  local -n _meta="$2"
  local line key current_field="" param_lines="" last_multiline_field=""
  local in_header=true saw_header_key=false
  declare -A map=(
    [name]="^# SCRIPT:[[:space:]]*(.*)"
    [description]="^# DESCRIPTION:[[:space:]]*(.*)"
    [author]="^# AUTHOR:[[:space:]]*(.*)"
    [created]="^# CREATED:[[:space:]]*(.*)"
    [version]="^# VERSION:[[:space:]]*(.*)"
    [usage]="^# USAGE:[[:space:]]*(.*)"
    [parameters]="^# PARAMETERS:[[:space:]]*(.*)"
    [example]="^# EXAMPLE:[[:space:]]*(.*)"
    [exit_codes]="^# EXIT_CODES:[[:space:]]*(.*)"
    [date]="^# DATE:[[:space:]]*(.*)"
    [creator]="^# CREATOR:[[:space:]]*(.*)"
  )
  # Fields that can be multi-line
  local -A multiline_fields=([parameters]=1 [usage]=1 [example]=1 [exit_codes]=1)
  for k in "${!map[@]}"; do _meta[$k]=""; done
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
    for key in "${!map[@]}"; do
      if [[ $line =~ ${map[$key]} ]]; then
        matched=1
        current_field=""
        saw_header_key=true
        if [[ -n "${multiline_fields[$key]:-}" ]]; then
          _meta[$key]="${BASH_REMATCH[1]}"
          current_field="$key"
          last_multiline_field="$key"
        else
          _meta[$key]="${BASH_REMATCH[1]}"
        fi
        break
      fi
    done
    if (( ! matched )); then
      # If inside a multiline field, accumulate lines
      if [[ -n "$current_field" ]]; then
        if [[ $line =~ ^#( |\t)(.*) ]]; then
          # Continuation line (starts with # and space/tab)
          _meta[$current_field]+=$'\n'"${BASH_REMATCH[2]}"
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
    if [[ "$current_field" == "parameters" ]] && [[ $line =~ ^#( |\t)(.*) ]]; then
      local param_line="${BASH_REMATCH[2]}"
      if [[ "$param_line" == PARAMETERS:* ]]; then
        continue
      fi
      param_lines+="${param_line}"$'\n'
    fi
  done < "$script_file"
  _meta[param_lines]="${param_lines%$'\n'}"
}

# Generic usage printer and common arg parser (network-scan style)
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
