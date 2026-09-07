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
  local file="${1:-}" version="${2:-}" bare
  [[ -n "$file" && -n "$version" ]] || { log_error "changelog_extract: need <file> <version>"; return 2; }
  [[ -f "$file" ]] || { log_error "changelog_extract: not found: $file"; return 2; }
  bare="${version#v}"

  awk -v want="$bare" '
    /^##[[:space:]]/ {
      if (inside) exit
      line = $0
      gsub(/^##[[:space:]]+/, "", line)
      # Accept "YYYY-MM-DD - vX.Y.Z", "[X.Y.Z] - YYYY-MM-DD", or a bare version.
      if (index(line, want) > 0) { inside = 1; next }
      next
    }
    inside { print }
  ' "$file" | sed -e '/./,$!d' | awk 'BEGIN{blank=0} {lines[NR]=$0} END{
      last=NR; while (last>0 && lines[last] ~ /^[[:space:]]*$/) last--
      for (i=1; i<=last; i++) print lines[i]
    }'

  grep -qE "^##[[:space:]].*${bare//./\\.}" "$file" || {
    log_error "changelog_extract: no section for $version in $file"
    return 1
  }
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
      --date) date="${2:-}"; shift 2 ;;
      --section) sections+=("${2:-}"); shift 2 ;;
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

  if grep -qE "^##[[:space:]].*${bare//./\\.}([^0-9]|$)" "$file"; then
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
