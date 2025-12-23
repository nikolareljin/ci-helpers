#!/usr/bin/env bash
# Browser helpers

check_port() {
  local port="$1" host="${2:-localhost}"
  if command -v nc >/dev/null 2>&1; then
    nc -z "$host" "$port" 2>/dev/null
    return $?
  elif command -v telnet >/dev/null 2>&1; then
    timeout 1 telnet "$host" "$port" >/dev/null 2>&1
    return $?
  else
    log_warn "Neither 'nc' nor 'telnet' found, skipping port check"
    return 1
  fi
}

open_url() {
  local url="$1"
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 || true; return 0; fi
  if command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 || true; return 0; fi
  if command -v gio >/dev/null 2>&1; then gio open "$url" >/dev/null 2>&1 || true; return 0; fi
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) cmd.exe /c start "" "$url" >/dev/null 2>&1 || true ;;
    *) log_warn "Could not auto-open browser. Please open: $url" ;;
  esac
}

open_frontend_when_ready() {
  local host="${FRONTEND_HOST:-localhost}" port="${FRONTEND_PORT:-3000}" max_wait="${1:-120}" waited=0
  local compose_extra=( )
  if declare -p COMPOSE_ARGS >/dev/null 2>&1; then compose_extra=( "${COMPOSE_ARGS[@]}" ); fi
  log_info "Waiting for 'frontend' service to be running..."
  local waited_running=0
  # Compose V2 shows "Up", V1 shows "Up"/"Up XX" and sometimes "running" — handle both.
  while ! docker_compose "${compose_extra[@]}" ps frontend 2>/dev/null | grep -Eiq "\\b(Up|running)\\b"; do
    sleep 2; waited_running=$((waited_running + 2))
    if [[ $waited_running -ge $max_wait ]]; then log_warn "'frontend' not detected as running after ${max_wait}s; attempting to open anyway."; break; fi
    if [[ $((waited_running % 10)) -eq 0 ]]; then log_info "Still waiting for 'frontend'... (${waited_running}s elapsed)"; fi
  done

  if command -v nc >/dev/null 2>&1 || command -v telnet >/dev/null 2>&1; then
    while ! check_port "$port" "$host"; do
      sleep 2; waited=$((waited + 2))
      if [[ $waited -ge $max_wait ]]; then log_warn "Frontend port $host:$port not responding after ${max_wait}s; opening URL anyway."; break; fi
      if [[ $((waited % 10)) -eq 0 ]]; then log_info "Waiting for $host:$port... (${waited}s elapsed)"; fi
    done
  fi
  local url="http://${host}:${port}/"
  log_info "Opening frontend at: $url"
  open_url "$url"
}
