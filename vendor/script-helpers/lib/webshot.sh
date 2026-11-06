#!/usr/bin/env bash
# Web page screenshots and HTML-to-PDF rendering with Playwright (Chromium).
#
# webshot_capture drives a list of pages from a JSON spec: log in once per
# auth profile, run optional clicks/fills, hide elements, and save a PNG per
# page (whole page, viewport, or one element). webshot_audit crawls a site on
# phone devices and fails on pages wider than the screen; webshot_android_audit
# runs the same checks in Chrome on a real phone over adb. webshot_pdf prints an
# HTML file to PDF. Both run a Python driver inside a venv that webshot_ensure creates
# outside the repository. Depends on the `python` module; `logging` is optional.
#
# Exit codes for every public function: 0 ok, 1 run failed, 2 bad arguments or
# spec, 3 Python or Playwright unavailable (webshot_android_audit: adb, Python or
# a ready device).

WEBSHOT_PLAYWRIGHT_VERSION="${WEBSHOT_PLAYWRIGHT_VERSION:-1.63.0}"

# Usage: webshot_venv_dir; prints the venv directory webshot uses.
# Returns: 0.
# Output: stdout the path (WEBSHOT_VENV, else the cache default).
webshot_venv_dir() {
  echo "${WEBSHOT_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/nr-webshot/venv}"
}

# Usage: webshot_python; prints a Python that can import playwright, or
# returns 3. WEBSHOT_PYTHON, when set, is the only candidate considered.
# Returns: 0 found; 3 none can import playwright.
# Output: stdout the python path; stderr the error.
webshot_python() {
  local candidate
  if [[ -n "${WEBSHOT_PYTHON:-}" ]]; then
    if _webshot_has_playwright "$WEBSHOT_PYTHON"; then
      echo "$WEBSHOT_PYTHON"
      return 0
    fi
    _webshot_log_error "WEBSHOT_PYTHON=$WEBSHOT_PYTHON cannot import playwright"
    return 3
  fi
  for candidate in "$(webshot_venv_dir)/bin/python" python3; do
    if _webshot_has_playwright "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done
  _webshot_log_error "Playwright for Python not found; run webshot_ensure (or bin/webshot ensure)"
  return 3
}

# Usage: webshot_ensure [venv_dir]
# Creates the venv if needed, installs the pinned playwright package and the
# Chromium build it expects. Safe to re-run; returns quickly when ready.
# Returns: 0 ready; 3 no Python 3.9+, python module not imported, venv, pip or browser install failed.
# Output: stdout the venv python path; stderr log lines and installer output.
webshot_ensure() {
  local venv_dir="${1:-$(webshot_venv_dir)}" py venv_py
  if _webshot_has_playwright "$venv_dir/bin/python" && _webshot_chromium_ready "$venv_dir/bin/python"; then
    echo "$venv_dir/bin/python"
    return 0
  fi
  if ! type python_resolve_3 >/dev/null 2>&1; then
    _webshot_log_error "webshot_ensure needs the python module (shlib_import python)"
    return 3
  fi
  py="$(python_resolve_3 "" 3 9)" || {
    _webshot_log_error "no Python 3.9+ found"
    return 3
  }
  mkdir -p "$(dirname "$venv_dir")"
  venv_py="$(python_ensure_venv "$py" "$venv_dir")" || return 3
  _webshot_log_info "installing playwright==$WEBSHOT_PLAYWRIGHT_VERSION into $venv_dir"
  "$venv_py" -m pip install --quiet --disable-pip-version-check "playwright==$WEBSHOT_PLAYWRIGHT_VERSION" || {
    _webshot_log_error "pip install playwright failed"
    return 3
  }
  "$venv_py" -m playwright install chromium >/dev/null || {
    _webshot_log_error "playwright install chromium failed"
    return 3
  }
  echo "$venv_py"
}

# Usage: webshot_capture <spec.json> <out_dir>
# Saves one PNG per shot plus out_dir/manifest.json. See docs/modules/webshot.md
# for the spec format.
# Returns: 0 captured; 1 out_dir not creatable; 2 bad arguments or missing spec; 3 no playwright; else the capture run's code.
# Output: files in out_dir; stderr log lines.
webshot_capture() {
  local spec="${1:-}" out="${2:-}" py
  if [[ -z "$spec" || -z "$out" ]]; then
    _webshot_log_error "usage: webshot_capture <spec.json> <out_dir>"
    return 2
  fi
  if [[ ! -f "$spec" ]]; then
    _webshot_log_error "spec not found: $spec"
    return 2
  fi
  py="$(webshot_python)" || return 3
  mkdir -p "$out" || return 1
  WEBSHOT_MODE=capture WEBSHOT_SPEC="$spec" WEBSHOT_OUT="$out" _webshot_run "$py"
}

# Usage: webshot_audit <start_url> [--device NAME]... [--skip PREFIX]...
#                      [--limit N] [--shots DIR] [--timeout-ms N]
# Crawls same-host links from start_url and loads every page on each device
# (default "iPhone 13" and "Galaxy S8", 390 and 360px). A page fails when the
# document is wider than the viewport, or when an h1-h3 is wider than its box
# (cut off by a hidden overflow, which does not widen the page). For a wide
# page the report names the deepest elements whose content overflows.
# --skip drops paths that start with PREFIX. --shots saves DIR/<page>--<device>.png.
# Returns: 0 no finding; 1 a finding, or the start page failed to load; 2 bad arguments; 3 no playwright.
# Output: stdout a JSON report {crawled, findings, http_errors}; stderr log lines.
webshot_audit() {
  local start="${1:-}" devices="" skips="" limit="500" shots="" timeout_ms="30000" py
  if [[ -z "$start" || "$start" == -* ]]; then
    _webshot_log_error "usage: webshot_audit <start_url> [--device NAME]... [--skip PREFIX]... [--limit N] [--shots DIR] [--timeout-ms N]"
    return 2
  fi
  shift
  while [[ $# -gt 0 ]]; do
    # A value option at the end would make "shift 2" fail and loop forever.
    case "$1" in
      --device|--skip|--limit|--shots|--timeout-ms)
        [[ $# -ge 2 ]] || { _webshot_log_error "$1 needs a value"; return 2; } ;;
    esac
    case "$1" in
      --device) [[ -n "${2:-}" ]] || { _webshot_log_error "--device needs a name"; return 2; }
        devices+="${2}"$'\n'; shift 2 ;;
      --skip) [[ -n "${2:-}" ]] || { _webshot_log_error "--skip needs a prefix"; return 2; }
        skips+="${2}"$'\n'; shift 2 ;;
      --limit) limit="${2:-}"; shift 2 ;;
      --shots) shots="${2:-}"; [[ -n "$shots" ]] || { _webshot_log_error "--shots needs a directory"; return 2; }; shift 2 ;;
      --timeout-ms) timeout_ms="${2:-}"; shift 2 ;;
      *) _webshot_log_error "unknown option: $1"; return 2 ;;
    esac
  done
  if [[ ! "$start" =~ ^(https?|file):// ]]; then
    _webshot_log_error "start_url must be an http(s) or file URL: $start"
    return 2
  fi
  if [[ ! "$limit" =~ ^[1-9][0-9]*$ ]]; then
    _webshot_log_error "--limit must be a positive integer: $limit"
    return 2
  fi
  if [[ ! "$timeout_ms" =~ ^[1-9][0-9]*$ ]]; then
    _webshot_log_error "--timeout-ms must be a positive integer: $timeout_ms"
    return 2
  fi
  py="$(webshot_python)" || return 3
  if [[ -n "$shots" ]]; then mkdir -p "$shots" || return 1; fi
  WEBSHOT_MODE=audit WEBSHOT_START="$start" WEBSHOT_DEVICES="$devices" WEBSHOT_SKIP="$skips" \
    WEBSHOT_LIMIT="$limit" WEBSHOT_OUT="$shots" WEBSHOT_TIMEOUT_MS="$timeout_ms" _webshot_run "$py"
}

# Usage: webshot_android_audit <url> [--serial S] [--path P]... [--shots DIR]
#                              [--timeout-ms N]
# Runs the webshot_audit checks in Chrome on a real Android phone over adb.
# A localhost or 127.0.0.1 URL reaches the phone through `adb reverse`, so the
# site is never opened to the network. The phone's Chrome opens the URL; the
# checks run through its DevTools socket (`adb forward ... chrome_devtools_remote`)
# with Python's standard library, so Playwright is not needed. --path (repeat)
# checks those paths of the URL instead of the URL itself; there is no crawl.
# --shots saves DIR/<page>--<model>.png with `adb exec-out screencap`. The
# phone needs USB debugging on and Chrome installed. Port forwards are removed
# on exit, also on INT and TERM; a reverse set up before the run stays.
# Returns: 0 no finding; 1 a finding or a page did not load; 2 bad arguments; 3 adb, Python or a ready device missing.
# Output: stdout a JSON report {device, viewport, checked, findings, http_errors}; stderr log lines.
webshot_android_audit() {
  local url="${1:-}" serial="" paths="" shots="" timeout_ms="30000"
  if [[ -z "$url" || "$url" == -* ]]; then
    _webshot_log_error "usage: webshot_android_audit <url> [--serial S] [--path P]... [--shots DIR] [--timeout-ms N]"
    return 2
  fi
  shift
  while [[ $# -gt 0 ]]; do
    # A value option at the end would make "shift 2" fail and loop forever.
    case "$1" in
      --serial|--path|--shots|--timeout-ms)
        [[ $# -ge 2 && -n "${2:-}" ]] || { _webshot_log_error "$1 needs a value"; return 2; } ;;
    esac
    case "$1" in
      --serial) serial="$2"; shift 2 ;;
      --path) paths+="$2"$'\n'; shift 2 ;;
      --shots) shots="$2"; shift 2 ;;
      --timeout-ms) timeout_ms="$2"; shift 2 ;;
      *) _webshot_log_error "unknown option: $1"; return 2 ;;
    esac
  done
  # No quote or space: the URL is passed through the phone's shell.
  if [[ ! "$url" =~ ^(https?)://([^/:?#]+)(:([0-9]+))?([/?#][^\'\"[:space:]]*)?$ ]]; then
    _webshot_log_error "url must be an http(s) URL without quotes or spaces: $url"
    return 2
  fi
  local scheme="${BASH_REMATCH[1]}" host="${BASH_REMATCH[2]}" port="${BASH_REMATCH[4]}"
  [[ -n "$port" ]] || { [[ "$scheme" == https ]] && port=443 || port=80; }
  if [[ ! "$timeout_ms" =~ ^[1-9][0-9]*$ ]]; then
    _webshot_log_error "--timeout-ms must be a positive integer: $timeout_ms"
    return 2
  fi
  local py
  py="$(webshot_python 2>/dev/null)" || py="$(command -v python3)" || {
    _webshot_log_error "no python3 found"
    return 3
  }
  command -v adb >/dev/null 2>&1 || { _webshot_log_error "adb not found on PATH"; return 3; }
  local ready
  ready="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}')"
  if [[ -z "$serial" ]]; then
    serial="$(head -n 1 <<<"$ready")"
    [[ -n "$serial" ]] || { _webshot_log_error "no Android device attached and ready (adb devices); connect a phone with USB debugging on"; return 3; }
  elif ! grep -qxF -- "$serial" <<<"$ready"; then
    _webshot_log_error "device $serial is not attached and ready (adb devices)"
    return 3
  fi
  if [[ -n "$shots" ]]; then mkdir -p "$shots" || return 1; fi
  # A subshell, so the EXIT trap removes the forwards when this call ends
  # without replacing a trap of the caller.
  (
    # Plain variables: the subshell keeps them private, and the EXIT trap
    # runs after a function scope would be gone.
    reversed="" cdp="" model="" driver="" existing="" dev="$serial"
    trap '[[ -n "${cdp:-}" ]] && adb -s "$dev" forward --remove "tcp:$cdp" >/dev/null 2>&1
          [[ -n "${reversed:-}" ]] && adb -s "$dev" reverse --remove "tcp:$reversed" >/dev/null 2>&1
          true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    case "$host" in
      localhost|127.0.0.1)
        # A reverse the user set up already stays, and is not removed at exit.
        existing="$(adb -s "$serial" reverse --list 2>/dev/null | tr -d '\r')"
        if ! grep -q " tcp:$port tcp:$port\$" <<<"$existing"; then
          adb -s "$serial" reverse "tcp:$port" "tcp:$port" >/dev/null || { _webshot_log_error "adb reverse tcp:$port failed"; exit 1; }
          reversed="$port"
        fi ;;
    esac
    adb -s "$serial" shell am start -a android.intent.action.VIEW -d "'$url'" -p com.android.chrome >/dev/null 2>&1 \
      || { _webshot_log_error "could not open Chrome on $serial"; exit 1; }
    # tcp:0 lets adb pick a free local port and print it.
    cdp="$(adb -s "$serial" forward tcp:0 localabstract:chrome_devtools_remote 2>/dev/null | tr -d '\r\n')"
    [[ "$cdp" =~ ^[0-9]+$ ]] || { cdp=""; _webshot_log_error "adb forward to Chrome's DevTools socket failed"; exit 1; }
    model="$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r\n')"
    # In the background, so a TERM to this subshell stops the driver too
    # instead of waiting for it to finish.
    WEBSHOT_MODE=android WEBSHOT_START="$url" WEBSHOT_PATHS="$paths" WEBSHOT_OUT="$shots" \
      WEBSHOT_TIMEOUT_MS="$timeout_ms" WEBSHOT_ADB_SERIAL="$serial" WEBSHOT_CDP_PORT="$cdp" \
      WEBSHOT_DEVICE_NAME="${model:-$serial}" _webshot_run "$py" &
    driver=$!
    # $driver is the subshell running _webshot_run; Python is its child, so
    # stop the child first or it keeps running without a parent.
    trap 'pkill -TERM -P "$driver" 2>/dev/null; kill "$driver" 2>/dev/null; exit 130' INT
    trap 'pkill -TERM -P "$driver" 2>/dev/null; kill "$driver" 2>/dev/null; exit 143' TERM
    wait "$driver"
  )
}

# Usage: webshot_pdf <input.html> <output.pdf> [--format Letter|A4|Legal]
#                    [--landscape] [--footer TEXT] [--wait-ms N]
# Prints an HTML file with backgrounds. CSS @page size and margins win when
# the document sets them. --footer adds "TEXT  page / total" at the bottom.
# Returns: 0 written; 1 output dir not creatable; 2 bad arguments or missing input; 3 no playwright; else the render run's code.
# Output: the PDF file; stderr log lines.
webshot_pdf() {
  local in="${1:-}" out="${2:-}" format="Letter" landscape="0" footer="" wait_ms="500" py
  if [[ -z "$in" || -z "$out" ]]; then
    _webshot_log_error "usage: webshot_pdf <input.html> <output.pdf> [--format F] [--landscape] [--footer TEXT] [--wait-ms N]"
    return 2
  fi
  shift 2
  while [[ $# -gt 0 ]]; do
    # A value option at the end would make "shift 2" fail and loop forever.
    case "$1" in
      --format|--footer|--wait-ms)
        [[ $# -ge 2 ]] || { _webshot_log_error "$1 needs a value"; return 2; } ;;
    esac
    case "$1" in
      --format) format="${2:-}"; shift 2 ;;
      --landscape) landscape="1"; shift ;;
      --footer) footer="${2:-}"; shift 2 ;;
      --wait-ms) wait_ms="${2:-}"; shift 2 ;;
      *) _webshot_log_error "unknown option: $1"; return 2 ;;
    esac
  done
  case "$format" in
    Letter|A4|A3|Legal|Tabloid) ;;
    *) _webshot_log_error "unsupported --format: $format"; return 2 ;;
  esac
  if [[ ! "$wait_ms" =~ ^[0-9]+$ ]]; then
    _webshot_log_error "--wait-ms must be a non-negative integer: $wait_ms"
    return 2
  fi
  if [[ ! -f "$in" ]]; then
    _webshot_log_error "input HTML not found: $in"
    return 2
  fi
  py="$(webshot_python)" || return 3
  mkdir -p "$(dirname "$out")" || return 1
  WEBSHOT_MODE=pdf WEBSHOT_IN="$in" WEBSHOT_OUT="$out" WEBSHOT_FORMAT="$format" \
    WEBSHOT_LANDSCAPE="$landscape" WEBSHOT_FOOTER="$footer" WEBSHOT_WAIT_MS="$wait_ms" _webshot_run "$py"
}

# --- internals ---------------------------------------------------------------

_webshot_has_playwright() {
  local bin="$1"
  [[ -n "$bin" ]] || return 1
  if [[ "$bin" == */* ]]; then
    [[ -x "$bin" ]] || return 1
  else
    command -v "$bin" >/dev/null 2>&1 || return 1
  fi
  "$bin" -c 'import playwright.sync_api' >/dev/null 2>&1
}

_webshot_chromium_ready() {
  "$1" - <<'PY' >/dev/null 2>&1
import os
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    raise SystemExit(0 if os.path.exists(p.chromium.executable_path) else 1)
PY
}

# Runs the driver; maps its exit codes straight through (0, 1, 2, 3).
_webshot_run() {
  "$1" - <<'PY'
import json, os, re, struct, sys, html as html_mod
from urllib.parse import urljoin
from pathlib import Path


def fail(code, msg):
    print(f"[webshot][ERROR] {msg}", file=sys.stderr)
    sys.exit(code)


try:
    from playwright.sync_api import sync_playwright, Error as PWError, TimeoutError as PWTimeout
except ImportError:
    # The android mode talks to the phone's Chrome directly.
    if os.environ.get("WEBSHOT_MODE") != "android":
        fail(3, "playwright is not importable in this Python")

NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
ACTIONS = {"click", "fill", "press", "hover", "wait_for", "wait_ms", "scroll_to", "select", "eval"}


def expand(value):
    """Expand ${VAR} in strings (recursively) so specs never carry secrets."""
    if isinstance(value, str):
        return os.path.expandvars(value)
    if isinstance(value, list):
        return [expand(v) for v in value]
    if isinstance(value, dict):
        return {k: expand(v) for k, v in value.items()}
    return value


def expand_spec(spec):
    """Expand ${VAR} only where data goes: URLs, auth profiles and filled-in values.
    Selectors and eval code are left alone, so a JS template literal stays intact."""
    def steps(items):
        return [dict(s, value=expand(s["value"])) if "value" in s else s for s in items or []]

    spec = dict(spec)
    if "base_url" in spec:
        spec["base_url"] = expand(spec["base_url"])
    spec["auth"] = {
        name: dict(expand({k: v for k, v in prof.items() if k != "steps"}), steps=steps(prof.get("steps")))
        for name, prof in (spec.get("auth") or {}).items()
    }
    shots = []
    for shot in spec["shots"]:
        shot = dict(shot)
        for key in ("path", "url"):
            if key in shot:
                shot[key] = expand(shot[key])
        shot["actions"] = steps(shot.get("actions"))
        shots.append(shot)
    spec["shots"] = shots
    return spec


def dig(data, path):
    for part in path.split("."):
        if isinstance(data, list) and part.isdigit():
            data = data[int(part)]
        elif isinstance(data, dict) and part in data:
            data = data[part]
        else:
            return None
    return data


def png_size(path):
    with open(path, "rb") as fh:
        head = fh.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None, None
    return struct.unpack(">II", head[16:24])


def validate(spec):
    if not isinstance(spec, dict):
        fail(2, "spec must be a JSON object")
    shots = spec.get("shots")
    if not isinstance(shots, list) or not shots:
        fail(2, "spec.shots must be a non-empty list")
    auth = spec.get("auth") or {}
    if not isinstance(auth, dict):
        fail(2, "spec.auth must be an object of named profiles")
    for name, prof in auth.items():
        kind = (prof or {}).get("type")
        if kind not in ("none", "api_token", "form"):
            fail(2, f"auth.{name}.type must be none, api_token or form")
        if kind == "api_token":
            for key in ("url", "token_path", "storage_key"):
                if not prof.get(key):
                    fail(2, f"auth.{name}.{key} is required for api_token")
        if kind == "form" and not isinstance(prof.get("steps"), list):
            fail(2, f"auth.{name}.steps must be a list for form")
    if "device" in spec and not (isinstance(spec["device"], str) and spec["device"]):
        fail(2, "spec.device must be a Playwright device name")
    seen = set()
    for i, shot in enumerate(shots):
        if not isinstance(shot, dict):
            fail(2, f"shots[{i}] must be an object")
        name = shot.get("name", "")
        if not NAME_RE.match(name):
            fail(2, f"shots[{i}].name must match [A-Za-z0-9._-]+")
        if name in seen:
            fail(2, f"duplicate shot name: {name}")
        seen.add(name)
        if not (shot.get("path") or shot.get("url")):
            fail(2, f"shot {name}: path or url is required")
        if shot.get("path") and not spec.get("base_url"):
            fail(2, f"shot {name}: path needs spec.base_url")
        if "device" in shot and not (isinstance(shot["device"], str) and shot["device"]):
            fail(2, f"shot {name}: device must be a Playwright device name")
        if shot.get("auth") and shot["auth"] not in auth:
            fail(2, f"shot {name}: unknown auth profile {shot['auth']}")
        for step in shot.get("actions") or []:
            if not isinstance(step, dict) or not (set(step) & ACTIONS):
                fail(2, f"shot {name}: each action needs one of {sorted(ACTIONS)}")


def run_steps(page, steps, timeout):
    for step in steps:
        if "click" in step:
            page.locator(step["click"]).first.click(timeout=timeout)
        elif "fill" in step:
            page.locator(step["fill"]).first.fill(str(step.get("value", "")), timeout=timeout)
        elif "select" in step:
            page.locator(step["select"]).first.select_option(str(step.get("value", "")), timeout=timeout)
        elif "press" in step:
            if step.get("selector"):
                page.locator(step["selector"]).first.press(step["press"], timeout=timeout)
            else:
                page.keyboard.press(step["press"])
        elif "hover" in step:
            page.locator(step["hover"]).first.hover(timeout=timeout)
        elif "scroll_to" in step:
            page.locator(step["scroll_to"]).first.scroll_into_view_if_needed(timeout=timeout)
        elif "wait_for" in step:
            page.locator(step["wait_for"]).first.wait_for(state="visible", timeout=timeout)
        elif "wait_ms" in step:
            page.wait_for_timeout(int(step["wait_ms"]))
        elif "eval" in step:
            page.evaluate(step["eval"])


def capture():
    spec_path = Path(os.environ["WEBSHOT_SPEC"])
    out_dir = Path(os.environ["WEBSHOT_OUT"])
    try:
        spec = json.loads(spec_path.read_text())
    except (OSError, ValueError) as exc:
        fail(2, f"cannot read spec {spec_path}: {exc}")
    validate(spec)
    spec = expand_spec(spec)

    base = spec.get("base_url", "")
    timeout = int(spec.get("timeout_ms", 15000))
    default_vp = spec.get("viewport") or {"width": 1440, "height": 900}
    default_dsf = float(spec.get("device_scale_factor", 1))
    default_wait = int(spec.get("wait_ms", 500))
    global_hide = spec.get("hide") or []
    auth = spec.get("auth") or {}
    manifest, tokens, states = [], {}, {}

    with sync_playwright() as p:
        wanted = {d for d in [spec.get("device")] + [s.get("device") for s in spec["shots"]] if d}
        unknown = sorted(wanted - set(p.devices))
        if unknown:
            fail(2, f"unknown device {', '.join(unknown)}; known: {', '.join(sorted(p.devices))}")
        browser = p.chromium.launch()
        try:
            for shot in spec["shots"]:
                name = shot["name"]
                device_name = shot.get("device") or spec.get("device")
                device = dict(p.devices[device_name]) if device_name else {}
                device.pop("default_browser_type", None)
                # Shot keys beat spec keys; at the same level an explicit
                # viewport or scale factor beats the device's.
                vp = (shot.get("viewport")
                      or (device.get("viewport") if shot.get("device") else None)
                      or spec.get("viewport") or device.get("viewport") or default_vp)
                dsf = (shot.get("device_scale_factor")
                       or (device.get("device_scale_factor") if shot.get("device") else None)
                       or spec.get("device_scale_factor") or device.get("device_scale_factor") or default_dsf)
                ctx_opts = {
                    **device,
                    "viewport": {"width": int(vp["width"]), "height": int(vp["height"])},
                    "device_scale_factor": float(dsf),
                    "color_scheme": shot.get("color_scheme", spec.get("color_scheme", "light")),
                    "locale": spec.get("locale", "en-US"),
                }
                if device and ctx_opts["viewport"] != device.get("viewport"):
                    # An overridden viewport would sit inside the device's screen.
                    ctx_opts["screen"] = dict(ctx_opts["viewport"])
                if spec.get("timezone_id"):
                    ctx_opts["timezone_id"] = spec["timezone_id"]
                prof_name = shot.get("auth")
                prof = auth.get(prof_name) if prof_name else None
                if prof and prof["type"] == "form" and prof_name in states:
                    ctx_opts["storage_state"] = states[prof_name]
                ctx = browser.new_context(**ctx_opts)
                ctx.set_default_timeout(timeout)

                if prof and prof["type"] == "api_token":
                    if prof_name not in tokens:
                        resp = ctx.request.fetch(
                            urljoin(base, prof["url"]),
                            method=prof.get("method", "POST"),
                            data=json.dumps(prof.get("body", {})),
                            headers={"content-type": "application/json", **(prof.get("headers") or {})},
                        )
                        if not resp.ok:
                            fail(1, f"auth {prof_name}: login returned HTTP {resp.status}")
                        token = dig(resp.json(), prof["token_path"])
                        if not token:
                            fail(1, f"auth {prof_name}: no value at {prof['token_path']}")
                        tokens[prof_name] = token
                    ctx.add_init_script(
                        f"window.localStorage.setItem({json.dumps(prof['storage_key'])}, {json.dumps(tokens[prof_name])});"
                    )

                page = ctx.new_page()
                console_errors, http_errors = [], []
                page.on("console", lambda m, errs=console_errors: m.type == "error" and errs.append(m.text[:300]))
                page.on("pageerror", lambda e, errs=console_errors: errs.append(str(e)[:300]))
                page.on("response", lambda r, errs=http_errors: r.status >= 400 and errs.append(f"{r.status} {r.url}"))

                if prof and prof["type"] == "form" and prof_name not in states:
                    page.goto(urljoin(base, prof.get("url", "/")), wait_until="networkidle")
                    run_steps(page, prof["steps"], timeout)
                    page.wait_for_load_state("networkidle")
                    states[prof_name] = ctx.storage_state()

                url = shot.get("url") or urljoin(base, shot["path"])
                try:
                    page.goto(url, wait_until=shot.get("wait_until", spec.get("wait_until", "networkidle")))
                    hide = list(global_hide) + list(shot.get("hide") or [])
                    if hide:
                        page.add_style_tag(content=",".join(hide) + "{display:none !important}")
                    if shot.get("wait_for"):
                        page.locator(shot["wait_for"]).first.wait_for(state="visible")
                    run_steps(page, shot.get("actions") or [], timeout)
                    page.wait_for_timeout(int(shot.get("wait_ms", default_wait)))
                    target = out_dir / f"{name}.png"
                    if shot.get("selector"):
                        el = page.locator(shot["selector"]).first
                        el.wait_for(state="visible")
                        el.scroll_into_view_if_needed()
                        box = el.bounding_box()
                        if not box:
                            fail(1, f"shot {name}: selector has no box: {shot['selector']}")
                        pad = float(shot.get("padding", 0))
                        scroll = page.evaluate("() => [window.scrollX, window.scrollY]")
                        clip = {
                            "x": max(box["x"] + scroll[0] - pad, 0),
                            "y": max(box["y"] + scroll[1] - pad, 0),
                            "width": box["width"] + 2 * pad,
                            "height": box["height"] + 2 * pad,
                        }
                        page.screenshot(path=str(target), clip=clip, full_page=True)
                    else:
                        page.screenshot(path=str(target), full_page=bool(shot.get("full_page", False)))
                except (PWError, PWTimeout) as exc:
                    fail(1, f"shot {name}: {str(exc).splitlines()[0]}")
                width, height = png_size(target)
                manifest.append({
                    "name": name, "file": target.name, "width": width, "height": height, "url": url,
                    "device": device_name or "",
                    "title": shot.get("title", ""), "console_errors": console_errors, "http_errors": http_errors,
                })
                print(f"[webshot] {name}: {width}x{height}", file=sys.stderr)
                ctx.close()
        finally:
            browser.close()

    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    noisy = [m["name"] for m in manifest if m["console_errors"]]
    if noisy and spec.get("fail_on_console_error"):
        fail(1, f"console errors on: {', '.join(noisy)}")
    if noisy:
        print(f"[webshot] console errors on: {', '.join(noisy)} (see manifest.json)", file=sys.stderr)


# Scroll width, the deepest elements whose content is wider than them (text
# that cannot wrap), clipped headings, and the page's links.
AUDIT_MEASURE = """() => {
  const d = document.documentElement;
  const label = e => {
    const cls = typeof e.className === 'string' ? e.className.trim().split(/\\s+/).filter(Boolean).slice(0, 3).join('.') : '';
    return `${e.tagName.toLowerCase()}${e.id ? '#' + e.id : ''}${cls ? '.' + cls : ''}`;
  };
  const wide = [];
  if (d.scrollWidth > d.clientWidth) {
    for (const e of document.querySelectorAll('body *')) {
      if (getComputedStyle(e).overflowX !== 'visible' || e.clientWidth === 0) continue;
      if (e.scrollWidth > e.clientWidth + 1 &&
          ![...e.children].some(c => c.scrollWidth > e.clientWidth + 1)) {
        wide.push(`${label(e)} ${e.scrollWidth}/${e.clientWidth}`);
      }
    }
  }
  const clipped = [...document.querySelectorAll('h1, h2, h3')]
    .filter(h => h.clientWidth > 0 && h.scrollWidth > h.clientWidth + 1)
    .map(h => `${label(h)} "${h.textContent.trim().slice(0, 40)}" ${h.scrollWidth}/${h.clientWidth}`);
  return {width: d.clientWidth, scroll_width: d.scrollWidth, elements: wide.slice(0, 5), clipped,
          links: [...document.querySelectorAll('a[href]')].map(a => a.href)};
}"""


def shot_slug(url):
    """File name stem for a page: its path and query, made safe; a long one is cut and keeps a hash."""
    import hashlib
    from urllib.parse import urlparse
    u = urlparse(url)
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", (u.path.strip("/") or "index") + (f"_{u.query}" if u.query else ""))
    if len(slug) > 120:
        slug = slug[-100:] + "_" + hashlib.sha1(url.encode()).hexdigest()[:12]
    return slug


def audit():
    from urllib.parse import urldefrag, urlparse
    start = os.environ["WEBSHOT_START"]
    names = [d for d in os.environ.get("WEBSHOT_DEVICES", "").splitlines() if d] or ["iPhone 13", "Galaxy S8"]
    skips = tuple(x for x in os.environ.get("WEBSHOT_SKIP", "").splitlines() if x)
    limit = int(os.environ["WEBSHOT_LIMIT"])
    timeout = int(os.environ["WEBSHOT_TIMEOUT_MS"])
    shots = Path(os.environ["WEBSHOT_OUT"]) if os.environ.get("WEBSHOT_OUT") else None
    origin = urlparse(start)

    def norm(url):
        # One key per page: no fragment, and "http://host" is "http://host/".
        u = urlparse(urldefrag(url)[0])
        return u._replace(path=u.path or "/").geturl()

    start = norm(start)
    findings, http_errors, seen, queue = {}, {}, set(), [start]
    queued, downloads, measured = set(queue), set(), set()
    with sync_playwright() as p:
        unknown = sorted(set(names) - set(p.devices))
        if unknown:
            fail(2, f"unknown device {', '.join(unknown)}; known: {', '.join(sorted(p.devices))}")
        browser = p.chromium.launch()
        try:
            pages = {}
            for n in names:
                opts = dict(p.devices[n])
                opts.pop("default_browser_type", None)
                pages[n] = browser.new_context(**opts).new_page()
                pages[n].set_default_timeout(timeout)
            while queue and len(seen) < limit:
                url = queue.pop(0)
                seen.add(url)
                key = url
                for n, page in pages.items():
                    # A page that fails to load or navigates away mid-check is
                    # an http_errors entry, not a crash of the whole crawl.
                    try:
                        resp = page.goto(url, wait_until="load")
                        if resp is not None and resp.status >= 400:
                            http_errors[url] = resp.status
                            break
                        # An image or other file the browser shows itself
                        # (a JPG wallpaper) is not a page: list it with the
                        # downloads instead of measuring it as a wide page.
                        ctype = (resp.headers.get("content-type", "") if resp is not None else "").lower()
                        if ctype and "html" not in ctype:
                            downloads.add(url)
                            break
                        if n == names[0]:
                            # A redirect lands on a page that may be checked
                            # already; report each page once, by where it ended up.
                            key = norm(page.url)
                            if key in measured:
                                break
                            measured.add(key)
                            if url == start:
                                # http -> https or example.com -> www.example.com:
                                # the site is where the start page ended up.
                                origin = urlparse(key)
                        m = page.evaluate(AUDIT_MEASURE)
                        if shots:
                            page.screenshot(path=str(shots / f"{shot_slug(key)}--{re.sub(r'[^A-Za-z0-9._-]+', '_', n)}.png"))
                    except (PWError, PWTimeout) as exc:
                        msg = str(exc).splitlines()[0]
                        # A link to a file the browser downloads (PDF, zip) is not a page.
                        if "Download is starting" in msg:
                            downloads.add(url)
                        else:
                            http_errors[url] = msg
                        break
                    if m["scroll_width"] > m["width"] or m["clipped"]:
                        findings.setdefault(key, {})[n] = {
                            "width": m["width"], "scroll_width": m["scroll_width"],
                            "elements": m["elements"], "clipped_headings": m["clipped"]}
                    if n != names[0]:
                        continue
                    for href in m["links"]:
                        target = norm(urljoin(page.url, href))
                        u = urlparse(target)
                        if (u.scheme, u.netloc) != (origin.scheme, origin.netloc) or u.path.startswith(skips):
                            continue
                        if target not in queued:
                            queued.add(target)
                            queue.append(target)
        finally:
            browser.close()
    print(json.dumps({"crawled": len(measured), "findings": findings, "http_errors": http_errors,
                      "downloads": sorted(downloads)}, indent=1))
    print(f"[webshot] audit: {len(measured)} pages, {len(findings)} with findings, {len(http_errors)} not loaded",
          file=sys.stderr)
    if start in http_errors:
        fail(1, f"start page did not load: {http_errors[start]}")
    if findings:
        sys.exit(1)


class DevTools:
    """A Chrome DevTools Protocol client over a plain WebSocket (RFC 6455),
    standard library only: Playwright does not support CDP to Chrome on Android."""

    def __init__(self, ws_url, timeout):
        import base64, socket
        from urllib.parse import urlparse
        u = urlparse(ws_url)
        self.sock = socket.create_connection((u.hostname, u.port or 80), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        path = u.path + (f"?{u.query}" if u.query else "")
        self.sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\nUpgrade: websocket\r\n"
                           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise OSError("DevTools closed the connection during the handshake")
            self.buf += chunk
        head, _, self.buf = self.buf.partition(b"\r\n\r\n")
        status = head.split(b"\r\n")[0].decode(errors="replace")
        if " 101 " not in f"{status} ":
            raise OSError(f"DevTools refused the WebSocket: {status}")
        self.next_id = 0

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise OSError("DevTools closed the connection")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _send(self, opcode, data):
        mask = os.urandom(4)
        n = len(data)
        head = bytes([0x80 | opcode])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _message(self):
        parts = b""
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            payload = self._read(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            opcode = b0 & 0x0F
            if opcode == 8:
                raise OSError("DevTools closed the connection")
            if opcode == 9:
                self._send(10, payload)
                continue
            if opcode in (0, 1, 2):
                parts += payload
                if b0 & 0x80:
                    return json.loads(parts.decode())

    def call(self, method, **params):
        self.next_id += 1
        mid = self.next_id
        self._send(1, json.dumps({"id": mid, "method": method, "params": params}).encode())
        while True:
            msg = self._message()  # events in between are skipped
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error'].get('message')}")
                return msg.get("result", {})

    def evaluate(self, expression):
        res = self.call("Runtime.evaluate", expression=expression, returnByValue=True)
        if "exceptionDetails" in res:
            raise RuntimeError(f"page script failed: {res['exceptionDetails'].get('text')}")
        return res.get("result", {}).get("value")


def android():
    import http.client, subprocess, time
    from urllib.parse import urlparse
    start = os.environ["WEBSHOT_START"]
    paths = [x for x in os.environ.get("WEBSHOT_PATHS", "").splitlines() if x]
    urls = [urljoin(start, x) for x in paths] or [start]
    timeout = int(os.environ["WEBSHOT_TIMEOUT_MS"]) / 1000
    shots = Path(os.environ["WEBSHOT_OUT"]) if os.environ.get("WEBSHOT_OUT") else None
    serial, device = os.environ["WEBSHOT_ADB_SERIAL"], os.environ["WEBSHOT_DEVICE_NAME"]
    port = int(os.environ["WEBSHOT_CDP_PORT"])
    origin = urlparse(start)

    # Chrome may still be starting: wait for its DevTools to list a tab.
    deadline, tabs, last = time.time() + timeout, [], ""
    while time.time() < deadline:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.request("GET", "/json")
            tabs = [t for t in json.loads(conn.getresponse().read()) if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
            if tabs:
                break
        except (OSError, ValueError) as exc:
            last = str(exc)
        time.sleep(0.5)
    if not tabs:
        fail(1, f"Chrome's DevTools listed no tab ({last or 'none open'}); is USB debugging on and Chrome running?")
    # The tab that opened the URL, else the first one.
    tab = next((t for t in tabs if urlparse(t.get("url", ""))[:2] == origin[:2]), tabs[0])

    findings, http_errors, checked = {}, {}, []
    try:
        cdp = DevTools(tab["webSocketDebuggerUrl"], timeout)
        viewport = cdp.evaluate("({width: innerWidth, height: innerHeight, dpr: devicePixelRatio})")
        for url in urls:
            nav = cdp.call("Page.navigate", url=url)
            if nav.get("errorText"):
                http_errors[url] = nav["errorText"]
                continue
            # Page.navigate returns before the page loads; wait for "complete"
            # on the new document.
            end = time.time() + timeout
            while time.time() < end:
                state = cdp.evaluate("[document.readyState, location.href]")
                if state and state[0] == "complete" and state[1] != "about:blank":
                    break
                time.sleep(0.25)
            else:
                http_errors[url] = f"not loaded in {int(timeout * 1000)} ms"
                continue
            time.sleep(0.5)  # late layout: fonts, lazy images
            status = cdp.evaluate("(performance.getEntriesByType('navigation')[0] || {}).responseStatus || 0")
            if status and status >= 400:
                http_errors[url] = status
                continue
            checked.append(url)
            m = cdp.evaluate(f"({AUDIT_MEASURE})()")
            if m["scroll_width"] > m["width"] or m["clipped"]:
                findings[url] = {device: {"width": m["width"], "scroll_width": m["scroll_width"],
                                          "elements": m["elements"], "clipped_headings": m["clipped"]}}
            if shots:
                png = subprocess.run([os.environ.get("WEBSHOT_ADB", "adb"), "-s", serial, "exec-out", "screencap", "-p"],
                                     capture_output=True, timeout=timeout)
                if png.returncode != 0 or not png.stdout.startswith(b"\x89PNG"):
                    fail(1, f"screencap failed on {serial}: {png.stderr.decode(errors='replace').strip()[:200]}")
                (shots / f"{shot_slug(url)}--{re.sub(r'[^A-Za-z0-9._-]+', '_', device)}.png").write_bytes(png.stdout)
    except (OSError, RuntimeError, ValueError, KeyError, TypeError) as exc:
        fail(1, f"DevTools: {exc}")
    print(json.dumps({"device": device, "viewport": viewport, "checked": checked, "findings": findings,
                      "http_errors": http_errors}, indent=1))
    print(f"[webshot] android audit on {device}: {len(checked)} pages, {len(findings)} with findings, "
          f"{len(http_errors)} not loaded", file=sys.stderr)
    if findings or http_errors:
        sys.exit(1)


def pdf():
    src = Path(os.environ["WEBSHOT_IN"]).resolve()
    out = Path(os.environ["WEBSHOT_OUT"])
    footer = os.environ.get("WEBSHOT_FOOTER", "")
    opts = {
        "path": str(out),
        "format": os.environ.get("WEBSHOT_FORMAT", "Letter"),
        "landscape": os.environ.get("WEBSHOT_LANDSCAPE") == "1",
        "print_background": True,
        "prefer_css_page_size": True,
    }
    if footer:
        opts["display_header_footer"] = True
        opts["header_template"] = "<span></span>"
        opts["footer_template"] = (
            '<div style="width:100%;font-size:8px;color:#6b7684;padding:0 12mm;display:flex;'
            'justify-content:space-between;font-family:sans-serif">'
            f"<span>{html_mod.escape(footer)}</span>"
            '<span><span class="pageNumber"></span> / <span class="totalPages"></span></span></div>'
        )
        opts["margin"] = {"top": "12mm", "bottom": "16mm", "left": "0", "right": "0"}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        try:
            page = browser.new_page()
            page.goto(src.as_uri(), wait_until="networkidle")
            page.evaluate("() => document.fonts ? document.fonts.ready : null")
            page.wait_for_timeout(int(os.environ.get("WEBSHOT_WAIT_MS", "500")))
            page.pdf(**opts)
        except (PWError, PWTimeout) as exc:
            fail(1, f"pdf: {str(exc).splitlines()[0]}")
        finally:
            browser.close()
    print(f"[webshot] pdf: {out}", file=sys.stderr)


{"capture": capture, "audit": audit, "android": android, "pdf": pdf}[os.environ["WEBSHOT_MODE"]]()
PY
}

# --- internal logging shims (use the logging module if present) -------------
_webshot_log_info()  { if type log_info  >/dev/null 2>&1; then log_info  "$*"; else echo "[webshot] $*" >&2; fi; }
_webshot_log_error() { if type log_error >/dev/null 2>&1; then log_error "$*"; else echo "[webshot][ERROR] $*" >&2; fi; }
