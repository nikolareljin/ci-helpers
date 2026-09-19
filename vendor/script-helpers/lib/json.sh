#!/usr/bin/env bash
# JSON helpers

# Usage: json_escape <string>; escapes for safe JSON output.
json_escape() {
  local input="${1-}"
  input=${input//\\/\\\\}
  # Escaped quote in the pattern: written as //"/ the quote opened a quoted
  # word instead, and double quotes went out unescaped (invalid JSON).
  input=${input//\"/\\\"}
  input=${input//$'\n'/\\n}
  input=${input//$'\r'/\\r}
  input=${input//$'\t'/\\t}
  # Every other control character is invalid raw inside a JSON string. A bash
  # string cannot hold NUL, so 0x01-0x1F is the whole remaining set.
  if [[ "$input" == *[[:cntrl:]]* ]]; then
    local i c rep
    for (( i = 1; i < 32; i++ )); do
      case "$i" in 9|10|13) continue ;; esac
      # The format string is the point: printf turns \ooo into that byte.
      # shellcheck disable=SC2059
      c="$(printf "\\$(printf '%03o' "$i")")"
      [[ "$input" == *"$c"* ]] || continue
      rep="\\u00$(printf '%02x' "$i")"
      input=${input//"$c"/"$rep"}
    done
  fi
  # printf, not echo: echo swallowed an input of -n or -e whole.
  printf '%s\n' "$input"
}

# Assumes the JSON has a .response field; exits non-zero if invalid JSON
format_response() {
  local response="$1"
  if [[ -z "$response" ]]; then
    print_error "No response received."
    return 1
  fi
  if ! echo "$response" | jq . >/dev/null 2>&1; then
    print_error "Response is not valid JSON."
    return 1
  fi
  echo "$response" | jq -r '.response'
}

# Usage: format_md_response <string>; strips fenced code blocks if present.
format_md_response() {
  local response="$1"
  if [[ "$response" == *"\`\`\`"* ]]; then
    echo "${response//\`\`\`/}"
  else
    echo "$response"
  fi
}
