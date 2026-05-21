#!/usr/bin/env bash
# Docker/Docker Compose helpers

# Prefer 'docker compose' (V2) over 'docker-compose' (V1); print error if neither.
get_docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return 0
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
    return 0
  else
    log_error "Neither 'docker compose' nor 'docker-compose' found."
    return 1
  fi
}

# Execute docker compose with auto-detected command
docker_compose() {
  local cmd; cmd=$(get_docker_compose_cmd) || return 1
  log_debug "Executing: $cmd $*"
  $cmd "$@"
}

# Compatibility: document-tracker style
run_docker_compose() { docker_compose "$@"; }

# Compatibility: helpergpt style (takes a single combined command string)
run_docker_compose_command() {
  local cmd; cmd=$(get_docker_compose_cmd) || return 1
  if [[ $# -eq 1 ]]; then
    local -a split_args=()
    read -r -a split_args <<< "$1"
    # shellcheck disable=SC2086
    $cmd "${split_args[@]}"
  else
    $cmd "$@"
  fi
}

# Usage: check_docker; validates Docker CLI and daemon availability.
check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker CLI not found. Install Docker and ensure it is on PATH."
    return 1
  fi

  local info_output
  if ! info_output=$(docker info 2>&1); then
    if echo "$info_output" | grep -qi "permission denied"; then
      log_error "Docker daemon reachable but permission denied. Add your user to the docker group or run with sudo."
    elif echo "$info_output" | grep -qi "Cannot connect to the Docker daemon"; then
      log_error "Docker daemon is not running. Start Docker and try again."
    else
      log_error "Docker daemon is not running or unreachable: $info_output"
    fi
    return 1
  fi
}

# Usage: check_project_root; errors if docker-compose.yml is missing in CWD.
check_project_root() {
  if [[ ! -f "docker-compose.yml" ]]; then
    log_error "docker-compose.yml not found. Run from the project root."
    return 1
  fi
}

# Usage: wait_for_service <service_name> [max_wait_seconds]; waits until running.
wait_for_service() {
  local service_name="$1"; local max_wait="${2:-60}"; local wait_time=0
  log_info "Waiting for service '$service_name' to be ready..."
  while [[ $wait_time -lt $max_wait ]]; do
    if docker_compose ps "$service_name" 2>/dev/null | grep -q "running"; then
      log_info "Service '$service_name' is ready"
      return 0
    fi
    sleep 2; wait_time=$((wait_time + 2))
    if [[ $((wait_time % 10)) -eq 0 ]]; then
      log_info "Still waiting for '$service_name'... (${wait_time}s elapsed)"
    fi
  done
  log_error "Timeout waiting for service '$service_name' after ${max_wait}s"
  return 1
}

# Show running Docker containers and status of services from docker-compose.yml
# - Prints a table of currently running containers (name, image, status, running for, ports)
# - If docker-compose.yml is present in CWD, lists defined services and marks:
#   ✅ running (with since), 💥 failed (exited/restarting), ✖️ not running
# - If no docker-compose.yml is found, prints a tip to cd into a directory that has it.
docker_status() {
  # Verify Docker engine
  if ! check_docker; then
    return 1
  fi

  log_info "Running containers (docker ps):"
  if [[ -n "$(docker ps -q 2>/dev/null)" ]]; then
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}\t{{.Ports}}'
  else
    log_warn "No containers are currently running."
  fi

  # Compose services status (if compose file exists in this directory)
  if [[ ! -f "docker-compose.yml" ]]; then
    log_warn "No docker-compose.yml in $(pwd). cd to your project root to check service status."
    return 0
  fi

  local services
  if ! services=$(docker_compose config --services 2>/dev/null); then
    log_error "Failed to parse services from docker-compose.yml"
    return 1
  fi

  if [[ -z "$services" ]]; then
    log_warn "No services found in docker-compose.yml"
    return 0
  fi

  echo
  log_info "Compose services (from docker-compose.yml):"

  local service ids since_list since out
  while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    # Container IDs for running instances of this service (empty if not running)
    ids=$(docker_compose ps -q "$service" 2>/dev/null | xargs)
    if [[ -n "$ids" ]]; then
      # Gather "running for" info for each container id
      since_list=()
      local cid rf
      for cid in $ids; do
        rf=$(docker ps --filter "id=$cid" --format '{{.RunningFor}}' 2>/dev/null | head -n1)
        [[ -n "$rf" ]] && since_list+=("$rf")
      done
      if [[ ${#since_list[@]} -gt 0 ]]; then
        since=$(IFS=","; echo "${since_list[*]}")
        log_info "✅ ${service} — running (since ${since})"
      else
        log_info "✅ ${service} — running"
      fi
    else
      # Not running; inspect ps output to differentiate failed vs not started
      out=$(docker_compose ps "$service" 2>/dev/null || true)
      if echo "$out" | grep -Eqi '\b(Exit|Exited|exited|dead|restarting)\b'; then
        # Extract a short status phrase if possible
        local reason
        reason=$(echo "$out" | grep -Eio '\b(Exit(ed)?\s*\(?[0-9]*\)?|exited\s*\(?[0-9]*\)?|dead|restarting[^ ]*)\b' | head -n1)
        log_error "💥 ${service} — failed (${reason:-last state unknown})"
      else
        log_warn "✖️ ${service} — not running"
      fi
    fi
  done <<< "$services"
}
