#!/usr/bin/env bash
# SCRIPT: signing_secrets.sh
# DESCRIPTION: Set the package-signing secrets and variables (the names in
#              ci-helpers docs/packaging.md) on a list of GitHub repositories,
#              or check which repositories miss which name. Values go to gh on
#              stdin, never on a command line, and are never printed. The
#              windows group sets the names of ci-helpers docs/windows-signing.md.
# USAGE: ./signing_secrets.sh --repos <owner/a,owner/b> --group <gpg|apple|windows> [--group ...] [options] [--check|--dry-run]
# PARAMETERS:
#   --repos <list>            Comma-separated owner/name list (required).
#   --group <gpg|apple|windows>
#                             Names to set or check; repeat for more (required).
#   --gpg-key <fingerprint>   gpg: key to export (40 hex characters).
#                             Passphrase: GPG_PASSPHRASE env, else prompted.
#   --ppa <owner/name=ppa:id/name>
#                             gpg: set PPA_TARGET on that repository; repeat.
#   --launchpad-ssh-key <file>
#                             gpg: set LAUNCHPAD_SSH_PRIVATE_KEY (sftp only).
#   --apple-p12 <file>        apple: Developer ID Application .p12.
#   --apple-identity <text>   apple: "Developer ID Application: Name (TEAMID)".
#   --apple-team <id>         apple: 10-character team ID.
#   --apple-id <email>        apple: Apple ID for notarization.
#                             Passwords: APPLE_CERTIFICATE_PASSWORD and
#                             APPLE_APP_PASSWORD env, else prompted.
#                             The .p12 must open with its password and hold
#                             the --apple-identity certificate, in date, and
#                             its private key (openssl). Warns when the
#                             certificate expires within 30 days.
#   --skip-p12-check          apple: store the .p12 without opening it
#                             (where openssl is not installed).
#   --windows-pfx <file>      windows: Authenticode code-signing .pfx.
#                             Password: --windows-password-file, else
#                             WINDOWS_CERTIFICATE_PASSWORD env, else prompted.
#                             The .pfx must open with its password and hold
#                             a private key and its certificate with the
#                             code-signing EKU (1.3.6.1.5.5.7.3.3), in date
#                             (openssl). Warns within 30 days of expiry.
#   --windows-password-file <file>
#                             windows: read the .pfx password from this file;
#                             a trailing LF or CRLF is dropped.
#   --skip-pfx-check          windows: store the .pfx without opening it.
#   --check                   Report missing names per repository; exit 1 if any.
#   --dry-run                 Print the names that would be set; set nothing.
#   -h, --help                Show help.
# EXIT_CODES:
#   0  Every name was set, or --check found every name on every repository.
#   1  --check found a missing name or could not list a repository, or gh
#      could not set a name.
#   2  Bad arguments, a missing tool (gh, gpg, openssl), a key not in the
#      keyring, a passphrase that does not unlock it, an --apple-identity
#      that does not end in the --apple-team, a .p12 that does not open with
#      APPLE_CERTIFICATE_PASSWORD, lacks the --apple-identity certificate or
#      its private key, or holds it expired, a .pfx that does not open
#      with its password, has no private key with an in-date code-signing
#      certificate, or an empty value; nothing was set.
#   130, 143  Interrupted (INT, TERM); the scratch directory is removed.
# EXAMPLE:
#   ./signing_secrets.sh --repos me/tool --group gpg --gpg-key <FPR> --ppa me/tool=ppa:me/tool
#   ./signing_secrets.sh --repos me/a,me/b --group gpg --group apple --check
#   ./signing_secrets.sh --repos me/app --group windows --windows-pfx sign.pfx --windows-password-file pw.txt
# ----------------------------------------------------
set -euo pipefail
# Lists are split on spaces unquoted; never let a "*" in an argument glob.
set -f

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { display_help; }

GPG_SECRETS="GPG_PRIVATE_KEY GPG_PASSPHRASE"
GPG_VARS="GPG_KEY_ID"
APPLE_SECRETS="APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_TEAM_ID APPLE_ID APPLE_APP_PASSWORD"
APPLE_VARS="APPLE_SIGNING_ENABLED"
WINDOWS_SECRETS="WINDOWS_CERTIFICATE WINDOWS_CERTIFICATE_PASSWORD"

repos_csv=""
groups=""
gpg_key=""
ppa_map=""
lp_ssh_key=""
apple_p12=""
apple_identity=""
apple_team=""
apple_id=""
mode="set"
skip_p12_check=0
windows_pfx=""
windows_pw_file=""
skip_pfx_check=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repos|--group|--gpg-key|--ppa|--launchpad-ssh-key|--apple-p12|--apple-identity|--apple-team|--apple-id|--windows-pfx|--windows-password-file)
      if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
        log_error "$1 needs a value"
        exit 2
      fi
      ;;
  esac
  case "$1" in
    --repos) repos_csv="${2:-}"; shift 2;;
    --group) groups="${groups} ${2:-}"; shift 2;;
    --gpg-key) gpg_key="${2:-}"; shift 2;;
    --ppa) ppa_map="${ppa_map} ${2:-}"; shift 2;;
    --launchpad-ssh-key) lp_ssh_key="${2:-}"; shift 2;;
    --apple-p12) apple_p12="${2:-}"; shift 2;;
    --apple-identity) apple_identity="${2:-}"; shift 2;;
    --apple-team) apple_team="${2:-}"; shift 2;;
    --apple-id) apple_id="${2:-}"; shift 2;;
    --skip-p12-check) skip_p12_check=1; shift;;
    --windows-pfx) windows_pfx="${2:-}"; shift 2;;
    --windows-password-file) windows_pw_file="${2:-}"; shift 2;;
    --skip-pfx-check) skip_pfx_check=1; shift;;
    --check) mode="check"; shift;;
    --dry-run) mode="dry-run"; shift;;
    -h|--help) usage; exit 0;;
    *) log_error "Unknown argument: $1"; usage; exit 2;;
  esac
done

has_group() { case " ${groups} " in *" $1 "*) return 0;; esac; return 1; }

if [[ -z "$repos_csv" ]] || [[ -z "${groups// /}" ]]; then
  log_error "--repos and --group are required"
  usage
  exit 2
fi
for g in $groups; do
  case "$g" in
    gpg|apple|windows) ;;
    *) log_error "--group must be gpg, apple or windows, got '$g'"; exit 2;;
  esac
done
repos=""
for r in ${repos_csv//,/ }; do
  if [[ ! "$r" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    log_error "Repository '$r' is not owner/name"
    exit 2
  fi
  case " ${repos} " in
    *" ${r} "*) log_error "Repository '$r' is listed twice"; exit 2;;
  esac
  repos="${repos} ${r}"
done
if [[ -z "$repos" ]]; then
  log_error "--repos names no repository"
  exit 2
fi
# An option for a group that was not asked for would be ignored silently.
if ! has_group gpg && [[ -n "${gpg_key}${ppa_map}${lp_ssh_key}" ]]; then
  log_error "--gpg-key, --ppa and --launchpad-ssh-key need --group gpg"
  exit 2
fi
if ! has_group apple && { [[ -n "${apple_p12}${apple_identity}${apple_team}${apple_id}" ]] || [[ "$skip_p12_check" -eq 1 ]]; }; then
  log_error "--apple-* options and --skip-p12-check need --group apple"
  exit 2
fi
if ! has_group windows && { [[ -n "${windows_pfx}${windows_pw_file}" ]] || [[ "$skip_pfx_check" -eq 1 ]]; }; then
  log_error "--windows-* options and --skip-pfx-check need --group windows"
  exit 2
fi
for m in $ppa_map; do
  if [[ ! "$m" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+=ppa:[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$ ]]; then
    log_error "--ppa '$m' is not owner/name=ppa:<id>/<name>"
    exit 2
  fi
  case " ${repos} " in
    *" ${m%%=*} "*) ;;
    *) log_error "--ppa names ${m%%=*}, which is not in --repos"; exit 2;;
  esac
  case " ${ppa_seen:-} " in
    *" ${m%%=*} "*) log_error "--ppa names ${m%%=*} twice"; exit 2;;
  esac
  ppa_seen="${ppa_seen:-} ${m%%=*}"
done

# Names expected on one repository, one per line: "secret NAME" or "variable NAME".
expected_names() {
  local repo="$1" n
  if has_group gpg; then
    for n in $GPG_SECRETS; do echo "secret $n"; done
    for n in $GPG_VARS; do echo "variable $n"; done
    for m in $ppa_map; do
      [[ "${m%%=*}" == "$repo" ]] && echo "variable PPA_TARGET"
    done
    [[ -n "$lp_ssh_key" ]] && echo "secret LAUNCHPAD_SSH_PRIVATE_KEY"
  fi
  if has_group apple; then
    for n in $APPLE_SECRETS; do echo "secret $n"; done
    for n in $APPLE_VARS; do echo "variable $n"; done
  fi
  if has_group windows; then
    for n in $WINDOWS_SECRETS; do echo "secret $n"; done
  fi
  return 0
}

if [[ "$mode" != "dry-run" ]] && ! command -v gh >/dev/null 2>&1; then
  log_error "gh is not installed"
  exit 2
fi

if [[ "$mode" == "check" ]]; then
  missing_total=0
  for repo in $repos; do
    have_s="$(gh secret list -R "$repo" --json name -q '.[].name')" || { log_error "$repo: cannot list secrets"; missing_total=$((missing_total+1)); continue; }
    have_v="$(gh variable list -R "$repo" --json name -q '.[].name')" || { log_error "$repo: cannot list variables"; missing_total=$((missing_total+1)); continue; }
    missing=""
    while read -r kind name; do
      [[ -z "$name" ]] && continue
      if [[ "$kind" == "secret" ]]; then have="$have_s"; else have="$have_v"; fi
      # A here-string, not printf | grep -q: under pipefail that pipe fails
      # when grep stops reading early, and a present name reads as missing.
      grep -qxF -- "$name" <<< "$have" || missing="${missing} ${name}"
    done <<< "$(expected_names "$repo")"
    if [[ -n "$missing" ]]; then
      echo "${repo}: missing${missing}"
      missing_total=$((missing_total+1))
    else
      echo "${repo}: ok"
    fi
  done
  [[ "$missing_total" -eq 0 ]]
  exit $?
fi

# Values are read once and kept in files under a private directory, so each
# reaches gh on stdin.
work="$(mktemp -d)"
chmod 700 "$work"
# Also stops the agent of the check keyring, so none is left running.
cleanup() {
  if [[ -d "$work/gnupg" ]]; then
    gpgconf --homedir "$work/gnupg" --kill gpg-agent >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then cleanup; fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ask() { # var-name prompt
  local val="${!1:-}"
  if [[ -z "$val" ]]; then
    if [[ "$mode" == "dry-run" ]]; then
      val="(prompted)"
    else
      # Open the terminal first, so its absence is reported; the prompt
      # itself goes to stderr and must stay visible.
      if ! { exec 3</dev/tty; } 2>/dev/null; then
        log_error "$1 is not set and there is no terminal to prompt on"
        exit 2
      fi
      read -r -s -p "$2: " val <&3 || val=""
      exec 3<&-
      echo >&2
    fi
  fi
  [[ -n "$val" ]] || { log_error "$1 is empty"; exit 2; }
  printf '%s' "$val" > "$work/$1"
}

# Open a PKCS#12 file with its password before it is stored. The password
# reaches openssl as a file, not argv. OpenSSL 3 needs -legacy for RC2/3DES
# files; LibreSSL has no -legacy and reads them without it.
# pkcs12_open <file> <password name> <option>: writes each certificate to
# $p12_certs/N.pem, sets n_certs, and key_pubs to the public half of each
# private key, one per line. Exits 2 on any failure.
p12_in="" p12_pw="" p12_legacy="" p12_certs="" n_certs=0 key_pubs=""
p12() { openssl pkcs12 -in "$p12_in" -passin "file:$p12_pw" ${p12_legacy:+"$p12_legacy"} "$@"; }
pkcs12_open() {
  local opt="$3" pwname="$2" err="$work/p12.err"
  p12_in="$1" p12_pw="$work/$2" p12_legacy=""
  if [[ "$(cat "$p12_pw"; echo x)" == *$'\n'* ]]; then
    log_error "$pwname contains a newline; openssl cannot read it"
    exit 2
  fi
  # openssl reads at most 1023 bytes of a password file and drops the rest.
  if [[ "$(wc -c < "$p12_pw" | tr -d ' ')" -gt 1023 ]]; then
    log_error "$pwname is longer than the 1023 bytes openssl reads; pass --skip-${opt##*-}-check"
    exit 2
  fi
  if ! p12 -noout 2>"$err"; then
    if grep -qi 'mac verify' "$err"; then
      log_error "$opt does not open: wrong $pwname"
      exit 2
    fi
    if ! grep -qi 'unsupported' "$err"; then
      log_error "openssl cannot read $opt: $(head -n 1 "$err")"
      exit 2
    fi
    p12_legacy="-legacy"
    if ! p12 -noout 2>"$err"; then
      if grep -qi 'mac verify' "$err"; then
        log_error "$opt does not open: wrong $pwname"
      else
        log_error "$opt uses a legacy algorithm (RC2/3DES) and the OpenSSL legacy provider is not available: $(grep -i -m 1 -E 'unsupported|provider|legacy' "$err" || head -n 1 "$err")"
      fi
      exit 2
    fi
  fi
  # A file without a MAC opens with any password, so a failure below is
  # reported as one, not as a missing key.
  p12_fail() {
    if grep -qi -E 'mac verify|bad decrypt|wrong password' "$err"; then
      log_error "$opt does not open: wrong $pwname"
    else
      log_error "openssl cannot read $opt: $(head -n 1 "$err")"
    fi
    exit 2
  }
  # Certificates are public; each goes to its own file to be read below.
  p12_certs="$work/certs.$pwname"
  mkdir "$p12_certs"
  n_certs="$(p12 -nokeys 2>"$err" | awk -v d="$p12_certs" '
    /-----BEGIN CERTIFICATE-----/ { n++; f = d "/" n ".pem" }
    f { print > f }
    /-----END CERTIFICATE-----/ { close(f); f = "" }
    END { print n + 0 }')" || p12_fail
  [[ "${n_certs:-0}" -ge 1 ]] || { log_error "$opt holds no certificate"; exit 2; }
  # Each key reaches openssl pkey through a pipe, never a file.
  key_pubs="$(p12 -nocerts -nodes 2>"$err" | awk -v cmd="openssl pkey -pubout 2>/dev/null | tr -d '\\n'; echo" '
    /-----BEGIN .*PRIVATE KEY-----/ { k = 1 }
    k { print | cmd }
    /-----END .*PRIVATE KEY-----/ { close(cmd); k = 0 }')" || p12_fail
  [[ -n "${key_pubs//$'\n'/}" ]] || { log_error "$opt holds no private key"; exit 2; }
  return 0
}

# True when certificate file $1 is for one of the private keys in key_pubs.
cert_has_key() {
  local pub
  pub="$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null | tr -d '\n')"
  [[ -n "$pub" ]] && grep -qxF -- "$pub" <<< "$key_pubs"
}

# Warn when certificate file $2 expires within 30 days; $1 names it.
warn_expiry() {
  local end
  if ! openssl x509 -in "$2" -noout -checkend 2592000 >/dev/null 2>&1; then
    end="$(openssl x509 -in "$2" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    log_warn "$1 expires on $end; renew it"
  fi
}

check_p12() {
  local i=0 cn found="" expired="" named=0
  pkcs12_open "$apple_p12" APPLE_CERTIFICATE_PASSWORD --apple-p12
  # codesign looks the certificate up by --apple-identity and signs with its
  # key, so that certificate must be in the file with its key, and in date.
  # A renewed certificate may sit next to the expired one, in any order.
  while [[ "$i" -lt "$n_certs" ]]; do
    i=$((i+1))
    # Unescaped: OpenSSL 3 prints a backslash in the name as "\\" otherwise.
    cn="$(openssl x509 -in "$p12_certs/$i.pem" -noout -subject -nameopt multiline,-esc_msb,-esc_ctrl,utf8 2>/dev/null \
      | sed -n 's/^ *commonName *= //p')"
    [[ "$cn" == "$apple_identity" ]] || continue
    named=1
    cert_has_key "$p12_certs/$i.pem" || continue
    if openssl x509 -in "$p12_certs/$i.pem" -noout -checkend 0 >/dev/null 2>&1; then
      found="$p12_certs/$i.pem"
      break
    fi
    expired="$p12_certs/$i.pem"
  done
  if [[ -z "$found" ]]; then
    if [[ -n "$expired" ]]; then
      log_error "--apple-p12: the certificate '$apple_identity' expired on $(openssl x509 -in "$expired" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    elif [[ "$named" -eq 1 ]]; then
      log_error "--apple-p12: the certificate '$apple_identity' does not match the private key"
    else
      log_error "--apple-p12 holds no certificate named '$apple_identity'"
    fi
    exit 2
  fi
  warn_expiry "--apple-p12: the certificate '$apple_identity'" "$found"
  return 0
}

# signtool signs with the key's certificate, so the .pfx must hold a
# certificate for one of its keys, with the code-signing EKU, in date.
# The EKU is read from -text: LibreSSL has no "x509 -ext".
check_pfx() {
  local i=0 found="" expired="" keyed=0 eku
  pkcs12_open "$windows_pfx" WINDOWS_CERTIFICATE_PASSWORD --windows-pfx
  while [[ "$i" -lt "$n_certs" ]]; do
    i=$((i+1))
    cert_has_key "$p12_certs/$i.pem" || continue
    keyed=1
    eku="$(openssl x509 -in "$p12_certs/$i.pem" -noout -text 2>/dev/null \
      | awk '/X509v3 Extended Key Usage/ { e = 1; next } e { print; e = 0 }')"
    [[ "$eku" == *"Code Signing"* ]] || continue
    if openssl x509 -in "$p12_certs/$i.pem" -noout -checkend 0 >/dev/null 2>&1; then
      found="$p12_certs/$i.pem"
      break
    fi
    expired="$p12_certs/$i.pem"
  done
  if [[ -z "$found" ]]; then
    if [[ -n "$expired" ]]; then
      log_error "--windows-pfx: the code-signing certificate expired on $(openssl x509 -in "$expired" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    elif [[ "$keyed" -eq 1 ]]; then
      log_error "--windows-pfx: the certificate of its private key has no code-signing (1.3.6.1.5.5.7.3.3) extended key usage"
    else
      log_error "--windows-pfx: no code-signing (1.3.6.1.5.5.7.3.3) certificate matches the private key"
    fi
    exit 2
  fi
  warn_expiry "--windows-pfx: the code-signing certificate" "$found"
  return 0
}

if has_group gpg; then
  if [[ ! "$gpg_key" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    log_error "--gpg-key must be the 40-character fingerprint"
    exit 2
  fi
  if [[ "$mode" != "dry-run" ]]; then
    command -v gpg >/dev/null 2>&1 || { log_error "gpg is not installed"; exit 2; }
    gpg --batch --list-secret-keys "$gpg_key" >/dev/null 2>&1 \
      || { log_error "no secret key $gpg_key in the local keyring"; exit 2; }
  fi
  ask GPG_PASSPHRASE "GPG passphrase for $gpg_key"
  if [[ "$mode" != "dry-run" ]]; then
    gpg_pw=(--batch --pinentry-mode loopback --passphrase-file "$work/GPG_PASSPHRASE")
    gpg "${gpg_pw[@]}" --armor --export-secret-keys "$gpg_key" > "$work/GPG_PRIVATE_KEY" 2>/dev/null \
      || { log_error "gpg could not export $gpg_key: wrong GPG_PASSPHRASE, or no secret part"; exit 2; }
    [[ -s "$work/GPG_PRIVATE_KEY" ]] || { log_error "gpg exported nothing for $gpg_key"; exit 2; }
    # Sign with the exported key and the passphrase before storing them, in a
    # fresh keyring: the local agent may have the passphrase cached and would
    # accept a wrong one. The value is passed as a file, not argv.
    check_home="$work/gnupg"
    mkdir -m 700 "$check_home"
    gpg --homedir "$check_home" "${gpg_pw[@]}" --import "$work/GPG_PRIVATE_KEY" >/dev/null 2>&1 \
      || { log_error "the exported key for $gpg_key does not import"; exit 2; }
    printf 'check' | gpg --homedir "$check_home" "${gpg_pw[@]}" --local-user "$gpg_key" --sign >/dev/null 2>&1 \
      || { log_error "cannot sign with $gpg_key: wrong GPG_PASSPHRASE, or the key is expired or cannot sign"; exit 2; }
    gpgconf --homedir "$check_home" --kill gpg-agent >/dev/null 2>&1 || true
  fi
  printf '%s' "$gpg_key" > "$work/GPG_KEY_ID"
  if [[ -n "$lp_ssh_key" ]]; then
    [[ -s "$lp_ssh_key" && -r "$lp_ssh_key" ]] || { log_error "--launchpad-ssh-key $lp_ssh_key is missing, empty or unreadable"; exit 2; }
    cp "$lp_ssh_key" "$work/LAUNCHPAD_SSH_PRIVATE_KEY"
  fi
fi

if has_group apple; then
  [[ -s "$apple_p12" && -r "$apple_p12" ]] || { log_error "--apple-p12 is missing, empty or unreadable"; exit 2; }
  [[ "$apple_identity" == "Developer ID Application: "* ]] || { log_error "--apple-identity must start with 'Developer ID Application: '"; exit 2; }
  [[ "$apple_team" =~ ^[A-Z0-9]{10}$ ]] || { log_error "--apple-team must be the 10-character team ID"; exit 2; }
  [[ "$apple_identity" == *" (${apple_team})" ]] || { log_error "--apple-identity must end in ' (${apple_team})', the --apple-team"; exit 2; }
  [[ "$apple_id" == *@* ]] || { log_error "--apple-id must be an e-mail address"; exit 2; }
  base64 < "$apple_p12" | tr -d '\n' > "$work/APPLE_CERTIFICATE"
  printf '%s' "$apple_identity" > "$work/APPLE_SIGNING_IDENTITY"
  printf '%s' "$apple_team" > "$work/APPLE_TEAM_ID"
  printf '%s' "$apple_id" > "$work/APPLE_ID"
  if [[ "$mode" != "dry-run" ]] && [[ "$skip_p12_check" -eq 0 ]] && ! command -v openssl >/dev/null 2>&1; then
    log_error "openssl is not installed; it checks the .p12 password. Install it, or pass --skip-p12-check"
    exit 2
  fi
  ask APPLE_CERTIFICATE_PASSWORD "Password of $apple_p12"
  if [[ "$mode" != "dry-run" ]] && [[ "$skip_p12_check" -eq 0 ]]; then
    check_p12
  fi
  ask APPLE_APP_PASSWORD "App-specific password for $apple_id"
  printf '%s' "true" > "$work/APPLE_SIGNING_ENABLED"
fi

if has_group windows; then
  [[ -s "$windows_pfx" && -r "$windows_pfx" ]] || { log_error "--windows-pfx is missing, empty or unreadable"; exit 2; }
  # tr, not base64 -w0: BSD base64 has no -w.
  base64 < "$windows_pfx" | tr -d '\n' > "$work/WINDOWS_CERTIFICATE"
  if [[ "$mode" != "dry-run" ]] && [[ "$skip_pfx_check" -eq 0 ]] && ! command -v openssl >/dev/null 2>&1; then
    log_error "openssl is not installed; it checks the .pfx password. Install it, or pass --skip-pfx-check"
    exit 2
  fi
  if [[ -n "$windows_pw_file" ]]; then
    [[ -s "$windows_pw_file" && -r "$windows_pw_file" ]] || { log_error "--windows-password-file is missing, empty or unreadable"; exit 2; }
    # One trailing line end (LF or CRLF), as an editor writes it, is not
    # part of the password.
    WINDOWS_CERTIFICATE_PASSWORD="$(cat "$windows_pw_file"; echo x)"
    WINDOWS_CERTIFICATE_PASSWORD="${WINDOWS_CERTIFICATE_PASSWORD%x}"
    if [[ "$WINDOWS_CERTIFICATE_PASSWORD" == *$'\n' ]]; then
      WINDOWS_CERTIFICATE_PASSWORD="${WINDOWS_CERTIFICATE_PASSWORD%$'\n'}"
      WINDOWS_CERTIFICATE_PASSWORD="${WINDOWS_CERTIFICATE_PASSWORD%$'\r'}"
    fi
  fi
  ask WINDOWS_CERTIFICATE_PASSWORD "Password of $windows_pfx"
  if [[ "$mode" != "dry-run" ]] && [[ "$skip_pfx_check" -eq 0 ]]; then
    check_pfx
  fi
fi

failed=0
for repo in $repos; do
  for m in $ppa_map; do
    [[ "${m%%=*}" == "$repo" ]] && printf '%s' "${m#*=}" > "$work/PPA_TARGET.${repo//\//__}"
  done
  while read -r kind name; do
    [[ -z "$name" ]] && continue
    src="$work/$name"
    [[ "$name" == "PPA_TARGET" ]] && src="$work/PPA_TARGET.${repo//\//__}"
    if [[ "$mode" == "dry-run" ]]; then
      echo "${repo}: would set ${kind} ${name}"
      continue
    fi
    if gh "$kind" set "$name" -R "$repo" < "$src" >/dev/null; then
      echo "${repo}: set ${kind} ${name}"
    else
      log_error "${repo}: could not set ${kind} ${name}"
      failed=$((failed+1))
    fi
  done <<< "$(expected_names "$repo")"
done
if [[ "$failed" -eq 0 ]] && has_group windows; then
  echo "Next: set 'windows_sign_mode: pfx' in the caller workflow of tauri-release.yml; see ci-helpers docs/windows-signing.md."
fi
[[ "$failed" -eq 0 ]]
