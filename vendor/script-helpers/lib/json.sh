#!/usr/bin/env bash
# JSON helpers

json_escape() {
  local input="$1"
  input=${input//\\/\\\\}
  input=${input//"/\\"}
  input=${input//$'\n'/\\n}
  input=${input//$'\r'/\\r}
  input=${input//$'\t'/\\t}
  echo "$input"
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

format_md_response() {
  local response="$1"
  if [[ "$response" == *"\`\`\`"* ]]; then
    echo "$response" | sed "s/\`\`\`//g"
  else
    echo "$response"
  fi
}

