#!/usr/bin/env bash
# /etc/hosts helpers

add_to_etc_hosts() {
  local domain="$1" ip_address="$2"
  if ! grep -qE "(^|\s)${domain}(\s|$)" /etc/hosts; then
    echo "$ip_address    $domain" | sudo tee -a /etc/hosts >/dev/null
    print_success "Added $domain to /etc/hosts"
  else
    print_info "$domain is already present in /etc/hosts"
  fi
}

