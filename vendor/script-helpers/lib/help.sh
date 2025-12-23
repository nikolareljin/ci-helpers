#!/usr/bin/env bash
# Help renderers from script header comments

display_help() {
  local script="${1:-$0}"
  local script_name script_description script_usage script_parameters script_example
  script_name=$(grep -m1 "^# SCRIPT:" "$script" | cut -d ":" -f 2- | sed 's/^ *//g')
  script_description=$(grep -m1 "^# DESCRIPTION:" "$script" | cut -d ":" -f 2- | sed 's/^ *//g')
  script_usage=$(grep -m1 "^# USAGE:" "$script" | cut -d ":" -f 2- | sed 's/^ *//g')
  script_parameters=$(awk '/^# PARAMETERS:/ {flag=1; next} /^# EXAMPLE/ {flag=0} flag {print substr($0, 3)}' "$script" | sed 's/^ *//g')
  script_example=$(grep -m1 "^# EXAMPLE:" "$script" | cut -d ":" -f 2- | sed 's/^ *//g')

  print_color "$GREEN" "Script Name:" " $script_name"
  print_color "$GREEN" "Description:" " $script_description"
  print_color "$GREEN" "Usage:" " $script_usage"
  if [[ -n "$script_parameters" ]]; then
    print_color "$WHITE" "Parameters:" "$script_parameters"
  fi
  print_color "$YELLOW" "Example:" " $script_example"
  print_color "$WHITE" "----------------------------------------------------"
}

print_help() {
  local script_file="${1:-$0}"
  local script_name description author created version usage parameters param_lines
  script_name=$(grep -m1 '^# SCRIPT:' "$script_file" | sed 's/^# SCRIPT:[[:space:]]*//')
  description=$(grep -m1 '^# DESCRIPTION:' "$script_file" | sed 's/^# DESCRIPTION:[[:space:]]*//')
  author=$(grep -m1 '^# AUTHOR:' "$script_file" | sed 's/^# AUTHOR:[[:space:]]*//')
  created=$(grep -m1 '^# CREATED:' "$script_file" | sed 's/^# CREATED:[[:space:]]*//')
  version=$(grep -m1 '^# VERSION:' "$script_file" | sed 's/^# VERSION:[[:space:]]*//')
  usage=$(grep -m1 '^# USAGE:' "$script_file" | sed 's/^# USAGE:[[:space:]]*//')
  parameters=$(grep -m1 '^# PARAMETERS:' "$script_file" | sed 's/^# PARAMETERS:[[:space:]]*//')
  param_lines=$(grep '^#   ' "$script_file" | sed 's/^#   //')
  print_color gray "----------------------------------------"
  print_color cyan "Script: $script_name"
  print_color white "Description: $description"
  print_color white "Author: $author"
  print_color white "Created: $created"
  print_color white "Version: $version"
  print_color white "Usage: $usage"
  if [[ -n "$parameters" ]]; then
    echo "Parameters:"
    echo "$param_lines" | while IFS= read -r line; do echo "  $line"; done
  fi
  print_color gray "----------------------------------------"
}

show_help() {
  local script_file="${1:-${BASH_SOURCE[1]:-$0}}"
  if [[ ! -f "$script_file" ]]; then
    log_error "Cannot find script file to read header: $script_file"
    return 1
  fi
  local description parameters example exit_codes date version creator line
  while IFS= read -r line; do
    if [[ $line =~ ^#\ DESCRIPTION:\ (.*) ]]; then description="${BASH_REMATCH[1]}"; fi
    if [[ $line =~ ^#\ PARAMETERS:\ (.*) ]]; then parameters="${BASH_REMATCH[1]}"; fi
    if [[ $line =~ ^#\ EXAMPLE:\ (.*) ]]; then example="${BASH_REMATCH[1]}"; fi
    if [[ $line =~ ^#\ EXIT_CODES:\ (.*) ]]; then exit_codes="${BASH_REMATCH[1]}"; fi
    if [[ $line =~ ^#\ DATE:\ (.*) ]]; then date="${BASH_REMATCH[1]}"; fi
    if [[ $line =~ ^#\ VERSION:\ (.*) ]]; then version="${BASH_REMATCH[1]}"; fi
    if [[ $line =~ ^#\ CREATOR:\ (.*) ]]; then creator="${BASH_REMATCH[1]}"; fi
  done < "$script_file"
  echo "Usage: $(basename "$script_file") [OPTIONS]"
  echo
  [[ -n "$description" ]] && { echo "Description:"; echo "  $description"; echo; }
  [[ -n "$parameters" ]] && { echo "Parameters:"; echo "  $parameters"; echo; }
  [[ -n "$example" ]] && { echo "Example:"; echo "  $example"; echo; }
  [[ -n "$exit_codes" ]] && { echo "Exit Codes:"; echo "  $exit_codes"; echo; }
  [[ -n "$date" ]] && echo "Date: $date"
  [[ -n "$version" ]] && echo "Version: $version"
  [[ -n "$creator" ]] && echo "Creator: $creator"
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

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) show_usage "$0"; exit 0;;
      -v|--verbose) export VERBOSE=true;;
      -d|--debug) export DEBUG=true;;
      *) break;;
    esac
    shift
  done
}
