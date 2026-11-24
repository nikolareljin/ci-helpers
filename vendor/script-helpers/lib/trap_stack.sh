#!/usr/bin/env bash
# trap_stack: temp files and directories that are removed when the shell
# exits or is interrupted, registered from nested functions.
#
#   dir="$(mktemp -d)" || return 1
#   trap_stack_push "$dir"
#   ...                      # may call other functions that push and pop
#   trap_stack_pop           # removes $dir, takes it off the stack
#
# trap_stack_push --run <function> <path> registers <function> instead of
# rm -rf: pop and the traps call "<function> <path>". Use it for a path that
# needs more than rm, such as a mount point that must be detached first.
# <function> must be defined at the push; in a trap it runs in a subshell.
#
# While anything is registered, EXIT, HUP, INT and TERM remove every
# registered path, newest first. A trap the caller already had for one of
# them is kept and runs after the removal; with none, HUP, INT and TERM exit
# 129, 130 and 143. A signal the caller ignores stays ignored. The caller's
# traps are put back when the last path is popped.
#
# A second push adds to the stack, it does not replace the first: an outer
# function's directory survives an inner function's push and pop. A trap the
# caller sets while paths are registered is kept too: the next push chains
# onto it, and a pop never replaces a trap this module did not set.
#
# Push and pop in the same shell. A path pushed inside $( ... ) or ( ... )
# belongs to that subshell and is removed when it exits, unless it is popped
# with --keep first. A subshell never removes a path its parent registered.
#
# bash 3.2, or POSIX mode, in a subshell: bash cannot tell there whether a
# trap it lists is the subshell's own or a copy of the parent's, so the
# first push in that subshell does not chain onto it (a parent's EXIT trap
# must not run in the subshell) and the last pop resets it.
#
# Expected imports by caller: none.
#
# Return codes: 0 done; 2 bad arguments.

# State. Kept across a second source of this file.
if [[ -z "${_TRAP_STACK_DEPTH:-}" ]]; then
  _TRAP_STACK_DEPTH=0
  _TRAP_STACK_PATHS=()
  _TRAP_STACK_RUNS=()    # per path: the --run function, "" for rm -rf
  _TRAP_STACK_OWNER=""   # _trap_stack_self of the shell the stack belongs to
  _TRAP_STACK_SELF=""
  _TRAP_STACK_STALE=0    # 1: trap -p may list the parent's traps (see the header)
  _TRAP_STACK_ACT=""
  # Indexed like _TRAP_STACK_SIGS: 1 when our trap is set, the action we set,
  # and the caller's "trap -p" line to put back ("" for none).
  _TRAP_STACK_SET=(0 0 0 0)
  _TRAP_STACK_OURS=("" "" "" "")
  _TRAP_STACK_SAVED=("" "" "" "")
fi
_TRAP_STACK_SIGS=(EXIT HUP INT TERM)
_TRAP_STACK_CODES=(0 129 130 143)

# Usage: trap_stack_push [--run <function>] <path>
# trap_stack_push [--run <function>] <path>; register a file or directory
# for removal on EXIT, HUP, INT and TERM, until trap_stack_pop takes it off.
# A relative path is registered as it resolves now, so a later cd does not
# change what is removed.
# With --run, "<function> <path>" is called instead of rm -rf. <function>
# must be a shell function defined at the push.
# Returns: 0 registered; 2 an empty path, "/", or --run without a defined
# function.
# Output: stderr the usage line on a bad argument.
trap_stack_push() {
  local run="" path
  if [[ "${1:-}" == --run ]]; then
    run="${2:-}"
    [[ -n "$run" ]] && shift 2 || set --
  fi
  path="${1:-}"
  if [[ -z "$path" || "$path" == / ]] || { [[ -n "$run" ]] && ! declare -F -- "$run" >/dev/null; }; then
    printf '[ERROR] trap_stack_push: usage: trap_stack_push [--run <function>] <path>\n' >&2
    return 2
  fi
  # [A-Za-z]:* is an absolute path on Windows (Git Bash).
  case "$path" in /*|[A-Za-z]:[\\/]*) ;; *) path="$PWD/$path" ;; esac
  _trap_stack_self
  if [[ "$_TRAP_STACK_SELF" != "$_TRAP_STACK_OWNER" ]]; then
    # A new shell, or a subshell: what the parent registered is the parent's.
    _TRAP_STACK_OWNER="$_TRAP_STACK_SELF"
    _TRAP_STACK_DEPTH=0
    _TRAP_STACK_PATHS=()
    _TRAP_STACK_RUNS=()
    _TRAP_STACK_SET=(0 0 0 0)
    _TRAP_STACK_OURS=("" "" "" "")
    _TRAP_STACK_SAVED=("" "" "" "")
    _TRAP_STACK_STALE=0
    if [[ "${BASH_SUBSHELL:-0}" -gt 0 ]]; then
      if [[ "${BASH_VERSINFO[0]:-3}" -ge 4 && ":${SHELLOPTS:-}:" != *:posix:* ]]; then
        # In a subshell "trap -p" lists the parent's traps until the subshell
        # sets one. Any trap command drops that list, also one that fails.
        trap - TRAP_STACK_NO_SUCH_SIGNAL 2>/dev/null || :
      else
        _TRAP_STACK_STALE=1
      fi
    fi
  fi
  _TRAP_STACK_PATHS[_TRAP_STACK_DEPTH]="$path"
  _TRAP_STACK_RUNS[_TRAP_STACK_DEPTH]="$run"
  _TRAP_STACK_DEPTH=$((_TRAP_STACK_DEPTH + 1))
  _trap_stack_install
  return 0
}

# Usage: trap_stack_pop [--keep]
# trap_stack_pop [--keep]; take the newest registered path off the stack and
# remove it (rm -rf). With --keep the path is left in place. Popping the last
# path puts the caller's traps back.
# Returns: 0, also with nothing registered in this shell.
# Output: stderr what rm (or the --run function) prints when the removal fails.
trap_stack_pop() {
  local keep=0 path run
  [[ "${1:-}" == --keep ]] && keep=1
  _trap_stack_self
  [[ "$_TRAP_STACK_SELF" == "$_TRAP_STACK_OWNER" ]] || return 0
  [[ "$_TRAP_STACK_DEPTH" -gt 0 ]] || return 0
  _TRAP_STACK_DEPTH=$((_TRAP_STACK_DEPTH - 1))
  path="${_TRAP_STACK_PATHS[_TRAP_STACK_DEPTH]}"
  run="${_TRAP_STACK_RUNS[_TRAP_STACK_DEPTH]:-}"
  unset "_TRAP_STACK_PATHS[$_TRAP_STACK_DEPTH]" "_TRAP_STACK_RUNS[$_TRAP_STACK_DEPTH]"
  if [[ "$keep" -eq 0 && -n "$path" ]]; then
    if [[ -n "$run" ]]; then "$run" "$path" || :; else rm -rf -- "$path" || :; fi
  fi
  if [[ "$_TRAP_STACK_DEPTH" -eq 0 ]]; then _trap_stack_restore; fi
  return 0
}

# _trap_stack_self: sets _TRAP_STACK_SELF to what tells this shell from its
# subshells: its pid, or on bash 3.2, which has no BASHPID, "$$:<subshell level>".
_trap_stack_self() { _TRAP_STACK_SELF="${BASHPID:-$$:${BASH_SUBSHELL:-0}}"; }

# _trap_stack_action: sets _TRAP_STACK_ACT to the action of a
# "trap -- <action> <sig>" line.
_trap_stack_action() { _TRAP_STACK_ACT="${3:-}"; }

# _trap_stack_install: set our trap for each of EXIT, HUP, INT and TERM that
# does not have it, chained onto the trap that is there.
_trap_stack_install() {
  local i sig line ours
  for i in 0 1 2 3; do
    sig="${_TRAP_STACK_SIGS[i]}"
    line="$(trap -p "$sig")"
    _TRAP_STACK_ACT=""
    [[ -z "$line" ]] || eval "_trap_stack_action ${line}"
    if [[ "${_TRAP_STACK_SET[i]}" -eq 1 && -n "$line" && "$_TRAP_STACK_ACT" == "${_TRAP_STACK_OURS[i]}" ]]; then
      continue
    fi
    if [[ -n "$line" && -z "$_TRAP_STACK_ACT" ]]; then
      # The caller ignores this signal: it stays ignored.
      _TRAP_STACK_SET[i]=0
      continue
    fi
    if [[ "$_TRAP_STACK_STALE" -eq 1 ]]; then line=""; _TRAP_STACK_ACT=""; fi
    if [[ "$i" -eq 0 ]]; then
      # "&& :" keeps set -e from ending the trap here, and leaves $? as it
      # was for the caller's EXIT trap.
      ours='_trap_stack_fire "$?" && :'
      [[ -z "$_TRAP_STACK_ACT" ]] || ours="${ours}"$'\n'"${_TRAP_STACK_ACT}"
    else
      ours="_trap_stack_fire 0"$'\n'"${_TRAP_STACK_ACT:-exit ${_TRAP_STACK_CODES[i]}}"
    fi
    # shellcheck disable=SC2064  # the action is built here on purpose
    trap -- "$ours" "$sig"
    _TRAP_STACK_SET[i]=1
    _TRAP_STACK_OURS[i]="$ours"
    _TRAP_STACK_SAVED[i]="$line"
  done
  # After the first pass every trap listed for these signals is this shell's.
  _TRAP_STACK_STALE=0
}

# _trap_stack_restore: put the caller's traps back. A trap that is no longer
# ours was set by the caller since, and is left alone.
_trap_stack_restore() {
  local i sig line
  for i in 0 1 2 3; do
    [[ "${_TRAP_STACK_SET[i]}" -eq 1 ]] || continue
    sig="${_TRAP_STACK_SIGS[i]}"
    line="$(trap -p "$sig")"
    _TRAP_STACK_ACT=""
    [[ -z "$line" ]] || eval "_trap_stack_action ${line}"
    if [[ -n "$line" && "$_TRAP_STACK_ACT" == "${_TRAP_STACK_OURS[i]}" ]]; then
      if [[ -n "${_TRAP_STACK_SAVED[i]}" ]]; then
        eval "${_TRAP_STACK_SAVED[i]}"
      else
        trap - "$sig"
      fi
    fi
    _TRAP_STACK_SET[i]=0
    _TRAP_STACK_OURS[i]=""
    _TRAP_STACK_SAVED[i]=""
  done
}

# _trap_stack_fire <status>: remove every registered path, newest first, and
# return <status>. Each is removed once: its entry stays on the stack, empty,
# so a caller's trap that does not exit returns to code that still pops it.
# The entry is emptied before its removal starts: a signal during it runs this
# again, which must not start the same removal a second time. A --run function
# runs in a subshell, so one that calls exit does not skip the older paths.
_trap_stack_fire() {
  local rc="${1:-0}" i path run
  _trap_stack_self
  # Only in the shell that registered the paths: bash can run a parent's trap
  # in a subshell that is signalled as it starts. Level 0 passes on bash 3.2:
  # it reads 0 in the EXIT trap of a $( ... ), and the top-level shell, the
  # only other shell at level 0, never holds a subshell's stack.
  if [[ "$_TRAP_STACK_SELF" == "$_TRAP_STACK_OWNER" || ( -z "${BASHPID:-}" && "${BASH_SUBSHELL:-0}" -eq 0 ) ]]; then
    i="$_TRAP_STACK_DEPTH"
    while [[ "$i" -gt 0 ]]; do
      i=$((i - 1))
      path="${_TRAP_STACK_PATHS[i]:-}"
      [[ -n "$path" ]] || continue
      run="${_TRAP_STACK_RUNS[i]:-}"
      # Also keeps the EXIT trap that follows a signal's exit from running it again.
      _TRAP_STACK_PATHS[i]=""
      if [[ -n "$run" ]]; then
        ( "$run" "$path" ) || :
      else
        rm -rf -- "$path" 2>/dev/null || :
      fi
    done
  fi
  return "$rc"
}
