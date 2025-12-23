#!/usr/bin/env bash
# Port utilities: detect usage and conflicts

PORT_DETECTION_ALLOW_SUDO=${PORT_DETECTION_ALLOW_SUDO:-false}

list_port_usage_details() {
  local port="$1"
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
      ss -Hltpn 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" { if (match($0, /users:\(\("([^\"]+)",pid=([0-9]+)/, arr)) { printf "%s (PID %s)\n", arr[1], arr[2]; } else { print "unknown process"; } }'
    )
    if [[ ${#details[@]} -eq 0 && "$allow_sudo" == "true" ]]; then
      while IFS= read -r line; do details+=("$line"); done < <(
        run_with_optional_sudo true ss -Hltpn 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" { if (match($0, /users:\(\("([^\"]+)",pid=([0-9]+)/, arr)) { printf "%s (PID %s)\n", arr[1], arr[2]; } else { print "unknown process"; } }'
      )
    fi
  fi

  if [[ ${#details[@]} -eq 0 ]] && command -v netstat >/dev/null 2>&1; then
    while IFS= read -r line; do details+=("$line"); done < <(
      netstat -ltnp 2>/dev/null | awk -v port=":$port" '$4 ~ port "$" { split($7, parts, "/"); if (parts[1] != "-" && parts[1] != "") { if (length(parts) > 1) { printf "%s (PID %s)\n", parts[2], parts[1]; } else { printf "PID %s\n", parts[1]; } } }'
    )
    if [[ ${#details[@]} -eq 0 && "$allow_sudo" == "true" ]]; then
      while IFS= read -r line; do details+=("$line"); done < <(
        run_with_optional_sudo true netstat -ltnp 2>/dev/null | awk -v port=":$port" '$4 ~ port "$" { split($7, parts, "/"); if (parts[1] != "-" && parts[1] != "") { if (length(parts) > 1) { printf "%s (PID %s)\n", parts[2], parts[1]; } else { printf "PID %s)\n", parts[1]; } } }'
      )
    fi
  fi

  if [[ ${#details[@]} -gt 0 ]]; then
    printf '%s\n' "${details[@]}"
    return 0
  fi
  return 1
}

list_port_listener_pids() {
  local port="$1"; local -a pids=()
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
      ss -Hltpn 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" { if (match($0, /pid=([0-9]+)/, arr)) { print arr[1]; } }'
    )
    if [[ ${#pids[@]} -eq 0 && "$allow_sudo" == "true" ]]; then
      while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <(
        run_with_optional_sudo true ss -Hltpn 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" { if (match($0, /pid=([0-9]+)/, arr)) { print arr[1]; } }'
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
    while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <(
      fuser "${port}/tcp" 2>/dev/null
    )
    if [[ ${#pids[@]} -eq 0 && "$allow_sudo" == "true" ]]; then
      while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <(
        run_with_optional_sudo true fuser "${port}/tcp" 2>/dev/null
      )
    fi
  fi

  if [[ ${#pids[@]} -gt 0 ]]; then
    printf '%s\n' "${pids[@]}" | sort -u
  fi
}

# Defaults used by document-tracker; callers may override or pass a different list
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

check_required_ports_available() {
  local env_file="${1:-.env}"
  REQUIRED_PORT_CONFLICT_MESSAGES=()
  REQUIRED_PORT_CONFLICT_SUMMARIES=()
  REQUIRED_PORT_CONFLICTS_JSON="[]"

  local entry var default port
  declare -A port_to_vars=()

  for entry in "${REQUIRED_PORT_DEFAULTS[@]}"; do
    var="${entry%%:*}"; default="${entry#*:}"
    port=$(resolve_env_value "$var" "$default" "$env_file")
    [[ -z "$port" ]] && continue
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
      REQUIRED_PORT_CONFLICT_MESSAGES+=("${var} has invalid port value: $port")
      REQUIRED_PORT_CONFLICT_SUMMARIES+=("Invalid port for ${var}: $port")
      continue
    fi
    if [[ -n "${port_to_vars[$port]:-}" ]]; then
      port_to_vars[$port]="${port_to_vars[$port]},$var"
    else
      port_to_vars[$port]="$var"
    fi
  done

  local -a json_entries=()
  local conflict_found=0
  for port in "${!port_to_vars[@]}"; do
    mapfile -t details < <(list_port_usage_details "$port" 2>/dev/null || true)
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
  fi

  [[ $conflict_found -eq 0 ]]
}

