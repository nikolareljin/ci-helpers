#!/usr/bin/env bash
# Port utilities: detect usage and conflicts

PORT_DETECTION_ALLOW_SUDO=${PORT_DETECTION_ALLOW_SUDO:-false}

# The awk programs below run under whatever awk the system has: mawk on
# Debian/Ubuntu, BSD awk on macOS. They used gawk's three-argument match(),
# which the others reject as a syntax error -- on stderr, discarded -- so the
# ss path found nothing and a port in use was reported free. POSIX match()
# with RSTART/RLENGTH and split()'s return value work everywhere.
#
# ss: users:(("name",pid=123,fd=4)) -> "name (PID 123)".
# The $ fields are awk's, not the shell's.
# shellcheck disable=SC2016
_PORTS_SS_DETAILS_AWK='$4 ~ ":" port "$" {
  if (match($0, /users:\(\("[^"]+",pid=[0-9]+/)) {
    s = substr($0, RSTART + 9, RLENGTH - 9)
    name = s; sub(/",pid=.*/, "", name)
    pid = s; sub(/.*,pid=/, "", pid)
    printf "%s (PID %s)\n", name, pid
  } else { print "unknown process" }
}'
# ss: every pid=N on a matching line (a socket shared by several processes).
# shellcheck disable=SC2016
_PORTS_SS_PID_AWK='$4 ~ ":" port "$" {
  rest = $0
  while (match(rest, /pid=[0-9]+/)) {
    print substr(rest, RSTART + 4, RLENGTH - 4)
    rest = substr(rest, RSTART + RLENGTH)
  }
}'
# netstat -ltnp: column 7 is PID/name, or "-" when not visible.
# shellcheck disable=SC2016
_PORTS_NETSTAT_DETAILS_AWK='$4 ~ port "$" {
  n = split($7, parts, "/")
  if (parts[1] != "-" && parts[1] != "") {
    if (n > 1) { printf "%s (PID %s)\n", parts[2], parts[1] } else { printf "PID %s\n", parts[1] }
  }
}'

# Internal: is $1 a single TCP port, 1-65535? A range such as 1-65535, or an
# empty string, reaches lsof as -iTCP:1-65535 / -iTCP: and matches every
# listener on the machine -- which a kill-port caller would then kill.
_ports__valid_port() {
  [[ "${1:-}" =~ ^0*[0-9]{1,5}$ ]] || return 1
  (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# Usage: list_port_usage_details <port>; prints process/user details for listeners.
list_port_usage_details() {
  local port="${1:-}" line
  _ports__valid_port "$port" || return 1
  port=$((10#$port))
  local -a details=()
  local allow_sudo="$PORT_DETECTION_ALLOW_SUDO"

  if command -v lsof >/dev/null 2>&1; then
    while IFS= read -r line; do details+=("$line"); done < <(
      lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {printf "%s (PID %s, user %s)\n", $1, $2, $3}'
    )
    if [[ ${#details[@]} -eq 0 && "$allow_sudo" == "true" ]]; then
      while IFS= read -r line; do details+=("$line"); done < <(
        run_with_optional_sudo true lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {printf "%s (PID %s, user %s)\n", $1, $2, $3}'
      )
    fi
  fi

  if [[ ${#details[@]} -eq 0 ]] && command -v ss >/dev/null 2>&1; then
    while IFS= read -r line; do details+=("$line"); done < <(
      ss -Hltpn 2>/dev/null | awk -v port="$port" "$_PORTS_SS_DETAILS_AWK"
    )
    if [[ ${#details[@]} -eq 0 && "$allow_sudo" == "true" ]]; then
      while IFS= read -r line; do details+=("$line"); done < <(
        run_with_optional_sudo true ss -Hltpn 2>/dev/null | awk -v port="$port" "$_PORTS_SS_DETAILS_AWK"
      )
    fi
  fi

  if [[ ${#details[@]} -eq 0 ]] && command -v netstat >/dev/null 2>&1; then
    while IFS= read -r line; do details+=("$line"); done < <(
      netstat -ltnp 2>/dev/null | awk -v port=":$port" "$_PORTS_NETSTAT_DETAILS_AWK"
    )
    if [[ ${#details[@]} -eq 0 && "$allow_sudo" == "true" ]]; then
      while IFS= read -r line; do details+=("$line"); done < <(
        run_with_optional_sudo true netstat -ltnp 2>/dev/null | awk -v port=":$port" "$_PORTS_NETSTAT_DETAILS_AWK"
      )
    fi
  fi

  if [[ ${#details[@]} -gt 0 ]]; then
    printf '%s\n' "${details[@]}"
    return 0
  fi
  return 1
}

# Usage: list_port_listener_pids <port>; prints unique listener PIDs.
list_port_listener_pids() {
  local port="${1:-}"; local -a pids=()
  _ports__valid_port "$port" || return 1
  port=$((10#$port))
  local allow_sudo="$PORT_DETECTION_ALLOW_SUDO"

  if command -v lsof >/dev/null 2>&1; then
    while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <(
      lsof -t -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null
    )
    if [[ ${#pids[@]} -eq 0 && "$allow_sudo" == "true" ]]; then
      while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <(
        run_with_optional_sudo true lsof -t -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null
      )
    fi
  fi

  if [[ ${#pids[@]} -eq 0 ]] && command -v ss >/dev/null 2>&1; then
    while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <(
      ss -Hltpn 2>/dev/null | awk -v port="$port" "$_PORTS_SS_PID_AWK"
    )
    if [[ ${#pids[@]} -eq 0 && "$allow_sudo" == "true" ]]; then
      while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <(
        run_with_optional_sudo true ss -Hltpn 2>/dev/null | awk -v port="$port" "$_PORTS_SS_PID_AWK"
      )
    fi
  fi

  if [[ ${#pids[@]} -eq 0 ]] && command -v netstat >/dev/null 2>&1; then
    while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <(
      netstat -ltnp 2>/dev/null | awk -v port=":$port" '$4 ~ port "$" { split($7, parts, "/"); if (parts[1] != "-" && parts[1] != "") { print parts[1]; } }'
    )
    if [[ ${#pids[@]} -eq 0 && "$allow_sudo" == "true" ]]; then
      while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <(
        run_with_optional_sudo true netstat -ltnp 2>/dev/null | awk -v port=":$port" '$4 ~ port "$" { split($7, parts, "/"); if (parts[1] != "-" && parts[1] != "") { print parts[1]; } }'
      )
    fi
  fi

  if [[ ${#pids[@]} -eq 0 ]] && command -v fuser >/dev/null 2>&1; then
    # fuser prints every PID on one line; one per element, not one element.
    while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <(
      fuser "${port}/tcp" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) print $i }'
    )
    if [[ ${#pids[@]} -eq 0 && "$allow_sudo" == "true" ]]; then
      while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <(
        run_with_optional_sudo true fuser "${port}/tcp" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) print $i }'
      )
    fi
  fi

  if [[ ${#pids[@]} -gt 0 ]]; then
    printf '%s\n' "${pids[@]}" | sort -u
  fi
}

# Usage: port_in_use_by <port>; prints process details or nothing if unused.
port_in_use_by() {
  local port="$1" _sh_line
  local -a details=()
  while IFS= read -r _sh_line; do details+=("$_sh_line"); done < <(list_port_usage_details "$port" 2>/dev/null || true)
  if [[ ${#details[@]} -gt 0 ]]; then
    printf '%s\n' "${details[@]}"
    return 0
  fi
  return 1
}

# Defaults for a typical containerised web stack -- reverse proxy, search,
# cache, database and a local model runner. Callers may override any of these
# or pass a different list entirely.
REQUIRED_PORT_DEFAULTS=(
  "TRAEFIK_HTTP_PORT:80"
  "TRAEFIK_DASHBOARD_PORT:8081"
  "ELASTICSEARCH_PORT:9200"
  "ELASTICSEARCH_TRANSPORT_PORT:9300"
  "REDIS_PORT:6379"
  "POSTGRES_PORT:5432"
  "OLLAMA_PORT:11434"
  "BACKEND_PORT:8000"
  "FRONTEND_PORT:3000"
  "API_PORT:8080"
)

# Usage: check_required_ports_available [env_file]; populates conflict globals.
check_required_ports_available() {
  local env_file="${1:-.env}"
  REQUIRED_PORT_CONFLICT_MESSAGES=()
  REQUIRED_PORT_CONFLICT_SUMMARIES=()
  REQUIRED_PORT_CONFLICTS_JSON="[]"

  local entry var default port
  # Indexed, not associative: every key here is a port number, so an indexed
  # array indexes identically on bash 3.2 and 5.x while an associative one
  # silently degrades on 3.2 into exactly this with no guarantee about it.
  declare -a port_to_vars=()

  for entry in "${REQUIRED_PORT_DEFAULTS[@]}"; do
    var="${entry%%:*}"; default="${entry#*:}"
    port=$(resolve_env_value "$var" "$default" "$env_file")
    [[ -z "$port" ]] && continue
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
      REQUIRED_PORT_CONFLICT_MESSAGES+=("${var} has invalid port value: $port")
      REQUIRED_PORT_CONFLICT_SUMMARIES+=("Invalid port for ${var}: $port")
      continue
    fi
    # Normalise before subscripting: an array subscript is an arithmetic
    # context, where a leading zero would be read as octal.
    port=$((10#$port))
    if [[ -n "${port_to_vars[$port]:-}" ]]; then
      port_to_vars[$port]="${port_to_vars[$port]},$var"
    else
      port_to_vars[$port]="$var"
    fi
  done

  local -a json_entries=() details=() vars_for_port=()
  local conflict_found=0 _sh_line
  for port in "${!port_to_vars[@]}"; do
    details=()
    while IFS= read -r _sh_line; do details+=("$_sh_line"); done < <(list_port_usage_details "$port" 2>/dev/null || true)
    if [[ ${#details[@]} -gt 0 ]]; then
      conflict_found=1
      IFS=',' read -ra vars_for_port <<< "${port_to_vars[$port]}"
      local primary="Port ${port} (${port_to_vars[$port]//,/, }) is already in use"
      if [[ -n "${details[0]:-}" ]]; then primary+=" by ${details[0]}"; fi
      primary+="."
      REQUIRED_PORT_CONFLICT_MESSAGES+=("$primary")
      REQUIRED_PORT_CONFLICT_SUMMARIES+=("Port ${port} (${port_to_vars[$port]//,/, }) in use")
      if [[ ${#details[@]} -gt 1 ]]; then
        local extra
        for extra in "${details[@]:1}"; do
          REQUIRED_PORT_CONFLICT_MESSAGES+=("    • Also detected: $extra")
        done
      fi
      REQUIRED_PORT_CONFLICT_MESSAGES+=("    • Tip: run ./kill-port ${port} to free it, then retry.")

      local var_json="" detail_json="" var_name detail
      for var_name in "${vars_for_port[@]}"; do
        var_name=$(echo "$var_name" | xargs)
        var_json+="${var_json:+,}\"$(json_escape "$var_name")\""
      done
      for detail in "${details[@]}"; do
        detail_json+="${detail_json:+,}\"$(json_escape "$detail")\""
      done
      json_entries+=("{\"port\":$port,\"variables\":[${var_json:-}],\"details\":[${detail_json:-}]}" )
    fi
  done

  if [[ ${#json_entries[@]} -gt 0 ]]; then
    local combined; combined=$(IFS=,; echo "${json_entries[*]}")
    REQUIRED_PORT_CONFLICTS_JSON="[${combined}]"
    export REQUIRED_PORT_CONFLICTS_JSON
  fi

  [[ $conflict_found -eq 0 ]]
}
