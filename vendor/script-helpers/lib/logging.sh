#!/usr/bin/env bash
# Logging and color helpers. Accepts both ANSI code constants and color name strings.
# shellcheck disable=SC2034

# ANSI color codes (both long and short names for compatibility)
COLOR_RED="\033[31m";      RED="\033[0;31m"
COLOR_GREEN="\033[32m";    GREEN="\033[0;32m"
COLOR_YELLOW="\033[33m";   YELLOW="\033[0;33m"; BOLD_YELLOW="\033[1;33m"
COLOR_BLUE="\033[34m";     BLUE="\033[0;34m"
COLOR_CYAN="\033[36m";     CYAN="\033[0;36m"
COLOR_MAGENTA="\033[35m";  MAGENTA="\033[0;35m"
COLOR_WHITE="\033[37m";    WHITE="\033[0;37m"
COLOR_GREY="\033[90m";     GRAY="\033[0;90m"; GREY="\033[0;90m"
COLOR_BOLD="\033[1m"
COLOR_UNDERLINE="\033[4m"
COLOR_RESET="\033[0m";     NC="\033[0m"

# Usage: _shlib__color_code_from_name <name>; maps color names to ANSI codes.
_shlib__color_code_from_name() {
  case "$1" in
    red) echo -e "$RED";;
    green) echo -e "$GREEN";;
    yellow) echo -e "$YELLOW";;
    blue) echo -e "$BLUE";;
    cyan) echo -e "$CYAN";;
    magenta) echo -e "$MAGENTA";;
    white) echo -e "$WHITE";;
    grey|gray) echo -e "$GREY";;
    bold) echo -e "$COLOR_BOLD";;
    underline) echo -e "$COLOR_UNDERLINE";;
    *) echo -e "$COLOR_RESET";;
  esac
}

# Print the text in color; supports both named colors and raw ANSI codes.
# Usage: print_color <color|ansi> <text> [text2] [color2]
# Returns: 0.
# Output: stdout the colored text (one or two lines).
print_color() {
  local color="$1" text="$2" text2="${3:-}" color2="${4:-}"
  local start_color end_color

  # If looks like an ANSI code, use as-is; otherwise map names
  if [[ "$color" == $'\033'* ]]; then
    start_color="$color"
  else
    start_color="$(_shlib__color_code_from_name "$color")"
  fi

  if [[ -n "$color2" ]]; then
    if [[ "$color2" == $'\033'* ]]; then
      end_color="$color2"
    else
      end_color="$(_shlib__color_code_from_name "$color2")"
    fi
  else
    end_color="$start_color"
  fi

  if [[ -z "$text2" ]]; then
    echo -e "${start_color}${text}${COLOR_RESET}"
  else
    echo -e "${start_color}${text}${COLOR_RESET}\n${end_color}${text2}${COLOR_RESET}"
  fi
}

# Usage: print_info <message...>; info output helper.
# Returns: 0.
# Output: stdout "[Info]: <message>".
print_info()    { print_color "$WHITE"   "[Info]: $*"; }
# Usage: print_error <message...>; error output helper (audible bell).
# Returns: 0.
# Output: stdout "[Error!]: <message>" and a bell (stdout, not stderr).
print_error()   { print_color "$RED"     "[Error!]: $*"; echo -e "\a"; }
# Usage: print_success <message...>; success output helper.
# Returns: 0.
# Output: stdout "Success [OK]: <message>".
print_success() { print_color "$GREEN"   "Success [OK]: $*"; }
# Usage: print_warning <message...>; warning output helper (audible bell).
# Returns: 0.
# Output: stdout "[Warning!]: <message>" and a bell.
print_warning() { print_color "$YELLOW"  "[Warning!]: $*"; echo -e "\a"; }
# Usage: print_line; prints a horizontal divider.
# Returns: 0.
# Output: stdout the divider.
print_line()    { echo "----------------------------------------"; }

# Bracketed, coloured, stderr-only levels: [INFO], [WARN], [ERROR], [DEBUG].
# Kept for callers written against that older shape.
# Usage: log_info <message...>; stderr info log.
# Returns: 0.
# Output: stderr "[INFO] <message>".
log_info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
# Usage: log_warn <message...>; stderr warning log.
# Returns: 0.
# Output: stderr "[WARN] <message>".
log_warn()  { echo -e "${BOLD_YELLOW:-$YELLOW}[WARN]${NC} $*" >&2; }
# Usage: log_error <message...>; stderr error log.
# Returns: 0.
# Output: stderr "[ERROR] <message>".
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
# Usage: log_debug <message...>; stderr debug log when DEBUG=true.
# Returns: 0.
# Output: stderr "[DEBUG] <message>" when DEBUG=true; else nothing.
log_debug() {
  if [[ "${DEBUG:-}" == "true" ]]; then
    echo -e "${BLUE}[DEBUG]${NC} $*" >&2
  fi
  return 0
}

# Compatibility wrapper for iso-forge's `print` function
# Usage: print <color> <message...>; prints the message in color, then "....".
# Returns: 0.
# Output: stdout the colored message and "....".
print() {
  local color="$1"; shift
  local message="$*"
  print_color "$color" "$message"
  # Echo '....' like original implementation to indicate progress
  echo "...."
}

# Additional compatibility helpers used by some scripts
# Usage: print_red <message...>; color helper.
# Returns: 0.
# Output: stdout the colored text.
print_red()    { print_color "$RED"    "$*"; }
# Usage: print_green <message...>; color helper.
# Returns: 0.
# Output: stdout the colored text.
print_green()  { print_color "$GREEN"  "$*"; }
# Usage: print_yellow <message...>; color helper.
# Returns: 0.
# Output: stdout the colored text.
print_yellow() { print_color "$YELLOW" "$*"; }
# Usage: print_blue <message...>; color helper.
# Returns: 0.
# Output: stdout the colored text.
print_blue()   { print_color "$BLUE"   "$*"; }
