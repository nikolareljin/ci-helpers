#!/usr/bin/env bash
# SVG rasterization helpers.
#
# Convert vector art (logos, icons) to PNG for app assets / launcher icons.
# Prefers Inkscape (best fidelity), falls back to ImageMagick (`magick` or
# `convert`). Depends on the `logging` module when available, but degrades to
# plain echo if not.

# Usage: svg_rasterizer; prints the rasterizer to use (inkscape|magick|convert)
# or nothing (and returns non-zero) if none is installed.
svg_rasterizer() {
  if command -v inkscape >/dev/null 2>&1; then
    echo "inkscape"
  elif command -v magick >/dev/null 2>&1; then
    echo "magick"
  elif command -v convert >/dev/null 2>&1; then
    echo "convert"
  else
    return 1
  fi
}

# Usage: svg_rasterize <in.svg> <out.png> [size]
# Renders a square PNG of <size>x<size> px (default 1024). Returns:
#   2 = bad args, 3 = no rasterizer available, non-zero = render failed.
svg_rasterize() {
  local in="${1:-}" out="${2:-}" size="${3:-1024}"
  if [[ -z "$in" || -z "$out" ]]; then
    _svg_log_error "usage: svg_rasterize <in.svg> <out.png> [size]"
    return 2
  fi
  if [[ ! "$size" =~ ^[1-9][0-9]*$ ]]; then
    _svg_log_error "size must be a positive integer: $size"
    return 2
  fi
  if [[ ! -f "$in" ]]; then
    _svg_log_error "input SVG not found: $in"
    return 2
  fi

  local tool
  tool="$(svg_rasterizer)" || {
    _svg_log_error "no SVG rasterizer found (install inkscape or ImageMagick)"
    return 3
  }

  mkdir -p "$(dirname "$out")"
  case "$tool" in
    inkscape)
      # Inkscape 1.x syntax, with a fallback to the 0.9x flags.
      inkscape "$in" --export-type=png --export-filename="$out" -w "$size" -h "$size" >/dev/null 2>&1 \
        || inkscape -z -e "$out" -w "$size" -h "$size" "$in" >/dev/null 2>&1
      ;;
    magick)
      # -extent on a centered gravity guarantees a square canvas.
      magick -background none "$in" -resize "${size}x${size}" \
        -gravity center -extent "${size}x${size}" "$out"
      ;;
    convert)
      convert -background none "$in" -resize "${size}x${size}" \
        -gravity center -extent "${size}x${size}" "$out"
      ;;
  esac || { _svg_log_error "rasterize failed ($tool): $in -> $out"; return 1; }

  _svg_log_info "rasterized $in -> $out (${size}px, $tool)"
}

# Usage: svg_rasterize_sizes <in.svg> <out_dir> <basename> <size> [size...]
# Renders one PNG per size as <out_dir>/<basename>-<size>.png. Handy for icon
# sets. Returns non-zero if any single render fails (continues the rest).
svg_rasterize_sizes() {
  local in="${1:-}" dir="${2:-}" base="${3:-}"
  if [[ -z "$in" || -z "$dir" || -z "$base" || $# -lt 4 ]]; then
    _svg_log_error "usage: svg_rasterize_sizes <in.svg> <out_dir> <basename> <size> [size...]"
    return 2
  fi
  shift 3
  local size rc=0
  for size in "$@"; do
    svg_rasterize "$in" "$dir/${base}-${size}.png" "$size" || rc=1
  done
  return "$rc"
}

# --- internal logging shims (use the logging module if present) -------------
_svg_log_info()  { if type log_info  >/dev/null 2>&1; then log_info  "$*"; else echo "[svg] $*"; fi; }
_svg_log_error() { if type log_error >/dev/null 2>&1; then log_error "$*"; else echo "[svg][ERROR] $*" >&2; fi; }
