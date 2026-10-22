#!/usr/bin/env bash
# Dialog helpers: sizing and input utilities.

# Usage: dialog_init
# Initialize dialog dimensions based on terminal size.
# Returns: always 0. Sets and exports DIALOG_WIDTH and DIALOG_HEIGHT (70% of the terminal, at least 60x20).
# Output: nothing.
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

# Usage: check_if_dialog_installed
# Ensure `dialog` CLI exists.
# Returns: 0 dialog is installed (and dialog_init ran); 1 it is not.
# Output: stderr an [Error!] line when missing.
check_if_dialog_installed() {
  if ! command -v dialog >/dev/null 2>&1; then
    # On stderr: several callers print their answer on stdout.
    print_error "Dialog is not installed. Please install it and try again." >&2
    return 1
  fi
  # Also initialize dialog dimensions for compatibility with callers
  dialog_init
}

# --- boxes for a caller that has captured stdout -------------------------------
#
# How dialog uses its streams: without --stdout it draws the box on stdout and
# prints the answer on stderr. So `value=$(dialog --inputbox ...)` or
# `$(dialog --msgbox ...)` puts the whole screen into the variable and shows
# nothing (measured with dialog 1.3: 2,235 bytes of screen as the "value").
# With --stdout, dialog opens the terminal itself and the box shows.
# The functions below work the same for either kind of box: the screen goes to
# the terminal device, and stdout carries only the answer.

# The terminal device. SHLIB_DIALOG_TTY can name another one; tests give it a
# file. (Not DIALOG_TTY: that is a variable of dialog itself.)
_dialog_tty() {
  printf '%s' "${SHLIB_DIALOG_TTY:-/dev/tty}"
}

# Usage: dialog_has_tty; true if the terminal device can be opened for reading
# and writing. It is opened, not only tested with -r/-w: without a controlling
# terminal, /dev/tty still exists and looks readable and writable, but opening
# it fails. Nothing is created: a missing path, a directory or a FIFO is not a
# terminal.
# Returns: 0 the terminal device opens; 1 it does not.
# Output: nothing.
dialog_has_tty() {
  local tty
  tty="$(_dialog_tty)"
  [[ -c "$tty" || -f "$tty" ]] || return 1
  # shellcheck disable=SC2094  # opened both ways to see that it opens
  ( exec 3<"$tty" 4>>"$tty" ) 2>/dev/null
}

# Usage: has_interactive_dialog_session; true if a person can see a dialog:
# one of the standard streams is a terminal, or the terminal device opens.
# False under cron, systemd or CI, where nothing should ask.
# Returns: 0 a terminal is available; 1 not.
# Output: nothing.
has_interactive_dialog_session() {
  [[ -t 0 || -t 1 || -t 2 ]] || dialog_has_tty
}

# Usage: _dialog_call_ok <dialog args...>; true if dialog knows every
# --option in the call.
# Why: for an unknown option (a typo like --yesn) dialog prints its help text
# to stdout and exits 0. Through dialog_run that 0 would mean "Yes"; through
# dialog_capture the help text would become the answer. So every --option is
# checked against the list that `dialog --help` prints (read once, cached).
# If that list is empty (an unknown dialog), nothing is checked.
# Returns 255, dialog's own code for an error, and names the option.
_DIALOG_KNOWN_OPTIONS=""
_dialog_call_ok() {
  local arg
  if [[ -z "$_DIALOG_KNOWN_OPTIONS" ]]; then
    _DIALOG_KNOWN_OPTIONS=" $(dialog --help </dev/null 2>&1 | grep -o -- '--[a-z][a-z0-9-]*' | sort -u | tr '\n' ' ')" || true
    [[ "$_DIALOG_KNOWN_OPTIONS" != " " ]] || _DIALOG_KNOWN_OPTIONS="*"
  fi
  [[ "$_DIALOG_KNOWN_OPTIONS" != "*" ]] || return 0
  for arg in "$@"; do
    case "$arg" in
      --[a-zA-Z]*)
        case "$_DIALOG_KNOWN_OPTIONS" in
          *" $arg "*) ;;
          *) print_error "dialog has no option '$arg'. Nothing was shown." >&2; return 255 ;;
        esac
        ;;
    esac
  done
  return 0
}

# Usage: _dialog_is_help_text <text>; true if text is dialog's help output.
# dialog prints it, and exits 0, for a box given no arguments. It must not be
# taken for an answer.
_dialog_is_help_text() {
  # Here-string, not a pipe: grep -q exits early and can SIGPIPE the writer (141 under pipefail).
  [[ "${1:-}" == *"Usage: dialog"* ]] && grep -q 'version' <<< "$(head -n 1 <<<"${1:-}")"
}

# Usage: dialog_run <dialog args...>; runs dialog for a box with no answer to
# capture (msgbox, infobox, yesno). The box is drawn on the terminal device if
# there is one, so it shows even if the caller captured stdout. Keys are read
# from the terminal too, so this is not for a gauge (it reads stdin).
# Returns dialog's own status. With no terminal device it is plain dialog.
# Returns: dialog's own code (0 OK/Yes, 1 Cancel/No, 255 Esc or error); 255 for an option dialog does not know.
# Output: the box on the terminal device; stderr an error for an unknown option.
dialog_run() {
  local tty
  _dialog_call_ok "$@" || return $?
  if dialog_has_tty; then
    tty="$(_dialog_tty)"
    # One device for all three streams, on purpose. Appended (>>): the same
    # for a terminal, and it keeps a file that stands in for one readable.
    # shellcheck disable=SC2094
    dialog "$@" <"$tty" >>"$tty" 2>>"$tty"
  else
    dialog "$@"
  fi
}

# Usage: <progress> | dialog_gauge <dialog args...>; runs dialog for a gauge.
# The progress comes from stdin, as dialog expects; the screen goes to the
# terminal device if there is one. A gauge draws on stdout like any other box
# (measured with dialog 1.3: under `$(...)` nothing on the terminal and 1,502
# bytes of screen in the variable).
# Returns dialog's own status. With no terminal device it is plain dialog.
# Returns: dialog's own code; 255 for an unknown option.
# Output: the gauge on the terminal device (stdout when there is none).
dialog_gauge() {
  local tty
  _dialog_call_ok "$@" || return $?
  if dialog_has_tty; then
    tty="$(_dialog_tty)"
    dialog "$@" >>"$tty"
  else
    dialog "$@"
  fi
}

# Usage: answer=$(dialog_capture <dialog args...>); runs dialog and prints the
# answer on stdout. Screen and keys use the terminal device if there is one.
# Do not pass --stdout: it is added. Nothing is written to disk.
# Returns dialog's own status (1 cancel, 255 escape or error) and then prints
# nothing. What dialog says about a bad call goes to the terminal with the
# screen, not to the caller's stderr.
# Returns: dialog's own code (0 OK, 1 Cancel, 255 Esc or error); 255 for an unknown option or when dialog printed its help text.
# Output: stdout the answer on 0, nothing otherwise; the box on the terminal device; stderr errors.
dialog_capture() {
  local tty answer status=0
  _dialog_call_ok "$@" || return $?
  if dialog_has_tty; then
    tty="$(_dialog_tty)"
    # shellcheck disable=SC2094  # the terminal, read and drawn on
    answer="$(dialog --stdout "$@" <"$tty" 2>>"$tty")" || status=$?
  else
    answer="$(dialog --stdout "$@")" || status=$?
  fi
  if [[ "$status" -eq 0 ]] && _dialog_is_help_text "$answer"; then
    print_error "dialog printed its help text instead of an answer: a box was given no arguments. Nothing was shown." >&2
    return 255
  fi
  if [[ "$status" -eq 0 ]]; then
    printf '%s\n' "$answer"
  fi
  return "$status"
}

# Usage: value=$(get_value "Title" "Message" "Default"); asks for a value in
# an input box and prints it on stdout.
# Returns 1 and prints nothing if the person cancels or leaves the box empty.
# Messages go to stderr: stdout is only the value.
# Returns: 0 a non-empty value was entered; 1 dialog missing, cancelled or empty.
# Output: stdout the value; stderr errors.
get_value() {
  local title="${1:-}" message="${2:-}" default_value="${3:-}" value
  dialog_init
  check_if_dialog_installed || return 1

  local cancel_msg="User pressed Cancel. Exiting."
  if ! value="$(dialog_capture --title "$title" --inputbox "$message" 10 60 "$default_value")"; then
    print_error "$cancel_msg" >&2
    return 1
  fi
  if [[ -z "$value" ]]; then
    print_error "$cancel_msg" >&2
    return 1
  fi
  printf '%s\n' "$value"
}


# The DISTROS-based selectors here take an associative array *from the caller*,
# which is the one thing in this library that genuinely cannot work on bash 3.2.
# os.sh carries require_bash4, which says so with an actionable message; load it
# the way screencap.sh loads its optional modules.
if ! declare -f require_bash4 >/dev/null 2>&1; then
  if [[ -n "${_SHLIB_LIB_DIR:-}" && -f "${_SHLIB_LIB_DIR}/os.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_SHLIB_LIB_DIR}/os.sh"
  fi
fi

# Usage: select_multiple_distros
# Selection helpers used by iso-forge. Expect an associative array DISTROS to be defined by the caller.
# Returns: 0 selection made; 1 bash older than 4, dialog missing, or nothing selected.
# Output: stdout the selected keys (space separated); stderr errors.
select_multiple_distros() {
  require_bash4 "select_multiple_distros (DISTROS associative array)" || return 1
  dialog_init; check_if_dialog_installed || return 1
  local selected_distros options=() d
  for d in "${!DISTROS[@]}"; do
    options+=("$d" "${DISTROS[$d]}")
  done
  if ! selected_distros=$(dialog_capture --title "Select Linux Distro" --checklist "Choose Linux distributions to download:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${options[@]}"); then
    print_error "No distro selected. Exiting..." >&2
    return 1
  fi
  echo "$selected_distros"
}

# Usage: select_distro; expects DISTROS associative array and echoes selection.
# Returns: 0 selection made; 1 bash older than 4, dialog missing, or nothing selected.
# Output: stdout the selected key; stderr errors.
select_distro() {
  require_bash4 "select_distro (DISTROS associative array)" || return 1
  dialog_init; check_if_dialog_installed || return 1
  local selected_distro options=() d
  for d in "${!DISTROS[@]}"; do
    options+=("$d" "${DISTROS[$d]}")
  done
  if ! selected_distro=$(dialog_capture --title "Select Linux Distro" --menu "Choose a Linux distribution to download:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${options[@]}"); then
    print_error "No distro selected. Exiting..." >&2
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
# Returns: 0 downloaded; 1 dialog missing, no URL, no curl/wget, unknown tool, directory not creatable, gauge cancelled, or the final move failed; otherwise the exit code of curl or wget.
# Output: the gauge and any error box on the terminal device; stdout an [Error!] line for setup errors.
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
  ) | dialog_gauge --no-shadow --title "Downloading" --gauge "Preparing download..." "$gauge_height" "$gauge_width" 0
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
    # Try to show a dialog message with error details unless explicitly suppressed.
    local show_error_dialog="${DIALOG_DOWNLOAD_SHOW_ERROR_DIALOG:-1}"
    if [[ "$show_error_dialog" != "0" && "$show_error_dialog" != "false" && "$show_error_dialog" != "never" ]]; then
      dialog_run --title "Download Error" \
        --msgbox "Download failed (exit $rc) for:\n$url\n\nDetails:\n$err_preview" \
        "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 2>/dev/null || true
    fi
    rm -f "$errfile"
    return $rc
  fi
}

# ---------------------------------------------------------------------------
# One set of prompts, three renderers: dialog, plain (read), none.
# ---------------------------------------------------------------------------

# Usage: ui_mode; prints dialog | plain | none.
#
# SHLIB_UI forces a renderer (tests, and a caller that knows better). Otherwise:
# no terminal on stdin or stdout means no prompts at all -- a systemd unit or a
# CI job must fail naming what it wanted rather than wait forever on a read;
# SHLIB_UI_PLAIN=1 means plain prompts even when `dialog` is installed.
# Returns: 0 printed; 1 SHLIB_UI is set to something other than dialog, plain or none.
# Output: stdout dialog, plain or none; stderr an error.
ui_mode() {
  local forced="${SHLIB_UI:-}"
  if [[ -n "$forced" ]]; then
    case "$forced" in
      dialog|plain|none) ;;
      *) log_error "${_UI_MODE_VAR:-SHLIB_UI} must be dialog, plain or none (got '$forced')"; return 1 ;;
    esac
    if [[ "$forced" == "dialog" && -n "${SHLIB_UI_PLAIN:-}" ]]; then
      echo plain
      return 0
    fi
    echo "$forced"
    return 0
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo none
    return 0
  fi
  if [[ -z "${SHLIB_UI_PLAIN:-}" ]] && command -v dialog >/dev/null 2>&1; then
    echo dialog
    return 0
  fi
  echo plain
}

# Usage: ui_menu TITLE TEXT DEFAULT key1 label1 [key2 label2 ...]
# Prints the chosen key. In `none` mode prints nothing and returns 1.
# Returns: 0 a key was chosen; 1 no UI (mode none), cancelled, EOF, invalid answer, or bad SHLIB_UI.
# Output: stdout the chosen key; stderr the plain-mode menu and errors.
ui_menu() {
  local title="$1" text="$2" default="$3"; shift 3
  local mode; mode="$(ui_mode)" || return 1
  local -a keys=() labels=()
  while [[ $# -ge 2 ]]; do keys+=("$1"); labels+=("$2"); shift 2; done
  case "$mode" in
    none) return 1 ;;
    dialog)
      dialog_init
      local -a items=()
      local i
      for i in "${!keys[@]}"; do items+=("${keys[$i]}" "${labels[$i]}"); done
      local choice
      choice="$(dialog_capture --title "$title" --default-item "$default" --menu "$text" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${items[@]}")" || return 1
      echo "$choice"
      ;;
    plain)
      local i answer
      echo "$title" >&2
      echo "$text" >&2
      for i in "${!keys[@]}"; do echo "  ${keys[$i]}  -- ${labels[$i]}" >&2; done
      read -r -p "[${default}] " answer || return 1
      answer="${answer:-$default}"
      for i in "${!keys[@]}"; do
        [[ "$answer" == "${keys[$i]}" ]] && { echo "$answer"; return 0; }
      done
      log_error "'$answer' is not one of: ${keys[*]}"
      return 1
      ;;
  esac
}

# Usage: ui_input TITLE TEXT [DEFAULT]; prints the answer, or DEFAULT when empty.
# Returns: 0 a value (or the default) was read; 1 no UI, cancelled, EOF, or bad SHLIB_UI.
# Output: stdout the value (default when empty); stderr the plain-mode prompt.
ui_input() {
  local title="$1" text="$2" default="${3:-}"
  local mode; mode="$(ui_mode)" || return 1
  case "$mode" in
    none) return 1 ;;
    dialog)
      dialog_init
      local v
      v="$(dialog_capture --title "$title" --inputbox "$text" 10 "$DIALOG_WIDTH" "$default")" || return 1
      echo "${v:-$default}"
      ;;
    plain)
      local v
      read -r -p "$text${default:+ [$default]}: " v || return 1
      echo "${v:-$default}"
      ;;
  esac
}

# Usage: ui_secret TITLE TEXT; prints the answer, never echoed while typed.
# Returns: 0 read; 1 no UI, cancelled, EOF, or bad SHLIB_UI.
# Output: stdout the secret (no echo while typing); stderr the prompt.
ui_secret() {
  local title="$1" text="$2"
  local mode; mode="$(ui_mode)" || return 1
  case "$mode" in
    none) return 1 ;;
    dialog)
      dialog_init
      dialog_capture --title "$title" --insecure --passwordbox "$text" 10 "$DIALOG_WIDTH" || return 1
      ;;
    plain)
      local v
      if [[ -t 0 ]]; then
        read -r -s -p "$text: " v || return 1
        echo >&2
      else
        # Piped answers (tests, scripted runs): -s would still work, but a
        # pipe is not a terminal and `stty` complaints are noise.
        read -r v || return 1
      fi
      echo "$v"
      ;;
  esac
}

# Usage: ui_yesno TITLE TEXT; 0 = yes, 1 = no, or no person to ask.
# Returns: 0 yes; 1 no, cancelled, EOF, no UI, or bad SHLIB_UI; 255 dialog Esc or error.
# Output: the question on the terminal (stderr in plain mode).
ui_yesno() {
  local title="$1" text="$2"
  local mode; mode="$(ui_mode)" || return 1
  case "$mode" in
    none) return 1 ;;
    dialog)
      dialog_init
      # dialog_run: a box without --stdout draws on stdout, and a caller that
      # captured it would be asked a question nobody can see.
      dialog_run --title "$title" --defaultno --yesno "$text" 10 "$DIALOG_WIDTH"
      ;;
    plain)
      local v
      read -r -p "$text [y/N] " v || return 1
      [[ "$v" =~ ^[Yy]([Ee][Ss])?$ ]]
      ;;
  esac
}

# Usage: ui_note TITLE TEXT...; a message the person should see, in whatever
# renderer. Never fails.
# Returns: always 0.
# Output: a message box in dialog mode; otherwise stderr an [INFO] line.
ui_note() {
  local title="$1"; shift
  local mode; mode="$(ui_mode 2>/dev/null || echo none)"
  if [[ "$mode" == "dialog" ]]; then
    dialog_init
    dialog_run --title "$title" --msgbox "$*" 12 "$DIALOG_WIDTH" 2>/dev/null || true
    return 0
  fi
  log_info "$*"
}
