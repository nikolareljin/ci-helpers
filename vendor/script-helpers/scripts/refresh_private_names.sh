#!/usr/bin/env bash
# SCRIPT: refresh_private_names.sh
# DESCRIPTION: Build the private-repository name list that check_private_names.sh reads, from your own GitHub account or organisation.
# USAGE: scripts/refresh_private_names.sh [--owner <user-or-org>] [--out <path>] [--stdout] [--check] [-h]
# PARAMETERS:
#   --owner <name>  GitHub user or organisation. Default: the owner of this repo's origin remote.
#   --out <path>    Where to write. Default: ${XDG_CONFIG_HOME:-~/.config}/script-helpers/private-names.tsv
#   --stdout        Print the list instead of writing it.
#   --check         Compare the written list with GitHub; change nothing.
#   -h, --help      Show this help message.
# EXIT_CODES:
#   0  written (or, with --check, unchanged)
#   1  --check found the list out of date
#   2  bad arguments, or the account has no private repositories
#   3  gh is missing or not authenticated
# ----------------------------------------------------
#
# check_private_names.sh refuses text that names a private repository, and it
# needs to know which names those are. That list is yours: your account, your
# organisation, your repositories. Nothing about it is shared, and nothing about
# it can be committed -- a file listing your private repositories is exactly the
# thing the gate exists to keep out of public trees.
#
# So it lives outside every working tree, at
# ${XDG_CONFIG_HOME:-~/.config}/script-helpers/private-names.tsv, one file per
# machine serving every repository on it.
#
# WHY THE NETWORK IS HERE AND NOWHERE ELSE. This script talks to GitHub; the
# gate never does. A check that made a network call would add a round trip to
# every commit and every push, to catch an event -- a repository being created,
# or changing visibility -- that happens a few times a month and that you
# perform deliberately. Refresh after one of those, or on a cadence of days.
#
# AMBIGUOUS NAMES. A repository whose name is also an ordinary word is flagged,
# and the gate then requires it to appear as a whole token rather than as a
# substring, so an everyday use of the word in prose stops matching while
# "owner/<name>" still does. The flag comes from the system word list when there is one.
#
# The `code` column is for citing a private repository in public text without
# naming it. If you have no such scheme it stays `-`, and the gate simply says
# which name it found.
# ----------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging >/dev/null 2>&1 || true
type log_info >/dev/null 2>&1 || log_info() { printf '[INFO] %s\n' "$*"; }
type log_warn >/dev/null 2>&1 || log_warn() { printf '[WARN] %s\n' "$*" >&2; }
type log_error >/dev/null 2>&1 || log_error() { printf '[ERROR] %s\n' "$*" >&2; }

OWNERS=""
OUT="${XDG_CONFIG_HOME:-$HOME/.config}/script-helpers/private-names.tsv"
TO_STDOUT=false
CHECK=false
WORDLIST="${PRIVATE_NAMES_WORDLIST:-/usr/share/dict/words}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNERS="${OWNERS}${OWNERS:+,}${2:?--owner needs a name}"; shift 2 ;;
    --out) OUT="${2:?--out needs a path}"; shift 2 ;;
    --stdout) TO_STDOUT=true; shift ;;
    --check) CHECK=true; shift ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) log_error "Unknown argument: $1"; exit 2 ;;
  esac
done

# A missing tool is exit 3, distinct from "found nothing", so a caller can tell
# "not set up here" from "your account has no private repositories".
if ! command -v gh >/dev/null 2>&1; then
  log_error "gh is not installed. This is the only step that talks to GitHub;"
  log_error "the check itself never does. See https://cli.github.com."
  exit 3
fi
if ! gh auth status >/dev/null 2>&1; then
  log_error "gh is not authenticated. Run: gh auth login"
  exit 3
fi

[[ -z "$OWNERS" ]] && OWNERS="${PRIVATE_NAMES_OWNERS:-}"

# Deliberately NOT inferred from this repository's origin.
#
# The dictionary is one file per machine, serving every repository on it. Inferring the
# owner from wherever you happen to be standing means a refresh run inside a third party's
# repository rebuilds that one file from THEIR namespace -- silently dropping your own
# private names from every gate on the machine, with no error and no clue. Naming the
# owners is the only safe default.
if [[ -z "$OWNERS" ]]; then
  log_error "No namespace given, and one is never guessed from the repository you are in."
  log_error "A guess would rebuild this machine's whole dictionary from someone else's"
  log_error "namespace and quietly drop your own names from every check."
  log_error "  scripts/refresh_private_names.sh --owner <user-or-org> [--owner <another>]"
  log_error "  or set PRIVATE_NAMES_OWNERS=\"a,b\""
  exit 2
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.body" "$tmp.raw" "${staged:-}"' EXIT

# One namespace per line, so several can be given. Each is fetched separately because
# `gh repo list` takes one owner; the rows carry their namespace, which is what lets one
# dictionary cover a personal account and any number of organisations at once.
: > "$tmp.raw"
owner_list="$(printf '%s' "$OWNERS" | tr ',' '\n')"
while IFS= read -r one; do
  one="$(printf '%s' "$one" | tr -d '[:space:]')"
  [[ -z "$one" ]] && continue
  raw="$(gh repo list "$one" --limit 1000 --json name,visibility,isArchived 2>/dev/null)"
  status=$?
  if (( status != 0 )) || [[ -z "$raw" ]]; then
    log_error "gh repo list $one failed (exit $status)."
    log_error "Check the name, and that this account can see it."
    exit 3
  fi
  printf '%s\t%s\n' "$one" "$raw" >> "$tmp.raw"
done <<EOF
$owner_list
EOF

if [[ ! -s "$tmp.raw" ]]; then
  log_error "no namespace produced any repositories"
  exit 3
fi

# One python pass: the JSON, the word list and the flagging. python3 is already
# required by the gate for the same reason -- parsing JSON in bash is how a
# quoted name with a bracket in it silently drops out of a security list.
WORDLIST="$WORDLIST" python3 - "$tmp.raw" <<'PY' > "$tmp.body"
import json, os, pathlib, sys

wordlist = pathlib.Path(os.environ.get("WORDLIST", ""))
words = set()
if wordlist.is_file():
    with wordlist.open(encoding="utf-8", errors="ignore") as fh:
        words = {w.strip().lower() for w in fh if w.strip()}

# A name that is also a ubiquitous path or code token can only ever be a real reference
# when it is qualified. Measured: a repository named `.github` -- GitHub's own convention
# for an organisation's files -- matched 508 lines in one public repository, because that
# string is in every workflow path.
GENERIC = {
    ".github", ".gitlab", "docs", "doc", "test", "tests", "src", "web", "www", "api",
    "app", "lib", "bin", "scripts", "config", "assets", "images", "data", "tools", "ci",
    "infra", "common", "core", "shared", "utils", "examples", "demo", "sandbox",
    "template", "templates", "main", "public", "static", "build", "dist", "site", "blog",
    "home", "admin", "server", "client", "frontend", "backend", "mobile",
}

rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    ns, _, payload = line.partition("\t")
    if not payload.strip():
        continue
    for repo in json.loads(payload):
        if repo.get("isArchived"):
            continue
        name = repo.get("name")
        if not name:
            continue
        visibility = "public" if str(repo.get("visibility", "")).upper() == "PUBLIC" \
            else "private"
        rows.append([visibility, ns, name, "-", ""])

public_names = {r[2].lower() for r in rows if r[0] == "public"}
out = []
for visibility, ns, name, code, _ in rows:
    flags = []
    if visibility == "private":
        low = name.lower()
        if low in words:
            flags.append("ambiguous")
        # Also qualified-only when the name is a public repository somewhere: the public
        # one is what a bare mention most likely means, and blocking it would refuse a
        # correct reference for ever.
        if low in GENERIC or low.startswith(".") or len(name) <= 4 or low in public_names:
            flags.append("qualified-only")
    out.append((visibility, ns, name, code, " ".join(flags)))

out.sort(key=lambda r: (r[1].lower(), r[2].lower()))
for row in out:
    print("\t".join(row).rstrip("\t"))
PY
status=$?
if (( status != 0 )); then
  log_error "could not parse the repository list (exit $status)"
  exit 3
fi

private_count="$(grep -c '^private' "$tmp.body")"
public_count="$(grep -c '^public' "$tmp.body")"
ambiguous="$(awk -F'\t' '$1=="private" && $5 ~ /ambiguous/ {print $3}' "$tmp.body" | tr '\n' ' ')"

# A list with no private names in it cannot be told from a clean tree by
# anything downstream, and the gate treats an empty list as a failure rather
# than a pass. Refusing to write one keeps that failure here, where the cause
# is visible.
if [[ "$private_count" -eq 0 ]]; then
  log_error "no private repositories visible to this account in: $OWNERS"
  log_error "Writing an empty list would leave a check that scans for nothing"
  log_error "and reports success, so nothing was written."
  exit 2
fi

{
  echo "# private-names v1 -- generated, never commit this to a public repository"
  echo "# generated: $(date -u +%Y-%m-%d) source: gh repo list ${OWNERS}"
  printf '# visibility\tnamespace\tname\tcode\tflags\n'
  cat "$tmp.body"
} > "$tmp"

if [[ "$TO_STDOUT" == true ]]; then
  cat "$tmp"
  exit 0
fi

if [[ "$CHECK" == true ]]; then
  if [[ ! -f "$OUT" ]]; then
    log_error "no list at $OUT; run without --check to write it"
    exit 1
  fi
  # The generated-on line differs on every run and says nothing about content.
  if diff -q <(grep -v '^# generated:' "$OUT") <(grep -v '^# generated:' "$tmp") >/dev/null; then
    log_info "$OUT matches GitHub ($private_count private, $public_count public)"
    exit 0
  fi
  log_error "$OUT no longer matches GitHub; re-run without --check"
  exit 1
fi

# Temp file beside the destination, then rename.
#
# `cp` truncates and then writes, so a reader during that window gets a partial file --
# and a dictionary truncated mid-row reads as a short, complete one: the gate exits 0 and
# prints "no private repository is named" over a list it never finished reading. Tested,
# not imagined.
#
# Beside the destination, not in $TMPDIR: a rename across filesystems is a copy, which is
# the non-atomic thing being removed. Rename also makes a lock unnecessary -- the last
# writer wins and every reader sees a whole file, old or new.
#
# 0600 because this is an inventory of someone's private repositories, and the ambient
# umask makes it world-readable on most systems.
mkdir -p "$(dirname "$OUT")"
staged="$(mktemp "${OUT}.XXXXXX")" || {
  log_error "could not create a temporary file beside $OUT"
  exit 2
}
cat "$tmp" > "$staged"
chmod 600 "$staged"
mv -f "$staged" "$OUT"
log_info "wrote $OUT: $private_count private, $public_count public"
[[ -n "${ambiguous// /}" ]] && log_info "ambiguous, matched as whole tokens only: ${ambiguous% }"
exit 0
