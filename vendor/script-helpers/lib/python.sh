#!/usr/bin/env bash
# Python helpers: resolve Python 3 and manage venvs.

python_version() {
  "$1" -c 'import sys; v = sys.version_info; print("{}.{}".format(v[0], v[1]))' 2>/dev/null || return 1
}

python_has_min_version() {
  local bin="$1"
  local min_major="$2"
  local min_minor="$3"
  local version
  version="$(python_version "$bin")" || return 1
  if ! [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi
  local major="${version%%.*}"
  local minor="${version#*.}"
  if [[ "$major" -gt "$min_major" ]]; then
    return 0
  fi
  if [[ "$major" -eq "$min_major" && "$minor" -ge "$min_minor" ]]; then
    return 0
  fi
  return 1
}

python_can_run() {
  local bin="$1"
  if [[ -z "$bin" ]]; then
    return 1
  fi
  if [[ "$bin" == */* ]]; then
    if [[ -x "$bin" ]]; then
      return 0
    fi
    return 1
  fi
  command -v "$bin" >/dev/null 2>&1
}

python_pick_3() {
  local min_major="${1:-3}"
  local min_minor="${2:-8}"
  for candidate in python3 python; do
    if python_can_run "$candidate"; then
      if python_has_min_version "$candidate" "$min_major" "$min_minor"; then
        echo "$candidate"
        return 0
      fi
    fi
  done
  return 1
}

python_resolve_3() {
  local requested="${1:-}"
  local min_major="${2:-3}"
  local min_minor="${3:-8}"

  if [[ -n "$requested" ]]; then
    if python_can_run "$requested" && python_has_min_version "$requested" "$min_major" "$min_minor"; then
      echo "$requested"
      return 0
    fi
  fi

  python_pick_3 "$min_major" "$min_minor"
}

python_ensure_venv() {
  local python_bin="$1"
  local venv_dir="$2"
  local venv_python

  if [[ -z "$python_bin" || -z "$venv_dir" ]]; then
    return 1
  fi

  venv_python="$venv_dir/bin/python"
  if [[ ! -x "$venv_python" ]]; then
    if ! "$python_bin" -m venv "$venv_dir"; then
      print_error "Failed to create virtualenv at $venv_dir. Ensure python3-venv is installed."
      return 1
    fi
  fi

  if ! python_can_run "$venv_python"; then
    print_error "Virtualenv Python at $venv_python is not executable."
    return 1
  fi
  if ! python_version "$venv_python" >/dev/null 2>&1; then
    print_error "Virtualenv Python at $venv_python is not functional. Try recreating the virtualenv."
    return 1
  fi

  echo "$venv_python"
}
