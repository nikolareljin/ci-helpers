#!/usr/bin/env bash
# SCRIPT: security_hooks.sh
# DESCRIPTION: The security steps every git hook runs, sourced by scripts/git-hooks/* and the global dispatcher.
# USAGE: source scripts/security_hooks.sh; sec_pre_push <refs-file> <remote-name> <url> | sec_pre_commit | sec_commit_msg <msg-file>
# PARAMETERS:
#   SCRIPT_HELPERS_SECURITY_DIR  Directory holding check_private_names.sh and
#                                check_sensitive.sh. Set by the global hooks;
#                                otherwise they are looked up in the repository.
#   SECURITY_GATE_ALLOW_UNCHECKED=1  Let a push through when a check could not
#                                run (exit 2, script missing, scope unknown), with
#                                a warning. Narrow on purpose: --no-verify skips
#                                every check, this skips none that can run.
#                                SENSITIVE_ALLOW_UNCHECKED=1 is the same.
#   FOXGUARD_CMD                 foxguard command to run (default: the pinned
#                                binary in the cache, else foxguard on PATH).
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
# identifiers and PII, both in check_sensitive.sh (block) -> foxguard (warn only). The caller handles the deletions-only shortcut and the
# tests. Every function returns 0 to continue and 1 to refuse.
#
# No "already checked" marker is exported: an environment variable that skips
# the checks could be set by any parent process. A hook chained after these
# steps runs them again; that costs time, never coverage.

# sec_unchecked <hook> <reason>: a check could not run. Return 1 (refuse) unless
# SECURITY_GATE_ALLOW_UNCHECKED=1, which lets it through with a warning. A check
# that did not run is not a clean one.
sec_unchecked() {
  if [[ "${SECURITY_GATE_ALLOW_UNCHECKED:-${SENSITIVE_ALLOW_UNCHECKED:-}}" == 1 ]]; then
    echo "[$1] WARNING: $2; SECURITY_GATE_ALLOW_UNCHECKED=1, allowed unchecked." >&2
    return 0
  fi
  echo "[$1] $2; refused." >&2
  echo "[$1] Fix the cause, or run once with SECURITY_GATE_ALLOW_UNCHECKED=1." >&2
  return 1
}

_SEC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    bash "$refresher" >"${list}.refresh.log" 2>&1
    rmdir "$lock" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  return 0
}

# sec_not_remote <remote-name>: git log arguments excluding what the push
# target already has. Only that remote's refs count: a commit already on some
# other remote (a private one, say) is still news to this one. A push to a bare
# URL has no remote refs, so everything it sends is checked.
sec_not_remote() {
  if [[ -n "${1:-}" ]] && LC_ALL=C grep -qxF -- "$1" <<< "$(git remote 2>/dev/null)"; then
    printf -- '--not --remotes=%s' "$1"
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
  if out="$(git rev-list -n 1 "$head" --not --remotes="${1:-}" 2>/dev/null)"; then
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
    sec_unchecked pre-push "could not read every outgoing commit message (shallow clone, or a remote ref never fetched)" || { rm -f "$messages"; return 1; }
  fi

  bash "$gate" --file "$messages" --only-public "${target[@]+"${target[@]}"}"
  rc=$?
  rm -f "$messages"
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
    rm -f "$messages"
    sec_unchecked pre-push "could not read every outgoing tag message" || return 1
    return 0
  fi
  [[ -s "$messages" ]] || { rm -f "$messages"; return 0; }
  bash "$gate" --file "$messages" --only-public "${target[@]+"${target[@]}"}" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -ne 1 ]]; then
    rm -f "$messages"
    [[ "$rc" -eq 0 ]] && return 0
    sec_unchecked pre-push "the private-name check could not run on the tag messages (exit $rc)" || return 1
    return 0
  fi

  local lref lsha rref rsha label="A tag message" one="${refs}.tag"
  # shellcheck disable=SC2034
  while read -r lref lsha rref rsha; do
    # Every ref, not only refs/tags/: a tag object can be pushed to any ref.
    printf '%s %s %s %s\n' "$lref" "$lsha" "$rref" "${rsha:-}" > "$one"
    sec_tag_messages "$one" > "$messages" && [[ -s "$messages" ]] || continue
    bash "$gate" --file "$messages" --only-public "${target[@]+"${target[@]}"}"
    if [[ $? -eq 1 ]]; then
      case "$rref" in
        refs/tags/*) label="The message of tag ${rref#refs/tags/}" ;;
        *)           label="The message of the tag pushed to $rref" ;;
      esac
      break
    fi
  done < "$refs"
  rm -f "$one" "$messages"
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

# sec_gitleaks_present: gitleaks where check_sensitive.sh looks for it.
sec_gitleaks_present() {
  local r
  if [[ -n "${GITLEAKS_BIN:-}" ]]; then [[ -x "$GITLEAKS_BIN" ]]; return; fi
  command -v gitleaks >/dev/null 2>&1 && return 0
  r="$(sec_lib_root)" || return 1
  # shellcheck source=/dev/null
  ( source "$r/helpers.sh" && shlib_import logging foxguard gitleaks >/dev/null 2>&1 && gitleaks_bin >/dev/null 2>&1 )
}

# sec_offer_install <tool> <what it runs>: install the pinned <tool>
# (downloaded, SHA-256 checked) when sec_may_install allows: 0 = installed.
# Otherwise, or when the install fails, print how to install it: 1.
sec_offer_install() {
  local tool="$1" what="$2" r
  r="$(sec_lib_root 2>/dev/null || true)"
  if [[ -n "$r" ]] && sec_may_install; then
    echo "[pre-push] $tool is not installed; installing the pinned release to run $what." >&2
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
  local refs="$1" remote="${2:-}" gate rc
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
    echo "[pre-push] ERROR: gitleaks is not installed; the credential scan cannot run." >&2
    sec_offer_install gitleaks "the credential scan" || true
  fi
  bash "$gate" --push-refs "$refs" --remote "$remote"
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

# foxguard_cmd: the foxguard to run, or return 1.
sec_foxguard_cmd() {
  local c
  if [[ -n "${FOXGUARD_CMD:-}" ]]; then printf '%s' "$FOXGUARD_CMD"; return 0; fi
  for c in "${XDG_CACHE_HOME:-${HOME:-}/.cache}"/script-helpers/foxguard/*/foxguard \
           "${XDG_CACHE_HOME:-${HOME:-}/.cache}"/script-helpers/foxguard/*/foxguard.exe; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  command -v foxguard 2>/dev/null && return 0
  return 1
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

# foxguard on the files this push changes. Never blocks: a missing foxguard
# (installed when it can be), a failed scan and every finding are
# loud warnings, and the push goes on.
# Measured 2026-09-29: its shell taint rules flagged 93 lines of this library,
# none exploitable, so as a gate it would fail correct code.
sec_foxguard_push() {
  local refs="$1" remote="${2:-}" cmd f out rc frc=0 shown=0 failed=0 r base="" issues=0 hit=0 k
  if ! cmd="$(sec_foxguard_cmd)"; then
    if ! sec_foxguard_platform_ok; then
      sec_loud "the foxguard scan did NOT run: foxguard has no binary for $(uname -s) $(uname -m)."
      return 0
    fi
    if ! { sec_offer_install foxguard "the static-analysis scan of the changed files" && cmd="$(sec_foxguard_cmd)"; }; then
      sec_loud "the foxguard scan did NOT run: foxguard is not installed (see above to install it)."
      return 0
    fi
  fi
  # The changed files that exist here, in an array: nothing written to disk.
  local files=()
  while IFS= read -r f; do
    [[ -f "$f" ]] && files+=("$f")
  done < <(sec_changed_files "$refs" "$remote" | cut -f2- | LC_ALL=C sort -u)
  [[ ${#files[@]} -gt 0 ]] || return 0
  # foxguard scans one path per run: 0 clean, 1 findings, anything else failed.
  for f in "${files[@]}"; do
    rc=0
    # shellcheck disable=SC2086  # FOXGUARD_CMD may carry arguments
    out="$($cmd "$f" 2>&1)" || rc=$?
    case "$rc" in
      0) ;;
      1)
        hit=$((hit + 1))
        # Its summary line, "N issues" (terminal format); 1 when it has none.
        k="$(printf '%s\n' "$out" | LC_ALL=C sed -n -e 's/^[^0-9]*\([0-9][0-9]*\) issues\{0,1\}$/\1/p' -e 's/^[^0-9]*\([0-9][0-9]*\) issues\{0,1\}[^a-z].*/\1/p' | tail -1)"
        issues=$((issues + ${k:-1}))
        while IFS= read -r r; do
          [[ -n "${r//[[:space:]]/}" ]] || continue
          shown=$((shown + 1))
          printf '[pre-push] WARNING (foxguard): %s\n' "$r" >&2
        done < <(printf '%s\n' "$out") ;;
      *)
        failed=$((failed + 1)); frc="$rc"
        while IFS= read -r r; do printf '[pre-push] foxguard (%s): %s\n' "$f" "$r" >&2; done < <(printf '%s\n' "$out" | sed -n 1,3p) ;;
    esac
  done
  [[ "$failed" -gt 0 ]] && sec_loud "the foxguard scan did NOT run on $failed of ${#files[@]} file(s) (exit $frc)."
  if [[ "$shown" -gt 0 ]]; then
    sec_loud "foxguard: $issues finding(s) in $hit of ${#files[@]} changed file(s) (above). They do not block the push."
    # The base for the report: the remote's commit of the first updated ref.
    base="$(awk '$4 !~ /^0+$/ && $2 !~ /^0+$/ { print $4; exit }' "$refs" 2>/dev/null || true)"
    echo "[pre-push] Keep them as JSON (evidence, or to compare later):" >&2
    if [[ -n "$base" ]]; then
      echo "[pre-push]   bash $(sec_lib_root 2>/dev/null || echo scripts/script-helpers)/scripts/foxguard_report.sh --base $base --output foxguard-report.json" >&2
    else
      echo "[pre-push]   bash $(sec_lib_root 2>/dev/null || echo scripts/script-helpers)/scripts/foxguard_report.sh --output foxguard-report.json -- <files above>" >&2
    fi
    echo "[pre-push] To review them, and secrets across the whole history, in VS Code: leak-lock, https://github.com/nikolareljin/leak-lock" >&2
  fi
  return 0
}

# sec_pre_push <refs-file> <remote-name> <url>: every security step of a push
# (git's two pre-push arguments). 1 refuses it.
sec_pre_push() {
  sec_private_names "$1" "${2:-}" "${3:-}" || return 1
  sec_sensitive_push "$1" "${2:-}" || return 1
  sec_foxguard_push "$1" "${2:-}"
  return 0
}

# sec_pre_commit: sensitive data in the staged lines. Exit 2 warns here and does
# not block: the push runs the same check and refuses then.
sec_pre_commit() {
  local gate rc
  gate="$(sec_find check_sensitive.sh)" || {
    echo "[pre-commit] check_sensitive.sh not found; staged lines NOT checked (the push refuses until it is found)." >&2
    return 0
  }
  bash "$gate" --staged
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) echo "[pre-commit] Sensitive data in the staged lines; commit refused." >&2; return 1 ;;
    *) echo "[pre-commit] sensitive-data check could not run (exit $rc); commit allowed, the push will check again." >&2; return 0 ;;
  esac
}

# sec_commit_msg <file>: a private name or sensitive data in the message.
sec_commit_msg() {
  local msg="$1" gate rc
  if gate="$(sec_find check_private_names.sh)"; then
    bash "$gate" --file "$msg" --only-public
    rc=$?
    if [[ "$rc" -eq 1 ]]; then
      echo "[commit-msg] This message names a private repository. Cite it by its code instead." >&2
      echo "[commit-msg] To override:  PRIVATE_NAMES_ALLOW=<term> git commit ..." >&2
      echo "[commit-msg]              or git commit --no-verify" >&2
      return 1
    elif [[ "$rc" -ne 0 ]]; then
      # Could not check. A missing list is a setup problem, not a clean message,
      # and the distinction is the whole point of the separate exit code.
      echo "[commit-msg] the private-name check could not run (exit $rc); commit allowed." >&2
      echo "[commit-msg] Generate the name list to enable it." >&2
    fi
  else
    # 127 territory: the check is not installed here. Saying so beats both a
    # silent pass and a refusal the author cannot act on.
    echo "[commit-msg] check_private_names.sh not found; private-name check skipped." >&2
  fi
  if gate="$(sec_find check_sensitive.sh)"; then
    # git keeps the template's comment lines in the file until it strips them.
    LC_ALL=C grep -v '^#' "$msg" > "$msg.sensitive" 2>/dev/null; [[ $? -le 1 ]] || cp "$msg" "$msg.sensitive"
    bash "$gate" --file "$msg.sensitive"
    rc=$?
    rm -f "$msg.sensitive"
    case "$rc" in
      0) ;;
      1) echo "[commit-msg] Sensitive data in the message; commit refused." >&2; return 1 ;;
      *) echo "[commit-msg] sensitive-data check could not run (exit $rc); commit allowed." >&2 ;;
    esac
  fi
  return 0
}
