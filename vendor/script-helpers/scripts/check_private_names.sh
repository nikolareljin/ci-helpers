#!/usr/bin/env bash
# SCRIPT: check_private_names.sh
# DESCRIPTION: Fail when the name of a private repository appears in text that is about to become public.
# USAGE: scripts/check_private_names.sh [--tree|--commits <range>|--file <path>|--stdin] [--list <path>] [--names <a,b>] [--repo <path>] [--only-public] [--for-repo <name>] [-h]
# PARAMETERS:
#   --tree              Scan tracked files (the default when nothing else is given).
#   --commits <range>   Scan commit messages in a range, e.g. origin/main..HEAD.
#   --file <path>       Scan a file — a pull request or issue body written out before posting.
#   --stdin             Scan standard input.
#   --list <path>       Name list to use. Overrides PRIVATE_NAMES_FILE and the cache.
#   --names <a,b>       Comma-separated names, instead of a list file. For tests.
#   --repo <path>       Repository to scan (default: cwd).
#   --only-public       Do nothing unless this repository is public, per the list.
#   --for-repo <name>   Judge visibility by this repository name, not the git remote.
#   -h, --help          Show this help message.
# EXIT_CODES:
#   0  no private name found
#   1  a private name was found
#   2  could not check (no list, an empty list, not a repository)
# ----------------------------------------------------
#
# A public repository must never contain the name of a private one -- not in its
# tree, and not in the text that lands around it on the forge: commit messages,
# pull request titles and bodies, issue text, review replies.
#
# Why a gate rather than a rule people remember: this rule was written down, in
# capitals, and was broken anyway. And unlike most mistakes it cannot be undone.
# GitHub keeps the edit history of every pull request and issue body publicly, so
# editing the body afterwards leaves the original a click away; rewriting the
# commits changes every tag that points at them. The only version of this fix
# that works is the one that happens before the push.
#
# Matching is `grep -iF` -- fixed strings, case-insensitive, and deliberately
# NOT `-w`. A hyphen is a word boundary, so `-w` would miss the name inside a
# longer path, a possessive or a compound, which is exactly how a name travels
# in real text. A filter that cannot see its own subject is the failure mode
# this whole gate exists to prevent.
#
# TWO PATTERNS, because one cannot work. Some repository names are also ordinary
# English words. Run the plain check over a public tree and every occurrence of
# that word in ordinary prose is a hit; measured on two real repositories that
# was 28 matches across 18 files, all innocent. A gate that fires on every push
# gets uninstalled within the week.
#
# The first version of this script answered that by not checking those names in
# the tree at all. That was wrong, and wrong in the direction that matters: the
# hole it left swallowed a real leak -- a path naming a private repository,
# written into this very file, which the gate then declared the tree clean of.
# An exemption you cannot see is not a quieter gate, it is a blind one.
#
# So every name is checked everywhere, and what differs is the pattern:
#
#   - an ordinary name matches as a fixed substring, so it is caught inside a
#     longer path, a possessive or a compound;
#   - a name flagged `ambiguous` must appear as a whole token -- not preceded or
#     followed by a letter or digit. "beaconed" and "unbeaconed" stop matching;
#     "beacon", "beacon/", "owner/beacon" and "<beacon>/path" still do.
#
# Measured on the same two repositories that leaves 8 matches instead of 28, all
# of them the English word, and one line in .git/private-names-allow silences
# them per repository -- visibly, and without a hole anyone can forget about.
#
# THE OVERRIDE. The check will sometimes be wrong -- that is a certainty, not a
# risk, given the dictionary words above. Three ways past it, loudest last:
#
#   PRIVATE_NAMES_ALLOW="term,term"   allow named terms for this run
#   .git/private-names-allow          one term per line, for a repository where
#                                     a word recurs innocently (inside .git, so
#                                     it can never be committed anywhere)
#   <cache>/private-names-allow       the same, for every repository on this
#                                     machine, beside the name list
#   git push --no-verify              git's own escape, for a human
#
# Allowed terms are echoed, so an override is visible in the output rather than
# silently shrinking what was checked.
#
# The list is data, generated elsewhere and never committed to a public
# repository. See --help output above for where it is read from.
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

# Paths are printed through this, never raw: an absolute default carries the
# account name into every message, and these messages end up in CI logs and
# pasted into issues.
tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

# One location, and it is config rather than cache: a cache is regenerable and
# disposable, and this file may be maintained by hand. It sits outside every working
# tree, so it cannot be committed by accident, and one file serves every repository on
# the machine.
DEFAULT_LIST="${XDG_CONFIG_HOME:-$HOME/.config}/script-helpers/private-names.tsv"
STALE_DAYS="${PRIVATE_NAMES_STALE_DAYS:-7}"
LOUD_DAYS="${PRIVATE_NAMES_LOUD_DAYS:-30}"

REPO=""
LIST=""
ONLY_PUBLIC=false
FOR_REPO=""
NAMES=""
COMMITS=""
FILE=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tree) MODE="tree"; shift ;;
    --commits) MODE="commits"; COMMITS="${2:?--commits needs a range}"; shift 2 ;;
    --file) MODE="file"; FILE="${2:?--file needs a path}"; shift 2 ;;
    --stdin) MODE="stdin"; shift ;;
    --list) LIST="${2:?--list needs a path}"; shift 2 ;;
    --names) NAMES="${2:?--names needs a comma-separated list}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a path}"; shift 2 ;;
    --only-public) ONLY_PUBLIC=true; shift ;;
    --for-repo) FOR_REPO="${2:?--for-repo needs a name}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) log_error "Unknown argument: $1"; exit 2 ;;
  esac
done
[[ -z "$MODE" ]] && MODE="tree"

if [[ -n "$REPO" ]]; then
  cd "$REPO" || { log_error "No such directory: $REPO"; exit 2; }
fi

work="$(mktemp -d)"
# Guarded: a subshell inherits an EXIT trap, and bash runs it there when the
# subshell is signalled -- so this could tear down the caller's stack, or
# delete a directory, while the run is still using it. ${BASHPID-$$} rather
# than $BASHPID alone: bash 3.2, which macOS ships, does not define BASHPID,
# and $$ is the top-level shell's pid in every subshell, so the comparison
# degrades to always-true there rather than to always-false.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$work"; fi' EXIT
hard="$work/hard"
ambiguous="$work/ambiguous"
entries="$work/entries"
qualified="$work/qualified"
: > "$entries"
: > "$qualified"
: > "$hard"
: > "$ambiguous"

# ---- the list -------------------------------------------------------------
# Every path that cannot produce a list exits 2. A gate that reports success
# because it had nothing to check is worse than no gate: the green line is read
# as evidence that the text is clean.
declare_from_names() {
  # --names is for tests and one-off use; every name is treated as unambiguous.
  printf '%s' "$1" | tr ',' '\n' | while IFS= read -r n; do
    n="$(printf '%s' "$n" | tr -d '[:space:]')"
    [[ -n "$n" ]] && printf '%s\n' "$n"
  done > "$hard"
}

list_age_days() {
  # Read the generation date out of the file, never the mtime: a copy, a restore
  # or a backup tool rewrites mtime and would make a year-old list look fresh.
  local stamp
  stamp="$(sed -n 's/^# generated: \([0-9-]*\).*/\1/p' "$1" | head -1)"
  [[ -z "$stamp" ]] && return 1
  local made now
  made="$(date_to_epoch "$stamp")" || return 1
  now="$(date +%s)"
  echo $(( (now - made) / 86400 ))
}

date_to_epoch() {
  # BSD and GNU date disagree here and the portability suite forbids `date -d`.
  # Python is already required by the generator and is present everywhere this
  # runs; falling back to "unknown age" is correct when it is not.
  python3 -c 'import datetime,sys; print(int(datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

if [[ -n "$NAMES" ]]; then
  declare_from_names "$NAMES"
else
  [[ -z "$LIST" ]] && LIST="${PRIVATE_NAMES_FILE:-$DEFAULT_LIST}"
  if [[ ! -f "$LIST" ]]; then
    log_error "No private-name list at: $(tilde "$LIST")"
    log_error "Without it this check would scan for nothing and report success."
    log_error "Generate one from your own account:"
    log_error "  scripts/refresh_private_names.sh --owner <your-user-or-org>"
    log_error "or point PRIVATE_NAMES_FILE at a list you already have."
    exit 2
  fi
  # The file is self-describing: its `# visibility<TAB>namespace<TAB>...` line names the
  # columns, and they are located by name rather than by position.
  #
  # This is not ceremony. The format gained a `namespace` column, and a parser reading the
  # new file by the old positions matched namespaces instead of repository names -- so it
  # reported "no private repository is named" over text that named one. A silent pass is
  # the worst failure this tool has, and column order is exactly the kind of thing that
  # changes underneath a positional reader. A file with no header is read as the documented
  # v1 order.
  #
  # Rows are emitted as: kind, needle, display, code, flags
  #   bare  a name matched as a whole token anywhere
  #   qual  matched only as namespace/name -- see the header for why
  #   ns    a namespace's own name
  awk -F'\t' -v out="$entries" '
    # Whether a bare mention can be a reference is a property of the NAME, so it is
    # decided here rather than trusted from the file. A generator that forgot to flag a
    # one-character repository would otherwise make this check match that letter
    # everywhere -- and the gate would be blamed, not the generator.
    function generic(n,   low) {
      low = tolower(n)
      if (length(n) <= 4) return 1              # too short to carry meaning on its own
      if (substr(low, 1, 1) == ".") return 1    # .github and friends: in every path
      return (low in GENERIC)
    }
    BEGIN {
      split(".github .gitlab docs doc test tests src web www api app lib bin scripts " \
            "config assets images data tools infra common core shared utils examples " \
            "demo sandbox template templates main public static build dist site blog " \
            "home admin server client frontend backend mobile", g, " ")
      for (i in g) GENERIC[g[i]] = 1
    }
    /^# *visibility/ {
      if (have_header) next
      for (i = 1; i <= NF; i++) {
        h = $i; sub(/^# */, "", h); gsub(/^[ \t]+|[ \t]+$/, "", h)
        col[h] = i
      }
      # The first header wins. A file carrying two -- which a generator briefly did
      # here -- would otherwise have its columns redefined by the last one, silently
      # shifting every field and matching namespaces instead of names.
      if (!have_header) have_header = 1
      next
    }
    /^#/ { next }
    NF == 0 { next }
    {
      vi = have_header && ("visibility" in col) ? col["visibility"] : 1
      ni = have_header && ("namespace"  in col) ? col["namespace"]  : 2
      mi = have_header && ("name"       in col) ? col["name"]       : 3
      ci = have_header && ("code"       in col) ? col["code"]       : 4
      fi = have_header && ("flags"      in col) ? col["flags"]      : 5

      if ($vi != "private") next
      ns = $ni; name = $mi; code = ($ci == "" ? "-" : $ci); flags = $fi
      if (name == "") next

      if (name == "*") { print "ns\t" ns "\t" ns "\t" code "\t" flags > out; next }
      # A name that is also an everyday word is matched ONLY when qualified.
      #
      # Measured on a real dictionary: matching those names bare produced 50 hits in this
      # repository alone -- "search", "core", "beacon" and friends as ordinary prose and
      # as identifiers in code -- and it blocked a commit whose only sin was a shell
      # function called search(). Requiring `namespace/name` takes the same tree to zero.
      #
      # The coverage given up is coverage that never existed: a bare "search" in English
      # is indistinguishable from a reference to a repository of that name, which is
      # precisely why it fired fifty times. A rule that cannot separate the two is not
      # protection, it is noise, and noise is what gets a gate switched off.
      if (flags ~ /qualified-only/ || flags ~ /ambiguous/ || generic(name)) {
        print "qual\t" ns "/" name "\t" ns "/" name "\t" code "\t" flags > out
        next
      }
      print "bare\t" name "\t" ns "/" name "\t" code "\t" flags > out
    }
  ' "$LIST"

  # Kept for the tiers the rest of the script still reads.
  awk -F'\t' -v amb="$ambiguous" -v hardf="$hard" -v qf="$qualified" '
    $1 == "bare" { if ($5 ~ /ambiguous/) print $2 "\t" $4 >> amb; else print $2 "\t" $4 >> hardf; next }
    # A qualified entry and a namespace are searched for the whole string they are, so
    # they share the tier that matches a needle as a token.
    { print $2 "\t" $4 >> qf }
  ' "$entries"

  if [[ ! -s "$hard" && ! -s "$ambiguous" ]]; then
    log_error "The private-name list has no private names in it: $(tilde "$LIST")"
    log_error "An empty list cannot be told from a clean tree, so this is a failure."
    exit 2
  fi

  age="$(list_age_days "$LIST")"
  # A non-numeric age must not be compared with -ge. `[[ "$age" -ge 5 ]]` resolves a
  # non-numeric operand as a variable name, finds nothing, evaluates 0, and reads as
  # "fresh" -- so a broken age parser would silently report a current dictionary for ever.
  if [[ -n "$age" && ! "$age" =~ ^-?[0-9]+$ ]]; then
    log_warn "could not read the dictionary's age (got '${age}'); treating it as unknown."
    age=""
  fi
  if [[ -z "$age" ]]; then
    log_warn "The list has no '# generated:' header, so its age is unknown."
  elif [[ "$age" -ge "$LOUD_DAYS" ]]; then
    log_warn "The private-name list is ${age} days old. A repository created since"
    log_warn "then is not in it and will not be caught. Refresh it."
  elif [[ "$age" -ge "$STALE_DAYS" ]]; then
    log_info "private-name list is ${age} days old; refresh it when convenient."
  fi
fi

# ---- does the rule apply to this repository? ------------------------------
# A private repository naming another private repository is fine; the rule is
# about what becomes public. --only-public lets one hook be installed everywhere
# rather than only in the repositories someone remembered to configure, which is
# the difference between a gate and a convention.
#
# An unlisted repository is CHECKED, not skipped. A repository missing from the
# list is most likely one created since it was generated, and guessing "private"
# there would turn the newest repositories -- the ones most likely to be public
# and least likely to be in the list -- into the blind spot.
if [[ "$ONLY_PUBLIC" == true && -z "$NAMES" ]]; then
  origin_url="$(git config --get remote.origin.url 2>/dev/null)"
  if [[ -n "$FOR_REPO" || -n "$origin_url" ]]; then
    if [[ -n "$FOR_REPO" ]]; then
      # A caller that already knows which repository the text is destined for --
      # a `gh pr create --repo X` run from somewhere else entirely.
      origin_name="${FOR_REPO%.git}"
      origin_name="${origin_name##*/}"
    else
      # owner/name from either git@host:owner/name.git or https://host/owner/name
      origin_name="${origin_url%.git}"
      origin_name="${origin_name##*/}"
    fi
    if [[ -n "$origin_name" ]]; then
      # Column 3 is the repository name; column 2 is its namespace. Reading the wrong one
      # here does not merely mis-report -- it decides whether the check runs at all, so it
      # would quietly skip every public repository whose name is not also a namespace.
      # Located by header, as everywhere else.
      visibility="$(awk -F'\t' -v want="$(printf '%s' "$origin_name" | tr 'A-Z' 'a-z')" '
        /^# *visibility/ {
          for (i = 1; i <= NF; i++) { h = $i; sub(/^# */, "", h); col[h] = i }
          hdr = 1; next
        }
        /^#/ { next }
        {
          vi = (hdr && ("visibility" in col)) ? col["visibility"] : 1
          mi = (hdr && ("name" in col))       ? col["name"]       : 3
          if (tolower($mi) == want) { print $vi; exit }
        }' "$LIST")"
      if [[ "$visibility" == "private" ]]; then
        log_info "$origin_name is private; a private name here does not become public."
        exit 0
      fi
    fi
  fi
fi

# ---- the override ---------------------------------------------------------
allowed="$work/allowed"
: > "$allowed"
if [[ -n "${PRIVATE_NAMES_ALLOW:-}" ]]; then
  printf '%s' "$PRIVATE_NAMES_ALLOW" | tr ',' '\n' >> "$allowed"
fi
repo_allow="$(git rev-parse --git-dir 2>/dev/null)/private-names-allow"
if [[ -f "$repo_allow" ]]; then
  cat "$repo_allow" >> "$allowed"
fi
# A machine-level allowlist beside the name list, for a word that recurs in
# every repository rather than one. Without it a word that is also everyday English has to be
# allowed again in every fresh clone on every machine, and a gate that has to be
# re-appeased that often is a gate someone eventually removes. It lives in the
# cache directory, never in a tree.
machine_allow="${XDG_CONFIG_HOME:-$HOME/.config}/script-helpers/private-names-allow"
if [[ -f "$machine_allow" ]]; then
  cat "$machine_allow" >> "$allowed"
fi
# Blank lines are stripped before any use: a pattern file containing an empty
# line makes grep match every line of input, which would turn either list into
# "everything is a hit" or, worse, silently allow everything.
sed 's/[[:space:]]//g' "$allowed" | grep -v '^$' > "$allowed.clean" 2>/dev/null
mv "$allowed.clean" "$allowed"

drop_allowed() {  # drop_allowed <names-file>
  [[ -s "$allowed" ]] || return 0
  local kept="$1.kept"
  : > "$kept"
  while IFS="$(printf '\t')" read -r name code; do
    if grep -qix -F "$name" "$allowed"; then
      log_info "allowed by override, not checked: $name"
    else
      printf '%s\t%s\n' "$name" "$code" >> "$kept"
    fi
  done < "$1"
  mv "$kept" "$1"
}
drop_allowed "$hard"
[[ -s "$ambiguous" ]] && drop_allowed "$ambiguous"

patterns() {      # patterns <names-file> -> a pattern file grep can take
  cut -f1 "$1" | grep -v '^$' > "$1.patterns"
  printf '%s' "$1.patterns"
}

# An ambiguous name has to appear as a whole token. The boundaries are spelled
# out as character classes rather than \b, which is a GNU extension: under BSD
# grep it is not a word boundary at all, so the pattern would quietly match
# nothing and this tier would stop checking while still reporting success.
#
# They are not `-w` either. `-w` treats a hyphen as a boundary, so it would
# match the name inside `some-beacon-thing`; these boundaries are letters and
# digits only, which is what separates "beaconed" from "owner/beacon".
ere_patterns() { # ere_patterns <names-file> -> a pattern file for grep -E
  local name rest
  : > "$1.ere"
  while IFS="$(printf '\t')" read -r name rest; do
    [[ -z "$name" ]] && continue
    # Escape the characters an ERE would otherwise read as syntax. Repository
    # names are mostly [a-z0-9-], but a dot must not become "any character".
    name="$(printf '%s' "$name" | sed 's/[][\.^$*+?(){}|\\]/\\&/g')"
    printf '(^|[^A-Za-z0-9])%s([^A-Za-z0-9]|$)\n' "$name" >> "$1.ere"
  done < "$1"
  printf '%s' "$1.ere"
}

# Only the names that actually matched, never the whole list. Printing every
# name on every hit would put the entire private inventory into a terminal, a
# CI log or a pasted error message -- publishing by accident the thing this
# gate exists to keep unpublished.
matched_names() { # matched_names <names-file> <hits-file> [fixed|token]
  local name code kind="${3:-fixed}" hit
  while IFS="$(printf '\t')" read -r name code; do
    [[ -z "$name" ]] && continue
    if [[ "$kind" == token ]]; then
      hit="(^|[^A-Za-z0-9])$(printf '%s' "$name" | sed 's/[][\.^$*+?(){}|\\]/\\&/g')([^A-Za-z0-9]|$)"
      grep -qiE -- "$hit" "$2" || continue
    else
      grep -qi -F -- "$name" "$2" || continue
    fi
    if [[ "$code" == "-" || -z "$code" ]]; then
      printf '        %s\n' "$name"
    else
      printf '        %s -> %s\n' "$name" "$code"
    fi
  done < "$1"
}

# ---- the subject ----------------------------------------------------------
subject="$work/subject"
case "$MODE" in
  tree)
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
      log_error "Not a git repository: $PWD"
      log_error "This mode scans tracked files; without a repository it would check"
      log_error "nothing and report success."
      exit 2
    }
    ;;
  commits)
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
      log_error "Not a git repository: $PWD"; exit 2
    }
    git log --format='%B' "$COMMITS" > "$subject" 2>/dev/null || {
      log_error "Could not read commit messages for range: $COMMITS"; exit 2
    }
    ;;
  file)
    [[ -f "$FILE" ]] || { log_error "No such file: $FILE"; exit 2; }
    cp "$FILE" "$subject"
    ;;
  stdin)
    cat > "$subject"
    ;;
esac

# ---- the search -----------------------------------------------------------
# grep's exit codes are load-bearing: 0 matched, 1 no match (the good case),
# 2+ it failed. Collapsing them with `|| true` is how a gate stops checking
# without anyone noticing.
# Two stages, and both are necessary.
#
# Stage one is a fixed-string filter, which is fast even with thousands of names: measured
# on a real dictionary of 1,488, `grep -F` over one repository takes 0.58s and yields 86
# candidate lines. Stage two applies the real rule to those candidates only.
#
# The alternative -- one `grep -E` with a boundary-anchored pattern per name -- gives the
# same answers and took over TWO MINUTES on the same repository, because the cost is
# compiling 1,488 regexes, not scanning. A check that slow is one people remove.
#
# Stage two is awk with index() and a character test, so nothing is compiled at all.
search() {        # search <names-file> <label>
  local names="$1" label="$2" pat hits status=0
  [[ -s "$names" ]] || return 1
  pat="$(patterns "$names")"
  [[ -s "$pat" ]] || return 1

  if [[ "$MODE" == "tree" ]]; then
    hits="$(git grep -nI -i -F -f "$pat" -- .)" || status=$?
  else
    hits="$(grep -nI -i -F -f "$pat" "$subject")" || status=$?
  fi
  if [[ "$status" -gt 1 ]]; then
    log_error "the search failed (exit $status) while checking $label"
    exit 2
  fi
  [[ -z "$hits" ]] && return 1

  # Stage two: a name counts only as a whole token -- not preceded or followed by a letter
  # or a digit. `/` and `-` are boundaries, so a name still matches inside a path, a URL or
  # a possessive; what stops matching is a name inside a longer word. Substring matching
  # was measured at 508 hits on one public repository against this dictionary, essentially
  # all of them one organisation repository named `.github`, which is in every workflow
  # path. Token matching takes the same subject to zero.
  printf '%s\n' "$hits" | awk -F'\t' -v namesfile="$names" '
    function hit(line, needle,   n, pos, before, after) {
      n = length(needle); pos = index(line, needle)
      while (pos > 0) {
        before = (pos == 1) ? "" : substr(line, pos - 1, 1)
        after  = substr(line, pos + n, 1)
        if (before !~ /[a-z0-9]/ && after !~ /[a-z0-9]/) return 1
        line = substr(line, pos + 1); pos = index(line, needle)
      }
      return 0
    }
    BEGIN {
      while ((getline row < namesfile) > 0) {
        split(row, f, "\t")
        if (f[1] != "") needle[tolower(f[1])] = 1
      }
    }
    { low = tolower($0); for (n in needle) if (hit(low, n)) { print; next } }
  ' | sed "s/^/      /" > "$work/stage2"

  [[ -s "$work/stage2" ]] || return 1
  cat "$work/stage2"
  return 0
}

found=0
hard_hits="$work/hits-hard"
qual_hits="$work/hits-qual"
amb_hits="$work/hits-amb"
all_hits="$work/all-hits"
: > "$hard_hits"; : > "$qual_hits"; : > "$amb_hits"; : > "$all_hits"

# Every tier is searched before anything is reported, so one pass covers all of them.
search "$hard"      "tracked text"    > "$hard_hits" || true
search "$qualified" "qualified names" > "$qual_hits" || true
search "$ambiguous" "ambiguous names" > "$amb_hits"  || true
cat "$hard_hits" "$qual_hits" "$amb_hits" > "$all_hits"

# ---- report ---------------------------------------------------------------
if [[ -s "$hard_hits" ]]; then
  found=1
  cat "$hard_hits" >&2
  log_error "A private repository is named above."
  # An organisation's repository has no acceptable public form at all -- not its name and
  # not a code -- so offering a citation would be advising a quieter version of the
  # disclosure being prevented. A hit mixing both kinds takes the stricter advice.
  if grep -qF "never-name" "$entries" 2>/dev/null && \
     awk -F'\t' -v hits="$hard_hits" '
      function hit(line, needle,   n, pos, b, a) {
        n = length(needle); pos = index(line, needle)
        while (pos > 0) {
          b = (pos == 1) ? "" : substr(line, pos - 1, 1); a = substr(line, pos + n, 1)
          if (b !~ /[a-z0-9]/ && a !~ /[a-z0-9]/) return 1
          line = substr(line, pos + 1); pos = index(line, needle)
        }
        return 0
      }
      BEGIN { while ((getline l < hits) > 0) lines[++n] = tolower(l) }
      $5 ~ /never-name/ { for (i = 1; i <= n; i++) if (hit(lines[i], tolower($2))) { f = 1; exit } }
      END { exit !f }' "$entries"; then
    log_error "At least one is owned by an organisation, which has no public form at all"
    log_error "-- not its name, and not a code. Remove the reference."
  elif awk -F'\t' '$2 != "-" && $2 != "" { found = 1 } END { exit !found }' "$hard"; then
    log_error "Refer to it by its code instead:"
  else
    log_error "Remove or reword the reference before this becomes public:"
  fi
  matched_names "$hard" "$hard_hits" >&2
fi

if [[ -s "$qual_hits" ]]; then
  found=1
  cat "$qual_hits" >&2
  log_error "An organisation, or a private repository named with its namespace, is above."
  log_error "There is no public form of it -- remove the reference."
  matched_names "$qualified" "$qual_hits" >&2
fi

if [[ -s "$amb_hits" ]]; then
  found=1
  cat "$amb_hits" >&2
  matched_names "$ambiguous" "$amb_hits" token >&2
  log_error "That is both an everyday word and a private repository, so it needs a person."
fi

if [[ "$found" -eq 1 ]]; then
  log_error "Nothing was changed -- this only reports. If it is a false positive:"
  log_error "  PRIVATE_NAMES_ALLOW=<name> <your command>      this run only"
  log_error "  $(tilde "$(git rev-parse --git-dir 2>/dev/null)/private-names-allow")   this repository"
  log_error "  $(tilde "$machine_allow")   every repository here"
  if [[ -n "${LIST:-}" && -f "${LIST:-}" ]]; then
    log_error "Checked against $(tilde "$LIST")$(
      awk -F'\t' '!/^#/ && $1=="private" {c++} END {printf " -- %d private names", c+0}' "$LIST")$(
      sed -n 's/^# generated: \([0-9-]*\).*/, generated \1/p' "$LIST" | head -1)."
  fi
  exit 1
fi

case "$MODE" in
  tree)    log_info "no private repository is named in tracked files" ;;
  commits) log_info "no private repository is named in $COMMITS" ;;
  file)    log_info "no private repository is named in $FILE" ;;
  stdin)   log_info "no private repository is named in the given text" ;;
esac
