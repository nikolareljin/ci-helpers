#!/usr/bin/env bash
# /etc/hosts helpers

# Usage: add_to_etc_hosts <domain> <ip>; appends entry if missing.
#
# HOSTS_FILE overrides the target, which is what makes the "already present"
# test above verifiable: it used to be wrong on macOS and nothing could tell,
# because the only way to exercise it was to edit the real /etc/hosts as root.
add_to_etc_hosts() {
  # Defaulted so a caller under `set -u` gets the error below rather than an
  # abort on the expansion itself.
  local domain="${1:-}" ip_address="${2:-}"
  if [[ -z "$domain" || -z "$ip_address" ]]; then
    print_error "add_to_etc_hosts: need <domain> <ip>"
    return 2
  fi
  local hosts_file="${HOSTS_FILE:-/etc/hosts}"
  # An exact token comparison rather than a grep pattern. Two reasons, and the
  # first one shipped broken: \s is a GNU extension that BSD grep does not
  # reject -- it simply never matches -- so on macOS this always concluded
  # "absent" and appended a duplicate line on every single call. And a domain
  # interpolated into a regex brings its own dots with it, where "." matches any
  # character: "demo.local" would then be found in a file that only holds
  # "demoXlocal", and the entry would silently never be added.
  local line found=0
  local -a parts=()
  if [[ -f "$hosts_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      # In /etc/hosts everything from the first # is a comment, wherever it
      # sits on the line. Stripping it handles an indented comment line and an
      # inline one alike; a comment-only line simply leaves no tokens.
      line="${line%%#*}"
      [[ -n "${line//[[:space:]]/}" ]] || continue
      # read -a rather than word-splitting $line, which would also glob.
      read -r -a parts <<< "$line"
      local tok
      for tok in "${parts[@]+"${parts[@]}"}"; do
        [[ "$tok" == "$domain" ]] && { found=1; break 2; }
      done
    done < "$hosts_file"
  fi

  if [[ "$found" -eq 0 ]]; then
    if [[ -w "$hosts_file" ]]; then
      printf '%s    %s\n' "$ip_address" "$domain" >> "$hosts_file"
    else
      echo "$ip_address    $domain" | sudo tee -a "$hosts_file" >/dev/null
    fi
    print_success "Added $domain to $hosts_file"
  else
    print_info "$domain is already present in $hosts_file"
  fi
}
