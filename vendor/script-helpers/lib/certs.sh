#!/usr/bin/env bash
# Certificates and trust store helpers

# Usage: create_self_signed_certs <cert_dir> <domain>; creates key/cert if missing.
create_self_signed_certs() {
  local cert_dir="$1" domain="$2"
  local cert_file="$cert_dir/$domain.crt" key_file="$cert_dir/$domain.key" openssl_config_file="$cert_dir/openssl.cnf"
  local subj="/C=US/ST=State/L=City/O=Organization/OU=OrgUnit/CN=$domain"
  if [[ ! -d "$cert_dir" ]]; then
    run_with_optional_sudo true mkdir -p "$cert_dir"
    run_with_optional_sudo true chmod 755 "$cert_dir"
  fi
  if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
    run_with_optional_sudo true openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$key_file" -out "$cert_file" -subj "$subj" \
      -config "$openssl_config_file"
  fi
  run_with_optional_sudo true chmod 644 "$cert_file"
  run_with_optional_sudo true chmod 600 "$key_file"
}

# Usage: add_cert_to_trust_store <cert_file> [friendly_name]; installs into trust store.
add_cert_to_trust_store() {
  local cert_file="$1" friendly_name="${2:-script-helpers}"
  if [[ -z "$cert_file" || ! -f "$cert_file" ]]; then
    print_error "Certificate file not found: $cert_file"
    return 1
  fi
  case "$(get_os)" in
    linux)
      if command -v update-ca-certificates >/dev/null 2>&1; then
        local dest="/usr/local/share/ca-certificates/${friendly_name}.crt"
        print_info "Installing cert to $dest (requires sudo)"
        run_with_optional_sudo true cp "$cert_file" "$dest"
        run_with_optional_sudo true chmod 644 "$dest"
        run_with_optional_sudo true update-ca-certificates
        return $?
      fi
      if command -v update-ca-trust >/dev/null 2>&1; then
        local dest2="/etc/pki/ca-trust/source/anchors/${friendly_name}.crt"
        print_info "Installing cert to $dest2 (requires sudo)"
        run_with_optional_sudo true cp "$cert_file" "$dest2"
        run_with_optional_sudo true chmod 644 "$dest2"
        run_with_optional_sudo true update-ca-trust extract
        return $?
      fi
      if command -v trust >/dev/null 2>&1; then
        print_info "Installing cert using p11-kit trust (may require sudo)"
        run_with_optional_sudo true trust anchor "$cert_file" || trust anchor "$cert_file"
        return $?
      fi
      print_warning "Could not auto-install cert. Install $cert_file manually into system trust."
      ;;
    mac)
      if command -v security >/dev/null 2>&1; then
        print_info "Adding trusted cert to System keychain (requires sudo)"
        run_with_optional_sudo true security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$cert_file"
        return $?
      fi
      print_warning "Could not auto-install cert. Double-click $cert_file and set 'Always Trust'."
      ;;
    windows)
      print_warning "Trust store automation not supported in this shell. Use PowerShell as Administrator:"
      echo "  Import-Certificate -FilePath '$cert_file' -CertStoreLocation Cert:\\LocalMachine\\Root"
      ;;
    *)
      print_warning "Unsupported OS for trust-store automation."
      ;;
  esac
  return 1
}
