#!/usr/bin/env bash
# Service lifecycle: start, stop, restart, status, logs and readiness for a
# repository's own services, run either through docker compose or as native
# processes. Configuration is plain variables, normally set in scripts/project.sh:
#
#   SVC_BACKEND          compose | proc
#   SVC_COMPOSE_FILES    array of compose files (-f each)
#   SVC_COMPOSE_PROJECT  compose project name (-p), optional
#   SVC_PROCS            array of "name:command" (proc backend)
#   SVC_PORTS            array of TCP ports the services listen on, each "port"
#                        or "NAME:port" where NAME is the setting that holds it
#                        (a taken port then names the setting to change)
#   SVC_HEALTH_URL       URL that answers 2xx once the stack is ready
#   SVC_URLS             array of "Label url", printed after a start
#   SVC_STOP_MODE        compose only: "stop" keeps containers (default: down)
#   SVC_STOP_TIMEOUT     seconds between TERM and KILL (default 10)
#   SVC_READY_TIMEOUT    seconds svc_wait_ready waits (default 180)
#   SVC_ROOT             repository root (default: git top level, else $PWD)
#
# Exit codes: 0 ok or nothing to do, 1 failure, 2 usage (bad configuration).
# Needs: logging, docker, ports (imported below when missing).

if ! declare -F port_choose >/dev/null 2>&1 || ! declare -F get_docker_compose_cmd >/dev/null 2>&1 \
   || ! declare -F env_set_value >/dev/null 2>&1; then
  if declare -F shlib_import >/dev/null 2>&1; then
    shlib_import docker ports env
  fi
fi

# Internal: repository root, where .run/ lives and commands run.
_svc_root() {
  local top
  if [[ -n "${SVC_ROOT:-}" ]]; then
    printf '%s\n' "$SVC_ROOT"
  elif top="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$top" ]]; then
    printf '%s\n' "$top"
  else
    pwd
  fi
}

# Internal: validate SVC_BACKEND. Returns 2 when unset or unknown.
_svc_backend() {
  case "${SVC_BACKEND:-}" in
    compose|proc) return 0 ;;
    "") log_error "service: SVC_BACKEND is not set (compose or proc)"; return 2 ;;
    *)  log_error "service: SVC_BACKEND='${SVC_BACKEND}' is not compose or proc"; return 2 ;;
  esac
}

# Internal: is $1 a whole number? Used for timeouts and pids.
_svc_is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# Internal: read a timeout variable, falling back to its default when unset.
# Returns 2 on a non-numeric value: a typo would otherwise wait forever or never.
_svc_timeout() {
  local name="$1" def="$2" val
  eval "val=\"\${$name:-}\""
  [[ -z "$val" ]] && val="$def"
  if ! _svc_is_uint "$val"; then
    log_error "service: $name='$val' is not a number of seconds"
    return 2
  fi
  printf '%s\n' "$((10#$val))"
}

# Internal: parse SVC_PROCS into _SVC_NAMES / _SVC_CMDS. Names become file
# names under .run/, so only [A-Za-z0-9_.-] is allowed and no leading dot.
_svc_parse_procs() {
  _SVC_NAMES=(); _SVC_CMDS=()
  local entry name cmd seen
  if [[ -z "${SVC_PROCS[*]+set}" || ${#SVC_PROCS[@]} -eq 0 ]]; then
    log_error "service: SVC_PROCS is empty; set it to (\"name:command\" ...)"
    return 2
  fi
  for entry in "${SVC_PROCS[@]}"; do
    if [[ "$entry" != *:* ]]; then
      log_error "service: SVC_PROCS entry '$entry' is not name:command"
      return 2
    fi
    name="${entry%%:*}"; cmd="${entry#*:}"
    if [[ ! "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
      log_error "service: process name '$name' may use only letters, digits, _ . - (no leading dot)"
      return 2
    fi
    if [[ -z "${cmd//[[:space:]]/}" ]]; then
      log_error "service: process '$name' has an empty command"
      return 2
    fi
    for seen in ${_SVC_NAMES[@]+"${_SVC_NAMES[@]}"}; do
      if [[ "$seen" == "$name" ]]; then
        log_error "service: process name '$name' appears twice in SVC_PROCS"
        return 2
      fi
    done
    _SVC_NAMES+=("$name"); _SVC_CMDS+=("$cmd")
  done
}

# Internal: the port of an SVC_PORTS entry ("8000" or "NAME:8000").
_svc_port_of() { printf '%s\n' "${1##*:}"; }
# Internal: the setting named by an entry, or nothing.
_svc_port_var() { [[ "$1" == *:* ]] && printf '%s\n' "${1%%:*}"; return 0; }

# Internal: validate SVC_PORTS. A bad entry is a usage error, not a free port.
_svc_check_ports_config() {
  local e p v
  for e in ${SVC_PORTS[@]+"${SVC_PORTS[@]}"}; do
    p="$(_svc_port_of "$e")"; v="$(_svc_port_var "$e")"
    if ! _svc_is_uint "$p" || (( 10#$p < 1 || 10#$p > 65535 )); then
      log_error "service: SVC_PORTS entry '$e' is not a port 1-65535 (or NAME:port)"
      return 2
    fi
    if [[ -n "$v" && ! "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      log_error "service: SVC_PORTS entry '$e': '$v' is not a variable name"
      return 2
    fi
    # NAME is exported when a taken port is moved; one the shell or the
    # loader reads would break every command after it.
    case "$v" in
      PATH|HOME|IFS|SHELL|PWD|OLDPWD|USER|TMPDIR|LD_*|DYLD_*|BASH*|SVC_*)
        log_error "service: SVC_PORTS entry '$e': '$v' is not a port setting the shell can lend out"
        return 2 ;;
    esac
  done
}

# Internal: start-time fingerprint of a pid. A pidfile whose pid now belongs to
# another process must never be signalled. /proc on Linux (busybox ps has no
# lstart), ps -o lstart elsewhere. Prints nothing when neither works.
_svc_fingerprint() {
  local pid="$1" stat
  if [[ -r "/proc/$pid/stat" ]]; then
    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 0
    # Field 22 is starttime; comm (field 2) may hold spaces, so cut after ')'.
    stat="${stat##*) }"
    printf '%s\n' "$stat" | awk '{ print $20 }'
    return 0
  fi
  ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//'
}

# Internal: is process group $1 (any member) alive?
_svc_group_alive() { kill -0 -- "-$1" 2>/dev/null; }

# Internal: is proc $1 running? Sets _SVC_PID. A pidfile that names no live
# group, or a pid now owned by another process, is removed and reported.
_svc_running() {
  local name="$1" run pidf startf pid want have
  run="$(_svc_root)/.run"; pidf="$run/$name.pid"; startf="$run/$name.started"
  _SVC_PID=""
  [[ -f "$pidf" ]] || return 1
  pid="$(head -n 1 "$pidf" 2>/dev/null)"
  if ! _svc_is_uint "$pid" || [[ "$pid" -le 1 ]]; then
    log_warn "service: $name: removed stale pidfile (no valid pid in it)"
    rm -f "$pidf" "$startf"; return 1
  fi
  if ! _svc_group_alive "$pid"; then
    log_warn "service: $name: removed stale pidfile (pid $pid is not running)"
    rm -f "$pidf" "$startf"; return 1
  fi
  # The leader can exit while its group lives on; then the pid cannot have
  # been reused, so only a live leader needs its fingerprint checked.
  if kill -0 "$pid" 2>/dev/null; then
    if [[ ! -f "$startf" ]]; then
      log_warn "service: $name: removed pidfile for pid $pid with no start record; pid $pid left alone"
      rm -f "$pidf"; return 1
    fi
    want="$(cat "$startf" 2>/dev/null)"; have="$(_svc_fingerprint "$pid")"
    if [[ "$want" != "$have" ]]; then
      log_warn "service: $name: removed stale pidfile (pid $pid is now another process; left alone)"
      rm -f "$pidf" "$startf"; return 1
    fi
  fi
  _SVC_PID="$pid"
  return 0
}

# Internal: is a TCP port taken on this machine? Prints the owner when known.
_svc_port_owner() {
  local port="$1" owner
  if owner="$(port_in_use_by "$port" 2>/dev/null)" && [[ -n "$owner" ]]; then
    printf '%s\n' "$owner" | head -n 1
    return 0
  fi
  # No lsof/ss/netstat (or no permission to see the owner): a connect still
  # tells taken from free.
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    printf 'unknown process\n'
    return 0
  fi
  return 1
}

# Internal: after a port was moved on a terminal, offer to keep it in the
# repository's .env. Without it, the next status, stop or start reads the old
# port again and reports a running service as down.
_svc_offer_save() {
  local v="$1" new="$2" env_file answer=""
  env_file="$(_svc_root)/.env"
  printf 'Save %s=%s in %s so status, stop and the next start use it? [Y/n] ' "$v" "$new" "$env_file" >&2
  IFS= read -r answer || answer="n"
  case "$(printf '%s' "$answer" | tr 'A-Z' 'a-z' | tr -d ' \t\r')" in
    ""|y|yes)
      if env_set_value "$env_file" "$v" "$new"; then
        log_info "service: saved $v=$new in $env_file"
        return 0
      fi
      ;;
  esac
  log_info "service: using $v=$new for this start only; set $v=$new in .env to keep it"
}

# Internal: a configured port that is taken. A NAME:port entry, with a terminal,
# is asked about (port_choose): the answer is exported as NAME for this start,
# and SVC_PORTS, SVC_HEALTH_URL and SVC_URLS follow it, or the health check
# would ask whatever took the old port. Otherwise the start is refused with
# what to do. Returns 1 when any port stays taken.
_svc_ports_free() {
  local e p v owner new free taken=0 i=0
  local -a ports=()
  for e in ${SVC_PORTS[@]+"${SVC_PORTS[@]}"}; do
    p="$((10#$(_svc_port_of "$e")))"; v="$(_svc_port_var "$e")"
    ports+=("$e")
    if ! owner="$(_svc_port_owner "$p")"; then i=$((i + 1)); continue; fi
    if [[ -n "$v" ]] && _ports__can_ask; then
      if new="$(port_choose "$p" "$v=N in .env or the environment")"; then
        export "$v=$new"
        ports[i]="$v:$new"
        SVC_HEALTH_URL="${SVC_HEALTH_URL:+${SVC_HEALTH_URL//:$p\//:$new/}}"
        [[ "${SVC_HEALTH_URL:-}" != *":$p" ]] || SVC_HEALTH_URL="${SVC_HEALTH_URL%:"$p"}:$new"
        local -a urls=() u
        for u in ${SVC_URLS[@]+"${SVC_URLS[@]}"}; do
          u="${u//:$p\//:$new/}"; [[ "$u" != *":$p" ]] || u="${u%:"$p"}:$new"
          urls+=("$u")
        done
        SVC_URLS=(${urls[@]+"${urls[@]}"})
        _svc_offer_save "$v" "$new"
        i=$((i + 1)); continue
      fi
      taken=1; i=$((i + 1)); continue
    fi
    free="$(port_next_free "$p" 2>/dev/null)" || free=""
    log_error "service: port $p${v:+ ($v)} is already in use by $owner"
    if [[ -n "$v" ]]; then
      log_error "service: stop that process, or set $v to a free port${free:+ ($free is free)} in .env or the environment, then start again"
    else
      log_error "service: stop that process, or move the service to a free port${free:+ ($free is free)} (its configuration and SVC_PORTS), then start again"
    fi
    taken=1; i=$((i + 1))
  done
  SVC_PORTS=(${ports[@]+"${ports[@]}"})
  [[ $taken -eq 0 ]]
}

# Internal: the compose command plus -f/-p, in _SVC_COMPOSE.
_svc_compose_cmd() {
  local cmd f
  cmd="$(get_docker_compose_cmd)" || return 1
  _SVC_COMPOSE=()
  read -r -a _SVC_COMPOSE <<< "$cmd"
  for f in ${SVC_COMPOSE_FILES[@]+"${SVC_COMPOSE_FILES[@]}"}; do
    _SVC_COMPOSE+=(-f "$f")
  done
  if [[ -n "${SVC_COMPOSE_PROJECT:-}" ]]; then
    _SVC_COMPOSE+=(-p "$SVC_COMPOSE_PROJECT")
  fi
}

# Internal: run compose from the repository root, so relative -f paths resolve.
_svc_compose() {
  (cd "$(_svc_root)" && "${_SVC_COMPOSE[@]}" "$@")
}

# Internal: does the health URL answer with a status below 400?
_svc_healthy() {
  curl -fsS -o /dev/null --max-time 5 "$SVC_HEALTH_URL" >/dev/null 2>&1
}

# Internal: last 40 log lines, for a failed start.
_svc_log_tail() {
  local root i logf
  root="$(_svc_root)"
  if [[ "$SVC_BACKEND" == "compose" ]]; then
    _svc_compose logs --tail 40 2>&1
    return 0
  fi
  _svc_parse_procs >/dev/null 2>&1 || return 0
  for i in "${!_SVC_NAMES[@]}"; do
    logf="$root/.run/${_SVC_NAMES[$i]}.log"
    [[ -f "$logf" ]] || continue
    printf -- '--- last 40 lines of .run/%s.log ---\n' "${_SVC_NAMES[$i]}"
    tail -n 40 "$logf"
  done
}

# Internal: print SVC_URLS as "Label: url".
_svc_print_urls() {
  local e
  for e in ${SVC_URLS[@]+"${SVC_URLS[@]}"}; do
    if [[ "$e" == *" "* ]]; then
      printf '  %s: %s\n' "${e% *}" "${e##* }"
    else
      printf '  %s\n' "$e"
    fi
  done
}

# Internal: detach one command into its own session and process group.
# perl first: it also restores SIGINT/SIGQUIT, which bash leaves ignored in a
# background job, and it is on stock macOS, which has no setsid binary. When
# the caller has job control the child already leads a group, setsid() fails,
# so it forks once more. Either way the leader writes its own pid.
_svc_launch() {
  local name="$1" cmd="$2" root run pidf logf how="${_SVC_DETACH:-}"
  root="$(_svc_root)"; run="$root/.run"
  pidf="$run/$name.pid"; logf="$run/$name.log"
  rm -f "$pidf" "$pidf.tmp" "$run/$name.started"
  if [[ -z "$how" ]]; then
    if command -v perl >/dev/null 2>&1; then how=perl
    elif command -v setsid >/dev/null 2>&1; then how=setsid
    else
      log_error "service: need perl or setsid to detach '$name'"
      return 1
    fi
  fi
  # shellcheck disable=SC2016
  local boot='echo $$ >"$1.tmp" && mv -f "$1.tmp" "$1" && exec bash -c "$2"'
  printf '=== %s start %s ===\n' "$name" "$(date '+%Y-%m-%d %H:%M:%S')" >>"$logf"
  case "$how" in
    perl)
      # shellcheck disable=SC2016
      (cd "$root" && exec perl -MPOSIX -e '
        $SIG{INT} = "DEFAULT"; $SIG{QUIT} = "DEFAULT";
        sub ok { my $s = POSIX::setsid(); defined $s && $s >= 0 }
        if (!ok()) {
          my $p = fork; die "fork: $!\n" unless defined $p; exit 0 if $p;
          ok() or die "setsid: $!\n";
        }
        exec @ARGV or die "exec: $!\n";' bash -c "$boot" svc "$pidf" "$cmd") </dev/null >>"$logf" 2>&1 &
      ;;
    setsid)
      (cd "$root" && exec setsid bash -c "$boot" svc "$pidf" "$cmd") </dev/null >>"$logf" 2>&1 &
      ;;
    *) log_error "service: unknown detach method '$how'"; return 2 ;;
  esac
  local tries=0
  while [[ ! -s "$pidf" && $tries -lt 100 ]]; do sleep 0.1; tries=$((tries + 1)); done
  if [[ ! -s "$pidf" ]]; then
    log_error "service: $name did not start (no pid after 10s); see .run/$name.log"
    return 1
  fi
  _svc_fingerprint "$(head -n 1 "$pidf")" >"$run/$name.started"
  return 0
}

# Internal: is at least one SVC_PROCS process group alive? Read-only: a
# stale pidfile is left for _svc_running to report.
_svc_any_running() {
  local root name pid
  root="$(_svc_root)"
  _svc_parse_procs >/dev/null 2>&1 || return 1
  for name in "${_SVC_NAMES[@]}"; do
    pid="$(head -n 1 "$root/.run/$name.pid" 2>/dev/null)"
    _svc_is_uint "$pid" && [[ "$pid" -gt 1 ]] && _svc_group_alive "$pid" && return 0
  done
  return 1
}

# Usage: svc_wait_ready; poll SVC_HEALTH_URL until it answers or
# SVC_READY_TIMEOUT runs out. On timeout prints the last 40 log lines, returns 1.
svc_wait_ready() {
  _svc_backend || return
  local limit start
  limit="$(_svc_timeout SVC_READY_TIMEOUT 180)" || return 2
  [[ -n "${SVC_HEALTH_URL:-}" ]] || return 0
  if ! command -v curl >/dev/null 2>&1; then
    log_error "service: curl is needed to check SVC_HEALTH_URL"
    return 1
  fi
  if [[ "$SVC_BACKEND" == "compose" ]]; then _svc_compose_cmd || return 1; fi
  start=$SECONDS
  log_info "service: waiting up to ${limit}s for $SVC_HEALTH_URL"
  while :; do
    if _svc_healthy; then
      log_info "service: ready ($SVC_HEALTH_URL)"
      return 0
    fi
    (( SECONDS - start >= limit )) && break
    # A process that crashed will not become ready; do not wait out the timeout.
    if [[ "$SVC_BACKEND" == "proc" ]] && ! _svc_any_running; then
      log_error "service: every process exited before $SVC_HEALTH_URL answered"
      _svc_log_tail
      return 1
    fi
    sleep 1
  done
  log_error "service: not ready after ${limit}s: $SVC_HEALTH_URL"
  _svc_log_tail
  return 1
}

# Usage: svc_start [--build]; start the services, wait for health, print URLs.
svc_start() {
  _svc_backend || return
  local build=0 a
  for a in "$@"; do
    case "$a" in
      --build) build=1 ;;
      *) log_error "service: svc_start: unknown argument '$a'"; return 2 ;;
    esac
  done
  _svc_check_ports_config || return
  _svc_timeout SVC_READY_TIMEOUT 180 >/dev/null || return 2
  # Checked before anything starts: found after the launch, it would leave
  # every process running behind a failed start.
  if [[ -n "${SVC_HEALTH_URL:-}" ]] && ! command -v curl >/dev/null 2>&1; then
    log_error "service: curl is needed to check SVC_HEALTH_URL; install it, or unset SVC_HEALTH_URL"
    return 1
  fi
  if [[ "$SVC_BACKEND" == "compose" ]]; then
    _svc_compose_start "$build"
  else
    _svc_proc_start_all
  fi
}

_svc_compose_start() {
  local build="$1" running
  check_docker || return 1
  _svc_compose_cmd || return 1
  # Ports a running stack holds are its own; check only a stack that is down.
  running="$(_svc_compose ps -q 2>/dev/null)"
  if [[ -z "$running" ]]; then _svc_ports_free || return 1; fi
  if [[ "$build" == 1 ]]; then
    _svc_compose up -d --build || return 1
  else
    _svc_compose up -d || return 1
  fi
  svc_wait_ready || return 1
  _svc_print_urls
}

_svc_proc_start_all() {
  local root i name started=0 any_running=0
  _svc_parse_procs || return
  root="$(_svc_root)"
  mkdir -p "$root/.run" || return 1
  local -a todo=()
  for i in "${!_SVC_NAMES[@]}"; do
    name="${_SVC_NAMES[$i]}"
    if _svc_running "$name"; then
      log_info "service: $name is already running (pid $_SVC_PID)"
      any_running=1
    else
      todo+=("$i")
    fi
  done
  if [[ ${#todo[@]} -eq 0 ]]; then
    _svc_print_urls
    return 0
  fi
  # A running sibling may own a configured port, so ports are checked only
  # when none of ours is up.
  if [[ $any_running -eq 0 ]]; then _svc_ports_free || return 1; fi
  for i in "${todo[@]}"; do
    name="${_SVC_NAMES[$i]}"
    if ! _svc_launch "$name" "${_SVC_CMDS[$i]}"; then
      _svc_log_tail
      return 1
    fi
    log_info "service: started $name (pid $(head -n 1 "$root/.run/$name.pid")), log .run/$name.log"
    started=1
  done
  if [[ -n "${SVC_HEALTH_URL:-}" ]]; then
    svc_wait_ready || return 1
  else
    # No health URL: at least catch a command that exits at once.
    sleep 1
    for i in "${todo[@]}"; do
      name="${_SVC_NAMES[$i]}"
      if ! _svc_running "$name" 2>/dev/null; then
        log_error "service: $name exited right after start"
        _svc_log_tail
        return 1
      fi
    done
  fi
  [[ $started -eq 1 ]] && _svc_print_urls
  return 0
}

# Usage: svc_stop; stop the services. Nothing running is not an error.
svc_stop() {
  _svc_backend || return
  local limit
  limit="$(_svc_timeout SVC_STOP_TIMEOUT 10)" || return 2
  if [[ "$SVC_BACKEND" == "compose" ]]; then
    check_docker || return 1
    _svc_compose_cmd || return 1
    if [[ "${SVC_STOP_MODE:-}" == "stop" ]]; then
      _svc_compose stop --timeout "$limit"
    else
      _svc_compose down --timeout "$limit"
    fi
    return
  fi
  _svc_parse_procs || return
  local i name pid run n rc=0
  run="$(_svc_root)/.run"
  for i in "${!_SVC_NAMES[@]}"; do
    name="${_SVC_NAMES[$i]}"
    if ! _svc_running "$name"; then
      log_info "service: $name is not running"
      continue
    fi
    pid="$_SVC_PID"
    kill -TERM -- "-$pid" 2>/dev/null || true
    n=0
    while _svc_group_alive "$pid" && [[ $n -lt $((limit * 10)) ]]; do
      sleep 0.1; n=$((n + 1))
    done
    if _svc_group_alive "$pid"; then
      log_warn "service: $name still running after ${limit}s; sending KILL"
      kill -KILL -- "-$pid" 2>/dev/null || true
      n=0
      while _svc_group_alive "$pid" && [[ $n -lt 50 ]]; do sleep 0.1; n=$((n + 1)); done
    fi
    if _svc_group_alive "$pid"; then
      log_error "service: $name (process group $pid) did not stop"
      rc=1
      continue
    fi
    rm -f "$run/$name.pid" "$run/$name.started"
    log_info "service: stopped $name"
  done
  return $rc
}

# Usage: svc_restart [--build]; svc_stop then svc_start.
svc_restart() {
  svc_stop || return
  svc_start "$@"
}

# Usage: svc_status; what runs, which ports listen, whether health answers.
# Returns 0 when everything is up (and healthy), 1 otherwise.
svc_status() {
  _svc_backend || return
  _svc_check_ports_config || return
  local ok=0 p owner
  if [[ "$SVC_BACKEND" == "compose" ]]; then
    check_docker || return 1
    _svc_compose_cmd || return 1
    _svc_compose ps || ok=1
    [[ -n "$(_svc_compose ps -q 2>/dev/null)" ]] || ok=1
  else
    _svc_parse_procs || return
    local i name
    for i in "${!_SVC_NAMES[@]}"; do
      name="${_SVC_NAMES[$i]}"
      if _svc_running "$name"; then
        printf '%s: running (pid %s)\n' "$name" "$_SVC_PID"
      else
        printf '%s: stopped\n' "$name"
        ok=1
      fi
    done
  fi
  local e
  for e in ${SVC_PORTS[@]+"${SVC_PORTS[@]}"}; do
    p="$((10#$(_svc_port_of "$e")))"
    if owner="$(_svc_port_owner "$p")"; then
      printf 'port %s: listening (%s)\n' "$p" "$owner"
    else
      printf 'port %s: not listening\n' "$p"
      ok=1
    fi
  done
  if [[ -n "${SVC_HEALTH_URL:-}" ]]; then
    if command -v curl >/dev/null 2>&1 && _svc_healthy; then
      printf 'health %s: ok\n' "$SVC_HEALTH_URL"
    else
      printf 'health %s: failing\n' "$SVC_HEALTH_URL"
      ok=1
    fi
  fi
  return $ok
}

# Usage: svc_logs [name]; follow the logs of one service, or all of them.
# SVC_LOGS_FOLLOW=0 prints the last 100 lines and returns instead.
svc_logs() {
  _svc_backend || return
  local want="${1:-}" follow="${SVC_LOGS_FOLLOW:-1}"
  if [[ "$SVC_BACKEND" == "compose" ]]; then
    _svc_compose_cmd || return 1
    local -a args=(logs)
    if [[ "$follow" == 1 ]]; then args+=(-f); else args+=(--tail 100); fi
    [[ -n "$want" ]] && args+=("$want")
    _svc_compose "${args[@]}"
    return
  fi
  _svc_parse_procs || return
  local root i found=0
  root="$(_svc_root)"
  local -a files=()
  for i in "${!_SVC_NAMES[@]}"; do
    if [[ -z "$want" || "$want" == "${_SVC_NAMES[$i]}" ]]; then
      found=1
      [[ -f "$root/.run/${_SVC_NAMES[$i]}.log" ]] && files+=("$root/.run/${_SVC_NAMES[$i]}.log")
    fi
  done
  if [[ $found -eq 0 ]]; then
    log_error "service: no process named '$want' in SVC_PROCS"
    return 2
  fi
  if [[ ${#files[@]} -eq 0 ]]; then
    log_info "service: no logs yet under .run/"
    return 0
  fi
  if [[ "$follow" == 1 ]]; then
    tail -n 100 -f "${files[@]}"
  else
    tail -n 100 "${files[@]}"
  fi
}
