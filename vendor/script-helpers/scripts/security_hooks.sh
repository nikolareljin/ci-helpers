#!/usr/bin/env bash
# SCRIPT: security_hooks.sh
# DESCRIPTION: The security steps every git hook runs, sourced by scripts/git-hooks/* and the global dispatcher.
# USAGE: source scripts/security_hooks.sh; sec_pre_push <refs-file> <remote-name> <url> | sec_pre_commit | sec_commit_msg <msg-file>
# PARAMETERS:
#   SCRIPT_HELPERS_SECURITY_DIR  Directory holding check_private_names.sh and
#                                check_sensitive.sh. Set by the global hooks;
#                                otherwise they are looked up in the repository.
#   Mandatory publication checks cannot be disabled with environment overrides.
#   FOXGUARD_CMD                 foxguard command to run (default: the pinned
#                                version: its binary in the cache, else a
#                                foxguard on PATH that reports that version).
#   SCRIPT_HELPERS_FOXGUARD_BLOCK  foxguard block level: off, critical, high,
#                                medium or low. With git config
#                                security.foxguardBlock also set, the stricter
#                                of the two applies. Neither: high.
#   SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE  1: a finding in a file
#                                whose base copy could not be scanned warns
#                                instead of blocking, for this push only.
#                                Any other value: it blocks.
# EXIT_CODES:
#   Sourced: no output, no exit. Each sec_* function returns 0 to let the
#   commit or push continue and 1 to refuse; sec_find returns 127 when a
#   check script is missing.
#   Executed: 0 for -h/--help; 2 for anything else (it must be sourced).
# EXAMPLE: source scripts/security_hooks.sh && sec_pre_push "$refs_file" origin "$url" || exit 1
# ----------------------------------------------------
# Run directly instead of sourced: -h/--help prints this header; anything else
# is a usage error, because the functions only make sense inside a hook.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    -h|--help) sed -n '2,/^# ----/p' "${BASH_SOURCE[0]}" | sed -e '/^# ---/d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "security_hooks.sh: source this file from a hook; see --help" >&2; exit 2 ;;
  esac
fi
#
# Order, in pre-push: private names (block) -> credentials, then personal
# identifiers and PII, both in check_sensitive.sh (block) -> foxguard (blocks
# new findings at or above the block level, default high; warns at off). The
# caller handles the deletions-only shortcut and the tests. Every function
# returns 0 to continue and 1 to refuse.
#
# No "already checked" marker is exported: an environment variable that skips
# the checks could be set by any parent process. A hook chained after these
# steps runs them again; that costs time, never coverage.

# sec_unchecked <hook> <reason>: a mandatory check could not run; refuse.
sec_unchecked() {
  echo "[$1] $2; refused." >&2
  return 1
}

# sec_scan_output <mode> [args]: results never leave a public or private clone.
sec_scan_output() {
  local gate
  gate="$(sec_find check_scan_output.sh)" || {
    sec_unchecked security "publication checker missing; reinstall the hooks"
    return 1
  }
  local out rc=0
  out="$(
  exec 2>&1
  bash "$gate" "$@"
  )" || rc=$?
  [[ -z "$out" ]] || printf '%s\n' "$out"
  # sec_guard keeps output in a private report. Lines for a file above 64 MiB
  # that was not fully checked (path and reason only) go to the terminal or the
  # CI log instead: fd 8 is the caller's stdout, fd 9 its stderr.
  if [[ "$rc" -eq 0 || "$rc" -eq 3 ]]; then
    { true >&8; } 2>/dev/null && { grep -E '^::warning title=Security check incomplete::' <<<"$out" >&8 || true; }
    { true >&9; } 2>/dev/null && { grep -E '^WARNING: security check incomplete' <<<"$out" >&9 || true; }
  fi
  return "$rc"
}

# sec_guard <check> [args]: diagnostics stay local; CI only receives a verdict.
sec_guard() (
  local report py rc=0 report_owner="${BASHPID-$$}" report_level="${BASH_SUBSHELL:-0}"
  trap - EXIT HUP INT TERM
  py="$(security_python || true)"
  [[ -n "$py" ]] || { security_notice Security; return 1; }
  if [[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ]]; then
    report="$("$py" -I "$_SEC_LIB_DIR/local_security_report.py" --temporary)" || {
      security_notice Security
      return 1
    }
    trap 'if [[ ${BASHPID-$$} == "$report_owner" && ${BASH_SUBSHELL:-0} == "$report_level" ]]; then rm -rf -- "${report%/*}"; fi' EXIT
    trap 'exit 1' HUP INT TERM
    if ! { printf 'SCRIPT_HELPERS_PRIVATE_SECURITY_REPORT_V1\n' >"$report"; } 2>/dev/null; then
      security_notice Security
      return 1
    fi
    { "$@" >>"$report" 2>&1; } 8>&1 9>&2 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      security_notice "$(security_notice_tool "$report")"
    fi
  else
    report="$("$py" -I "$_SEC_LIB_DIR/local_security_report.py")" || {
      echo 'Security checks could not create a private local report; refused.' >&2
      return 1
    }
    printf 'SCRIPT_HELPERS_PRIVATE_SECURITY_REPORT_V1\n' >"$report" || return 1
    "$@" 8>&1 9>&2 >>"$report" 2>&1 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      printf 'Security checks passed. Local report: %s\n' "$report"
    else
      printf 'Security issues found. Local report: %s\n' "$report" >&2
      security_notice "$(security_notice_tool "$report")" "$report"
    fi
  fi
  return "$rc"
)

_SEC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_SEC_LIB_DIR/security_notice.sh"
# A copy without remote_excludes.sh excludes nothing: every pushed commit is checked.
# shellcheck source=/dev/null
source "$_SEC_LIB_DIR/remote_excludes.sh" 2>/dev/null || remote_excludes() { return 1; }

# sec_find <script>: path of a security script, or return 127.
sec_find() {
  local name="$1" top candidate
  # Set by the global hooks: their own copy and nothing else, so a missing
  # script there never falls back to one from the repository being checked.
  if [[ -n "${SCRIPT_HELPERS_SECURITY_DIR:-}" ]]; then
    [[ -f "$SCRIPT_HELPERS_SECURITY_DIR/$name" ]] || return 127
    printf '%s' "$SCRIPT_HELPERS_SECURITY_DIR/$name"; return 0
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  for candidate in \
    "$top/scripts/script-helpers/scripts/$name" \
    "$top/vendor/script-helpers/scripts/$name" \
    "$top/scripts/$name"; do
    [[ -f "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  # Last, the copy next to this library (the hooks a repository points at).
  if [[ -f "$_SEC_LIB_DIR/$name" ]]; then
    printf '%s' "$_SEC_LIB_DIR/$name"; return 0
  fi
  return 127
}

# A stale dictionary misses every repository created since it was built, and
# nothing reports that. Kick a refresh into the background when it ages: never
# blocking, never failing the push, at most one at a time.
#
# Deliberately not a systemd timer or a launchd agent: this has to behave the
# same on Linux, macOS and Windows, and git runs its hooks under bash on all
# three. Nothing to install.
sec_maybe_refresh_private_names() {
  local list="${PRIVATE_NAMES_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/private-names.tsv}"
  local age_days="${PRIVATE_NAMES_REFRESH_DAYS:-7}"
  [[ "${PRIVATE_NAMES_AUTO_REFRESH:-true}" == true ]] || return 0
  command -v gh >/dev/null 2>&1 || return 0

  local refresher
  refresher="$(sec_find refresh_private_names.sh)" || return 0

  # Fresh enough, nothing to do. A missing list counts as stale.
  if [[ -s "$list" ]] && [[ -z "$(find "$list" -mtime "+$age_days" 2>/dev/null)" ]]; then
    return 0
  fi

  # Hooks run at the top of the working tree, so a relative path would have the
  # list (with its temporary file, log and lock) or the per-owner caches, which
  # hold the same names, written into the repository being pushed. Those are
  # what the gate keeps out of public trees: refresh only when they, and
  # TMPDIR (its temporary files hold the names too), are absolute. The cache
  # directory is derived as refresh_private_names.sh does. Drive-letter and UNC
  # forms are absolute only on Windows; elsewhere they are relative names.
  local cache_dir="${PRIVATE_NAMES_CACHE_DIR:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/script-helpers/owners}"
  local p
  for p in "$list" "$cache_dir" "${TMPDIR:-/tmp}"; do
    case "$p" in
      /*) continue ;;
    esac
    case "${OSTYPE:-}" in
      msys*|cygwin*|win32*)
        case "$p" in
          [A-Za-z]:[\\/]*|\\\\*) continue ;;
        esac ;;
    esac
    echo "[pre-push] private-name list is stale, but a path it uses is not absolute (PRIVATE_NAMES_FILE, PRIVATE_NAMES_CACHE_DIR, XDG_CONFIG_HOME, HOME or TMPDIR); not refreshing it here."
    return 0
  done

  # One at a time. mkdir is the atomic primitive available everywhere; a stale
  # lock older than a day is cleared, so a killed refresh cannot wedge it.
  local lock="${list}.refresh.lock"
  [[ -d "$lock" ]] && [[ -n "$(find "$lock" -mtime +1 2>/dev/null)" ]] && rmdir "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || return 0

  echo "[pre-push] private-name list is stale; refreshing in the background."
  # No EXIT trap here: a trap in a backgrounded subshell is the construct
  # run_bounded_test refuses, and it buys nothing. A refresh that is killed
  # leaves the lock, which the day-old check above clears.
  (
    # --out: the list whose age was just checked, not the default one. A
    # refresher staged before it read PRIVATE_NAMES_FILE would write elsewhere.
    bash "$refresher" --out "$list" >"${list}.refresh.log" 2>&1
    rmdir "$lock" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  return 0
}

# sec_not_remote <remote-name>: git log arguments excluding what the push
# target already has. Only that remote's tracking refs count, and only when
# remote_excludes.sh trusts them: a commit already on some other remote (a
# private one, say) is still news to this one. A push to a bare URL has no
# remote refs, so everything it sends is checked.
sec_not_remote() {
  local ids
  if ids="$(remote_excludes . "${1:-}")"; then
    printf -- '--not %s' "${ids//$'\n'/ }"
  else
    printf -- '--not'
  fi
}

# sec_revs <refs-file> <remote-name>: one line of git log arguments per pushed
# ref: what that ref sends that the target does not have.
sec_revs() {
  local lref lsha rref rsha
  # shellcheck disable=SC2034
  while read -r lref lsha rref rsha; do
    [[ -n "${lsha:-}" ]] || continue
    [[ "$lsha" =~ ^0+$ ]] && continue          # a deletion carries no commits
    if [[ "${rsha:-0}" =~ ^0+$ ]] || ! git cat-file -e "${rsha}^{commit}" 2>/dev/null; then
      # A new branch, or a remote tip this clone never fetched: everything the
      # target remote does not already have (see sec_not_remote).
      printf '%s %s\n' "$lsha" "$(sec_not_remote "${2:-}")"
    else
      printf '%s..%s\n' "$rsha" "$lsha"
    fi
  done < "$1"
}

# sec_changed_files <refs-file> <remote-name>: "<commit><TAB><path>" for every
# file a pushed ref adds or changes and still has at its tip, once per pair.
# <commit> is that ref's pushed tip, so a caller reads the content being pushed
# (git show <commit>:<path>), not the work tree. -z: git would otherwise quote a
# path with non-ASCII characters; a path holding a tab or newline is skipped.
# One git log and one cat-file per pushed ref, however many commits and files:
# naming each path once per commit and checking each with its own process took
# 5 s for a 363-file first push here.
# Writes nothing: the list is a variable, and pipes carry the rest.
sec_changed_files() {
  local revs tip f t list
  while IFS= read -r revs; do
    case "$revs" in
      *..*) tip="${revs##*..}" ;;
      *)    tip="${revs%% *}" ;;
    esac
    # shellcheck disable=SC2086
    list="$(git log -z --name-only --format= --diff-filter=ACMR $revs 2>/dev/null \
      | while IFS= read -r -d '' f; do
          f="${f#$'\n'}"
          if [[ -n "$f" && "$f" != *$'\t'* && "$f" != *$'\n'* ]]; then printf '%s\n' "$f"; fi
        done | LC_ALL=C sort -u)"
    [[ -n "$list" ]] || continue
    # One answer line per question, in order; "<name> missing" for a path the
    # tip no longer has (deleted by a later commit of the push).
    printf '%s\n' "$list" | while IFS= read -r f; do printf '%s:%s\n' "$tip" "$f"; done \
      | git cat-file --batch-check='%(objecttype)' 2>/dev/null \
      | paste - <(printf '%s\n' "$list") | while IFS=$'\t' read -r t f; do
          # if, not &&: a last path the tip no longer has must not make the
          # loop, and under pipefail the whole list, fail.
          if [[ "$t" == blob || "$t" == commit ]]; then printf '%s\t%s\n' "$tip" "$f"; fi
        done
  done < <(sec_revs "$1" "${2:-}") | LC_ALL=C sort -u
}

# sec_push_head_line <remote-name>: for a push that came with no ref lines,
# one ref line for HEAD when it has commits the remote's tracking refs lack;
# nothing when it has none. git sends no lines when every ref is up to date or
# will be rejected, but a hook manager that drops git's stdin sends none too,
# and that must not wave the push through: HEAD's unpushed commits are checked
# instead. A git error prints the line (checked, not skipped).
sec_push_head_line() {
  local head ref out
  head="$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || return 0
  # shellcheck disable=SC2046
  if out="$(git rev-list -n 1 "$head" $(sec_not_remote "${1:-}") 2>/dev/null)"; then
    [[ -n "$out" ]] || return 0
  fi
  ref="$(git symbolic-ref -q HEAD 2>/dev/null || echo HEAD)"
  printf '%s %s %s %s\n' "$ref" "$head" "$ref" "${head//?/0}"
}

# sec_tag_messages <refs-file>: the message of every annotated tag the push
# sends (each level of a tag of a tag), without its signature. 1 = unreadable.
sec_tag_messages() {
  local lref lsha rref rsha t body
  # shellcheck disable=SC2034
  while read -r lref lsha rref rsha; do
    [[ -n "${lsha:-}" ]] || continue
    t="$lsha"
    while [[ "$(git cat-file -t "$t" 2>/dev/null)" == tag ]]; do
      body="$(git cat-file tag "$t" 2>/dev/null)" || return 1
      [[ "$t" == "${rsha:-}" ]] || printf '%s\n' "$body" | LC_ALL=C awk '/^-----BEGIN (PGP|SSH) SIGNATURE-----/ { s = 1 } p && !s { print } /^$/ { p = 1 }'
      t="$(printf '%s\n' "$body" | LC_ALL=C awk '!f && $1 == "object" { print $2; f = 1 }')"
      [[ -n "$t" ]] || break
    done
  done < "$1"
  return 0
}

# A private repository's name must never reach a public one, and a push is the
# last moment it can be stopped: GitHub keeps the edit history of every pull
# request and issue body publicly, and rewriting commits changes every tag.
#
# Both the tracked tree and the messages of the commits actually being pushed.
# The check decides for itself whether this repository is one the rule applies
# to, so the hook can be installed everywhere rather than only where someone
# remembered to configure it.
sec_private_names() {
  local refs="$1" remote="${2:-}" url="${3:-}" gate rc revs
  # Public or private is the push target's, not origin's: a private repository
  # pushed to a public mirror must be checked. --for-repo takes the target.
  local -a target=()
  [[ -n "$url" ]] && target=(--for-repo "$url")
  gate="$(sec_find check_private_names.sh)" || {
    sec_unchecked pre-push "check_private_names.sh not found; private names NOT checked"
    return
  }

  sec_maybe_refresh_private_names

  bash "$gate" --tree --only-public "${target[@]+"${target[@]}"}"
  rc=$?
  # 2 means it could not check -- no name list, most often. That is a setup
  # problem rather than a clean tree, and it is deliberately a different exit
  # code from "found something" so the two can never be confused.
  if [[ "$rc" -eq 1 ]]; then
    echo "[pre-push] A tracked file names a private repository. Cite it by its code." >&2
    return 1
  elif [[ "$rc" -ne 0 ]]; then
    sec_unchecked pre-push "the private-name check could not run on the tree (exit $rc)" || return 1
  fi

  # The messages go to a file first, and the gate is called on the file.
  #
  # This used to be `... done < refs | bash "$gate" --stdin`, with `rc=$?` read straight
  # after. Under `set -o pipefail` that is the PIPELINE's status, not the gate's: when
  # `git log` failed -- a shallow clone, or a remote ref never fetched -- rc was git's 128,
  # the `-eq 1` test below did not fire, and the commit-message check silently did nothing
  # while the push went ahead. The mirror case was worse: anything on the left exiting 1
  # blocked the push and blamed a private name that was not there.
  local messages="${refs}.messages" log_failed=0
  : > "$messages"
  while IFS= read -r revs; do
    # shellcheck disable=SC2086  # revs is a list of git log arguments
    git log --format='%B' $revs >> "$messages" 2>/dev/null || log_failed=1
  done < <(sec_revs "$refs" "$remote")

  if [[ "$log_failed" -eq 1 ]]; then
    # Distinct from both "clean" and "found something", because it is neither.
    sec_unchecked pre-push "could not read every outgoing commit message (shallow clone, or a remote ref never fetched)" || { rm -f -- "$messages"; return 1; }
  fi

  bash "$gate" --file "$messages" --only-public "${target[@]+"${target[@]}"}"
  rc=$?
  rm -f -- "$messages"
  if [[ "$rc" -eq 1 ]]; then
    echo "[pre-push] A commit message names a private repository." >&2
    echo "[pre-push] To override:  PRIVATE_NAMES_ALLOW=<term> git push ..." >&2
    echo "[pre-push]              or git push --no-verify" >&2
    return 1
  elif [[ "$rc" -ne 0 ]]; then
    sec_unchecked pre-push "the private-name check could not run on the commit messages (exit $rc)" || return 1
  fi

  # Tag messages: one gate run over all of them (a run costs ~0.3s, and a
  # first push can carry hundreds of tags), then, only on a hit, one run per
  # tag so the refusal names the tag instead of blaming the commit messages.
  if ! sec_tag_messages "$refs" > "$messages"; then
    rm -f -- "$messages"
    sec_unchecked pre-push "could not read every outgoing tag message" || return 1
    return 0
  fi
  [[ -s "$messages" ]] || { rm -f -- "$messages"; return 0; }
  bash "$gate" --file "$messages" --only-public "${target[@]+"${target[@]}"}" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -ne 1 ]]; then
    rm -f -- "$messages"
    [[ "$rc" -eq 0 ]] && return 0
    sec_unchecked pre-push "the private-name check could not run on the tag messages (exit $rc)" || return 1
    return 0
  fi

  local lref lsha rref rsha label="A tag message" one="${refs}.tag"
  # shellcheck disable=SC2034
  while read -r lref lsha rref rsha; do
    # Every ref, not only refs/tags/: a tag object can be pushed to any ref.
    printf '%s %s %s %s\n' "$lref" "$lsha" "$rref" "${rsha:-}" > "$one"
    if ! sec_tag_messages "$one" > "$messages" || [[ ! -s "$messages" ]]; then
      continue
    fi
    bash "$gate" --file "$messages" --only-public "${target[@]+"${target[@]}"}"
    if [[ $? -eq 1 ]]; then
      case "$rref" in
        refs/tags/*) label="The message of tag ${rref#refs/tags/}" ;;
        *)           label="The message of the tag pushed to $rref" ;;
      esac
      break
    fi
  done < "$refs"
  rm -f -- "$one" "$messages"
  echo "[pre-push] $label names a private repository." >&2
  echo "[pre-push] To override:  PRIVATE_NAMES_ALLOW=<term> git push ..." >&2
  echo "[pre-push]              or git push --no-verify" >&2
  return 1
}

# sec_lib_root: the script-helpers copy the security scripts come from (it
# holds helpers.sh and lib/), or return 1.
sec_lib_root() {
  local gate r
  gate="$(sec_find check_sensitive.sh)" || return 1
  r="$(cd "$(dirname "$gate")/.." && pwd)" || return 1
  [[ -f "$r/helpers.sh" ]] || return 1
  printf '%s' "$r"
}

# sec_may_install: a missing scanner may be downloaded here. Not in CI (it
# installs its own tools) and not with SCRIPT_HELPERS_NO_AUTO_INSTALL=1.
sec_may_install() {
  [[ -z "${CI:-}" && "${SCRIPT_HELPERS_NO_AUTO_INSTALL:-}" != 1 ]]
}

# sec_gitleaks_present: gitleaks where check_sensitive.sh looks for it:
# GITLEAKS_BIN (run as given), else what lib/gitleaks.sh accepts: one on PATH
# at the pinned version or newer, or the cached pinned binary. An older
# gitleaks on PATH is not present.
sec_gitleaks_present() {
  local r
  if [[ -n "${GITLEAKS_BIN:-}" ]]; then [[ -x "$GITLEAKS_BIN" ]]; return; fi
  r="$(sec_lib_root)" || return 1
  # shellcheck source=/dev/null
  ( source "$r/helpers.sh" && shlib_import logging foxguard gitleaks >/dev/null 2>&1 && gitleaks_bin >/dev/null 2>&1 )
}

# sec_gitleaks_missing: why sec_gitleaks_present found none, in one line.
sec_gitleaks_missing() {
  local r why=""
  if r="$(sec_lib_root 2>/dev/null)"; then
    # shellcheck source=/dev/null
    why="$( source "$r/helpers.sh" >/dev/null 2>&1 && shlib_import logging foxguard gitleaks >/dev/null 2>&1 && gitleaks_missing_reason 2>/dev/null )" || why=""
  else
    why="lib/gitleaks.sh was not found, so the minimum gitleaks version is unknown"
  fi
  printf '%s' "${why:-gitleaks is not installed}"
}

# sec_foxguard_newer_note <cmd>: the warning for a foxguard on PATH in a newer
# breaking series than the pin, on stderr. Nothing for FOXGUARD_CMD.
sec_foxguard_newer_note() {
  local r warn=""
  [[ -z "${FOXGUARD_CMD:-}" ]] || return 0
  r="$(sec_lib_root 2>/dev/null)" || return 0
  # shellcheck source=/dev/null
  warn="$( source "$r/helpers.sh" >/dev/null 2>&1 && shlib_import logging foxguard >/dev/null 2>&1 && foxguard_version_warning "$1" 2>/dev/null )" || warn=""
  [[ -z "$warn" ]] || echo "[pre-push] $warn" >&2
  return 0
}

# sec_offer_install <tool> <what it runs> [<why>]: install the pinned <tool>
# (downloaded, SHA-256 checked) when sec_may_install allows: 0 = installed.
# Otherwise, or when the install fails, print how to install it: 1. <why> is
# what is wrong now; the default is "<tool> is not installed".
sec_offer_install() {
  local tool="$1" what="$2" r
  r="$(sec_lib_root 2>/dev/null || true)"
  if [[ -n "$r" ]] && sec_may_install; then
    echo "[pre-push] ${3:-$tool is not installed}; installing the pinned release to run $what." >&2
    # shellcheck source=/dev/null
    if ( source "$r/helpers.sh" && shlib_import logging foxguard gitleaks && "${tool}_install" ) >&2; then
      echo "[pre-push] $tool installed." >&2
      return 0
    fi
    echo "[pre-push] $tool install failed (see above)." >&2
  fi
  # The staged copies of the global and repository hooks carry no setup-hooks.sh.
  if [[ -n "$r" && -f "$r/scripts/setup-hooks.sh" ]]; then
    echo "[pre-push] To install $tool: bash $r/scripts/setup-hooks.sh --install-$tool (or see docs/security-gates.md)." >&2
  else
    echo "[pre-push] To install $tool: scripts/setup-hooks.sh --install-$tool in a script-helpers checkout (or see docs/security-gates.md)." >&2
  fi
  return 1
}

# Credentials, personal identifiers and PII in the added lines and messages.
# Exit 2 (could not check: gitleaks missing, commits unreadable) refuses the
# push: a credential scan that did not run is not a clean one.
sec_sensitive_push() {
  local refs="$1" remote="${2:-}" gate rc why
  gate="$(sec_find check_sensitive.sh)" || {
    sec_unchecked pre-push "check_sensitive.sh not found; credentials and personal data NOT checked"
    return
  }
  # Missing gitleaks: installed (not in CI, nor with
  # SCRIPT_HELPERS_NO_AUTO_INSTALL=1); still missing, the scan exits 2 and the
  # push is refused below.
  if [[ -n "${GITLEAKS_BIN:-}" && ! -x "$GITLEAKS_BIN" ]]; then
    # Only that path counts: an install elsewhere would not be used.
    echo "[pre-push] ERROR: GITLEAKS_BIN is $GITLEAKS_BIN, which is not an executable; the credential scan cannot run." >&2
  elif ! sec_gitleaks_present; then
    # An ERROR only when it stays missing: an older gitleaks on PATH that the
    # pinned release replaces here is not one.
    why="$(sec_gitleaks_missing)"
    if ! sec_offer_install gitleaks "the credential scan" "$why"; then
      echo "[pre-push] ERROR: $why; the credential scan cannot run." >&2
    fi
  fi
  bash "$gate" --no-inline-allow --push-refs "$refs" --remote "$remote"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      echo "[pre-push] Sensitive data in the commits being pushed; push refused." >&2
      echo "[pre-push] Rewrite the commit that added it (git rebase -i), not a follow-up commit:" >&2
      echo "[pre-push] the push carries every commit, so the value would still be published." >&2
      return 1
      ;;
    *) sec_unchecked pre-push "sensitive-data check could not run (exit $rc)" ;;
  esac
}

# sec_foxguard_cmd: the foxguard to run: FOXGUARD_CMD, else the pinned release
# as lib/foxguard.sh finds it (the cached binary of the pinned version, checked
# against the pinned SHA-256, else one on PATH that reports that version or a
# newer one). Return 1 when there is none: another cached version is never run,
# nor an older foxguard on PATH.
sec_foxguard_cmd() {
  local r
  if [[ -n "${FOXGUARD_CMD:-}" ]]; then printf '%s' "$FOXGUARD_CMD"; return 0; fi
  r="$(sec_lib_root 2>/dev/null)" || return 1
  # shellcheck source=/dev/null
  ( source "$r/helpers.sh" >/dev/null 2>&1 && shlib_import logging foxguard >/dev/null 2>&1 && foxguard_bin 2>/dev/null ) || return 1
}

# sec_foxguard_missing: why sec_foxguard_cmd found none, in one line.
sec_foxguard_missing() {
  local r why=""
  if r="$(sec_lib_root 2>/dev/null)"; then
    # shellcheck source=/dev/null
    why="$( source "$r/helpers.sh" >/dev/null 2>&1 && shlib_import logging foxguard >/dev/null 2>&1 && foxguard_missing_reason 2>/dev/null )" || why=""
  else
    why="lib/foxguard.sh was not found, so the pinned foxguard version is unknown"
  fi
  printf '%s' "${why:-foxguard is not installed}"
}

# sec_foxguard_platform_ok: foxguard publishes a binary for this machine
# (Linux and macOS x86_64/arm64, Windows x86_64).
sec_foxguard_platform_ok() {
  case "$(uname -s)" in Linux|Darwin|MINGW*|MSYS*|CYGWIN*) ;; *) return 1 ;; esac
  case "$(uname -s)/$(uname -m)" in
    MINGW*/x86_64|MSYS*/x86_64|CYGWIN*/x86_64) return 0 ;;
    MINGW*|MSYS*|CYGWIN*) return 1 ;;
  esac
  case "$(uname -m)" in x86_64|amd64|aarch64|arm64) return 0 ;; esac
  return 1
}

# sec_loud <text>: a warning meant to be seen: bold yellow on a terminal
# (plain in CI or with NO_COLOR), framed by rules either way.
sec_loud() {
  local y="" r=""
  # Plain in CI and with NO_COLOR, as the SSH note.
  if [[ -t 2 && -z "${NO_COLOR:-}" && -z "${CI:-}" ]]; then y=$'\033[1;33m'; r=$'\033[0m'; fi
  printf '%s[pre-push] ========================================================%s\n' "$y" "$r" >&2
  printf '%s[pre-push] WARNING: %s%s\n' "$y" "$1" "$r" >&2
  printf '%s[pre-push] ========================================================%s\n' "$y" "$r" >&2
}

# sec_foxguard_left_out <exit status> <output>: why foxguard left the one file
# of a run out, from its summary line ("Skipped 1 file: 1 parse error."):
# "parse error", "noise path", "unsupported extension". Nothing when it read
# the file. A skip line ("warning: skipping <file> (<reason>)") is not read: it
# carries the file name, and a file named "Skipped 1 file: 1 unsupported
# extension..py" with a parse error was not left out for its extension. A run
# with findings read the file, and prints lines of it.
sec_foxguard_left_out() {
  [[ "$1" -eq 0 ]] || return 0
  printf '%s\n' "$2" | LC_ALL=C sed -n -e '/warning: skipping /d' -e 's/^.*Skipped 1 file: 1 \([^.]*\)\..*$/\1/p' | sed -n 1p
}

# sec_foxguard_warn <refs-file> <remote>: foxguard at security.foxguardBlock=off.
# Never blocks: a missing foxguard (installed when it can be), a failed scan
# and every finding are loud warnings, and the push goes on. Each changed file
# is scanned where it is, under the repository's foxguard config, and never
# as a copy: a copy elsewhere is judged without that config. A file foxguard
# does not read there is named and counted: one it drops as noise (a noise
# path such as a/build/x.py, a noise name such as x.min.js), one whose
# extension it reads in lower case only (app.PY), a parse error, a file that
# is too large. A file type it does not know is not named.
sec_foxguard_warn() {
  local refs="$1" remote="${2:-}" cmd f out rc frc=0 shown=0 failed=0 r base="" issues=0 hit=0 k
  local probes="" unread=0 x e lx mr p pout prc n=0 why cr=$'\r'
  if ! cmd="$(sec_foxguard_cmd)"; then
    if ! sec_foxguard_platform_ok; then
      sec_loud "the foxguard scan did NOT run: foxguard has no binary for $(uname -s) $(uname -m)."
      return 0
    fi
    if ! { sec_offer_install foxguard "the static-analysis scan of the changed files" "$(sec_foxguard_missing)" && cmd="$(sec_foxguard_cmd)"; }; then
      sec_loud "the foxguard scan did NOT run: $(sec_foxguard_missing) (see above to install the pinned one)."
      return 0
    fi
  fi
  sec_foxguard_newer_note "$cmd"
  # The changed files that exist here, in an array: nothing written to disk.
  local files=()
  while IFS= read -r f; do
    [[ -f "$f" ]] && files+=("$f")
  done < <(sec_changed_files "$refs" "$remote" | cut -f2- | LC_ALL=C sort -u)
  [[ ${#files[@]} -gt 0 ]] || return 0
  # Distinguish reported findings from scanner execution errors.
  for f in "${files[@]}"; do
    rc=0
    # "./" in front of a name that starts with a dash: a path, not an option.
    x="$f"; case "$f" in -*) x="./$f" ;; esac
    # shellcheck disable=SC2086  # FOXGUARD_CMD may carry arguments
    out="$($cmd "$x" 2>&1)" || rc=$?
    why="$(sec_foxguard_left_out "$rc" "$out")"
    # Left out for an extension with an upper-case letter: foxguard knows an
    # extension in lower case only, and app.PY still runs. Whether it reads
    # the name in lower case is asked of an empty file of that name, under
    # the same directories (and of probe.<extension> beside it, for ".PY"):
    # nothing of the file is copied. Each file has a directory of its own, so
    # the empty file of one is never where the next needs a directory. When
    # foxguard cannot be asked, the file is named too.
    x="${f##*/}"; e="${x##*.}"; n=$((n + 1))
    if [[ "$why" == "unsupported extension" && "$x" == *.* ]]; then
      # A tr that fails leaves the case unknown: name the file.
      lx="$(printf '%s' "$e" | LC_ALL=C tr 'A-Z' 'a-z')" || { lx=""; why="upper-case extension"; }
      if [[ -n "$lx" && "$lx" != "$e" ]]; then
        mr=""; case "$f" in */*) mr="${f%/*}/" ;; esac
        why="upper-case extension"
        if { [[ -n "$probes" ]] || probes="$(mktemp -d "${TMPDIR:-/tmp}/sh-foxguard.XXXXXX" 2>/dev/null)"; } \
          && mkdir -p "$probes/$n/$mr" 2>/dev/null; then
          why="unsupported extension"
          for k in "${x%.*}.$lx" "probe.$lx"; do
            p="$mr$k"; case "$p" in -*) p="./$p" ;; esac
            prc=0; pout=""
            if : 2>/dev/null > "$probes/$n/$mr$k"; then
              # shellcheck disable=SC2086
              pout="$(cd "$probes/$n" && $cmd "$p" 2>&1)" || prc=$?
            else
              prc=2
            fi
            # foxguard reads that name, or could not be asked: say so.
            if [[ "$(sec_foxguard_left_out "$prc" "$pout")" != "unsupported extension" ]]; then why="upper-case extension"; break; fi
          done
        fi
      fi
    fi
    # Not read, and not for a file type foxguard does not know: say so.
    if [[ -n "$why" && "$why" != "unsupported extension" ]]; then
      unread=$((unread + 1))
      printf '%s (%s)\n' "$f" "$why" | sec_foxguard_show '[pre-push] foxguard: not scanned: '
    fi
    case "$rc" in
      0) ;;
      1)
        hit=$((hit + 1))
        # Its summary line, "N issues" (terminal format); 1 when it has none.
        k="$(printf '%s\n' "$out" | LC_ALL=C sed -n -e 's/^[^0-9]*\([0-9][0-9]*\) issues\{0,1\}$/\1/p' -e 's/^[^0-9]*\([0-9][0-9]*\) issues\{0,1\}[^a-z].*/\1/p' | tail -1)"
        issues=$((issues + ${k:-1}))
        if [[ -n "${out//[[:space:]]/}" ]]; then shown=$((shown + 1)); fi
        # foxguard prints the file name as it is: through sec_foxguard_show,
        # so a carriage return in it cannot draw over the line. Its progress
        # ("<CR>  foxguard v0.14.2 . scanning... ") and the blanks that wipe
        # it are left out. Only those: a message of its own (a rule it could
        # not load, an unknown rule id in the config) follows the progress on
        # the same line, and is shown.
        while IFS= read -r r; do
          if [[ "$r" == "$cr"* ]]; then
            r="${r#"$cr"}"
            case "$r" in "  foxguard v"*"scanning..."*) r="${r#*scanning...}"; r="${r# }" ;; esac
          fi
          [[ -n "${r//[[:space:]]/}" ]] || continue
          printf '[pre-push] WARNING (foxguard): %s\n' "$r"
        done < <(printf '%s\n' "$out") | sec_foxguard_show '' ;;
      *)
        failed=$((failed + 1)); frc="$rc"
        while IFS= read -r r; do printf '[pre-push] foxguard (%s): %s\n' "$f" "$r"; done < <(printf '%s\n' "$out" | sed -n 1,3p) | sec_foxguard_show '' ;;
    esac
  done
  if [[ -n "$probes" ]]; then rm -rf -- "$probes"; fi
  [[ "$failed" -gt 0 ]] && sec_loud "the foxguard scan did NOT run on $failed of ${#files[@]} file(s) (exit $frc)."
  [[ "$unread" -gt 0 ]] && sec_loud "foxguard did NOT read $unread of ${#files[@]} changed file(s) (named above as not scanned)."
  if [[ "$shown" -gt 0 ]]; then
    sec_loud "foxguard: $issues finding(s) in $hit of ${#files[@]} changed file(s) (above). They do not block the push (security.foxguardBlock is off)."
    # The base for the report: the remote's commit of the first updated ref.
    base="$(awk '$4 !~ /^0+$/ && $2 !~ /^0+$/ { print $4; exit }' "$refs" 2>/dev/null || true)"
    echo "[pre-push] Keep them as JSON (evidence, or to compare later):" >&2
    if [[ -n "$base" ]]; then
      echo "[pre-push]   bash $(sec_lib_root 2>/dev/null || echo scripts/script-helpers)/scripts/foxguard_report.sh --base $base" >&2
    else
      echo "[pre-push]   bash $(sec_lib_root 2>/dev/null || echo scripts/script-helpers)/scripts/foxguard_report.sh -- <files above>" >&2
    fi
    echo "[pre-push] To review them, and secrets across the whole history, in VS Code: leak-lock, https://nikolareljin.github.io/leak-lock/" >&2
  fi
  return 0
}

# sec_foxguard_rank <level>: 0 off .. 4 low, the order of strictness; 1 when
# <level> is not one.
sec_foxguard_rank() {
  case "$1" in
    off) echo 0 ;; critical) echo 1 ;; high) echo 2 ;; medium) echo 3 ;; low) echo 4 ;;
    *) return 1 ;;
  esac
}

# sec_foxguard_level: the effective block level, from git config
# security.foxguardBlock and SCRIPT_HELPERS_FOXGUARD_BLOCK. Set in both: the
# stricter wins, so an environment variable cannot weaken a repository's
# setting. Neither: high. A value that is not off, critical, high, medium or
# low returns 2 with the reason on stderr; it is never read as off.
sec_foxguard_level() {
  local cfg env rc=0 level="" value name v
  cfg="$(git config --get security.foxguardBlock 2>/dev/null)" || rc=$?
  if [[ "$rc" -gt 1 ]]; then
    echo "[pre-push] ERROR: git config security.foxguardBlock could not be read (exit $rc)." >&2
    return 2
  fi
  env="${SCRIPT_HELPERS_FOXGUARD_BLOCK:-}"
  for name in "git config security.foxguardBlock" SCRIPT_HELPERS_FOXGUARD_BLOCK; do
    if [[ "$name" == SCRIPT_HELPERS_FOXGUARD_BLOCK ]]; then
      [[ -n "$env" ]] || continue
      value="$env"
    else
      [[ "$rc" -eq 0 ]] || continue
      value="$cfg"
    fi
    v="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    if ! sec_foxguard_rank "$v" >/dev/null; then
      echo "[pre-push] ERROR: $name is '$value'; use off, critical, high, medium or low." >&2
      return 2
    fi
    if [[ -z "$level" || "$(sec_foxguard_rank "$v")" -gt "$(sec_foxguard_rank "$level")" ]]; then level="$v"; fi
  done
  printf '%s\n' "${level:-high}"
}

# sec_foxguard_refuse <level> <reason> [<fix>]: the scan could not decide;
# refuse. <fix> is the remedy for this cause; the default is to install foxguard.
sec_foxguard_refuse() {
  echo "Foxguard check failed: $2." >&2
  echo "[pre-push] ERROR: $2; security.foxguardBlock is $1, so the push is refused." >&2
  echo "[pre-push] ${3:-Install the pinned foxguard: scripts/setup-hooks.sh --install-foxguard} (see docs/security-gates.md)," >&2
  echo "[pre-push] or only warn in this repository: git config security.foxguardBlock off" >&2
  return 1
}

# sec_foxguard_tree <commit> <map-file> <dir>: for each "<src><TAB><dst>" line,
# the blob of <commit> at <src>, written under <dir> as <dst>. A path the
# commit lacks, a symlink and a submodule are left out: only regular files are
# code foxguard should read. Ignore files (.ignore and the like) are never
# written: foxguard honours .ignore, so a pushed one could hide the files
# beside it. Inline suppressions ("foxguard: ignore" in a comment, any
# case) are defused on every side, so a push cannot silence a finding it adds.
# <src> is read as a literal path: ":(top)x.py" and ":!x.py" are file names
# here, not pathspec magic that would leave the file out unscanned, and
# "-z/x.py" is a path, not an option of dirname. Return 1 when git or a write
# fails. Return 2 when <dst> is already in <dir>: two names that are one file
# on this file system (they differ in case, or in Unicode form, on macOS and
# Windows), where the second would replace the first and the first would never
# be scanned. The same when a file is where a directory of <dst> must be (A
# and a/x.py). SEC_FOXGUARD_CLASH then holds that <dst>.
sec_foxguard_tree() {
  local c="$1" src dst mode up defuse='s/[Ff][Oo][Xx][Gg][Uu][Aa][Rr][Dd]/f0xguard/g'
  SEC_FOXGUARD_CLASH=""
  mkdir -p "$3" || return 1
  while IFS=$'\t' read -r src dst; do
    [[ -n "$src" && -n "$dst" ]] || continue
    case "/$dst/" in */../*|*/./*|//*) return 1 ;; esac
    case "${dst##*/}" in .*ignore) continue ;; esac
    mode="$(git --literal-pathspecs ls-tree --full-tree "$c" -- "$src" 2>/dev/null)" || return 1
    mode="${mode%% *}"
    [[ "$mode" == 100644 || "$mode" == 100755 ]] || continue
    if [[ -e "$3/$dst" || -L "$3/$dst" ]]; then SEC_FOXGUARD_CLASH="$dst"; return 2; fi
    # A file where a directory of <dst> must be: mkdir could only fail.
    up="$dst"
    while [[ "$up" == */* ]]; do
      up="${up%/*}"
      if [[ -e "$3/$up" && ! -d "$3/$up" ]]; then SEC_FOXGUARD_CLASH="$dst"; return 2; fi
    done
    mkdir -p "$3/$(dirname -- "$dst")" && git cat-file blob "$c:$src" > "$3.blob" || return 1
    # Any case and separator: foxguard 0.14.1 honours only "foxguard: ignore",
    # a later one may accept more.
    LC_ALL=C sed -e "$defuse" "$3.blob" > "$3/$dst" || return 1
    # Read back: not every sed reports a write that failed, and a short copy
    # would be scanned in place of the file.
    LC_ALL=C sed -e "$defuse" "$3.blob" | cmp -s - "$3/$dst" || return 1
  done < "$2"
}

# sec_foxguard_absent <commit> <map-file> <out>: the <dst> of each
# "<src><TAB><dst>" line whose <src> <commit> has no entry for, one per line
# in <out>. A base without the file neither read nor skipped it. A symlink, a
# submodule or a directory at <src> is an entry: not absent. Return 1 when git
# or the write fails.
sec_foxguard_absent() {
  local src dst entry
  : > "$3" || return 1
  while IFS=$'\t' read -r src dst; do
    [[ -n "$src" && -n "$dst" ]] || continue
    entry="$(git --literal-pathspecs ls-tree --full-tree "$1" -- "$src" 2>/dev/null)" || return 1
    if [[ -z "$entry" ]]; then printf '%s\n' "$dst" >> "$3" || return 1; fi
  done < "$2"
}

# sec_foxguard_skip_name <scanned name> <real path> <in> <out>: foxguard's
# messages of <in>, with a file scanned from its own directory or as a copy
# named by its real path. "skipping app.py" for src/dist/app.py would
# otherwise read as the app.py at the root. The shell writes <out>: a skip line
# lost there would be a skipped file nobody hears of. Return 1 when it fails.
sec_foxguard_skip_name() {
  local s
  s="$(C="$1" R="$2" awk '{ p = "skipping " ENVIRON["C"] " ("; i = index($0, p)
    if (i) $0 = substr($0, 1, i - 1) "skipping " ENVIRON["R"] " (" substr($0, i + length(p)); print }' "$3")" || return 1
  if [[ -n "$s" ]]; then printf '%s\n' "$s" > "$4"; else : > "$4"; fi
}

# sec_foxguard_noise <messages>: foxguard dropped the file as a noise path
# ("Skipped 1 file: 1 noise path."). A skip line is not read: it carries the
# file name, and "noise path.py" with a parse error is not a noise path.
sec_foxguard_noise() {
  awk '!/^warning: skipping / && /noise path/ { found = 1 } END { exit !found }' "$1"
}

# sec_foxguard_unsupported <messages>: foxguard left the file out for its
# extension ("Skipped 1 file: 1 unsupported extension."). A skip line is not
# read: it carries the file name.
sec_foxguard_unsupported() {
  awk '!/^warning: skipping / && /unsupported extension/ { found = 1 } END { exit !found }' "$1"
}

# sec_foxguard_show <prefix>: the lines of stdin on stderr, each after <prefix>.
# A control character is shown as "?": a carriage return or an escape sequence
# in a file name must not draw over the line that names the file. The same for
# the UTF-8 form of the C1 controls (U+0080 to U+009F: U+009B starts an escape
# sequence on some terminals) and of the characters that reorder, hide or
# break text, which foxguard_push_compare.py escapes too: U+00AD, U+0600 to
# U+0605, U+061C, U+06DD, U+070F, U+0890, U+0891, U+08E2, U+180E, U+200B to
# U+200F, U+2028 to U+202E, U+2060 to U+206F, U+FEFF, U+FFF9 to U+FFFB,
# U+110BD, U+110CD, U+13430 to U+1343F, U+1BCA0 to U+1BCA3, U+1D173 to U+1D17A
# and the tags U+E0000 to U+E007F. LC_ALL=C: bytes, whatever the locale.
sec_foxguard_show() {
  LC_ALL=C tr '\001-\010\013-\037\177' '?' \
    | LC_ALL=C sed -e $'s/\302[\200-\237\255]/?/g' -e $'s/\330[\200-\205\234]/?/g' -e $'s/\333\235/?/g' \
      -e $'s/\334\217/?/g' -e $'s/\340\242[\220\221]/?/g' -e $'s/\340\243\242/?/g' -e $'s/\341\240\216/?/g' \
      -e $'s/\342\200[\213-\217\250-\256]/?/g' -e $'s/\342\201[\240-\257]/?/g' \
      -e $'s/\357\273\277/?/g' -e $'s/\357\277[\271-\273]/?/g' \
      -e $'s/\360\221\202\275/?/g' -e $'s/\360\221\203\215/?/g' -e $'s/\360\223\220[\260-\277]/?/g' \
      -e $'s/\360\233\262[\240-\243]/?/g' -e $'s/\360\235\205[\263-\272]/?/g' -e $'s/\363\240[\200\201][\200-\277]/?/g' \
      -e "s/^/$1/" >&2
}

# sec_foxguard_skips <messages>: the lines of <messages> that name a file
# foxguard skipped, but for an unsupported extension (not code it reads).
# LC_ALL=C: a name is bytes, whatever the locale makes of them.
sec_foxguard_skips() {
  LC_ALL=C awk '/^warning: skipping .* \(.*\)$/ && !/\(unsupported extension\)$/' "$1"
}

# sec_foxguard_copy_name <name>: <name> for a copy of a file foxguard calls
# noise by its name (x.min.js): "._min" for each ".min", which is not noise.
# The rest stays: foxguard tells some files by their name (Dockerfile.x,
# nginx.conf, haproxy.cfg, Cargo.lock), and a copy named <n>.conf or <n>.js
# is an unsupported extension, or another language.
sec_foxguard_copy_name() {
  printf '%s\n' "${1//.min/._min}"
}

# sec_foxguard_scan_copy <cmd> <config> <file> <out> <n> <dirs> <name> <path>:
# foxguard on a copy of <file> named <dirs><name> under <out>/<n>.d, its
# report in <out>/<n>.json and its messages in <out>.one, the copy named
# there by its real <path>. SEC_FOXGUARD_RC holds foxguard's exit status.
# Return 1 when a write fails.
sec_foxguard_scan_copy() {
  SEC_FOXGUARD_RC=0
  # The report of the run before is emptied: a rerun that writes none must
  # not be read as that one.
  { mkdir -p "$4/$5.d/$6" && cat < "$3" > "$4/$5.d/$6$7" && : > "$4/$5.json"; } || return 1
  # shellcheck disable=SC2086  # FOXGUARD_CMD may carry arguments
  ( cd "$4/$5.d" && $1 --quiet --format json --output "$4/$5.json" --config "$2" -- "$6$7" ) </dev/null >/dev/null 2>"$4.two" || SEC_FOXGUARD_RC=$?
  sec_foxguard_skip_name "$6$7" "$8" "$4.two" "$4.one"
}

# sec_foxguard_scan <cmd> <config> <dir> <out> <list>: foxguard on each file
# of <list> (paths relative to <dir>) present in <dir>, one report per file
# in the directory <out>. One file at a time: a directory scan never reads
# hidden paths, and foxguard drops a path it calls noise (vendor/,
# node_modules/, build/ ...) without a word, so such a file is scanned again
# as a copy and <out>/<n>.path keeps its real name. A copy keeps its
# directories, each with "d_" in front (d_a/d_build/x.py): "d_build" is not
# noise ("_" alone would make the noise path __tests__ of _tests__), and
# foxguard tells some files by their path (conf.d/, nginx: with its own
# directory alone nginx/build/apache.conf would be read as an Apache config). It keeps its name too, but for the part that is noise
# (sec_foxguard_copy_name); <n>.<extension> is the name of last resort.
# foxguard knows an extension in lower case only, and app.PY still runs: such
# a file is scanned as a copy with the extension in lower case. Return 0
# scanned; 1 failed. Files it skipped for any reason but an unsupported
# extension (parse error, too large, still noise) are listed in <out>.skipped,
# each under its real path: the list says which base copies were never read.
# foxguard says "noise" only of a file type it knows, so one that no copy got
# read, whatever the last copy was left out for, is listed as a noise path.
# A .C or .H that does not parse as C is C++, which foxguard does not read:
# listed in <out>.cxx instead, for the caller to name.
# A list, a name or a message that cannot be written fails the scan: a short
# <out>.skipped would read as "nothing skipped", and the file would pass unread.
sec_foxguard_scan() {
  local rc f x e lx s c mr known under=/d_ k=0
  { mkdir -p "$4" && : > "$4.err" && : > "$4.skipped" && : > "$4.cxx"; } || return 1
  while IFS= read -r f; do
    [[ -n "$f" && -f "$3/$f" ]] || continue
    k=$((k + 1)); rc=0; known=0
    # Where a copy goes: the directories of <f>, each with "d_" in front.
    mr=""
    case "$f" in */*) mr="${f%/*}"; mr=d_${mr//\//$under}/ ;; esac
    x="${f##*/}"; e="${x##*.}"
    # shellcheck disable=SC2086  # FOXGUARD_CMD may carry arguments
    ( cd "$3" && $1 --quiet --format json --output "$4/$k.json" --config "$2" -- "$f" ) </dev/null >/dev/null 2>"$4.one" || rc=$?
    if [[ "$rc" -le 1 ]] && sec_foxguard_noise "$4.one"; then
      known=1; printf '%s\n' "$f" > "$4/$k.path" || return 1
      c="$(sec_foxguard_copy_name "$x")" || return 1
      sec_foxguard_scan_copy "$1" "$2" "$3/$f" "$4" "$k" "$mr" "$c" "$f" || return 1
      rc="$SEC_FOXGUARD_RC"
      if [[ "$rc" -le 1 ]] && sec_foxguard_noise "$4.one"; then
        # Still noise: a name foxguard drops that this hook does not know.
        sec_foxguard_scan_copy "$1" "$2" "$3/$f" "$4" "$k" "$mr" "$k.$e" "$f" || return 1
        rc="$SEC_FOXGUARD_RC"
      fi
    fi
    # Not read for its extension, which has an upper-case letter (app.PY,
    # x.Js): scan a copy with the extension in lower case.
    if [[ "$rc" -le 1 && "$x" == *.*[[:upper:]]* ]] && sec_foxguard_unsupported "$4.one"; then
      lx="$(printf '%s' "$e" | LC_ALL=C tr 'A-Z' 'a-z')" || return 1
      if [[ -n "$lx" && "$lx" != "$e" ]]; then
        printf '%s\n' "$f" > "$4/$k.path" || return 1
        c="$(sec_foxguard_copy_name "${x%.*}.$lx")" || return 1
        sec_foxguard_scan_copy "$1" "$2" "$3/$f" "$4" "$k" "$mr" "$c" "$f" || return 1
        rc="$SEC_FOXGUARD_RC"
        if [[ "$rc" -le 1 ]] && sec_foxguard_noise "$4.one"; then known=1; fi
        # Not read under its own name (noise, or ".PY" with nothing in front).
        if [[ "$rc" -le 1 ]] && { sec_foxguard_noise "$4.one" || sec_foxguard_unsupported "$4.one"; }; then
          sec_foxguard_scan_copy "$1" "$2" "$3/$f" "$4" "$k" "$mr" "$k.$lx" "$f" || return 1
          rc="$SEC_FOXGUARD_RC"
        fi
        # .C and .H are C to some and C++ to a compiler. One that parses as C
        # is scanned as C. One that does not is C++: not a file to fix, so
        # not a skip that refuses the push, but named.
        if [[ "$e" == C || "$e" == H ]]; then
          s="$(LC_ALL=C awk '/^warning: skipping .* \(parse error\)$/' "$4.one")" || return 1
          if [[ -n "$s" ]]; then
            printf '%s\n' "$s" >> "$4.cxx" || return 1
            s="$(LC_ALL=C awk '!/^warning: skipping .* \(parse error\)$/' "$4.one")" || return 1
            if [[ -n "$s" ]]; then printf '%s\n' "$s" > "$4.one" || return 1; else : > "$4.one" || return 1; fi
          fi
        fi
      fi
    fi
    # A file type foxguard knows that no copy got read: never a silent pass.
    if [[ "$rc" -le 1 && "$known" -eq 1 ]] && { sec_foxguard_noise "$4.one" || sec_foxguard_unsupported "$4.one"; }; then
      printf 'warning: skipping %s (noise path)\n' "$f" >> "$4.one" || return 1
    fi
    awk '{ print }' "$4.one" >> "$4.err" || return 1
    # The shell writes the list itself, one checked write per file.
    s="$(sec_foxguard_skips "$4.one")" || return 1
    if [[ -n "$s" ]]; then printf '%s\n' "$s" >> "$4.skipped" || return 1; fi
    { [[ "$rc" -eq 0 || "$rc" -eq 1 ]] && [[ -s "$4/$k.json" ]]; } || return 1
  done < "$5"
  return 0
}

# sec_foxguard_paths <base> <tip> <files> <map>: the paths <tip> adds or changes
# against <base> (merges and type changes included), appended to <files>, and
# "<path at base><TAB><path at tip>" for each to <map>, so a renamed file is
# compared with its old self. No <base>: every file of <tip>. Return 1 when git
# or a write fails (a file left off the list is never scanned), 2 for a path
# with a tab or newline (it cannot be named safely).
sec_foxguard_paths() {
  local st p old raw="$3.raw"
  if [[ -n "$1" ]]; then
    git diff -z --name-status -M --diff-filter=ACMRT "$1" "$2" -- > "$raw" 2>/dev/null || return 1
  else
    git ls-tree -r -z --name-only --full-tree "$2" > "$raw" 2>/dev/null || return 1
  fi
  while IFS= read -r -d '' st; do
    if [[ -n "$1" ]]; then
      case "$st" in
        R*|C*) IFS= read -r -d '' old || return 1; IFS= read -r -d '' p || return 1 ;;
        *) IFS= read -r -d '' p || return 1; old="$p" ;;
      esac
    else
      p="$st"; old="$st"
    fi
    case "$p$old" in *$'\t'*|*$'\n'*) return 2 ;; esac
    printf '%s\n' "$p" >> "$3" || return 1
    printf '%s\t%s\n' "$old" "$p" >> "$4" || return 1
  done < "$raw"
}

# sec_foxguard_push <refs-file> <remote>: foxguard on the files each pushed ref
# changes, at its tip. A finding at or above the block level that the push
# introduces refuses it; one below the level, or one already present at the
# base (the commits next to the push that the target already has), is a
# warning. With no base known (a bare URL, an unfetched remote), every file of
# the tip is scanned and every finding counts as new. At level off:
# sec_foxguard_warn. Any other level fails closed: no foxguard, a failed scan
# or git command, or a skipped changed file refuses the push.
sec_foxguard_push() {
  local level
  level="$(sec_foxguard_level)" || { echo "Foxguard check failed: invalid block level." >&2; return 1; }
  if [[ "$level" == off ]]; then sec_foxguard_warn "$@"; return 0; fi
  sec_foxguard_block "$1" "${2:-}" "$level"
}

# sec_foxguard_block <refs-file> <remote> <level>: the blocking scan, in a
# subshell so its temporary directory goes on any exit.
sec_foxguard_block() (
  refs="$1"; remote="$2"; level="$3"
  trap - EXIT HUP INT TERM
  if ! cmd="$(sec_foxguard_cmd)"; then
    if ! sec_foxguard_platform_ok; then
      sec_foxguard_refuse "$level" "foxguard has no binary for $(uname -s) $(uname -m)"; exit 1
    fi
    if ! { sec_offer_install foxguard "the static-analysis scan of the changed files" "$(sec_foxguard_missing)" && cmd="$(sec_foxguard_cmd)"; }; then
      sec_foxguard_refuse "$level" "$(sec_foxguard_missing)"; exit 1
    fi
  fi
  sec_foxguard_newer_note "$cmd"
  py="$(security_python)" || { sec_foxguard_refuse "$level" "no Python 3 to compare foxguard reports"; exit 1; }
  helper="$_SEC_LIB_DIR/foxguard_push_compare.py"
  [[ -f "$helper" ]] || { sec_foxguard_refuse "$level" "foxguard_push_compare.py is missing (rerun setup-hooks.sh to refresh the hook copy)"; exit 1; }
  # Absolute: the scan runs from inside the tree it writes.
  tmp_root="$(cd "${TMPDIR:-/tmp}" && pwd)" \
    || { sec_foxguard_refuse "$level" "no temporary directory" "Point TMPDIR at a directory that exists and push again"; exit 1; }
  # The remedy when a working file cannot be written: not a foxguard to install.
  tmpfix="Check that $tmp_root is writable and has free space, then push again"
  work="$(mktemp -d "$tmp_root/sh-foxguard.XXXXXX")" || { sec_foxguard_refuse "$level" "no temporary directory" "$tmpfix"; exit 1; }
  owner="${BASHPID-$$}"
  trap 'if [[ ${BASHPID-$$} == "$owner" ]]; then rm -rf -- "$work"; fi' EXIT
  trap 'exit 1' HUP INT TERM
  n=0; blocked=0; warned=0; unscanned_block=0; nfiles=0
  while read -r lref lsha rref rsha; do
    [[ -n "${lsha:-}" ]] || continue
    [[ "$lsha" =~ ^0+$ ]] && continue
    n=$((n + 1)); d="$work/$n"
    mkdir -p "$d" || { sec_foxguard_refuse "$level" "no temporary directory" "$tmpfix"; exit 1; }
    # The base: the commits next to the pushed ones that the target has.
    excl=""
    if [[ ! "${rsha:-0}" =~ ^0+$ ]] && git cat-file -e "${rsha}^{commit}" 2>/dev/null; then
      excl="$rsha"
    else
      excl="$(remote_excludes . "$remote" 2>/dev/null)" || excl=""
    fi
    : > "$d/bases"
    if [[ -n "$excl" ]]; then
      # shellcheck disable=SC2086  # ids are checked hex, one per word
      git rev-list --boundary "$lsha" --not $excl > "$d/rev-list" 2>/dev/null \
        || { sec_foxguard_refuse "$level" "git rev-list failed for $lref"; exit 1; }
      # A base lost from either list would not be scanned, and nothing would say so.
      # Counted after the write: not every sed reports one that failed.
      nb="$(grep -c '^-' "$d/rev-list")" || nb=0
      { sed -n -e 's/^-//p' "$d/rev-list" > "$d/all-bases" && sed -n 1,8p "$d/all-bases" > "$d/bases" \
        && [[ "$(wc -l < "$d/all-bases")" -eq "$nb" && "$(wc -l < "$d/bases")" -eq "$((nb > 8 ? 8 : nb))" ]]; } \
        || { sec_foxguard_refuse "$level" "the base commits of $lref could not be listed" "$tmpfix"; exit 1; }
      # Nothing new on this ref: the remote has every commit.
      [[ -s "$d/rev-list" ]] || continue
    fi
    # The files to scan, and for each base the path each had there.
    : > "$d/files"; i=0
    if [[ -s "$d/bases" ]]; then
      while IFS= read -r b; do
        i=$((i + 1)); : > "$d/map$i"
        rc=0; sec_foxguard_paths "$b" "$lsha" "$d/files" "$d/map$i" || rc=$?
        case "$rc" in
          0) ;;
          2) sec_foxguard_refuse "$level" "$lref changes a path with a tab or newline, which foxguard cannot be pointed at"; exit 1 ;;
          *) sec_foxguard_refuse "$level" "git could not list the files $lref changes"; exit 1 ;;
        esac
      done < "$d/bases"
    else
      rc=0; sec_foxguard_paths "" "$lsha" "$d/files" "$d/map0" || rc=$?
      case "$rc" in
        0) ;;
        2) sec_foxguard_refuse "$level" "$lref has a path with a tab or newline, which foxguard cannot be pointed at"; exit 1 ;;
        *) sec_foxguard_refuse "$level" "git could not list the files of $lref"; exit 1 ;;
      esac
    fi
    # A file lost from the list or the map is never scanned: refuse instead.
    LC_ALL=C sort -u "$d/files" -o "$d/files" \
      || { sec_foxguard_refuse "$level" "the list of changed files could not be sorted" "$tmpfix"; exit 1; }
    [[ -s "$d/files" ]] || continue
    # foxguard takes no argument that is not UTF-8, and its reports could not
    # name such a file.
    rc=0; bad="$("$py" -I "$helper" --names "$d/files" < /dev/null)" || rc=$?
    case "$rc" in
      0) ;;
      4) printf '%s\n' "$bad" | sec_foxguard_show '[pre-push] foxguard: not UTF-8: '
         sec_foxguard_refuse "$level" "$lref changes a path whose name is not valid UTF-8, which foxguard cannot be pointed at" \
           "Rename each file named above"; exit 1 ;;
      *) sec_foxguard_refuse "$level" "the names of the changed files could not be checked" "$tmpfix"; exit 1 ;;
    esac
    nfiles=$((nfiles + $(wc -l < "$d/files")))
    # Counted after the write: not every awk reports one that failed.
    { awk '{ print $0 "\t" $0 }' "$d/files" > "$d/tipmap" && [[ "$(wc -l < "$d/tipmap")" -eq "$(wc -l < "$d/files")" ]]; } \
      || { sec_foxguard_refuse "$level" "the list of pushed files could not be written" "$tmpfix"; exit 1; }
    # Each base gets every file of the union, under its path there (the old
    # name when renamed against that base), so no base copy is missing a file.
    i=0
    while IFS= read -r b; do
      i=$((i + 1))
      # FILENAME, not NR == FNR: an empty map would swallow the file list.
      # LC_ALL=C: an old name is bytes. Counted after the write, as above: a
      # file lost from the map would have no base copy, and no base to judge it.
      { LC_ALL=C awk -F'\t' 'FILENAME == ARGV[1] { old[$2] = $1; next } { print (($0 in old) ? old[$0] : $0) "\t" $0 }' \
        "$d/map$i" "$d/files" > "$d/map$i.all" && [[ "$(wc -l < "$d/map$i.all")" -eq "$(wc -l < "$d/files")" ]] \
        && mv -f "$d/map$i.all" "$d/map$i"; } \
        || { sec_foxguard_refuse "$level" "the base file map could not be built" "$tmpfix"; exit 1; }
    done < "$d/bases"
    # One config for every side, the base's: the push being checked must not
    # bring the config that judges it. No base, or none there: no config.
    printf '{}\n' > "$d/config" || { sec_foxguard_refuse "$level" "the foxguard config could not be written" "$tmpfix"; exit 1; }
    : > "$d/config.base"; : > "$d/config.tip"
    cbase="$(sed -n 1p "$d/bases")"
    for name in .foxguard.yml .foxguard.yaml foxguard.yml foxguard.yaml; do
      if [[ -n "$cbase" && ! -s "$d/config.base" && "$(git cat-file -t "$cbase:$name" 2>/dev/null)" == blob ]]; then
        # Half a config, or none, would judge the push by other rules.
        git cat-file blob "$cbase:$name" > "$d/config" \
          || { sec_foxguard_refuse "$level" "the foxguard config of the base could not be read" "$tmpfix"; exit 1; }
        # Left empty, the next name would be read as the base's config.
        { printf '%s\n' "$name" && cat "$d/config"; } > "$d/config.base" \
          || { sec_foxguard_refuse "$level" "the foxguard config of the base could not be copied" "$tmpfix"; exit 1; }
      fi
      if [[ ! -s "$d/config.tip" && "$(git cat-file -t "$lsha:$name" 2>/dev/null)" == blob ]]; then
        # Only compared with the base's: lost, a changed config would go unsaid.
        { printf '%s\n' "$name" && git cat-file blob "$lsha:$name"; } > "$d/config.tip" \
          || { sec_foxguard_refuse "$level" "the foxguard config of $lref could not be read" "$tmpfix"; exit 1; }
      fi
    done
    if ! cmp -s "$d/config.base" "$d/config.tip"; then
      sec_loud "this push changes the foxguard config; it takes effect only after it lands on the remote. This push is checked with the remote's config."
    fi
    rc=0; sec_foxguard_tree "$lsha" "$d/tipmap" "$d/tip" || rc=$?
    case "$rc" in
      0) ;;
      2) printf '%s\n' "$SEC_FOXGUARD_CLASH" | sec_foxguard_show '[pre-push] foxguard: same file here: '
         sec_foxguard_refuse "$level" "$lref changes two paths that are one file under $tmp_root (as names that differ only in case or in Unicode form are on macOS and Windows), so one of them cannot be scanned" \
           "Rename one of them, or point TMPDIR at a case-sensitive file system and push again"; exit 1 ;;
      *) sec_foxguard_refuse "$level" "the pushed files could not be read" "$tmpfix"; exit 1 ;;
    esac
    if ! sec_foxguard_scan "$cmd" "$d/config" "$d/tip" "$d/tip.json" "$d/files"; then
      sed -n 1,3p "$d/tip.json.err" | sec_foxguard_show '[pre-push] foxguard: '
      # foxguard failed, or a working file of the scan could not be written.
      sec_foxguard_refuse "$level" "the foxguard scan failed" \
        "Install the pinned foxguard: scripts/setup-hooks.sh --install-foxguard, and check that $tmp_root is writable and has free space"; exit 1
    fi
    # Said, not refused: C++ is no file to fix, and foxguard reads none of it.
    # Before the refusal below: a push it stops still names each file not read.
    if [[ -s "$d/tip.json.cxx" ]]; then
      sec_foxguard_show '[pre-push] foxguard: not scanned: ' < "$d/tip.json.cxx"
      echo "[pre-push] foxguard: $(wc -l < "$d/tip.json.cxx" | tr -d ' ') .C or .H file(s) above do not parse as C and were not scanned: foxguard reads C, not C++." >&2
    fi
    if [[ -s "$d/tip.json.skipped" ]]; then
      sec_foxguard_show '[pre-push] foxguard: ' < "$d/tip.json.skipped"
      sec_foxguard_refuse "$level" "foxguard skipped $(wc -l < "$d/tip.json.skipped" | tr -d ' ') changed file(s)" \
        "Fix each file named above (a parse error, or over 1 MB) so foxguard can read it"; exit 1
    fi
    # A base left out (over 8), unreadable or whose scan failed skipped
    # nothing: the override then covers no file.
    set --; i=0; incomplete=0
    if [[ -s "$d/all-bases" && "$(wc -l < "$d/all-bases")" -gt 8 ]]; then incomplete=1; fi
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      i=$((i + 1))
      if ! sec_foxguard_tree "$b" "$d/map$i" "$d/base$i"; then
        incomplete=1
        echo "[pre-push] foxguard: the files of base ${b:0:12} could not be read; its findings count as new." >&2
        continue
      fi
      # A base copy that is C++ was not read either: it vouches for nothing.
      if sec_foxguard_scan "$cmd" "$d/config" "$d/base$i" "$d/base$i.json" "$d/files" \
        && cat "$d/base$i.json.cxx" >> "$d/base$i.json.skipped"; then
        set -- "$@" --base "$d/base$i.json"
        # A base copy foxguard could not read cannot say what was already
        # there: its findings at the tip block, unless the operator opts in.
        if [[ -s "$d/base$i.json.skipped" ]]; then
          sec_foxguard_show '[pre-push] foxguard: base: ' < "$d/base$i.json.skipped"
          set -- "$@" --base-unscanned "$d/base$i.json.skipped"
        fi
        # A base without the file has no copy to read or skip: it does not
        # stand between the override and a file another base skipped.
        if sec_foxguard_absent "$b" "$d/map$i" "$d/base$i.absent"; then
          if [[ -s "$d/base$i.absent" ]]; then set -- "$@" --base-absent "$d/base$i.absent"; fi
        else
          incomplete=1
          echo "[pre-push] foxguard: the files base ${b:0:12} lacks could not be listed; SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1 does not apply." >&2
        fi
      else
        incomplete=1
        echo "[pre-push] foxguard: the scan of base ${b:0:12} failed; its findings count as new." >&2
      fi
    done < "$d/bases"
    # Exit 3 is a block; 0 nothing blocks; anything else (a crash too) refuses.
    if [[ "${SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE:-}" == 1 ]]; then set -- "$@" --allow-unscanned; fi
    if [[ "$incomplete" -eq 1 ]]; then set -- "$@" --base-incomplete; fi
    rc=0
    "$py" -I "$helper" --level "$level" --tip "$d/tip.json" ${@+"$@"} < /dev/null > "$d/verdict" || rc=$?
    case "$rc" in 0|3) ;; *) sec_foxguard_refuse "$level" "the foxguard reports could not be compared"; exit 1 ;; esac
    if [[ "$rc" -eq 3 ]] && ! grep -q '^BLOCK	' "$d/verdict"; then
      sec_foxguard_refuse "$level" "the foxguard comparison reported a block it did not list"; exit 1
    fi
    while IFS=$'\t' read -r verdict sev loc rule why desc; do
      if [[ "$verdict" == BLOCK ]]; then
        blocked=$((blocked + 1))
        case "$why" in "the base copy could not be scanned"*"then push with"*) unscanned_block=$((unscanned_block + 1)) ;; esac
        printf '[pre-push] BLOCK (foxguard): %s %s %s (%s): %s\n' "$sev" "$loc" "$rule" "$why" "$desc" >&2
      else
        warned=$((warned + 1))
        printf '[pre-push] WARNING (foxguard): %s %s %s (%s): %s\n' "$sev" "$loc" "$rule" "$why" "$desc" >&2
      fi
    done < "$d/verdict"
  done < "$refs"
  if [[ "$blocked" -gt 0 ]]; then
    echo "Foxguard check failed: $blocked new finding(s) at or above $level." >&2
    sec_loud "foxguard: $blocked new finding(s) at or above $level in the pushed files (above); push refused."
    if [[ "$unscanned_block" -gt 0 ]]; then
      echo "[pre-push] A file whose remote copy foxguard could not scan has findings the base cannot vouch for. Review that file; if they are not new, push again with SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE=1." >&2
    fi
    echo "[pre-push] Fix them in the commit that added them, or change the level: git config security.foxguardBlock critical|off (see docs/security-gates.md)." >&2
    exit 1
  fi
  if [[ "$warned" -gt 0 ]]; then
    sec_loud "foxguard: $warned finding(s) below $level, already in the base, or allowed in a file the base could not scan, in $nfiles changed file(s) (above). They do not block the push."
  fi
  exit 0
)

# sec_pre_push <refs-file> <remote-name> <url>: every security step of a push
# (git's two pre-push arguments). 1 refuses it.
sec_pre_push() { sec_guard _sec_pre_push "$@"; }
_sec_pre_push() {
  sec_scan_output --push-refs "$1" --remote "${2:-}" || return 1
  sec_private_names "$1" "${2:-}" "${3:-}" || return 1
  sec_sensitive_push "$1" "${2:-}" || return 1
  sec_foxguard_push "$1" "${2:-}" || return 1
  return 0
}

# sec_pre_commit: refuse prohibited output or an incomplete mandatory check.
sec_pre_commit() { sec_guard _sec_pre_commit "$@"; }
_sec_pre_commit() {
  local gate rc
  sec_scan_output --staged || return 1
  gate="$(sec_find check_sensitive.sh)" || {
    sec_unchecked pre-commit "sensitive-data checker missing; reinstall the hooks"
    return 1
  }
  bash "$gate" --no-inline-allow --staged
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) echo "[pre-commit] Sensitive data in the staged lines; commit refused." >&2; return 1 ;;
    *) sec_unchecked pre-commit "sensitive-data check could not run"; return 1 ;;
  esac
}

# sec_commit_msg <file>: a private name or sensitive data in the message.
sec_commit_msg() { sec_guard _sec_commit_msg "$@"; }
_sec_commit_msg() {
  local msg="$1" gate rc
  sec_scan_output --file "$msg" || return 1
  if gate="$(sec_find check_private_names.sh)"; then
    bash "$gate" --file "$msg" --only-public
    rc=$?
    if [[ "$rc" -eq 1 ]]; then
      echo "[commit-msg] This message names a private repository. Cite it by its code instead." >&2
      echo "[commit-msg] To override:  PRIVATE_NAMES_ALLOW=<term> git commit ..." >&2
      echo "[commit-msg]              or git commit --no-verify" >&2
      return 1
    elif [[ "$rc" -ne 0 ]]; then
      sec_unchecked commit-msg "private-name check could not run"
      return 1
    fi
  else
    sec_unchecked commit-msg "private-name checker missing; reinstall the hooks"
    return 1
  fi
  if gate="$(sec_find check_sensitive.sh)"; then
    # git keeps the template's comment lines in the file until it strips them.
    LC_ALL=C grep -v '^#' "$msg" > "$msg.sensitive" 2>/dev/null; [[ $? -le 1 ]] || cp -- "$msg" "$msg.sensitive"
    bash "$gate" --no-inline-allow --file "$msg.sensitive"
    rc=$?
    rm -f -- "$msg.sensitive"
    case "$rc" in
      0) ;;
      1) echo "[commit-msg] Sensitive data in the message; commit refused." >&2; return 1 ;;
      *) sec_unchecked commit-msg "sensitive-data check could not run"; return 1 ;;
    esac
  else
    sec_unchecked commit-msg "sensitive-data checker missing; reinstall the hooks"
    return 1
  fi
  return 0
}
