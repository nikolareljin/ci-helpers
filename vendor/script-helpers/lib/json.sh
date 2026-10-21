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

# Usage: json_get_field BODY KEY; prints a top-level scalar field of a JSON
# object, or nothing when it is absent. Returns 1 only for a KEY that is not
# a plain word.
json_get_field() {
  local body="${1:-}" key="${2:-}"
  # A word, nothing else: the fallback interpolates the key into a grep
  # pattern, and a JSON field name here is never more than [A-Za-z0-9_].
  [[ "$key" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$body" | python3 -c '
import json, sys
key = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
v = d.get(key) if isinstance(d, dict) else None
if v is None or isinstance(v, (dict, list)):
    sys.exit(0)
# Non-strings in JSON spelling: true and false, not True and False.
print(v if isinstance(v, str) else json.dumps(v))
' "$key"
    return 0
  fi
  # No python3: a string field out of compact or pretty JSON. The quoted key
  # keeps "api_version" from matching "version". A missing field prints
  # nothing and still exits 0: grep's miss must not surface through a
  # caller's set -o pipefail.
  printf '%s' "$body" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' || true
  return 0
}
