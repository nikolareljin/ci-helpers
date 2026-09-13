#!/usr/bin/env bash
# Static portability gate.
#
# Every finding here is something that does not fail on Linux and does not fail
# loudly on macOS -- it silently does the wrong thing. A BSD grep given \s does
# not complain, it just never matches; an associative array on bash 3.2 becomes
# an indexed one and returns plausible nonsense. That is why this is a blocking
# test rather than a lint: shellcheck runs with `|| true` in CI and cannot fail
# a build, and the macOS breakage this guards against stood for 23 releases.
#
# Runs on any platform, needs no Mac, and must itself stay bash 3.2 clean.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

failures=0
note()  { echo "[portability_test] $*"; }
error() { echo "[portability_test][ERROR] $*" >&2; failures=$((failures+1)); }

# This file necessarily contains every pattern it searches for.
SELF="tests/portability_test.sh"

# Files to scan: every tracked shell script, plus the extensionless entry points.
shell_files() {
  # git when it is there, find when it is not: this test also runs inside the
  # bash 3.2 container, which has no git.
  _candidates() {
    if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
      # --others --exclude-standard so a brand-new file is scanned before it is
      # committed. With plain ls-files a new script passed here and failed only
      # once staged, which is the wrong moment to find out.
      git ls-files --cached --others --exclude-standard \
        '*.sh' 'bin/*' 'scripts/git-hooks/*' 'templates/dev-cli/dev' 2>/dev/null | sort -u
    else
      find . -type d -name .git -prune -o -type f \
        \( -name '*.sh' -o -path './bin/*' -o -path './scripts/git-hooks/*' \
           -o -path './templates/dev-cli/dev' \) -print 2>/dev/null \
        | sed 's|^\./||' | sort
    fi
  }
  local f first interp rest
  _candidates \
    | while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        [[ "$f" == "$SELF" ]] && continue
        case "$f" in *.ps1|*.md) continue ;; esac
        # Classify by shebang, not by "does line 1 mention bash". The old test
        # dropped every file whose first line did not contain the word, which
        # silently excluded exactly the files the shebang check below exists to
        # catch: `#!/bin/sh`, `#!/bin/zsh` and scripts with no shebang at all
        # never reached it, so that check could only ever fire on a shebang that
        # already said bash. A gate that cannot see its own subject is not a gate.
        #
        # The interpreter is compared by name and not by a `*sh` suffix, because
        # `pwsh` ends in one: this repository ships a PowerShell library, and
        # matching on the suffix would have run bash-4 and GNU-grep bans over it
        # and then failed its shebang for not saying bash.
        first="$(head -n1 "$f" 2>/dev/null)"
        if [[ "$first" == '#!'* ]]; then
          interp="${first#\#!}"
          # `#! /bin/sh` is a valid shebang with a space after the magic; without
          # this trim it read as an empty interpreter and was dropped.
          interp="${interp#"${interp%%[![:space:]]*}"}"
          interp="${interp%%[[:space:]]*}"
          interp="${interp##*/}"
          if [[ "$interp" == "env" ]]; then
            rest="${first#*env}"
            rest="${rest#"${rest%%[![:space:]]*}"}"
            interp="${rest%%[[:space:]]*}"
            interp="${interp##*/}"
            # `env` carrying options -- `-S`, `-i`, `--ignore-environment`,
            # `-u VAR` -- leaves a flag here rather than an interpreter. Guessing
            # which flags take an argument to find the real one is how this
            # filter kept growing a new hole; an unclassifiable shebang is left
            # for the shebang check below to name, since this repository
            # mandates exactly `#!/usr/bin/env bash` and every one of these
            # forms is something it should report.
            [[ "$interp" == -* ]] && interp=""
            # `#!/usr/bin/env FOO=bar bash` is an assignment, not an interpreter,
            # and the same rule applies: unclassifiable is reported, not dropped.
            [[ "$interp" == *=* ]] && interp=""
          fi
          case "$interp" in
            sh|bash|rbash|dash|ksh|ash|zsh) printf '%s\n' "$f" ;;
            # A `#!` line with no interpreter left after resolving it -- bare
            # `#!/usr/bin/env`, `#!/usr/bin/env -S`, `#!` alone. Dropping those
            # would be the original blind spot again, one shape smaller: the
            # shebang check below is the thing that should name a broken
            # shebang, so the file has to reach it.
            "") printf '%s\n' "$f" ;;
            # python, perl, pwsh, tclsh, ... are not this test's subject --
            # unless the file is one this repository runs as a shell script
            # anyway: a `.sh` name, or one of the entry-point locations
            # _candidates collects on purpose. There the name and the shebang
            # disagree, and the shebang check should say so rather than the
            # file vanishing from the scan.
            *) case "$f" in
                 *.sh|bin/*|scripts/git-hooks/*|templates/dev-cli/dev)
                   printf '%s\n' "$f" ;;
               esac ;;
          esac
        else
          # No shebang. A `.sh` name still says what it is, and so does living
          # in one of the entry-point locations _candidates collects on purpose:
          # a shebang-less file under bin/ or the hooks is still something that
          # will be run by bash, and dropping it here is the original blind
          # spot again for exactly those files.
          case "$f" in
            *.sh|bin/*|scripts/git-hooks/*|templates/dev-cli/dev) printf '%s\n' "$f" ;;
          esac
        fi
      done
}

FILES=""
while IFS= read -r f; do FILES="${FILES}${f}"$'\n'; done < <(shell_files)
[[ -n "$FILES" ]] || { error "found no shell files to scan"; exit 1; }
note "scanning $(printf '%s' "$FILES" | grep -c . ) shell files"

# ban <label> <extended-regex> [allowed-file ...]
#
# An allowed file is a deliberate, named exception. Adding one is a decision to
# be argued for in review, which is the point of listing them here rather than
# tuning the pattern until it stops matching.
ban() {
  local label="$1" pattern="$2"; shift 2
  local allowed=" $* "
  local hit file
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    file="${hit%%:*}"
    case "$allowed" in *" $file "*) continue ;; esac
    error "$label -> $hit"
  done < <(printf '%s' "$FILES" | grep -v '^$' | xargs grep -nE "$pattern" 2>/dev/null \
             | grep -vE ':[[:space:]]*#')
}

# --- bash 4+ syntax; stock macOS /bin/bash is 3.2 ---------------------------
ban "mapfile/readarray is bash 4+"        '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)'
ban "associative array is bash 4+"        '(declare|local|typeset)[[:space:]]+-[A-Za-z]*A'
ban "nameref is bash 4.3+"                '(declare|local|typeset)[[:space:]]+-[A-Za-z]*n[[:space:]]'
ban "case modification is bash 4+"        '\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)'
ban "globstar is bash 4+"                 'shopt[[:space:]]+-s[[:space:]]+globstar'
# Not a bash-4 issue, but the same shape of silent wrong answer: `*(` is the
# extglob "zero or more" operator, so ${x##*(} parses differently in a caller
# that ran `shopt -s extglob` and returns the wrong text with no error. Escape
# the paren: ${x##*\(}.
ban "unescaped *( in a parameter expansion" '\$\{[^}]*#\*\('

# --- GNU-only regex; BSD grep does not error, it silently never matches -----
ban "GNU \\s/\\b in grep or sed"          '(grep|sed)([^|;]*)(\\s|\\b)'

# --- GNU-only coreutils flags ----------------------------------------------
ban "GNU sed -i/-r"                       'sed[[:space:]]+(-[a-zA-Z]*i([[:space:]]|$)|-[a-zA-Z]*r([[:space:]]|$))'
ban "readlink -f / realpath"              '(readlink[[:space:]]+-[a-zA-Z]*f|(^|[^[:alnum:]_])realpath([^[:alnum:]_]|$))'
ban "GNU date -d"                         'date[[:space:]]+(-d|--date)([[:space:]]|=)'
ban "grep -P"                             'grep[[:space:]]+-[a-zA-Z]*P'
ban "find -printf/-regextype"             'find[^|;]*(-printf|-regextype)'
ban "xargs -r/-d"                         'xargs[[:space:]]+-[rd]([[:space:]]|$)'
ban "base64 -w"                           'base64[[:space:]]+-w'
ban "md5sum/sha256sum are GNU" \
    '(^|[^[:alnum:]_])(md5sum|sha256sum)([^[:alnum:]_]|$)' \
    "lib/file.sh"   # verify_checksum's default; guarded by command_exists and
                    # tracked as a follow-up, not reachable from ./dev.

# --- \t in a bash regex ------------------------------------------------------
#
# `[[ $x =~ \t ]]` does not match a tab. Bash's ERE has no \t escape, so this
# is the \s and \b problem in the other direction: no error, no match, and a
# tab-indented script header silently lost every continuation line. Use
# [[:space:]] (one character wide, so indentation past the first column
# survives).
ban "\\t is not a tab in a bash regex; use [[:space:]]" '=~[^;]*\\t'

# --- unguarded $OSTYPE ------------------------------------------------------
#
# Same silent shape as the rest of this file, from the other direction: every
# script here runs under `set -u`, so a bare "$OSTYPE" aborts the whole run for
# a caller that has unset it, and it aborts on the expansion -- before any
# branch that would have said what went wrong. lib/os.sh reads it defensively
# once and everything else asks get_os/is_macos.
ban "bare \$OSTYPE under set -u; use get_os/is_macos" \
    '\$OSTYPE|\$\{OSTYPE\}' \
    "lib/os.sh"     # the one defensive read, ${OSTYPE:-}, that get_os is built on

# --- shebangs ---------------------------------------------------------------
#
# Checked directly rather than through ban(), which drops comment lines -- and a
# shebang looks exactly like one. `#!/bin/bash` on macOS is bash 3.2 forever,
# whatever the user has installed.
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  first="$(head -n1 "$f")"
  case "$first" in
    '#!/usr/bin/env bash') ;;
    '#!'*) error "shebang is not '#!/usr/bin/env bash' -> $f: $first" ;;
    # The classifier deliberately keeps a shebang-less `.sh` or entry point, so
    # that it reaches this check rather than vanishing. Without a branch here it
    # arrived and nothing happened, which is the same silence one step later.
    *) error "no shebang; every scanned file needs '#!/usr/bin/env bash' -> $f" ;;
  esac
done < <(printf '%s' "$FILES" | grep -v '^$')

# The same, for shebangs a script writes into a file it generates.
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  error "generated shebang hardcodes an interpreter -> $hit"
done < <(printf '%s' "$FILES" | grep -v '^$' \
           | xargs grep -nE '^[[:space:]]*#!/bin/(ba)?sh[[:space:]]*$' 2>/dev/null \
           | grep -v ':1:')

# --- stat needs both spellings ----------------------------------------------
#
# GNU `stat -c` and BSD `stat -f` take different format flags, so a file using
# one must carry the other as a fallback. Checked per file rather than per line
# because the working pattern here is a multi-line probe: try -c, fall back to
# -f (lib/dialog.sh:124, lib/ollama.sh:282).
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  grep -q 'stat -c' "$f" 2>/dev/null || continue
  grep -q 'stat -f' "$f" 2>/dev/null && continue
  error "stat -c with no BSD (stat -f) fallback anywhere in $f"
done < <(printf '%s' "$FILES" | grep -v '^$')

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED — no GNU-only or bash-4-only construct found"
  exit 0
fi
note "$failures portability problem(s) found"
exit 1
