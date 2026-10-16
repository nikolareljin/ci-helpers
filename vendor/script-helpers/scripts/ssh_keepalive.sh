#!/usr/bin/env bash
# SCRIPT: ssh_keepalive.sh
# DESCRIPTION: Sourced by the pre-push hook and the hook dispatcher: warn, before the checks, when an SSH push can be cut off while they run.
# USAGE: source scripts/ssh_keepalive.sh; ssh_keepalive_note <remote-url> <prefix>
# PARAMETERS:
#   <remote-url>  The URL git passes to pre-push as its second argument.
#   <prefix>      The tag for the lines, e.g. "[pre-push]".
# EXAMPLE: ssh_keepalive_note "git@github.com:owner/repo.git" "[pre-push]"
# ----------------------------------------------------
# Why: git opens the push's connection before pre-push runs and keeps it open,
# idle, until the hooks pass. Over SSH the server closes an idle connection
# (GitHub after a few minutes), and the push exits 141 with "Connection to
# <host> closed by remote host" after every check passed. A keepalive fixes it.
# The note is shown once per push (SCRIPT_HELPERS_SSH_NOTE_SHOWN), never for
# HTTPS or local remotes, and not when a keepalive is already set.

# ssh_host_of <url>: the host of an SSH remote URL (ssh://[user@]host[:port]/path
# or the scp form [user@]host:path, IPv6 in brackets included), else nothing.
# As git reads it: a drive letter (C:/repo, C:\repo) is a local path, and a
# colon after a slash is a path, not the scp form.
ssh_host_of() {
  local url="$1" rest host
  case "$url" in
    ssh://*|git+ssh://*|ssh+git://*) rest="${url#*://}"; rest="${rest%%/*}"; rest="${rest##*@}" ;;
    *://*|/*|./*|../*|[A-Za-z]:|[A-Za-z]:[/\\]*) return 0 ;;
    *:*) rest="${url%%:*}"
         [[ "$rest" != */* ]] || return 0
         rest="${rest##*@}"
         [[ "$rest" != \[* ]] || rest="${url#*@}"   # [::1]:path keeps its colons
         ;;
    *) return 0 ;;
  esac
  if [[ "$rest" == \[* ]]; then
    host="${rest#\[}"; host="${host%%]*}"
  else
    host="${rest%%:*}"
  fi
  # A host that would read as an ssh option is not a host.
  [[ -n "$host" && "$host" != -* ]] && echo "$host"
  return 0   # no host is an answer, not a failure: callers may run under set -e
}

# ssh_keepalive_set <host>: 0 when a keepalive is set in GIT_SSH_COMMAND,
# core.sshCommand, or the ssh config for that host (ssh -G reads it, aliases
# and Match blocks included, without connecting). A non-OpenSSH client
# (GIT_SSH, e.g. plink) has its own settings this cannot read: counted as set,
# so its users are not told to change a file their client ignores.
ssh_keepalive_set() {
  local v
  [[ -z "${GIT_SSH:-}" ]] || return 0
  [[ "${GIT_SSH_COMMAND:-} $(git config --get core.sshCommand 2>/dev/null || true)" == *[Ss]erver[Aa]live[Ii]nterval* ]] && return 0
  v="$(ssh -G -- "$1" 2>/dev/null | awk '$1 == "serveraliveinterval" { print $2; exit }')"
  [[ -n "$v" && "$v" != 0 ]]
}

# ssh_keepalive_note <url> <prefix>: print the note on stderr when it applies.
# Yellow on a terminal; plain in CI, with NO_COLOR, or when stderr is a file.
ssh_keepalive_note() {
  local url="$1" p="$2" host on="" off=""
  [[ -z "${SCRIPT_HELPERS_SSH_NOTE_SHOWN:-}" ]] || return 0
  host="$(ssh_host_of "$url")"
  [[ -n "$host" ]] && command -v ssh >/dev/null 2>&1 || return 0
  ssh_keepalive_set "$host" && return 0
  export SCRIPT_HELPERS_SSH_NOTE_SHOWN=1
  if [[ -t 2 && -z "${CI:-}" && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
    on=$'\033[1;33m'; off=$'\033[0m'
  fi
  {
    printf '%s%s The push waits for these checks with its SSH connection to %s idle; a long\n' "$on" "$p" "$host"
    printf '%s run can be cut off (exit 141, "closed by remote host"). Keep the connection alive:\n' "$p"
    printf '%s   every repository: add to ~/.ssh/config   Host %s\n' "$p" "$host"
    printf '%s                                               ServerAliveInterval 20\n' "$p"
    printf '%s   this repository:  git config core.sshCommand "ssh -o ServerAliveInterval=20"\n' "$p"
    printf '%s   this push only:   GIT_SSH_COMMAND="ssh -o ServerAliveInterval=20" git push\n' "$p"
    printf '%s An HTTPS remote is not affected.%s\n' "$p" "$off"
  } >&2
}
