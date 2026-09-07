#!/usr/bin/env bash
# Screen capture — screenshots and screen video off a phone, tablet, emulator or
# simulator, for README media, store listings and bug reports.
#
# One surface, two backends, chosen by platform:
#
#   android   adb exec-out screencap   /  adb shell screenrecord + adb pull
#   ios       xcrun simctl io screenshot / xcrun simctl io recordVideo
#
# Two limits are the device's, not this module's, and are reported rather than
# hidden:
#
#   * `screenrecord` caps a single clip at 180 seconds and records no audio.
#     screencap_record splits longer requests into chunks and concatenates them,
#     so a 300-second request produces 300 seconds rather than a silent 180.
#   * A physical iOS device cannot be recorded without Xcode driving it. That
#     returns 3 with an explanation instead of appearing to succeed.
#
# Depends on the `adb` and `ios` modules; both are loaded below if the caller did
# not ask for them. Exit codes: 2 = bad arguments, 3 = required tool unavailable.

_screencap__require_module() {
  local module="$1" probe="$2"
  declare -f "$probe" >/dev/null 2>&1 && return 0
  [[ -n "${_SHLIB_LIB_DIR:-}" && -f "${_SHLIB_LIB_DIR}/${module}.sh" ]] || return 1
  # shellcheck source=/dev/null
  source "${_SHLIB_LIB_DIR}/${module}.sh"
}

_screencap__require_module adb adb_ready_serials
_screencap__require_module ios ios_available

# Longest single clip `adb shell screenrecord` will produce.
_SCREENCAP_ANDROID_MAX_SECONDS=180

# Usage: screencap_available; returns 0 when at least one backend can capture —
# adb with a ready device, or a booted iOS simulator.
screencap_available() {
  if declare -f adb_available >/dev/null 2>&1 && adb_available; then
    [[ -n "$(adb_ready_serials 2>/dev/null)" ]] && return 0
  fi
  if declare -f ios_available >/dev/null 2>&1 && ios_available; then
    [[ -n "$(ios_booted_simulators 2>/dev/null)" ]] && return 0
  fi
  return 1
}

# Usage: _screencap__resolve <platform> <device>; prints "<platform> <device>".
# Fills in whichever of the two the caller left blank, and refuses to guess when
# more than one device is connected.
_screencap__resolve() {
  local platform="${1:-}" device="${2:-}"
  local -a serials=() sims=()

  if [[ -n "$device" && -z "$platform" ]]; then
    # An emulator/phone serial is not a UDID; simulator UDIDs are hyphenated hex.
    if [[ "$device" =~ ^[0-9A-Fa-f-]{30,}$ ]]; then platform="ios"; else platform="android"; fi
  fi

  if [[ -z "$platform" ]]; then
    declare -f adb_ready_serials >/dev/null 2>&1 && mapfile -t serials < <(adb_ready_serials 2>/dev/null)
    declare -f ios_booted_simulators >/dev/null 2>&1 && mapfile -t sims < <(ios_booted_simulators 2>/dev/null)
    if [[ ${#serials[@]} -gt 0 && ${#sims[@]} -eq 0 ]]; then platform="android"
    elif [[ ${#sims[@]} -gt 0 && ${#serials[@]} -eq 0 ]]; then platform="ios"
    elif [[ ${#serials[@]} -eq 0 && ${#sims[@]} -eq 0 ]]; then
      log_error "screencap: no ready Android device and no booted iOS simulator"
      return 3
    else
      log_error "screencap: both Android and iOS targets are present — pass --platform"
      return 2
    fi
  fi

  if [[ -z "$device" ]]; then
    case "$platform" in
      android)
        mapfile -t serials < <(adb_ready_serials 2>/dev/null)
        [[ ${#serials[@]} -gt 0 ]] || { log_error "screencap: no ready Android device"; return 3; }
        [[ ${#serials[@]} -eq 1 ]] || {
          log_error "screencap: ${#serials[@]} Android devices ready — pass --device"
          printf '  %s\n' "${serials[@]}" >&2
          return 2
        }
        device="${serials[0]}"
        ;;
      ios)
        mapfile -t sims < <(ios_booted_simulators 2>/dev/null)
        [[ ${#sims[@]} -gt 0 ]] || { log_error "screencap: no booted iOS simulator"; return 3; }
        [[ ${#sims[@]} -eq 1 ]] || {
          log_error "screencap: ${#sims[@]} simulators booted — pass --device"
          printf '  %s\n' "${sims[@]}" >&2
          return 2
        }
        device="${sims[0]}"
        ;;
      *) log_error "screencap: platform must be android or ios, got '$platform'"; return 2 ;;
    esac
  fi

  printf '%s %s\n' "$platform" "$device"
}

# Usage: _screencap__default_out <device> <ext>; prints the conventional output
# path, creating the directory. Media lands where a README can reference it.
_screencap__default_out() {
  local device="$1" ext="$2" dir="${SCREENCAP_DIR:-docs/screenshots}" stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$dir" || return 1
  printf '%s/%s-%s.%s\n' "$dir" "$stamp" "${device//[^A-Za-z0-9_.-]/_}" "$ext"
}

# Usage: screencap_shot [--device <id>] [--platform android|ios] [--out <path>]
#
# Capture a single PNG. With no arguments, targets the only connected device and
# writes to docs/screenshots/<UTC-timestamp>-<device>.png. Prints the path it
# wrote, so a caller can pipe it straight into a docs step.
screencap_shot() {
  local device="" platform="" out="" resolved
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device) device="${2:-}"; shift 2 ;;
      --platform) platform="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      -*) log_error "screencap_shot: unknown option $1"; return 2 ;;
      *) log_error "screencap_shot: unexpected argument '$1'"; return 2 ;;
    esac
  done

  resolved="$(_screencap__resolve "$platform" "$device")" || return $?
  platform="${resolved%% *}"; device="${resolved#* }"
  [[ -n "$out" ]] || out="$(_screencap__default_out "$device" png)" || return 1
  mkdir -p "$(dirname "$out")" || return 1

  case "$platform" in
    android)
      # exec-out keeps the PNG binary-clean; `adb shell screencap -p` mangles
      # newlines on some devices.
      adb -s "$device" exec-out screencap -p > "$out" 2>/dev/null || {
        rm -f "$out"; log_error "screencap_shot: capture failed on $device"; return 1
      }
      ;;
    ios)
      xcrun simctl io "$device" screenshot "$out" >/dev/null 2>&1 || {
        rm -f "$out"; log_error "screencap_shot: capture failed on $device"; return 1
      }
      ;;
  esac

  [[ -s "$out" ]] || { rm -f "$out"; log_error "screencap_shot: produced an empty file"; return 1; }
  log_info "screencap: wrote $out"
  printf '%s\n' "$out"
}

# Usage: screencap_record [--device <id>] [--platform android|ios] [--out <path>]
#                        [--seconds <n>] [--size <WxH>] [--bitrate <bps>] [--gif]
#
# Capture screen video. Defaults to 30 seconds. Android clips longer than 180
# seconds are recorded in chunks and concatenated, which needs ffmpeg; without
# ffmpeg a longer request is refused rather than silently truncated. --gif also
# writes a .gif beside the video. Prints the path to the video it wrote.
screencap_record() {
  local device="" platform="" out="" seconds=30 size="" bitrate="" want_gif=0 resolved

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device) device="${2:-}"; shift 2 ;;
      --platform) platform="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      --seconds) seconds="${2:-30}"; shift 2 ;;
      --size) size="${2:-}"; shift 2 ;;
      --bitrate) bitrate="${2:-}"; shift 2 ;;
      --gif) want_gif=1; shift ;;
      -*) log_error "screencap_record: unknown option $1"; return 2 ;;
      *) log_error "screencap_record: unexpected argument '$1'"; return 2 ;;
    esac
  done

  [[ "$seconds" =~ ^[0-9]+$ && "$seconds" -gt 0 ]] \
    || { log_error "screencap_record: --seconds must be a positive integer"; return 2; }

  resolved="$(_screencap__resolve "$platform" "$device")" || return $?
  platform="${resolved%% *}"; device="${resolved#* }"
  [[ -n "$out" ]] || out="$(_screencap__default_out "$device" mp4)" || return 1
  mkdir -p "$(dirname "$out")" || return 1

  case "$platform" in
    android) _screencap__record_android "$device" "$out" "$seconds" "$size" "$bitrate" || return $? ;;
    ios)     _screencap__record_ios "$device" "$out" "$seconds" || return $? ;;
  esac

  [[ -s "$out" ]] || { rm -f "$out"; log_error "screencap_record: produced an empty file"; return 1; }
  log_info "screencap: wrote $out"

  if [[ "$want_gif" -eq 1 ]]; then
    screencap_gif "$out" "${out%.mp4}.gif" || log_warn "screencap_record: video written, GIF conversion failed"
  fi
  printf '%s\n' "$out"
}

# Usage: _screencap__record_android <serial> <out> <seconds> [size] [bitrate];
# record via screenrecord, chunking past the 180-second device cap.
_screencap__record_android() {
  local serial="$1" out="$2" seconds="$3" size="${4:-}" bitrate="${5:-}"
  local remote="/sdcard/screencap-$$.mp4" rc=0
  local -a flags=()

  # A screen that is off records a single frame of nothing, and screenrecord
  # still exits 0 — so the caller gets a non-empty file that is unusable, and
  # any downstream GIF conversion fails with an ffmpeg error that says nothing
  # about the real cause. Say it up front.
  if declare -f adb_screen_on >/dev/null 2>&1; then
    adb_screen_on "$serial" >/dev/null 2>&1
    if [[ $? -eq 1 ]]; then
      log_warn "screencap: the screen on $serial is off — the recording will be blank."
      log_warn "Wake it first: adb -s $serial shell input keyevent KEYCODE_WAKEUP"
    fi
  fi
  [[ -n "$size" ]] && flags+=(--size "$size")
  [[ -n "$bitrate" ]] && flags+=(--bit-rate "$bitrate")

  if [[ "$seconds" -le "$_SCREENCAP_ANDROID_MAX_SECONDS" ]]; then
    log_info "screencap: recording ${seconds}s on $serial"
    adb -s "$serial" shell screenrecord --time-limit "$seconds" "${flags[@]}" "$remote" || rc=1
    if [[ "$rc" -eq 0 ]]; then
      adb -s "$serial" pull "$remote" "$out" >/dev/null 2>&1 || rc=1
    fi
    adb -s "$serial" shell rm -f "$remote" >/dev/null 2>&1 || true
    [[ "$rc" -eq 0 ]] || log_error "_screencap__record_android: recording failed on $serial"
    return $rc
  fi

  # Longer than the device allows: chunk and concatenate.
  if ! command -v ffmpeg >/dev/null 2>&1; then
    log_error "screencap_record: ${seconds}s exceeds screenrecord's ${_SCREENCAP_ANDROID_MAX_SECONDS}s cap and ffmpeg is not installed to join chunks."
    log_error "Install ffmpeg, or ask for ${_SCREENCAP_ANDROID_MAX_SECONDS}s or less."
    return 3
  fi

  local tmpdir chunk_dur left=$seconds index=0 list
  tmpdir="$(mktemp -d)" || return 1
  list="$tmpdir/chunks.txt"
  log_info "screencap: recording ${seconds}s on $serial in ${_SCREENCAP_ANDROID_MAX_SECONDS}s chunks"
  while [[ "$left" -gt 0 ]]; do
    chunk_dur=$(( left > _SCREENCAP_ANDROID_MAX_SECONDS ? _SCREENCAP_ANDROID_MAX_SECONDS : left ))
    if ! adb -s "$serial" shell screenrecord --time-limit "$chunk_dur" "${flags[@]}" "$remote"; then
      rc=1; break
    fi
    if ! adb -s "$serial" pull "$remote" "$tmpdir/part-$index.mp4" >/dev/null 2>&1; then
      rc=1; break
    fi
    printf "file '%s'\n" "$tmpdir/part-$index.mp4" >> "$list"
    adb -s "$serial" shell rm -f "$remote" >/dev/null 2>&1 || true
    left=$(( left - chunk_dur ))
    index=$(( index + 1 ))
  done

  if [[ "$rc" -eq 0 ]]; then
    ffmpeg -y -f concat -safe 0 -i "$list" -c copy "$out" >/dev/null 2>&1 || rc=1
  fi
  rm -rf "$tmpdir"
  adb -s "$serial" shell rm -f "$remote" >/dev/null 2>&1 || true
  [[ "$rc" -eq 0 ]] || log_error "_screencap__record_android: chunked recording failed on $serial"
  return $rc
}

# Usage: _screencap__record_ios <udid> <out> <seconds>; record a simulator.
# Physical devices are refused — see the module header.
_screencap__record_ios() {
  local udid="$1" out="$2" seconds="$3" pid rc=0
  if declare -f ios_booted_simulators >/dev/null 2>&1; then
    if ! ios_booted_simulators 2>/dev/null | grep -qx "$udid"; then
      log_error "screencap_record: '$udid' is not a booted simulator."
      log_error "Recording a physical iOS device needs Xcode or QuickTime driving it; simctl cannot do it."
      return 3
    fi
  fi
  log_info "screencap: recording ${seconds}s on simulator $udid"
  # recordVideo runs until interrupted; SIGINT is what makes it finalize the file.
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$out" >/dev/null 2>&1 &
  pid=$!
  sleep "$seconds"
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [[ -s "$out" ]] || rc=1
  [[ "$rc" -eq 0 ]] || log_error "_screencap__record_ios: recording failed on $udid"
  return $rc
}

# Usage: screencap_frame <video> <out.png> [--at <seconds>]; extract a still
# frame from a recording, for a README image taken from a demo clip. Defaults to
# 1 second in, because frame zero is often a blank or transitioning screen.
# Returns 3 when ffmpeg is not installed.
screencap_frame() {
  local video="" out="" at="1"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --at) at="${2:-1}"; shift 2 ;;
      -*) log_error "screencap_frame: unknown option $1"; return 2 ;;
      *) if [[ -z "$video" ]]; then video="$1"; else out="$1"; fi; shift ;;
    esac
  done
  [[ -n "$video" && -n "$out" ]] || { log_error "screencap_frame: need <video> <out.png>"; return 2; }
  [[ -f "$video" ]] || { log_error "screencap_frame: not found: $video"; return 2; }
  command -v ffmpeg >/dev/null 2>&1 || { log_error "screencap_frame: ffmpeg is not installed"; return 3; }
  mkdir -p "$(dirname "$out")" || return 1
  ffmpeg -y -ss "$at" -i "$video" -frames:v 1 "$out" >/dev/null 2>&1 || {
    log_error "screencap_frame: extraction failed"; return 1;
  }
  log_info "screencap: wrote $out"
  printf '%s\n' "$out"
}

# Usage: screencap_gif <video> <out.gif> [--fps <n>] [--width <px>]; convert a
# recording to a GIF suitable for a README. Two-pass with a generated palette,
# because a single-pass GIF from video is visibly dithered. Defaults to 12 fps
# and 480px wide, which keeps a short clip under a couple of megabytes.
# Returns 3 when ffmpeg is not installed.
screencap_gif() {
  local video="" out="" fps=12 width=480 palette rc=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fps) fps="${2:-12}"; shift 2 ;;
      --width) width="${2:-480}"; shift 2 ;;
      -*) log_error "screencap_gif: unknown option $1"; return 2 ;;
      *) if [[ -z "$video" ]]; then video="$1"; else out="$1"; fi; shift ;;
    esac
  done
  [[ -n "$video" && -n "$out" ]] || { log_error "screencap_gif: need <video> <out.gif>"; return 2; }
  [[ -f "$video" ]] || { log_error "screencap_gif: not found: $video"; return 2; }
  command -v ffmpeg >/dev/null 2>&1 || { log_error "screencap_gif: ffmpeg is not installed"; return 3; }
  mkdir -p "$(dirname "$out")" || return 1

  # A recording made with the screen off is a single frame with zero duration.
  # palettegen then encodes nothing and ffmpeg fails with a message about -ss
  # and -t, which points nowhere near the real cause. Check first and say it.
  if command -v ffprobe >/dev/null 2>&1; then
    local frames
    frames="$(ffprobe -v error -select_streams v:0 -count_packets \
                -show_entries stream=nb_read_packets -of csv=p=0 "$video" 2>/dev/null | head -n1)"
    if [[ "$frames" =~ ^[0-9]+$ && "$frames" -lt 2 ]]; then
      log_error "screencap_gif: $video has $frames frame(s) — there is nothing to animate."
      log_error "A recording made with the device screen off looks like this. Wake the screen and record again."
      return 1
    fi
  fi

  palette="$(mktemp --suffix=.png 2>/dev/null || mktemp)" || return 1
  ffmpeg -y -i "$video" \
    -vf "fps=$fps,scale=$width:-1:flags=lanczos,palettegen" "$palette" >/dev/null 2>&1 || rc=1
  if [[ "$rc" -eq 0 ]]; then
    ffmpeg -y -i "$video" -i "$palette" \
      -lavfi "fps=$fps,scale=$width:-1:flags=lanczos[x];[x][1:v]paletteuse" "$out" >/dev/null 2>&1 || rc=1
  fi
  rm -f "$palette"
  [[ "$rc" -eq 0 ]] || { log_error "screencap_gif: conversion failed"; return 1; }
  log_info "screencap: wrote $out"
  printf '%s\n' "$out"
}

# Usage: screencap_record_stop [device]; stop an in-flight recording started
# outside screencap_record's own timed wait — a background `screenrecord` on a
# device, or a `simctl recordVideo` on this host. Safe to call when nothing is
# recording.
screencap_record_stop() {
  local device="${1:-}" s
  if [[ -n "$device" ]]; then
    adb -s "$device" shell pkill -INT screenrecord >/dev/null 2>&1 || true
  elif declare -f adb_ready_serials >/dev/null 2>&1; then
    for s in $(adb_ready_serials 2>/dev/null); do
      adb -s "$s" shell pkill -INT screenrecord >/dev/null 2>&1 || true
    done
  fi
  pkill -INT -f 'simctl io .* recordVideo' >/dev/null 2>&1 || true
  return 0
}
