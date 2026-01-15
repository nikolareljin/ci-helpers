#!/usr/bin/env bash
# Dialog helpers: sizing and input utilities.

# Initialize dialog dimensions based on terminal size.
dialog_init() {
  local cols lines
  cols=$(tput cols 2>/dev/null || echo 120)
  lines=$(tput lines 2>/dev/null || echo 40)
  DIALOG_WIDTH=$((cols * 70 / 100))
  DIALOG_HEIGHT=$((lines * 70 / 100))
  (( DIALOG_WIDTH < 60 )) && DIALOG_WIDTH=60
  (( DIALOG_HEIGHT < 20 )) && DIALOG_HEIGHT=20
  export DIALOG_WIDTH DIALOG_HEIGHT
}

# Ensure `dialog` CLI exists.
check_if_dialog_installed() {
  if ! command -v dialog >/dev/null 2>&1; then
    print_error "Dialog is not installed. Please install it and try again."
    return 1
  fi
  # Also initialize dialog dimensions for compatibility with callers
  dialog_init
}

# Prompt for a value using dialog; prints the value to stdout.
# Usage: get_value "Title" "Message" "Default"
get_value() {
  local title="$1" message="$2" default_value="${3:-}"
  dialog_init
  check_if_dialog_installed || return 1

  local tmp
  tmp=$(mktemp "/tmp/$(basename "$0").XXXXXXXXXX")
  local cancel_msg="User pressed Cancel. Exiting."

  dialog --title "$title" --inputbox "$message" 10 60 "$default_value" 2>"$tmp"
  local status=$?
  if [[ $status -ne 0 ]]; then
    print_error "$cancel_msg"
    rm -f "$tmp"
    return 1
  fi

  if [[ -z "$(cat "$tmp")" ]]; then
    print_error "$cancel_msg"
    rm -f "$tmp"
    return 1
  fi

  cat "$tmp"
  rm -f "$tmp"
}

# Selection helpers used by burn-iso project. Expect an associative array DISTROS to be defined by the caller.
select_multiple_distros() {
  dialog_init; check_if_dialog_installed || return 1
  local selected_distros options=() d
  for d in "${!DISTROS[@]}"; do
    options+=("$d" "${DISTROS[$d]}")
  done
  selected_distros=$(dialog --stdout --title "Select Linux Distro" --checklist "Choose Linux distributions to download:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${options[@]}")
  if [[ $? -ne 0 ]]; then
    print_error "No distro selected. Exiting..."
    return 1
  fi
  echo "$selected_distros"
}

# Usage: select_distro; expects DISTROS associative array and echoes selection.
select_distro() {
  dialog_init; check_if_dialog_installed || return 1
  local selected_distro options=() d
  for d in "${!DISTROS[@]}"; do
    options+=("$d" "${DISTROS[$d]}")
  done
  selected_distro=$(dialog --stdout --title "Select Linux Distro" --menu "Choose a Linux distribution to download:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${options[@]}")
  if [[ $? -ne 0 ]]; then
    print_error "No distro selected. Exiting..."
    return 1
  fi
  echo "$selected_distro"
}

# --- Download progress gauge ---

# Internal: format bytes to human-readable (e.g., 1.2 MB)
_dialog__human_size() {
  local bytes=${1:-0}
  awk -v b="$bytes" '
    function human(x){
      split("B KB MB GB TB", u, " ");
      i=0; while (x>=1024 && i<length(u)-1){ x/=1024; i++ }
      printf "%.2f %s", x, u[i+1]
    }
    BEGIN{ human(b) }
  '
}

# Internal: format seconds to HH:MM:SS
_dialog__fmt_time() {
  local sec=${1:-0}
  if (( sec < 0 )); then sec=0; fi
  local h=$((sec/3600)) m=$(((sec%3600)/60)) s=$((sec%60))
  printf "%02d:%02d:%02d" "$h" "$m" "$s"
}

# Internal: get file size in bytes (portable GNU/BSD stat)
_dialog__filesize() {
  local f="$1"
  if [[ -f "$f" ]]; then
    if stat -c %s "$f" >/dev/null 2>&1; then
      stat -c %s "$f"
    else
      stat -f%z "$f" 2>/dev/null || echo 0
    fi
  else
    echo 0
  fi
}

# Internal: derive filename from URL when no output provided
_dialog__filename_from_url() {
  local url="$1"
  local out
  out=$(basename "$url")
  if [[ "$out" != *.* ]]; then
    out=$(echo "$url" | sed -E 's|.*/([^/]+\.[^/]+)(/.*)?$|\1|')
    [[ -z "$out" ]] && out="downloaded.file"
  fi
  echo "$out"
}

# Internal: try to read Content-Length via HEAD; prints bytes or 0 if unknown
_dialog__fetch_content_length() {
  local url="$1"
  local cl=0
  if command -v curl >/dev/null 2>&1; then
    cl=$(curl -L -sI "$url" 2>/dev/null | tr -d '\r' | awk -F": *" 'tolower($1)=="content-length"{print $2}' | tail -n1)
  elif command -v wget >/dev/null 2>&1; then
    cl=$(wget --server-response --spider -O /dev/null "$url" 2>&1 | awk -F": *" 'tolower($1)=="content-length"{print $2}' | tail -n1)
  fi
  cl=${cl:-0}
  if [[ "$cl" =~ ^[0-9]+$ ]]; then echo "$cl"; else echo 0; fi
}

# Download a URL with a dialog gauge showing percent, size, speed, and ETA.
# Usage: dialog_download_file "URL" [output_path] [tool]
#  - tool: one of auto|curl|wget (default: auto)
# Returns: 0 on success, non-zero on failure.
dialog_download_file() {
  dialog_init; check_if_dialog_installed || return 1

  local url="$1"; local output="${2:-}"; local tool="${3:-auto}"
  if [[ -z "$url" ]]; then
    print_error "dialog_download_file: URL is required"
    return 1
  fi

  # Choose tool
  case "$tool" in
    auto)
      if command -v curl >/dev/null 2>&1; then tool=curl
      elif command -v wget >/dev/null 2>&1; then tool=wget
      else print_error "Neither curl nor wget is installed."; return 1; fi
      ;;
    curl|wget) :;;
    *) print_error "Unknown tool: $tool (expected auto|curl|wget)"; return 1;;
  esac

  # Resolve output path
  if [[ -z "$output" ]]; then
    output=$(_dialog__filename_from_url "$url")
  fi
  local dir; dir=$(dirname -- "$output")
  if [[ -n "$dir" && "$dir" != "." ]] && [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" || { print_error "Cannot create output directory: $dir"; return 1; }
  fi

  local tmpfile="${output}.part"
  local errfile
  errfile=$(mktemp "/tmp/$(basename "$0").download_err.XXXXXXXX")
  rm -f "$tmpfile"

  # Fetch total size if possible for accurate percent/ETA
  local total_bytes; total_bytes=$(_dialog__fetch_content_length "$url")

  # Start the download in background
  local cmd pid
  if [[ "$tool" == "curl" ]]; then
    # -sS hides progress meter but shows errors; --fail makes HTTP errors non-zero
    cmd=(curl -L --fail -sS -o "$tmpfile" "$url")
    "${cmd[@]}" >"$errfile" 2>&1 &
  else
    cmd=(wget -q -O "$tmpfile" "$url")
    "${cmd[@]}" >"$errfile" 2>&1 &
  fi
  pid=$!

  # Gauge updater loop
  local start_ts now_ts prev_ts prev_bytes cur_bytes speed eta remaining_bytes percent=0
  start_ts=$(date +%s)
  prev_ts=$start_ts
  prev_bytes=0

  # We stream updates to dialog via pipe
  local gauge_height="$DIALOG_HEIGHT"
  local gauge_width="$DIALOG_WIDTH"
  # Clamp gauge size to avoid oversized boxes and shadow artifacts on some terminals.
  (( gauge_height > 15 )) && gauge_height=15
  (( gauge_height < 10 )) && gauge_height=10
  (( gauge_width > 80 )) && gauge_width=80
  (( gauge_width < 60 )) && gauge_width=60

  (
    echo 0
    while kill -0 "$pid" >/dev/null 2>&1; do
      cur_bytes=$(_dialog__filesize "$tmpfile")
      now_ts=$(date +%s)
      local dt=$(( now_ts - prev_ts ))
      (( dt <= 0 )) && dt=1
      local delta=$(( cur_bytes - prev_bytes ))
      (( delta < 0 )) && delta=0
      speed=$(( delta / dt ))
      if (( total_bytes > 0 )); then
        percent=$(( cur_bytes * 100 / total_bytes ))
        (( percent > 99 )) && percent=99
        remaining_bytes=$(( total_bytes - cur_bytes ))
        if (( speed > 0 )); then
          eta=$(( remaining_bytes / speed ))
        else
          eta=-1
        fi
        # Update message with sizes and ETA
        printf "XXX\n%d\n" "$percent"
        printf "Downloading: %s\n" "$(basename -- "$output")"
        printf "Progress: %d%% (%s / %s)\n" "$percent" "$(_dialog__human_size "$cur_bytes")" "$(_dialog__human_size "$total_bytes")"
        printf "Speed: %s/s | ETA: %s\n" "$(_dialog__human_size "$speed")" "$([[ $eta -ge 0 ]] && _dialog__fmt_time "$eta" || echo "--:--:--")"
        printf "XXX\n"
      else
        # Unknown total size: show bytes and rolling percent
        percent=$(( (percent + 2) % 100 ))
        printf "XXX\n%d\n" "$percent"
        printf "Downloading: %s\n" "$(basename -- "$output")"
        printf "Downloaded: %s (total size unknown)\n" "$(_dialog__human_size "$cur_bytes")"
        printf "Speed: %s/s\n" "$(_dialog__human_size "$speed")"
        printf "XXX\n"
      fi
      prev_ts=$now_ts
      prev_bytes=$cur_bytes
      sleep 1
    done

    # Final update after process ends
    cur_bytes=$(_dialog__filesize "$tmpfile")
    if (( total_bytes > 0 )); then
      percent=100
      printf "XXX\n%d\n" "$percent"
      printf "Download complete: %s\n" "$(basename -- "$output")"
      printf "Size: %s\n" "$(_dialog__human_size "$cur_bytes")"
      printf "Time: %s\n" "$(_dialog__fmt_time $(( $(date +%s) - start_ts )) )"
      printf "XXX\n"
    else
      percent=100
      printf "XXX\n%d\n" "$percent"
      printf "Download complete: %s\n" "$(basename -- "$output")"
      printf "Downloaded: %s\n" "$(_dialog__human_size "$cur_bytes")"
      printf "XXX\n"
    fi
  ) | dialog --no-shadow --title "Downloading" --gauge "Preparing download..." "$gauge_height" "$gauge_width" 0
  local dlg_rc=$?

  # If user cancelled the dialog, terminate the download
  if (( dlg_rc != 0 )); then
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" 2>/dev/null || true
      sleep 0.5
      kill -9 "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    rm -f "$tmpfile"
    rm -f "$errfile"
    return 1
  fi

  # Check download exit code
  wait "$pid" 2>/dev/null
  local rc=$?
  if (( rc == 0 )); then
    mv -f "$tmpfile" "$output" 2>/dev/null || { print_error "Failed to finalize download to $output"; return 1; }
    rm -f "$errfile"
    return 0
  else
    rm -f "$tmpfile"
    # Show a dialog error with captured cause
    local err_preview
    if [[ -s "$errfile" ]]; then
      err_preview=$(tail -n 20 "$errfile")
    else
      err_preview="No additional error output captured."
    fi
    # Try to show a dialog message with error details
    dialog --title "Download Error" \
      --msgbox "Download failed (exit $rc) for:\n$url\n\nDetails:\n$err_preview" \
      "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 2>/dev/null || true
    rm -f "$errfile"
    return $rc
  fi
}
