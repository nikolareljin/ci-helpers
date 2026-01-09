#!/usr/bin/env bash
# Clipboard helpers

# Usage: copy_to_clipboard <text>; returns non-zero if no clipboard tool found.
copy_to_clipboard() {
  local text="$1"
  if command -v xclip &>/dev/null; then
    printf "%s" "$text" | xclip -selection clipboard
    print_info "Copied to clipboard."
  elif command -v pbcopy &>/dev/null; then
    printf "%s" "$text" | pbcopy
    print_info "Copied to clipboard."
  else
    print_error "No clipboard utility found (xclip/pbcopy)."
    return 1
  fi
}
