#!/usr/bin/env bash
# SCRIPT: check_sensitive.sh
# DESCRIPTION: Fail when text about to be published carries a credential, a personal identifier or PII.
# USAGE: scripts/check_sensitive.sh [--push-refs <file>|--range <revs>|--staged|--file <path>|--stdin] [--repo <path>] [--no-gitleaks] [--no-machine] [--no-inline-allow] [--terms <path>] [--refresh-public-ip] [--list-identifiers] [-h]
# PARAMETERS:
#   --push-refs <file>  The ref lines git gives a pre-push hook on stdin, saved to a file.
#                       Checks every commit in the push that the target lacks (--remote).
#   --range <revs>      Commits to check, as git log arguments, e.g. origin/main..HEAD.
#   --staged            The staged changes (pre-commit).
#   --file <path>       A file, all of it: a commit message, a PR or issue body. Repeatable.
#   --stdin             Standard input, all of it.
#   --remote <name>     With --push-refs: the remote pushed to (git's first pre-push
#                       argument). A new branch is checked against that remote's refs
#                       only; without it, or for a bare URL, its whole history.
#   --repo <path>       Repository (default: cwd).
#   --no-gitleaks       Skip the credential scan. It then reports nothing about credentials.
#   --no-machine        Skip this machine's live identifiers (addresses, hostname, home path).
#   --terms <path>      Personal terms file. Default: SENSITIVE_TERMS_FILE, else
#                       ${XDG_CONFIG_HOME:-~/.config}/script-helpers/sensitive-terms.txt
#   --refresh-public-ip Fetch this machine's public IPv4/IPv6 once and cache it, then exit.
#                       The only network call this script makes; never run implicitly.
#   --list-identifiers  Print the kinds of identifier checked and how many, never the values.
#   --no-inline-allow   Ignore `sensitive:allow` in the text. For text whose author is
#                       the one being checked (the agent hook): it could add the marker.
#   -h, --help          Show this help message.
# EXIT_CODES:
#   0  nothing found
#   1  something found (block)
#   2  could not check: gitleaks missing or failed, or git could not read the commits
# ----------------------------------------------------
#
# Only ADDED text is checked: added lines of each commit (or of the index) and
# the commit messages. A line that removes a value never blocks.
#
# Three checks:
#   1. credentials   gitleaks with its default rules. A committed .gitleaks.toml
#                    is NOT used: repository content must not switch rules off.
#   2. personal      every term in sensitive-terms.txt (one per line, never
#                    committed), plus this machine's identifiers read at check
#                    time: non-loopback IPv4/IPv6 addresses, default gateways,
#                    MAC addresses, hostname, home directory, and the cached
#                    public IP. Docker/bridge/veth/virbr interfaces are skipped.
#                    Whole tokens only: 192.0.2.10 does not match 192.0.2.100.
#   3. PII           email addresses, phone numbers, US SSNs, card numbers
#                    (Luhn-checked). noreply/example/test addresses, the git
#                    identity's own email, RFC 5737 addresses pass.
#
# Values are never printed: a term is shown as its line number, a PII hit as a
# masked value. The output can land in a CI log or a transcript.
#
# ALLOWING A FALSE POSITIVE, each one shown in the output:
#   - `sensitive:allow` anywhere on the line (not for credentials: use
#     `gitleaks:allow` on the line, which gitleaks reads itself)
#   - .git/sensitive-allow (local to the clone, never committed): one PII value
#     per line, or `@domain` for every address at that domain. A committed
#     .sensitive-allow is ignored, so cloned content cannot allow itself.
#   - SENSITIVE_ALLOW="value,value" for one run.
# ----------------------------------------------------
set -uo pipefail
export LC_ALL=C   # byte semantics for grep/awk; see the NUL note below

TAG="[sensitive]"
MODE=""
PUSH_REFS=""
RANGE=""
FILES=()
REPO="."
USE_GITLEAKS=true
USE_MACHINE=true
TERMS_FILE="${SENSITIVE_TERMS_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/sensitive-terms.txt}"
PUBLIC_IP_CACHE="${SENSITIVE_PUBLIC_IP_CACHE:-${XDG_CACHE_HOME:-${HOME:-}/.cache}/script-helpers/public-ip}"
REFRESH_IP=false
TERMS_FROM_ARG=false
PUSH_REMOTE=""
LIST_IDS=false
INLINE_ALLOW=true

usage() { sed -n '2,/^# ------/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

set_mode() {
  if [[ -n "$MODE" && "$MODE" != "$1" ]]; then
    echo "$TAG choose one of --push-refs, --range, --staged, --file, --stdin" >&2
    exit 2
  fi
  MODE="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push-refs) set_mode push; PUSH_REFS="${2:?--push-refs needs a file}"; shift 2 ;;
    --range) set_mode range; RANGE="${2:?--range needs revisions}"; shift 2 ;;
    --staged) set_mode staged; shift ;;
    --file) set_mode file; FILES+=("${2:?--file needs a path}"); shift 2 ;;
    --stdin) set_mode stdin; shift ;;
    --remote) PUSH_REMOTE="${2-}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a path}"; shift 2 ;;
    --no-gitleaks) USE_GITLEAKS=false; shift ;;
    --no-machine) USE_MACHINE=false; shift ;;
    --terms) TERMS_FROM_ARG=true; TERMS_FILE="${2:?--terms needs a path}"; shift 2 ;;
    --refresh-public-ip) REFRESH_IP=true; shift ;;
    --list-identifiers) LIST_IDS=true; shift ;;
    --no-inline-allow) INLINE_ALLOW=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "$TAG unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$USE_GITLEAKS" == true ]] || echo "$TAG notice: --no-gitleaks: credentials are NOT checked in this run." >&2
if [[ "${SENSITIVE_NO_MACHINE:-}" == 1 ]]; then
  USE_MACHINE=false
  echo "$TAG WARNING: SENSITIVE_NO_MACHINE=1 is set: this machine's identifiers are NOT checked." >&2
fi
if [[ -n "${SENSITIVE_MACHINE_IDS_FILE:-}" ]]; then
  echo "$TAG WARNING: SENSITIVE_MACHINE_IDS_FILE is set: machine identifiers come from it, not from this machine." >&2
fi

# One private directory per run (mktemp -d, mode 700, random name).
tmp="$(mktemp -d "${TMPDIR:-/tmp}/check_sensitive.XXXXXX" 2>/dev/null)" && [[ -n "$tmp" && -d "$tmp" && ! -L "$tmp" ]] || {
  echo "$TAG could not create a private temp directory (TMPDIR=${TMPDIR:-unset}); NOT checked." >&2
  exit 2
}
chmod 700 "$tmp" 2>/dev/null || true
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# ---------------------------------------------------------------- public IP
if [[ "$REFRESH_IP" == true ]]; then
  command -v curl >/dev/null 2>&1 || { echo "$TAG curl is needed for --refresh-public-ip" >&2; exit 2; }
  mkdir -p "$(dirname "$PUBLIC_IP_CACHE")" || exit 2
  : > "$tmp/ip"
  for url in https://api.ipify.org https://api6.ipify.org; do
    ip="$(curl -fsS --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
    case "$ip" in *[!0-9A-Fa-f.:]*|"") continue ;; esac
    grep -qxF "$ip" "$tmp/ip" || printf '%s\n' "$ip" >> "$tmp/ip"
  done
  [[ -s "$tmp/ip" ]] || { echo "$TAG could not fetch the public IP; cache unchanged" >&2; exit 2; }
  (umask 077; cp "$tmp/ip" "$PUBLIC_IP_CACHE") || exit 2
  chmod 600 "$PUBLIC_IP_CACHE" 2>/dev/null
  echo "$TAG cached $(wc -l < "$tmp/ip" | tr -d ' ') public address(es) in $PUBLIC_IP_CACHE"
  exit 0
fi

# ------------------------------------------------------ machine identifiers
# skip_iface <name>: container, bridge and loopback interfaces. Their addresses
# are the same on every machine with Docker, so they identify nobody.
skip_iface() {
  case "$1" in
    lo|lo0|docker*|br-*|veth*|virbr*|cni*|flannel*|cali*|vxlan*|tunl0|vmnet*|vboxnet*|bridge*|podman*|lxcbr*|lxdbr*|awdl*|llw*|anpi*|ap1|gif*|stf*) return 0 ;;
  esac
  return 1
}

# skip_value <value>: values that identify nobody.
skip_value() {
  case "$1" in
    ""|127.*|0.0.0.0|::|::1|172.17.0.1|00:00:00:00:00:00|ff:ff:ff:ff:ff:ff) return 0 ;;
  esac
  return 1
}

# machine_ids: "description<TAB>value", one per identifier of this machine.
machine_ids() {
  if [[ -n "${SENSITIVE_MACHINE_IDS_FILE:-}" ]]; then
    cat "$SENSITIVE_MACHINE_IDS_FILE" 2>/dev/null || { echo "$TAG cannot read $SENSITIVE_MACHINE_IDS_FILE" >&2; return 2; }
    return 0
  fi
  local ifc fam addr mac gw h short
  if command -v ip >/dev/null 2>&1; then
    ip -o addr show 2>/dev/null | awk '{print $2, $3, $4}' | while read -r ifc fam addr; do
      ifc="${ifc%%@*}"; skip_iface "$ifc" && continue
      addr="${addr%%/*}"; addr="${addr%%%*}"
      skip_value "$addr" && continue
      case "$fam" in
        inet)  printf "this machine's IPv4 address (%s)\t%s\n" "$ifc" "$addr" ;;
        inet6) printf "this machine's IPv6 address (%s)\t%s\n" "$ifc" "$addr" ;;
      esac
    done
    ip -o link show 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "link/ether") print $2, $(i + 1) }' \
      | while read -r ifc mac; do
          ifc="${ifc%:}"; ifc="${ifc%%@*}"; skip_iface "$ifc" && continue
          skip_value "$mac" && continue
          printf "this machine's MAC address (%s)\t%s\n" "$ifc" "$mac"
        done
    { ip route show default 2>/dev/null; ip -6 route show default 2>/dev/null; } \
      | awk '{ gw = ""; dev = ""; for (i = 1; i < NF; i++) { if ($i == "via") gw = $(i + 1); if ($i == "dev") dev = $(i + 1) } if (gw != "") print dev, gw }' \
      | while read -r ifc gw; do
          skip_iface "$ifc" && continue
          gw="${gw%%%*}"; skip_value "$gw" && continue
          printf "this machine's default gateway (%s)\t%s\n" "$ifc" "$gw"
        done
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null | awk '
      /^[^ \t]/ { ifc = $1; sub(/:$/, "", ifc); next }
      $1 == "inet"  { print ifc, "inet", $2 }
      $1 == "inet6" { print ifc, "inet6", $2 }
      $1 == "ether" { print ifc, "ether", $2 }' \
      | while read -r ifc fam addr; do
          skip_iface "$ifc" && continue
          addr="${addr#addr:}"; addr="${addr%%/*}"; addr="${addr%%%*}"
          skip_value "$addr" && continue
          case "$fam" in
            inet)  printf "this machine's IPv4 address (%s)\t%s\n" "$ifc" "$addr" ;;
            inet6) printf "this machine's IPv6 address (%s)\t%s\n" "$ifc" "$addr" ;;
            ether) printf "this machine's MAC address (%s)\t%s\n" "$ifc" "$addr" ;;
          esac
        done
    if command -v route >/dev/null 2>&1; then
      gw="$(route -n get default 2>/dev/null | awk '$1 == "gateway:" { print $2 }')"
      skip_value "$gw" || printf "this machine's default gateway\t%s\n" "$gw"
    fi
  elif command -v ipconfig >/dev/null 2>&1; then
    # Windows (Git Bash): "IPv4 Address. . . : x", "Physical Address. . : AA-BB-..".
    ipconfig //all 2>/dev/null | tr -d '\r' | awk -F': ' '
      /IPv4 Address|IPv6 Address|Default Gateway|Physical Address/ {
        v = $2; sub(/\(.*$/, "", v); gsub(/[ \t]/, "", v); sub(/%.*$/, "", v)
        k = $1; sub(/[ .]*$/, "", k); gsub(/^[ \t]+/, "", k)
        if (v != "") print k "\t" v }' \
      | while IFS=$'\t' read -r fam addr; do
          skip_value "$addr" && continue
          printf "this machine's %s\t%s\n" "$fam" "$addr"
        done
  fi
  h="$(hostname 2>/dev/null || uname -n 2>/dev/null || true)"
  short="${h%%.*}"
  case "$(printf '%s' "$short" | tr '[:upper:]' '[:lower:]')" in
    ""|localhost|ubuntu|debian|fedora|raspberrypi|kali|archlinux|arch|alpine|centos|linux|host|server|computer|desktop|laptop|macbook|imac|mac|runner|buildkitsandbox) ;;
    *) [[ ${#short} -ge 4 ]] && printf "this machine's hostname\t%s\n" "$short" ;;
  esac
  [[ "$h" == *.* ]] && printf "this machine's FQDN\t%s\n" "$h"
  case "${HOME:-}" in
    /home/?*|/Users/?*|/c/Users/?*|/C/Users/?*|/var/home/?*) printf "this machine's home directory\t%s\n" "${HOME%/}" ;;
  esac
  if [[ -f "$PUBLIC_IP_CACHE" ]]; then
    while IFS= read -r addr; do
      skip_value "$addr" || printf "this machine's public IP (cached)\t%s\n" "$addr"
    done < "$PUBLIC_IP_CACHE"
  fi
  return 0
}

# terms: every personal term to look for, "description<TAB>value".
build_terms() {
  local n=0 line
  if [[ -z "${SENSITIVE_TERMS_FILE:-}${XDG_CONFIG_HOME:-}${HOME:-}" && "$TERMS_FROM_ARG" != true ]]; then
    echo "$TAG HOME and XDG_CONFIG_HOME are unset: cannot find sensitive-terms.txt; personal terms NOT checked." >&2
    return 2
  fi
  if [[ -e "$TERMS_FILE" && ! -r "$TERMS_FILE" ]]; then
    echo "$TAG cannot read $TERMS_FILE; personal terms NOT checked." >&2
    return 2
  fi
  if [[ -f "$TERMS_FILE" ]]; then
    if [[ -n "$(find "$TERMS_FILE" -perm -004 2>/dev/null)" ]]; then
      echo "$TAG WARNING: $TERMS_FILE is readable by other users; chmod 600 it." >&2
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      n=$((n + 1))
      line="${line%$'\r'}"
      # Trim, skip blanks and comments.
      line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      [[ ${#line} -lt 3 ]] && continue   # a one or two character term matches everything
      printf 'sensitive-terms.txt line %s\t%s\n' "$n" "$line"
    done < "$TERMS_FILE" || return 2
  fi
  # A MAC is written with ":" on Linux/macOS and "-" on Windows; look for both.
  # Optional, but its absence is said, not silent.
  [[ -f "$TERMS_FILE" ]] || echo "$TAG notice: no $TERMS_FILE; only machine identifiers and PII patterns are checked." >&2
  [[ "$USE_MACHINE" == true ]] || return 0
  machine_ids | awk -F'\t' '
    { print }
    $2 ~ /^[0-9A-Fa-f][0-9A-Fa-f][:-][0-9A-Fa-f][0-9A-Fa-f][:-][0-9A-Fa-f][0-9A-Fa-f][:-][0-9A-Fa-f][0-9A-Fa-f][:-][0-9A-Fa-f][0-9A-Fa-f][:-][0-9A-Fa-f][0-9A-Fa-f]$/ {
      v = $2; if (index(v, ":")) gsub(/:/, "-", v); else gsub(/-/, ":", v); print $1 "\t" v }' \
    || { echo "$TAG could not read this machine's identifiers; NOT checked." >&2; return 2; }
  return 0
}

if [[ "$LIST_IDS" == true ]]; then
  build_terms | awk -F'\t' '{ k = $1; sub(/ \(.*$/, "", k); sub(/ line [0-9]+$/, "", k); c[k]++ } END { for (k in c) printf "%4d  %s\n", c[k], k }' | sort -k2
  exit 0
fi

# ------------------------------------------------------------------- repo
# git runs pre-commit with GIT_INDEX_FILE=.git/index, relative to the hook's
# directory. gitleaks runs elsewhere (below), where that path names no index,
# so it saw nothing staged and every commit passed. Make them absolute here;
# under Git Bash in the C:/ form, which native git and gitleaks both read.
_b="$PWD"
command -v cygpath >/dev/null 2>&1 && _b="$(cygpath -m "$PWD")"
for _v in GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE; do
  _p="${!_v:-}"
  case "$_p" in ''|/*|[A-Za-z]:[\\/]*) ;; *) export "$_v=$_b/$_p" ;; esac
done
unset _b _v _p
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || (cd "$REPO" && pwd))"
  IN_REPO=true
else
  TOP="$(cd "$REPO" 2>/dev/null && pwd || pwd)"
  IN_REPO=false
fi
case "$MODE" in push|range|staged)
  [[ "$IN_REPO" == true ]] || { echo "$TAG $REPO is not a git repository" >&2; exit 2; } ;;
esac
[[ -n "$MODE" ]] || { echo "$TAG nothing to check: give --push-refs, --range, --staged, --file or --stdin" >&2; exit 2; }

unchecked=0
found=0
fail() { echo "$TAG $1; NOT checked" >&2; unchecked=1; }
units="$tmp/units"          # label<TAB>text, one added line per row
: > "$units"
REV_SETS=()                 # git log argument strings, for gitleaks
TEXT_FILES=()               # whole files (messages, --file, --stdin), for gitleaks

# diff_to_units <label prefix>: unified diff on stdin -> added lines as units.
# A "+++ " line is a file header only between "diff --git" and the first hunk,
# so an added line whose text starts with "++ " is still read as content.
#
# A merge commit comes as a combined diff (--cc): "@@@" hunks, one marker
# column per parent. Only a line added against every parent ("++") is new in
# the merge itself, such as a conflict resolution; the others came from a
# parent, which is checked as its own commit.
# A binary file has no lines to read: it is named on stderr, not skipped silently.
diff_to_units() {
  awk -v pfx="$1" -v sep="$(printf '\001')" -v tag="$TAG" '
    index($0, sep) == 1 { commit = substr($0, 2); next }
    /^diff --(git|cc|combined) / { hdr = 1; cc = ($2 != "--git"); np = 1; next }
    hdr && /^Binary files / { print tag " notice: binary file not checked: " (commit != "" ? commit " " : pfx) $0 > "/dev/stderr"; next }
    hdr && /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
    /^@@@* / {
      hdr = 0; np = 1
      if (cc) { np = 0; while (substr($1, np + 1, 1) == "@") np++; np-- }
      n = $(np + 2); sub(/^\+/, "", n); split(n, b, ","); ln = b[1] + 0; next }
    hdr { next }
    {
      m = substr($0, 1, np)
      if (m ~ /^\++$/) { lab = (commit != "" ? commit " " : pfx) f ":" ln; print lab "\t" substr($0, np + 1); ln++ }
      else if (m !~ /-/) ln++
    }'
}

add_revs() {
  local revs="$1" log msgs
  log="$tmp/log.$RANDOM"; msgs="$tmp/msgs.$RANDOM"
  # shellcheck disable=SC2086  # revs is a list of git log arguments
  if ! git -C "$TOP" log -p --cc -M -U0 --no-color --no-ext-diff --format='%x01%h' $revs > "$log" 2>"$log.err"; then
    echo "$TAG git could not read $revs: $(head -1 "$log.err")" >&2
    unchecked=1
    return 0
  fi
  diff_to_units "" < "$log" >> "$units" || fail "could not read the diff of $revs"
  # shellcheck disable=SC2086
  if git -C "$TOP" log --format='%x01%h%n%B' $revs > "$msgs" 2>/dev/null; then
    awk -v sep="$(printf '\001')" 'index($0, sep) == 1 { c = substr($0, 2); n = 0; next } { n++; print "message " c ":" n "\t" $0 }' "$msgs" >> "$units" || fail "could not read the messages of $revs"
    awk -v sep="$(printf '\001')" 'index($0, sep) != 1' "$msgs" > "$msgs.txt"
    [[ -s "$msgs.txt" ]] && TEXT_FILES+=("$msgs.txt")
  else
    unchecked=1
  fi
  REV_SETS+=("$revs")
}

case "$MODE" in
  push)
    [[ -r "$PUSH_REFS" ]] || { echo "$TAG cannot read $PUSH_REFS" >&2; exit 2; }
    # shellcheck disable=SC2034
    while read -r lref lsha rref rsha; do
      [[ -n "${lsha:-}" ]] || continue
      [[ "$lsha" =~ ^0+$ ]] && continue                  # a deletion adds nothing
      # An annotated tag publishes its message too (a tag of a tag: each one).
      # The signature block is not text anybody wrote.
      t="$lsha"
      while [[ "$(git -C "$TOP" cat-file -t "$t" 2>/dev/null)" == tag ]]; do
        tagobj="$tmp/tag.$RANDOM"
        git -C "$TOP" cat-file tag "$t" > "$tagobj" 2>/dev/null || { fail "could not read tag $t"; break; }
        if [[ "$rsha" != "$t" ]]; then
          awk '/^-----BEGIN (PGP|SSH) SIGNATURE-----/ { exit } p { print } /^$/ { p = 1 }' "$tagobj" > "$tagobj.msg"
          awk -v t="${t:0:7}" '{ print "tag " t ":" FNR "\t" $0 }' "$tagobj.msg" >> "$units"
          [[ -s "$tagobj.msg" ]] && TEXT_FILES+=("$tagobj.msg")
        fi
        t="$(awk '$1 == "object" { print $2; exit }' "$tagobj")"
        [[ -n "$t" ]] || break
      done
      if [[ "${rsha:-0}" =~ ^0+$ ]] || ! git -C "$TOP" cat-file -e "${rsha}^{commit}" 2>/dev/null; then
        # New branch, or a remote tip this clone has never seen: everything the
        # target remote's refs do not have. Only that remote counts: a commit
        # already on another remote (a private one) is still new to this one.
        if [[ -n "$PUSH_REMOTE" ]] && git -C "$TOP" remote 2>/dev/null | grep -qxF -- "$PUSH_REMOTE"; then
          add_revs "$lsha --not --remotes=$PUSH_REMOTE"
        else
          add_revs "$lsha"
        fi
      else
        add_revs "${rsha}..${lsha}"
      fi
    done < "$PUSH_REFS"
    # The hook calls this only for a push that adds something. No ref to check
    # means the input was empty or malformed, not that the push is clean.
    if [[ ${#REV_SETS[@]} -eq 0 && "$unchecked" -eq 0 ]]; then
      echo "$TAG no pushed ref in $PUSH_REFS; nothing could be checked" >&2
      exit 2
    fi
    ;;
  range) add_revs "$RANGE" ;;
  staged)
    if ! git -C "$TOP" diff --cached -M -U0 --no-color --no-ext-diff > "$tmp/staged" 2>/dev/null; then
      echo "$TAG git could not read the index" >&2; exit 2
    fi
    diff_to_units "staged " < "$tmp/staged" >> "$units" || fail "could not read the staged diff"
    ;;
  file)
    for f in "${FILES[@]}"; do
      [[ -r "$f" ]] || { echo "$TAG cannot read $f" >&2; unchecked=1; continue; }
      awk -v f="$f" '{ print f ":" FNR "\t" $0 }' "$f" >> "$units" || fail "could not read $f"
      TEXT_FILES+=("$f")
    done
    ;;
  stdin)
    cat > "$tmp/stdin.txt" || fail "could not read standard input"
    awk '{ print "stdin:" FNR "\t" $0 }' "$tmp/stdin.txt" >> "$units" || fail "could not read standard input"
    TEXT_FILES+=("$tmp/stdin.txt")
    ;;
esac

# A NUL byte or invalid UTF-8 makes grep call the whole file binary and print
# nothing for it, which would drop every line. Strip NULs, read bytes as bytes.
{ tr -d '\000' < "$units" > "$units.c" && mv "$units.c" "$units"; } || { echo "$TAG could not prepare the text to check" >&2; exit 2; }

# ---------------------------------------------------------------- allows
# Inline marker: the line is dropped, and said so.
allowed_inline="$(grep -ac 'sensitive:allow' "$units" 2>/dev/null || true)"
if [[ "${allowed_inline:-0}" -gt 0 && "$INLINE_ALLOW" != true ]]; then
  echo "$TAG --no-inline-allow: sensitive:allow on ${allowed_inline} line(s) is ignored here." >&2
elif [[ "${allowed_inline:-0}" -gt 0 ]]; then
  grep -a 'sensitive:allow' "$units" | cut -f1 | while IFS= read -r lab; do
    echo "$TAG allowed by inline sensitive:allow: $lab" >&2
  done
  # grep -v exits 1 when every line was allowed; 2 is an error.
  rc=0; grep -av 'sensitive:allow' "$units" > "$units.kept" || rc=$?
  [[ "$rc" -le 1 ]] || { echo "$TAG could not apply the inline allows" >&2; exit 2; }
  mv "$units.kept" "$units" || exit 2
fi

allow_list="$tmp/allow"
: > "$allow_list"
LOCAL_ALLOW=""
if [[ "$IN_REPO" == true ]]; then
  LOCAL_ALLOW="$(git -C "$TOP" rev-parse --git-common-dir 2>/dev/null)"
  [[ -n "$LOCAL_ALLOW" && "$LOCAL_ALLOW" != /* ]] && LOCAL_ALLOW="$TOP/$LOCAL_ALLOW"
  [[ -n "$LOCAL_ALLOW" ]] && LOCAL_ALLOW="$LOCAL_ALLOW/sensitive-allow"
fi
if [[ -f "$TOP/.sensitive-allow" ]]; then
  echo "$TAG ignoring the committed .sensitive-allow: allows are local (.git/sensitive-allow)." >&2
fi
if [[ -n "$LOCAL_ALLOW" && -f "$LOCAL_ALLOW" ]]; then
  grep -v '^[[:space:]]*\(#\|$\)' "$LOCAL_ALLOW" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' >> "$allow_list"
fi
if [[ -n "${SENSITIVE_ALLOW:-}" ]]; then
  printf '%s\n' "$SENSITIVE_ALLOW" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' >> "$allow_list"
fi
# The git identity is public by definition: it is on every commit already.
{ git -C "$TOP" config --get user.email 2>/dev/null; git config --global --get user.email 2>/dev/null; } | grep -v '^$' > "$tmp/ident" || true

cut -f1 "$units" > "$tmp/labels" && cut -f2- "$units" > "$tmp/text" || { echo "$TAG could not split the text to check" >&2; exit 2; }
findings="$tmp/findings"    # label<TAB>what
: > "$findings"

# ----------------------------------------------------------------- gitleaks
gitleaks_bin() {
  local c
  if [[ -n "${GITLEAKS_BIN:-}" ]]; then
    [[ -x "$GITLEAKS_BIN" ]] && { printf '%s\n' "$GITLEAKS_BIN"; return 0; }
    return 1
  fi
  command -v gitleaks 2>/dev/null && return 0
  for c in "${XDG_CACHE_HOME:-${HOME:-}/.cache}"/script-helpers/gitleaks/*/gitleaks "${XDG_CACHE_HOME:-${HOME:-}/.cache}"/script-helpers/gitleaks/*/gitleaks.exe; do
    [[ -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# run_gitleaks <kind> <target>: kind is revs, staged or file. Sets found/unchecked.
run_gitleaks() {
  local kind="$1" target="$2" report="$tmp/gl.$RANDOM.json" out rc=0 n
  local -a cfg=() cmd=()
  # Always our own config, so gitleaks does not pick up the repository's
  # .gitleaks.toml (it would by default) and committed content cannot allow itself.
  printf 'title = "script-helpers default"\n[extend]\nuseDefault = true\n' > "$tmp/gitleaks.toml"
  cfg=(--config "$tmp/gitleaks.toml")
  # Nor a committed .gitleaksignore: gitleaks reads one from the source
  # directory (and, in newer releases, from the current one), so a commit
  # could list its own fingerprint. gitleaks runs in an empty directory whose
  # .git file points at this repository: every ref and the index, no work
  # tree. A local, uncommitted <git dir>/gitleaksignore still applies.
  local src="$tmp/glsrc"
  if [[ ! -d "$src" ]]; then
    mkdir -p "$src" || { unchecked=1; echo "$TAG could not prepare the gitleaks directory" >&2; return; }
    if [[ "$IN_REPO" == true ]]; then
      printf 'gitdir: %s\n' "$(git -C "$TOP" rev-parse --absolute-git-dir)" > "$src/.git"
      local common
      common="$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git -C "$TOP" rev-parse --git-common-dir)"
      [[ -f "$common/gitleaksignore" ]] && cp "$common/gitleaksignore" "$src/.gitleaksignore"
    fi
  fi
  [[ "$kind" == file && "$target" != /* ]] && target="$PWD/$target"
  if [[ "$GL_NEW" == true ]]; then
    case "$kind" in
      revs)   cmd=(git --log-opts="$target" "$src") ;;
      staged) cmd=(git --staged "$src") ;;
      file)   cmd=(dir "$target") ;;
    esac
  else
    case "$kind" in
      revs)   cmd=(detect --source "$src" --log-opts="$target") ;;
      staged) cmd=(protect --staged --source "$src") ;;
      file)   cmd=(detect --no-git --source "$target") ;;
    esac
  fi
  out="$(cd "$src" && "$GL" "${cmd[@]}" "${cfg[@]+"${cfg[@]}"}" --no-banner --redact --verbose --exit-code 1 \
          --report-format json --report-path "$report" 2>&1)" || rc=$?
  n=0
  [[ -f "$report" ]] && n="$(grep -c '"RuleID"' "$report" 2>/dev/null || true)"
  if [[ "${n:-0}" -gt 0 ]]; then
    found=1
    printf '%s\n' "$out" | grep -E '^(Finding|RuleID|File|Line|Commit|Secret|Fingerprint):' | sed -e "s/$(printf '\033')\\[[0-9;]*m//g" -e "s/^/$TAG gitleaks: /" >&2
    echo "$TAG BLOCK gitleaks found $n credential(s) in $([[ "$kind" == file ]] && echo "${target##*/}" || echo "$kind $target")" >&2
  elif [[ "$rc" -ne 0 ]]; then
    unchecked=1
    printf '%s\n' "$out" | tail -3 | sed "s/^/$TAG gitleaks: /" >&2
    echo "$TAG gitleaks failed (exit $rc) on $kind; credentials NOT checked" >&2
  fi
}

if [[ "$USE_GITLEAKS" == true ]]; then
  if GL="$(gitleaks_bin)"; then
    GL_NEW=false
    "$GL" git --help >/dev/null 2>&1 && GL_NEW=true
    if [[ "$MODE" == staged ]]; then
      run_gitleaks staged ""
    fi
    for r in "${REV_SETS[@]+"${REV_SETS[@]}"}"; do run_gitleaks revs "$r"; done
    for f in "${TEXT_FILES[@]+"${TEXT_FILES[@]}"}"; do run_gitleaks file "$f"; done
  else
    unchecked=1
    echo "$TAG gitleaks is not installed: credentials NOT checked." >&2
    echo "$TAG install the pinned release: bash <script-helpers>/scripts/ci_security.sh --install-gitleaks" >&2
  fi
fi

# ----------------------------------------------------------- personal terms
build_terms > "$tmp/terms" || unchecked=1
if [[ -s "$tmp/terms" && -s "$units" ]]; then
  # Whole tokens, case-insensitive. A term edge that is a letter or digit must
  # not touch another letter or digit, nor a "." followed by one (so
  # 192.0.2.10 does not match inside 192.0.2.100 or 1.192.0.2.10). For a term
  # with a ":" (IPv6, MAC) the same holds for ":".
  awk -F'\t' '
    function alnum(c) { return c ~ /^[a-z0-9]$/ }
    function sepok(c, t) { return c == "." || (c == ":" && index(t, ":") > 0) }
    function edge_ok(s, t, start, L,   c, c2) {
      if (alnum(substr(t, 1, 1))) {
        # awk substr with a start below 1 returns the first character, not "".
        c = (start > 1 ? substr(s, start - 1, 1) : ""); c2 = (start > 2 ? substr(s, start - 2, 1) : "")
        if (alnum(c)) return 0
        if (sepok(c, t) && alnum(c2)) return 0
      }
      if (alnum(substr(t, L, 1))) {
        c = substr(s, start + L, 1); c2 = substr(s, start + L + 1, 1)
        if (alnum(c)) return 0
        if (sepok(c, t) && alnum(c2)) return 0
      }
      return 1
    }
    NR == FNR { n++; d[n] = $1; v[n] = tolower($2); next }
    {
      lab = $1; s = tolower(substr($0, length($1) + 2))
      for (i = 1; i <= n; i++) {
        t = v[i]; L = length(t); rest = s; off = 0
        while ((p = index(rest, t)) > 0) {
          if (edge_ok(s, t, off + p, L)) { print lab "\t" d[i]; break }
          rest = substr(rest, p + 1); off += p
        }
      }
    }' "$tmp/terms" "$units" >> "$findings" || { echo "$TAG the personal-term scan failed; NOT checked." >&2; unchecked=1; }
fi

# --------------------------------------------------------------------- PII
# grep -E finds candidates (it has {m,n}, which some awks lack); awk validates
# them and drops the allowed ones. B and A are the token edges.
B='(^|[^0-9A-Za-z_.+-])'
A='([^0-9A-Za-z_]|$)'
pii_candidates() {   # <kind> <regex>
  local rc=0
  grep -anoE "$2" "$tmp/text" > "$tmp/cand" 2>/dev/null || rc=$?
  # grep: 1 is "no match"; 2 is an error, which must not read as clean.
  if [[ "$rc" -gt 1 ]]; then echo "$TAG the $1 scan failed (grep exit $rc); NOT checked." >&2; touch "$tmp/pii.failed"; return 0; fi
  awk -v k="$1" '{ i = index($0, ":"); print substr($0, 1, i - 1) "\t" k "\t" substr($0, i + 1) }' "$tmp/cand" || touch "$tmp/pii.failed"
}
if [[ -s "$tmp/text" ]]; then
  {
    pii_candidates email '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
    pii_candidates phone "${B}(\([2-9][0-9]{2}\) ?|[2-9][0-9]{2}[-.])[2-9][0-9]{2}[-.][0-9]{4}${A}"
    pii_candidates phone "${B}\+[1-9][0-9]{0,3}([ .-]?\([0-9]{1,4}\))?([ .-][0-9]{2,8}){1,4}${A}"
    pii_candidates ssn "${B}[0-9]{3}-[0-9]{2}-[0-9]{4}${A}"
    pii_candidates card "${B}[0-9]([ -]?[0-9]){12,18}${A}"
  } > "$tmp/pii"
  [[ -f "$tmp/pii.failed" ]] && unchecked=1
  if [[ -s "$tmp/pii" ]]; then
    awk -F'\t' '
      function mask(v,   n) { n = length(v); if (n <= 6) return substr(v, 1, 1) "***"; return substr(v, 1, 3) "***" substr(v, n - 1, 2) }
      function digits(v,   o) { o = v; gsub(/[^0-9]/, "", o); return o }
      function luhn(num,   i, s, d, alt) {
        s = 0; alt = 0
        for (i = length(num); i >= 1; i--) {
          d = substr(num, i, 1) + 0
          if (alt) { d *= 2; if (d > 9) d -= 9 }
          s += d; alt = !alt
        }
        return s % 10 == 0
      }
      function allowed(v,   lv, i, e) {
        lv = tolower(v)
        for (i = 1; i <= na; i++) {
          e = al[i]
          if (lv == e) return 1
          if (substr(e, 1, 1) == "@" && length(lv) >= length(e) && substr(lv, length(lv) - length(e) + 1) == e) return 1
        }
        return 0
      }
      function email_ok(v,   lv, at, local, dom, tld) {
        lv = tolower(v); at = index(lv, "@"); local = substr(lv, 1, at - 1); dom = substr(lv, at + 1)
        for (i = 1; i <= ni; i++) if (lv == id[i]) return 1
        if (local ~ /^(git|noreply|no-reply|no_reply|donotreply|do-not-reply|notifications|mailer-daemon)$/ || local ~ /^noreply/) return 1
        if (dom ~ /(^|\.)(example\.(com|org|net)|example|test|invalid|localhost|local)$/) return 1
        if (dom ~ /(^|\.)noreply\.github\.com$/ || dom ~ /(^|\.)(domain|yourdomain|yourcompany|company|email)\.(com|tld)$/) return 1
        tld = dom; sub(/^.*\./, "", tld)
        if (tld ~ /^(png|jpe?g|gif|svg|webp|ico|pdf|js|mjs|cjs|ts|tsx|jsx|css|scss|json|ya?ml|md|txt|sh|py|rb|go|rs|java|kt|zip|gz|tgz|tar|lock|xml|html?|map|wasm|so|dll|exe|bin|log)$/) return 1
        if (dom ~ /^[0-9]+x?\./) return 1     # logo@2x.png, document@1.extra
        if (local == "this" || local == "super") return 1   # Kotlin this@Label.member
        tld = substr(v, length(v) - length(tld) + 1)
        if (tld ~ /[a-z]/ && tld ~ /[A-Z]/) return 1        # camelCase member, not a TLD
        if (dom == "github.com" || dom == "users.github.com") return 1   # bot/service addresses
        return 0
      }
      function card_ok(v,   num, n, sep, g, i, k, shape) {
        num = digits(v); n = length(num)
        if (n < 13 || n > 19) return 1
        if (v ~ /[ -]/) {
          k = split(v, g, /[ -]/); shape = ""
          for (i = 1; i <= k; i++) shape = shape (i > 1 ? "," : "") length(g[i])
          if (shape != "4,4,4,4" && shape != "4,6,5" && shape != "4,6,4" && shape != "4,4,4,4,3" && shape != "4,4,4,1") return 1
          if (v ~ / / && v ~ /-/) return 1
        }
        if (num !~ /^(4|5[1-5]|2[2-7]|3[47]|6011|65|64[4-9]|35)/) return 1
        if (num ~ /^(4111111111111111|4242424242424242|4012888888881881|4000056655665556|5555555555554444|5500000000000004|5105105105105100|5200828282828210|378282246310005|371449635398431|6011111111111117|6011000990139424|3530111333300000)$/) return 1
        if (num ~ ("^" substr(num, 1, 1) "+$")) return 1
        return !luhn(num)
      }
      function ssn_ok(v) {
        if (v ~ /^(000|666|9)/ || v ~ /^...-00-/ || v ~ /-0000$/) return 1
        if (v == "123-45-6789" || v == "078-05-1120") return 1
        return 0
      }
      function phone_ok(v, k,   num) {
        num = digits(v)
        if (k == "intl") return (length(num) < 9 || length(num) > 15)
        if (num ~ /^...55501[0-9][0-9]$/) return 1        # 555-0100..0199, reserved for fiction
        return 0
      }
      FILENAME == ARGV[1] { al[++na] = tolower($0); next }
      FILENAME == ARGV[2] { id[++ni] = tolower($0); next }
      FILENAME == ARGV[3] { lab[FNR] = $0; next }
      {
        line = $1; kind = $2; v = $3
        sub(/^[^0-9A-Za-z+(]/, "", v); sub(/[^0-9A-Za-z)]$/, "", v)
        if (allowed(v)) { print lab[line] "\tallowed by .git/sensitive-allow/SENSITIVE_ALLOW: " kind " " mask(v) > "/dev/stderr"; next }
        if (kind == "email" && email_ok(v)) next
        if (kind == "card" && card_ok(v)) next
        if (kind == "ssn" && ssn_ok(v)) next
        if (kind == "phone" && phone_ok(v, (substr(v, 1, 1) == "+" ? "intl" : "us"))) next
        what = (kind == "email" ? "an email address" : kind == "phone" ? "a phone number" : kind == "ssn" ? "a US social security number" : "a payment card number")
        print lab[line] "\t" what " (" mask(v) ")"
      }' "$allow_list" "$tmp/ident" "$tmp/labels" "$tmp/pii" >> "$findings" 2> "$tmp/allowed" \
      || { echo "$TAG the PII scan failed; NOT checked." >&2; unchecked=1; }
    sed "s/^/$TAG /" "$tmp/allowed" >&2
  fi
fi

if [[ -s "$findings" ]]; then
  found=1
  sort -u "$findings" | while IFS=$'\t' read -r lab what; do
    echo "$TAG BLOCK $lab: $what" >&2
  done
fi

if [[ "$found" -eq 1 ]]; then
  echo "$TAG Remove the value, or, for a false positive, see: check_sensitive.sh --help (ALLOWING)." >&2
  exit 1
fi
if [[ "$unchecked" -eq 1 ]]; then
  echo "$TAG COULD NOT CHECK everything (see above)." >&2
  exit 2
fi
exit 0
