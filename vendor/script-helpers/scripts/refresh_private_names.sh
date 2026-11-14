#!/usr/bin/env bash
# SCRIPT: refresh_private_names.sh
# DESCRIPTION: Build the private-repository name list that check_private_names.sh reads, from your own GitHub account or organization.
# USAGE: scripts/refresh_private_names.sh [--owner <user-or-org>] [--out <path>] [--stdout] [--check] [--force] [--codes <path>] [--limit <n>] [--ttl <days>] [-h]
# PARAMETERS:
#   --owner <name>  Limit to this user or organization; repeatable. Default: every
#                   account this token can see (you, plus your organizations).
#   --out <path>    Where to write. Default: $PRIVATE_NAMES_FILE, else
#                   ${XDG_CONFIG_HOME:-~/.config}/script-helpers/private-names.tsv
#   --stdout        Print the list instead of writing it.
#   --check         Compare the written list with GitHub; the list is not written.
#                   Always refetches, so it is the slow path and it does
#                   refresh the per-owner caches.
#   --force         Write even if it would drop names or codes.
#   --limit <n>     Repositories to ask gh for per owner (default 8000).
#   --ttl <days>    Refetch an owner whose cache is older than this. Default: 1 day
#                   for your own account, 14 for an organization.
#   --cache-dir <d> Where the per-owner caches live.
#   --no-graphql    Use `gh repo list` instead of the GraphQL query.
#   --codes <path>  Two columns, `name<TAB>code`, used to fill the code column that
#                   `gh repo list` cannot supply. A third column
#                   `alias-of=<current-name>` adds a name the repository used to
#                   have, under its code and flagged `alias`, so a renamed
#                   repository's old names stay refused (chains of alias lines
#                   are followed; the code may be left out). Default:
#                   ~/.config/script-helpers/private-names-codes.tsv
#   -h, --help      Show this help message.
# ENVIRONMENT:
#   PRIVATE_NAMES_FILE                  The list to write when --out is not given, the
#                                       same file check_private_names.sh reads.
#   PRIVATE_NAMES_NEVER_AMBIGUOUS       Names to match bare even though they are dictionary
#                                       words. Comma or newline separated.
#   PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE  A file of the same, one per line, comments allowed.
#                                       Default: ~/.config/script-helpers/private-names-unambiguous
# EXIT_CODES:
#   0  written (or, with --check, unchanged; or printed with --stdout)
#   1  --check found the list out of date or missing, or the write would drop
#      names or codes (rerun with --force)
#   2  bad arguments, the account has no private repositories, or no temporary
#      file could be created beside --out
#   3  gh is missing, not authenticated, a listing failed part-way, or your
#      login could not be read (gh api user)
# EXAMPLE: scripts/refresh_private_names.sh --owner my-org --check
# ----------------------------------------------------
#
# check_private_names.sh refuses text that names a private repository, and it
# needs to know which names those are. That list is yours: your account, your
# organization, your repositories. Nothing about it is shared, and nothing about
# it can be committed -- a file listing your private repositories is exactly the
# thing the gate exists to keep out of public trees.
#
# So it lives outside every working tree, at
# ${XDG_CONFIG_HOME:-~/.config}/script-helpers/private-names.tsv (or
# PRIVATE_NAMES_FILE, which the checks read too), one file per machine serving
# every repository on it.
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
# No -e: every step checks its own status, so a failure maps to exit 2 or 3
# and never leaves a half-written cache behind.
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
# The file the checks read, so a custom list is the one refreshed.
OUT="${PRIVATE_NAMES_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/private-names.tsv}"
TO_STDOUT=false
CHECK=false
FORCE=false
GH_LIMIT="${PRIVATE_NAMES_GH_LIMIT:-8000}"

# One cache per owner, so a re-index touches the owner that changed instead of
# refetching every account. Assembly reads whatever caches exist, which is also
# what makes `--owner X` safe: it updates one cache, it does not replace the file.
CACHE_DIR="${PRIVATE_NAMES_CACHE_DIR:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/owners}"
# Days before a cache is refetched. Your own account changes often and is small;
# an employer organization with thousands of repositories rarely gains one that
# matters and costs a minute to list.
TTL_SELF="${PRIVATE_NAMES_TTL_SELF:-1}"
TTL_ORG="${PRIVATE_NAMES_TTL_ORG:-14}"
TTL_OVERRIDE=""
USE_GRAPHQL="${PRIVATE_NAMES_GRAPHQL:-true}"
CODES_FILE="${PRIVATE_NAMES_CODES_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/private-names-codes.tsv}"
WORDLIST="${PRIVATE_NAMES_WORDLIST:-/usr/share/dict/words}"

# Names that are dictionary words but never written as words in the repos this
# account publishes, so they stay matched bare. One per line, comments allowed.
NEVER_AMBIGUOUS_FILE="${PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/private-names-unambiguous}"
NEVER_AMBIGUOUS="${PRIVATE_NAMES_NEVER_AMBIGUOUS:-}"
if [[ -f "$NEVER_AMBIGUOUS_FILE" ]]; then
  NEVER_AMBIGUOUS="${NEVER_AMBIGUOUS}
$(cat -- "$NEVER_AMBIGUOUS_FILE")"
fi

# need_value <opt> [value]: exit 2 (bad arguments) when the option has no value.
need_value() { [[ $# -ge 2 && -n "$2" ]] || { log_error "$1 needs a value"; exit 2; }; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) need_value "$@"; OWNERS="${OWNERS}${OWNERS:+,}$2"; shift 2 ;;
    --out) need_value "$@"; OUT="$2"; shift 2 ;;
    --stdout) TO_STDOUT=true; shift ;;
    --check) CHECK=true; shift ;;
    --force) FORCE=true; shift ;;
    --codes) need_value "$@"; CODES_FILE="$2"; shift 2 ;;
    --limit) need_value "$@"; GH_LIMIT="$2"; shift 2 ;;
    --ttl) need_value "$@"; TTL_OVERRIDE="$2"; shift 2 ;;
    --cache-dir) need_value "$@"; CACHE_DIR="$2"; shift 2 ;;
    --no-graphql) USE_GRAPHQL=false; shift ;;
    -h|--help) sed -n '2,/^# ----/p' "${BASH_SOURCE[0]}" | sed -e '/^# ---/d' -e 's/^# \{0,1\}//'; exit 0 ;;
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
# A non-numeric TTL or limit is not a smaller number, it is no check at all:
# `find -mtime +abc` errors, prints nothing, and the cache reads as fresh --
# so `--ttl abc` silently means "never refetch", and the log said "under abcd".
for _num in "TTL_OVERRIDE:--ttl:$TTL_OVERRIDE" "TTL_SELF:PRIVATE_NAMES_TTL_SELF:$TTL_SELF" \
            "TTL_ORG:PRIVATE_NAMES_TTL_ORG:$TTL_ORG" "GH_LIMIT:--limit:$GH_LIMIT"; do
  _name="${_num%%:*}"; _rest="${_num#*:}"; _flag="${_rest%%:*}"; _val="${_rest#*:}"
  [[ -z "$_val" ]] && continue
  if [[ ! "$_val" =~ ^[0-9]+$ ]]; then
    log_error "${_flag} takes a whole number, got '${_val}'."
    log_error "Left as it is, the comparison silently passes and nothing is refetched."
    exit 2
  fi
done
unset _num _name _rest _flag _val

SELF_LOGIN=""
OWNERS_DISCOVERED=false
if [[ -z "$OWNERS" ]]; then
  # Discovered from the TOKEN, not from the repository you are standing in.
  # The token's own account and organizations are yours wherever you run this;
  # the cwd's remote belongs to whoever owns that checkout.
  SELF_LOGIN="$(gh api user -q .login 2>/dev/null || true)"
  discovered="$SELF_LOGIN"
  while IFS= read -r org; do
    [[ -n "$org" ]] && discovered="${discovered}${discovered:+,}${org}"
  done < <(gh api user/orgs --paginate -q '.[].login' 2>/dev/null || true)
  OWNERS="$discovered"
  OWNERS_DISCOVERED=true
  [[ -n "$OWNERS" ]] && log_info "owners from this token: ${OWNERS//,/ }"
fi

if [[ -z "$OWNERS" ]]; then
  log_error "No namespace given, and none could be read from this token."
  log_error "One is never guessed from the repository you are in: that would rebuild"
  log_error "this machine's dictionary from someone else's namespace and quietly drop"
  log_error "your own names from every check."
  log_error "  scripts/refresh_private_names.sh --owner <user-or-org> [--owner <another>]"
  log_error "  or set PRIVATE_NAMES_OWNERS=\"a,b\""
  exit 2
fi
# Each owner becomes a file name under the cache directory, which is replaced
# and removed. A GitHub login is ASCII letters, digits and hyphens, plus "_"
# in an Enterprise Managed User login; anything else (`--owner ../x`) would
# write outside the cache. LC_ALL=C keeps the ranges to ASCII.
owner_is_login() {
  local LC_ALL=C
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]
}
while IFS= read -r _owner; do
  _owner="$(printf '%s' "$_owner" | tr -d '[:space:]')"
  [[ -z "$_owner" ]] && continue
  owner_is_login "$_owner" && continue
  log_error "'${_owner}' is not a GitHub user or organization name."
  exit 2
done < <(printf '%s\n' "$OWNERS" | tr ',' '\n')
unset _owner
[[ -n "$SELF_LOGIN" ]] || SELF_LOGIN="$(gh api user -q .login 2>/dev/null || true)"
# Your own login is what tells your repositories (citable by code) from an
# organization's (never-name). Without it every row would look like yours, and
# the loss guard, which counts names and codes but not flags, would then hold
# that weaker list in place. Refuse instead.
if [[ -z "$SELF_LOGIN" ]]; then
  log_error "Could not read your login from this token (gh api user)."
  log_error "Without it an organization's repositories cannot be told from yours; nothing written."
  exit 3
fi
# GitHub logins ignore case; so does every comparison with this one.
is_self() {
  [[ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$SELF_LOGIN" | tr '[:upper:]' '[:lower:]')" ]]
}

tmp="$(mktemp)"
# Guarded: a subshell inherits an EXIT trap, and bash runs it there when the
# subshell is signalled -- so this could tear down the caller's stack, or
# delete a directory, while the run is still using it. ${BASHPID-$$} rather
# than $BASHPID alone: bash 3.2, which macOS ships, does not define BASHPID,
# and $$ is the top-level shell's pid in every subshell, so the comparison
# degrades to always-true there rather than to always-false.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -f -- "$tmp" "$tmp.body" "$tmp.raw" "$tmp.oldrows" "$tmp.newrows" "${staged:-}"; fi' EXIT

# One namespace per line, so several can be given. Each is fetched separately because
# `gh repo list` takes one owner; the rows carry their namespace, which is what lets one
# dictionary cover a personal account and any number of organizations at once.
: > "$tmp.raw"
mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR" 2>/dev/null || true

# GraphQL by default. The speed is the same -- measured 45.8s against 49s for
# 5042 repositories, because the cost is 51 sequential pages, not payload --
# but it paginates properly, so there is no --limit to guess at and no
# "exactly full page" heuristic standing in for a truncation signal gh
# never gives.
_fetch_graphql() {   # <owner> -> name<TAB>PRIVATE|PUBLIC<TAB>true|false
  gh api graphql --paginate -F login="$1" -f query='
    query($login: String!, $endCursor: String) {
      repositoryOwner(login: $login) {
        repositories(first: 100, after: $endCursor, ownerAffiliations: OWNER) {
          pageInfo { hasNextPage endCursor }
          nodes { name isPrivate isArchived }
        }
      }
    }' -q '.data.repositoryOwner.repositories.nodes[]
           | [.name, (if .isPrivate then "PRIVATE" else "PUBLIC" end), (.isArchived|tostring)]
           | @tsv' 2>/dev/null
}

_fetch_repo_list() {   # <owner>, the fallback
  local raw got
  raw="$(gh repo list "$1" --limit "$GH_LIMIT" --json name,visibility,isArchived 2>/dev/null)" || return 1
  [[ -n "$raw" ]] || return 1
  got="$(printf '%s' "$raw" | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
  if [[ "$got" == "$GH_LIMIT" ]]; then
    log_error "gh returned exactly $GH_LIMIT repositories for $1, so the list is cut short."
    log_error "Raise it with --limit <n>, or drop --no-graphql."
    return 1
  fi
  printf '%s' "$raw" | python3 -I -c '
import json, sys
for r in json.load(sys.stdin):
    print(r["name"], r.get("visibility","").upper(), str(bool(r.get("isArchived"))).lower(), sep="\t")
'
}

# Fresh when it exists and find cannot age it past the TTL. find -mtime is
# POSIX; stat is not, and its flags differ between GNU and BSD.
_cache_is_fresh() {   # <file> <ttl-days>
  [[ -s "$1" ]] || return 1
  [[ "$FORCE" == true ]] && return 1
  # 0 means always refetch. find -mtime +0 is "older than 24h", which would
  # make --ttl 0 the same as --ttl 1 and quietly do nothing.
  [[ "$2" == "0" ]] && return 1
  [[ -z "$(find "$1" -mtime "+$2" 2>/dev/null)" ]]
}

owner_list="$(printf '%s' "$OWNERS" | tr ',' '\n')"
fetched=0
reused=0
skipped=""
while IFS= read -r one; do
  one="$(printf '%s' "$one" | tr -d '[:space:]')"
  [[ -z "$one" ]] && continue
  cache="$CACHE_DIR/${one}.tsv"

  ttl="$TTL_ORG"
  is_self "$one" && ttl="$TTL_SELF"
  [[ -n "$TTL_OVERRIDE" ]] && ttl="$TTL_OVERRIDE"
  # --check exists to answer "is this file still what GitHub says", so it can
  # never answer from a cache. It said "matches GitHub" after asking GitHub
  # about one owner in five.
  [[ "$CHECK" == true ]] && ttl=0

  if _cache_is_fresh "$cache" "$ttl"; then
    log_info "$one: cached ($(grep -c . "$cache") repos, under ${ttl}d)"
    reused=$((reused + 1))
  else
    log_info "$one: fetching"
    # The exit status matters as much as the output. `gh api graphql --paginate`
    # that dies on page 30 of 51 leaves 3000 names in the file, and a size
    # check calls that a complete fetch -- the exact failure this list cannot
    # have, since a name that is missing is a name nothing blocks.
    fetch_rc=0
    if [[ "$USE_GRAPHQL" == true ]]; then
      _fetch_graphql "$one" > "$cache.new" || fetch_rc=$?
    else
      _fetch_repo_list "$one" > "$cache.new" || fetch_rc=$?
    fi
    if [[ "$fetch_rc" -ne 0 ]]; then
      rm -f -- "$cache.new"
      log_error "listing $one failed part-way (exit $fetch_rc); the cache was left alone."
      log_error "A partial list would drop names silently, so nothing was written."
      exit 3
    fi
    if [[ ! -s "$cache.new" ]]; then
      rm -f -- "$cache.new"
      # Nothing came back. If the organization says it HAS repositories, this
      # token cannot see them -- SSO authorisation, most often -- and that is a
      # hole in the gate rather than an empty account. Loud either way, but a
      # discovered owner must not stop the other four from indexing.
      claimed="$(gh api "orgs/$one" -q '(.public_repos // 0) + (.total_private_repos // 0)' 2>/dev/null || echo 0)"
      if [[ "${claimed:-0}" -gt 0 ]]; then
        log_warn "$one reports ${claimed} repositories and this token can list none of them."
        log_warn "Their names will match nothing. Usually SSO: gh auth refresh, or authorise"
        log_warn "the token for $one at https://github.com/settings/tokens"
      else
        log_warn "$one: no repositories visible to this token."
      fi
      if [[ "$OWNERS_DISCOVERED" != true ]]; then
        log_error "$one was named explicitly, so this is an error rather than a skip."
        exit 3
      fi
      skipped="${skipped}${skipped:+ }${one}"
      continue
    fi
    chmod 600 "$cache.new" 2>/dev/null || true
    mv -f -- "$cache.new" "$cache"
    fetched=$((fetched + 1))
  fi

done <<EOF
$owner_list
EOF
log_info "${fetched} owner(s) fetched, ${reused} from cache"
[[ -n "$skipped" ]] && log_warn "not indexed, nothing visible: ${skipped}"

# Assembly reads EVERY cache, not just the owners fetched this run. That is what
# makes `--owner X` a per-owner re-index rather than a replacement: one cache is
# refreshed, the file is rebuilt from all of them.
# Logins ignore case, cache file names do not: `--owner NikX` and a discovered
# `nikx` are one account with two caches. Reading both would list every
# repository twice, in two namespaces, so only the newest is read.
assembled=0
seen_owners=","
while IFS= read -r cache; do
  [[ -e "$cache" ]] || continue
  one="$(basename "$cache" .tsv)"
  low="$(printf '%s' "$one" | tr '[:upper:]' '[:lower:]')"
  if [[ "$seen_owners" == *",$low,"* ]]; then
    log_warn "ignored $(basename "$cache"): an older cache of an account already read in other case"
    continue
  fi
  seen_owners="${seen_owners}${low},"
  # Your own account is always written as GitHub spells your login, so its
  # namespace does not change with whichever case was typed last.
  is_self "$one" && one="$SELF_LOGIN"
  while IFS= read -r row; do
    [[ -n "$row" ]] && printf '%s\t%s\n' "$one" "$row" >> "$tmp.raw"
  done < "$cache"
  assembled=$((assembled + 1))
done < <(find "$CACHE_DIR" -maxdepth 1 -name '*.tsv' -type f -exec ls -t {} + 2>/dev/null)
if [[ "$assembled" -eq 0 ]]; then
  log_error "no owner caches in $CACHE_DIR, so there is nothing to assemble."
  exit 3
fi
log_info "assembled from ${assembled} owner cache(s)"

if [[ ! -s "$tmp.raw" ]]; then
  log_error "no namespace produced any repositories"
  exit 3
fi

# One python pass: the JSON, the word list and the flagging. python3 is already
# required by the gate for the same reason -- parsing JSON in bash is how a
# quoted name with a bracket in it silently drops out of a security list.
WORDLIST="$WORDLIST" NEVER_AMBIGUOUS="$NEVER_AMBIGUOUS" CODES_FILE="$CODES_FILE" SELF_LOGIN="$SELF_LOGIN" python3 -I - "$tmp.raw" <<'PY' > "$tmp.body"
import os, pathlib, sys

wordlist = pathlib.Path(os.environ.get("WORDLIST", ""))
words = set()
if wordlist.is_file():
    with wordlist.open(encoding="utf-8", errors="ignore") as fh:
        words = {w.strip().lower() for w in fh if w.strip()}

# "Is it a dictionary word?" is a proxy for "would matching it bare give false
# positives in the repos I publish?". When it is wrong the name is flagged, so
# matched only when qualified, so no gate fires on it. Measure with git grep.
never_ambiguous = {
    w.strip().lower()
    for w in os.environ.get("NEVER_AMBIGUOUS", "").replace(",", "\n").splitlines()
    if w.strip() and not w.strip().startswith("#")
}

# A name that is also a ubiquitous path or code token can only ever be a real reference
# when it is qualified. Measured: a repository named `.github` -- GitHub's own convention
# for an organization's files -- matched 508 lines in one public repository, because that
# string is in every workflow path. `coverage` is here for the same reason: it is in
# every coverage.xml and check_*_coverage.py. The same list is in check_private_names.sh,
# which applies it whatever this file says; tests/private_names_test.sh fails if the two
# disagree.
GENERIC = {
    ".github", ".gitlab", "docs", "doc", "test", "tests", "src", "web", "www", "api",
    "app", "lib", "bin", "scripts", "config", "assets", "images", "data", "tools", "ci",
    "infra", "common", "core", "shared", "utils", "examples", "demo", "sandbox",
    "template", "templates", "main", "public", "static", "build", "dist", "site", "blog",
    "home", "admin", "server", "client", "frontend", "backend", "mobile", "coverage",
}

# name -> code, for the column `gh repo list` cannot supply. Deliberately a
# plain two-column file rather than an inventory format: this repository is
# public and must build standalone, so it cannot know where the codes come
# from. Whoever has the inventory produces the file.
#
# A third column, `alias-of=<current-name>`, says the name is one the repository
# used to have. GitHub lists a renamed repository under its new name only, so
# without this the old name -- still in other repositories' history -- would
# drop out of the list and stop being refused. A repository renamed twice has
# two alias lines; each may name the current name or the name that came next
# (a chain), and chains are followed. The code may be left out of an alias line,
# `old<TAB>alias-of=<name>`: the alias then takes its repository's code.
codes = {}
aliases = []  # (alias, code, the name it points at)
codes_path = pathlib.Path(os.environ.get("CODES_FILE", ""))
if codes_path.is_file():
    for raw in codes_path.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        parts = raw.replace("\t", " ").split()
        if len(parts) < 2:
            continue
        marks = [p for p in parts[1:] if p.lower().startswith("alias-of=")]
        if marks:
            target = marks[0][len("alias-of="):]
            if not target:
                print(f"skipped alias {parts[0]}: alias-of= names no repository", file=sys.stderr)
                continue
            code = parts[1] if not parts[1].lower().startswith("alias-of=") else "-"
            aliases.append((parts[0], code, target))
        else:
            codes[parts[0].lower()] = parts[1]

# owner<TAB>name<TAB>PRIVATE|PUBLIC<TAB>true|false, one row per repository,
# assembled from the per-owner caches.
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 4:
        continue
    ns, name, vis, archived = parts[0], parts[1], parts[2], parts[3]
    if not name or archived.lower() == "true":
        continue
    visibility = "public" if vis.upper() == "PUBLIC" else "private"
    rows.append([visibility, ns, name, codes.get(name.lower(), "-"), ""])

# An alias becomes a row of its own, in its repository's namespace and with its
# visibility, so it is refused exactly as the current name is. Never invented:
# an alias whose repository is not listed, or that is itself a listed name,
# is reported and skipped.
self_login = os.environ.get("SELF_LOGIN", "").lower()
listed = {}
for r in rows:
    listed.setdefault(r[2].lower(), []).append(r)
points_at = {}
for alias, _code, target in aliases:
    points_at.setdefault(alias.lower(), target)


def owners_for(chain):
    """Every repository an alias may belong to, one per namespace.

    `chain` is the names the old name led to, oldest first. An alias line names
    no namespace, so it cannot say whose old name it is. Rather than guess, it
    is listed in every namespace that has a repository along the chain: under
    the first private one there (the chain ends where a repository has the name
    now; a new one took a freed name), or the first public one if the namespace
    has no private one. It is refused in each, never-name outside your account,
    citable by code only in it. Public ones count only when no namespace has a
    private one: filing an old private name under a public namesake would stop
    refusing it.
    """
    per_ns = {}
    for name in chain:
        for r in listed.get(name.lower(), []):
            ns = r[1].lower()
            held = per_ns.get(ns)
            if held is None or (held[0] == "public" and r[0] == "private"):
                per_ns[ns] = r
    chosen = list(per_ns.values())
    private = [r for r in chosen if r[0] == "private"]
    return private if private else chosen


def chain_of(target):
    """The names an alias line leads to, in order, ending at the last one."""
    names, seen, name = [], set(), target
    while name.lower() not in seen:
        seen.add(name.lower())
        names.append(name)
        if name.lower() not in points_at:
            break
        name = points_at[name.lower()]
    return names


alias_rows = {}  # (alias, namespace), lowercased -> row
for alias, code, target in aliases:
    low = alias.lower()
    chain = chain_of(target)
    owners = owners_for(chain)
    if not owners:
        print(f"skipped alias {alias}: {chain[-1]}, the repository it points at, is not "
              f"listed", file=sys.stderr)
        continue
    for owner in owners:
        # Only a repository of that name in the same namespace contradicts the
        # alias. The same name elsewhere is another account's repository, and
        # the old one is still refused as namespace/name (qualified-only when
        # the other is public, as for any name that is public somewhere).
        if any(r[1].lower() == owner[1].lower() for r in listed.get(low, [])):
            print(f"skipped alias {alias}: it is the name of a listed repository in "
                  f"{owner[1]}", file=sys.stderr)
            continue
        # A public repository's old name is recorded as a public row with no
        # code. It does not make a private namesake qualified-only, as a public
        # current name does: an old name is not what a bare mention most likely
        # means.
        out_code = "-" if owner[0] == "public" else (code if code != "-" else owner[3])
        row = [owner[0], owner[1], alias, out_code, "alias"]
        key = (low, owner[1].lower())
        held = alias_rows.get(key)
        if held is None:
            alias_rows[key] = row
        elif held != row:
            # One old name claimed twice in one namespace: keep the private
            # claim (or the first), so the name stays refused, and say so.
            if row[0] == "private" and held[0] != "private":
                alias_rows[key] = row
            kept = alias_rows[key]
            print(f"alias {alias} is claimed by two repositories in {owner[1]}; kept "
                  f"the {kept[0]} one, code {kept[3]}", file=sys.stderr)
rows.extend(alias_rows.values())

public_names = {r[2].lower() for r in rows if r[0] == "public" and r[4] != "alias"}
out = []
for visibility, ns, name, code, extra in rows:
    flags = [extra] if extra else []
    # An organization's private repository has no acceptable public reference,
    # not even a code: offering one would advise a quieter form of the same
    # disclosure. Codes are matched by name, so without this one of yours that
    # shares a name with it would lend it your code.
    if visibility == "private" and self_login and ns.lower() != self_login:
        code = "-"
        flags.append("never-name")
    if visibility == "private":
        low = name.lower()
        if low in words and low not in never_ambiguous:
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

# An organization's namespace is never-name in its own right: there is no
# public form of it, not even a code. gh lists repositories, so it cannot
# produce that row -- it used to be carried over from the previous file, which
# meant a fresh machine had none at all and the namespace itself matched
# nothing. Derived from the owners instead, for every one that is not you.
for one in $(printf '%s' "$OWNERS" | tr ',' ' '); do
  [[ -z "$one" ]] && continue
  is_self "$one" && continue
  printf 'private\t%s\t*\t-\tnever-name\n' "$one" >> "$tmp.body"
done

# Anything else in the old file that gh cannot produce, and this run did not
# derive -- an organization no longer discovered, a row added by hand.
if [[ -f "$OUT" ]]; then
  # Compared ignoring case, like logins; a `*` row for your own account (an
  # older version wrote one for `--owner` in other case) is never carried.
  awk -F'\t' -v owners=",$(printf '%s' "$OWNERS" | tr '[:upper:]' '[:lower:]')," \
      -v self="$(printf '%s' "$SELF_LOGIN" | tr '[:upper:]' '[:lower:]')" '
    !/^#/ && $3=="*" && index(owners, "," tolower($2) ",") == 0 && tolower($2) != self
  ' "$OUT" >> "$tmp.body"
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
  echo "# generated: $(date -u +%Y-%m-%d) source: ${OWNERS}"
  printf '# visibility\tnamespace\tname\tcode\tflags\n'
  cat -- "$tmp.body"
} > "$tmp"

if [[ "$TO_STDOUT" == true ]]; then
  cat -- "$tmp"
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
# --owner takes one account; the file holds every account. A subset overwrite
# replaced 1499 names with 66 and turned every R- code into "-".
if [[ -f "$OUT" && "$FORCE" != true ]]; then
  # Rows are counted once per namespace/name ignoring case, as GitHub names
  # them: an older version could list one account twice in two cases, and
  # merging those is not a loss. Nor is dropping a `*` row an older version
  # wrote for your own account. Every other row counts, alias rows included:
  # an alias row that goes away is a name no longer refused, whatever the
  # reason, and a person decides with --force. Alias rows are compared by name,
  # not only counted, so a new repository arriving in the same refresh cannot
  # hide one. Other rows are compared by count, so a rename nobody recorded
  # swaps one name for another and passes; only a name that carried a code is
  # caught that way.
  self_low="$(printf '%s' "$SELF_LOGIN" | tr '[:upper:]' '[:lower:]')"
  rows_of() {   # <file>: visibility, namespace and name (lowercased), code, alias?, once each
    awk -F'\t' -v self="$self_low" '
      !/^#/ && NF >= 3 {
        ns = tolower($2); name = tolower($3)
        if (name == "*" && ns == self) next
        if (seen[ns SUBSEP name]++) next
        print $1 "\t" ns "\t" name "\t" $4 "\t" (((" " $5 " ") ~ / alias /) ? "alias" : "")
      }' "$1"
  }
  rows_of "$OUT" > "$tmp.oldrows"
  rows_of "$tmp" > "$tmp.newrows"
  old_n="$(awk -F'\t' '$1=="private"{n++} END{print n+0}' "$tmp.oldrows")"
  new_n="$(awk -F'\t' '$1=="private"{n++} END{print n+0}' "$tmp.newrows")"
  old_c="$(awk -F'\t' '$1=="private" && $4!="-" && $4!=""{n++} END{print n+0}' "$tmp.oldrows")"
  new_c="$(awk -F'\t' '$1=="private" && $4!="-" && $4!=""{n++} END{print n+0}' "$tmp.newrows")"
  # Per namespace too. Totals hid a real loss: 59 names went and 64 arrived, so
  # the count grew while the gate got weaker.
  shrunk_ns="$(awk -F'\t' '
    $1=="private" { if (FILENAME==old) a[$2]++; else b[$2]++ }
    END { for (ns in a) if (b[ns]+0 < a[ns]) printf "  %s: %d -> %d\n", ns, a[ns], b[ns]+0 }
  ' old="$tmp.oldrows" "$tmp.oldrows" "$tmp.newrows")"
  lost_alias="$(awk -F'\t' '
    FILENAME == new { if ($1 == "private") have[$2 SUBSEP $3] = 1; next }
    $1 == "private" && $5 == "alias" && !(($2 SUBSEP $3) in have) { printf "  %s/%s\n", $2, $3 }
  ' new="$tmp.newrows" "$tmp.newrows" "$tmp.oldrows")"
  old_w="$(awk -F'\t' '$3=="*"{n++} END{print n+0}' "$tmp.oldrows")"
  new_w="$(awk -F'\t' '$3=="*"{n++} END{print n+0}' "$tmp.newrows")"
  rm -f -- "$tmp.oldrows" "$tmp.newrows"
  if [[ "$new_n" -lt "$old_n" || "$new_c" -lt "$old_c" || -n "$shrunk_ns" || "$new_w" -lt "$old_w" || -n "$lost_alias" ]]; then
    log_error "This write would lose data, so nothing was written:"
    [[ "$new_n" -lt "$old_n" ]] && log_error "  names: ${old_n} -> ${new_n}"
    [[ "$new_c" -lt "$old_c" ]] && log_error "  names carrying a code: ${old_c} -> ${new_c}"
    [[ "$new_w" -lt "$old_w" ]] && log_error "  org-wide rows: ${old_w} -> ${new_w}"
    [[ -n "$shrunk_ns" ]] && { log_error "  namespaces that lost names:"; printf '%s\n' "$shrunk_ns" >&2; }
    [[ -n "$lost_alias" ]] && { log_error "  former names no longer listed:"; printf '%s\n' "$lost_alias" >&2; }
    log_error "Name every owner the file covers, or pass --force to overwrite."
    log_error "Owners in the current file:"
    awk -F'\t' '!/^#/ && $1=="private"{print "  " $2}' "$OUT" | sort -u >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$OUT")"
staged="$(mktemp "${OUT}.XXXXXX")" || {
  log_error "could not create a temporary file beside $OUT"
  exit 2
}
cat -- "$tmp" > "$staged"
chmod 600 "$staged"
mv -f -- "$staged" "$OUT"
log_info "wrote $OUT: $private_count private, $public_count public"
[[ -n "${ambiguous// /}" ]] && log_info "ambiguous, matched as whole tokens only: ${ambiguous% }"
exit 0
