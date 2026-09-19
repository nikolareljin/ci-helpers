#!/usr/bin/env bash
# CHANGELOG maintenance.
#
# The header format is load-bearing, not a style preference: `ci-helpers`
# extracts GitHub Release notes from CHANGELOG.md by finding the section for the
# tag being released. Any other header shape and the release notes silently fall
# back to an auto-generated commit list. The canonical form is
#
#     ## 2026-07-28 — v0.19.0
#
# `YYYY-MM-DD`, a space, an em-dash, a space, then the version with an optional
# `v` prefix. `changelog_check_header` is what stops that from rotting.
#
# Exit codes: 2 = bad arguments, 1 = the file does not conform / the section is
# missing.

# The canonical release header. Both hyphen styles are matched so the checker can
# tell "wrong dash" from "wrong shape entirely" and say which.
_CHANGELOG_HEADER_RE='^##[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+(—|-{1,2})[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*)[[:space:]]*$'

# Usage: changelog_check_header <file>; verify the newest release header
# conforms. Prints the offending line and an explanation on failure. An
# `## [Unreleased]` section at the top is allowed and skipped over.
changelog_check_header() {
  local file="${1:-}" line first=""
  [[ -n "$file" ]] || { log_error "changelog_check_header: need <file>"; return 2; }
  [[ -f "$file" ]] || { log_error "changelog_check_header: not found: $file"; return 2; }

  while IFS= read -r line; do
    [[ "$line" == \#\#[[:space:]]* ]] || continue
    # Skip the conventional Unreleased placeholder; it is not a release header.
    [[ "$line" =~ ^##[[:space:]]+\[?[Uu]nreleased\]? ]] && continue
    first="$line"
    break
  done < "$file"

  if [[ -z "$first" ]]; then
    log_error "changelog_check_header: $file has no release section at all"
    return 1
  fi

  if [[ "$first" =~ $_CHANGELOG_HEADER_RE ]]; then
    if [[ "${BASH_REMATCH[2]}" != "—" ]]; then
      log_error "changelog_check_header: $file uses an ASCII hyphen where the format needs an em-dash:"
      log_error "  $first"
      log_error "Expected: ## $(date -u +%Y-%m-%d) — v${BASH_REMATCH[3]}"
      return 1
    fi
    printf '%s\n' "${BASH_REMATCH[3]}"
    return 0
  fi

  log_error "changelog_check_header: $file's newest release header does not conform:"
  log_error "  $first"
  log_error "Expected: ## YYYY-MM-DD — vX.Y.Z  (ci-helpers extracts release notes from this)"
  return 1
}

# Usage: changelog_extract <file> <version>; prints the body of the section for
# <version>, without its header, for use as release notes. The `v` prefix is
# optional on both sides. Returns 1 when there is no such section.
changelog_extract() {
  local file="${1:-}" version="${2:-}" section
  [[ -n "$file" && -n "$version" ]] || { log_error "changelog_extract: need <file> <version>"; return 2; }
  [[ -f "$file" ]] || { log_error "changelog_extract: not found: $file"; return 2; }

  if ! section="$(_changelog__section "$file" "$version")"; then
    log_error "changelog_extract: no section for $version in $file"
    return 1
  fi
  printf '%s\n' "$section" | sed -e '/./,$!d' | awk '{lines[NR]=$0} END{
      last=NR; while (last>0 && lines[last] ~ /^[[:space:]]*$/) last--
      for (i=1; i<=last; i++) print lines[i]
    }'
}

# Usage: changelog_has_entries <text>; return 0 when <text> -- a section body as
# changelog_extract prints it -- has at least one line that is neither blank nor
# a markdown heading.
#
# A section existing is not the same as a release being written up.
# changelog_new_section writes a header over four empty `###` headings; checked
# only for existence, that template passed the release gate and was published as
# the release body: four headings and nothing under them.
changelog_has_entries() {
  printf '%s\n' "${1:-}" | awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#+[[:space:]]/ || /^[[:space:]]*#+[[:space:]]*$/ { next }
    { found = 1; exit }
    END { exit found ? 0 : 1 }
  '
}

# Usage: _changelog__section <file> <version>; print the raw lines of the
# section whose header names <version>, and return 1 when there is none.
#
# The one place a header is matched against a version, so "is there a section"
# and "what is in it" cannot disagree. They used to be two regexes, an awk one
# and a grep one, and changelog_new_section had a third.
#
# The version has to match as a whole. This was `index(line, want) > 0`, a plain
# substring test, so asking for 0.2.0 matched a `## 2026-09-10 — v10.2.0` header
# -- "10.2.0" contains "0.2.0" -- and the release notes for one version were
# silently the body of another. So the character before the version must not be
# a digit or a dot, and the character after it must not be anything a version
# can continue with: a digit, a letter, `.`, `-` or `+`. The last three matter
# because `0.2.0` must not select `v0.2.0-rc.1`. `YYYY-MM-DD — vX.Y.Z`,
# `[X.Y.Z] - YYYY-MM-DD` and a bare version all still match.
_changelog__section() {
  local file="$1" bare="${2#v}" escaped
  # Every ERE metacharacter, not only the dot: `1.0.0+build.1` carries a `+`.
  escaped="$(printf '%s' "$bare" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"

  # Through the environment, not -v: awk processes escape sequences in a -v
  # assignment, so "0\.2\.0" arrived as "0.2.0" -- unescaped dots matching any
  # character, and a warning on every run. ENVIRON is passed through verbatim.
  #
  # The line is padded with a space on both sides so the boundaries are plain
  # bracket expressions. `(^|[^0-9.])` needs `^` inside an alternation, which
  # not every awk and grep accept; GNU grep also matched it mid-line.
  #
  # Only the FIRST version in a header is the section's version. A header such as
  # `## 2026-09-01 — v1.0.0 (supersedes 0.9.0)` is the 1.0.0 section, and
  # matching anywhere in the line returned it as the notes for 0.9.0. A version
  # is two or more dot-separated numbers (`## [1.2] - date` is a section too),
  # and a dotted date (`## 2026.09.01 — v1.1.9`) is skipped over rather than
  # taken as the version -- unless it is the only candidate in the header.
  #
  # A `##` line inside a fenced code block is content, not a header: a section
  # documenting markdown ended at its example, and everything after the fence
  # was silently dropped from the release notes. Fences follow CommonMark: up to
  # three spaces of indent, then three or more backticks or tildes; a backtick
  # fence's info string cannot contain a backtick (so ```make test``` at column
  # 0 is inline code, not a fence); and a fence closes only on a line of the
  # same character, at least as long as the opener, followed by nothing but
  # spaces or tabs.
  #
  # One deliberate departure: CommonMark runs an unclosed fence to the end of
  # the document. In a changelog that is a typo, and honouring it would hide
  # every older release header -- each of those versions would silently have no
  # section. So a fence opener with no closer after it is ordinary text. That
  # needs lookahead, hence the whole file is read before any line is judged;
  # changelogs are small.
  CHANGELOG_WANT="[^0-9.]${escaped}[^0-9A-Za-z.+-]" awk '
    # Sets fch/flen and returns 1 when s opens a fence.
    function fence_open(s,   t, ind, c, cnt) {
      t = s; ind = 0
      while (ind < 3 && substr(t, 1, 1) == " ") { t = substr(t, 2); ind++ }
      c = substr(t, 1, 1)
      if (c != "`" && c != "~") return 0
      cnt = 0
      while (substr(t, cnt + 1, 1) == c) cnt++
      if (cnt < 3) return 0
      if (c == "`" && index(substr(t, cnt + 1), "`") > 0) return 0
      fch = c; flen = cnt
      return 1
    }
    function fence_close(s, c, len,   t, ind, cnt) {
      t = s; ind = 0
      while (ind < 3 && substr(t, 1, 1) == " ") { t = substr(t, 2); ind++ }
      cnt = 0
      while (substr(t, cnt + 1, 1) == c) cnt++
      if (cnt < 3 || cnt < len) return 0
      return substr(t, cnt + 1) ~ /^[ \t]*$/
    }
    # The version a header names: its first version-like token that is not a
    # dotted date, or its first token when every one is.
    function header_version(line,   rest, tok, first) {
      rest = line; first = ""
      while (match(rest, /[0-9]+(\.[0-9]+)+[0-9A-Za-z.+-]*/)) {
        tok = substr(rest, RSTART, RLENGTH)
        if (first == "") first = tok
        if (tok !~ /^[0-9][0-9][0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]$/) return tok
        rest = substr(rest, RSTART + RLENGTH)
      }
      return first
    }
    { L[NR] = $0 }
    END {
      want = ENVIRON["CHANGELOG_WANT"]
      n = NR
      i = 1
      while (i <= n) {
        if (fence_open(L[i])) {
          for (j = i + 1; j <= n; j++) if (fence_close(L[j], fch, flen)) break
          if (j <= n) { for (k = i; k <= j; k++) infence[k] = 1; i = j + 1; continue }
        }
        i++
      }
      found = 0
      for (i = 1; i <= n; i++) {
        if (!(i in infence) && L[i] ~ /^##[[:space:]]/) {
          if (found) break
          line = L[i]
          sub(/^##[[:space:]]+/, "", line)
          v = header_version(line)
          if (v != "" && (" " v " ") ~ want) found = 1
          continue
        }
        if (found) print L[i]
      }
      exit found ? 0 : 1
    }
  ' "$file"
}

# Usage: changelog_new_section <file> <version> [--date YYYY-MM-DD]
#                              [--section <name>]...
#
# Insert a new release section at the top, above the newest existing one and
# below any `## [Unreleased]` placeholder and the file's title. Refuses to run
# twice for the same version, so it is safe in a release script that gets rerun.
#
# With no --section, writes the four Keep-a-Changelog headings ci-helpers'
# release notes render well: Added, Changed, Fixed, Security.
changelog_new_section() {
  local file="" version="" date="" tmp inserted=0 line bare
  local -a sections=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date)
        [[ $# -ge 2 ]] || { log_error "changelog_new_section: $1 requires a value"; return 2; }
        date="${2:-}"; shift 2 ;;
      --section)
        [[ $# -ge 2 ]] || { log_error "changelog_new_section: $1 requires a value"; return 2; }
        sections+=("${2:-}"); shift 2 ;;
      -*) log_error "changelog_new_section: unknown option $1"; return 2 ;;
      *) if [[ -z "$file" ]]; then file="$1"; else version="$1"; fi; shift ;;
    esac
  done
  [[ -n "$file" && -n "$version" ]] || { log_error "changelog_new_section: need <file> <version>"; return 2; }
  [[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]] \
    || { log_error "changelog_new_section: not a semver version: '$version'"; return 2; }
  [[ ${#sections[@]} -gt 0 ]] || sections=(Added Changed Fixed Security)
  [[ -n "$date" ]] || date="$(date -u +%Y-%m-%d)"
  bare="${version#v}"

  if [[ ! -f "$file" ]]; then
    log_info "changelog: creating $file"
    printf '# Changelog\n\n' > "$file"
  fi

  # The same whole-version rule as changelog_extract. This was a substring grep,
  # so an existing v10.2.0 section made 0.2.0 look present and nothing was added.
  if _changelog__section "$file" "$bare" >/dev/null; then
    log_info "changelog: $file already has a section for $bare"
    return 0
  fi

  tmp="$(mktemp)" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$inserted" -eq 0 && "$line" == \#\#[[:space:]]* ]] \
       && ! [[ "$line" =~ ^##[[:space:]]+\[?[Uu]nreleased\]? ]]; then
      _changelog__emit_section "$date" "$bare" "${sections[@]}" >> "$tmp"
      inserted=1
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$file"

  # No existing release section: append after the title block.
  if [[ "$inserted" -eq 0 ]]; then
    _changelog__emit_section "$date" "$bare" "${sections[@]}" >> "$tmp"
  fi

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    log_error "changelog_new_section: rewriting $file produced an empty file — refusing to replace it"
    return 1
  fi
  # Not `cat && rm || return 1`: that reports failure when the write succeeded
  # and only the cleanup failed.
  if ! cat "$tmp" > "$file"; then
    rm -f "$tmp"
    log_error "changelog_new_section: could not write $file"
    return 1
  fi
  rm -f "$tmp"
  log_info "changelog: added section $date — v$bare to $file"
}

# Usage: _changelog__emit_section <date> <version> <section...>; print one
# formatted, empty release section.
_changelog__emit_section() {
  local date="$1" version="$2"; shift 2
  local section
  printf '## %s — v%s\n\n' "$date" "$version"
  for section in "$@"; do
    printf '### %s\n\n' "$section"
  done
}
