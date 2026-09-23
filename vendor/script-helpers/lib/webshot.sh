#!/usr/bin/env bash
# Web page screenshots and HTML-to-PDF rendering with Playwright (Chromium).
#
# webshot_capture drives a list of pages from a JSON spec: log in once per
# auth profile, run optional clicks/fills, hide elements, and save a PNG per
# page (whole page, viewport, or one element). webshot_pdf prints an HTML file
# to PDF. Both run a Python driver inside a venv that webshot_ensure creates
# outside the repository. Depends on the `python` module; `logging` is optional.
#
# Exit codes for every public function: 0 ok, 1 run failed, 2 bad arguments or
# spec, 3 Python or Playwright unavailable.

WEBSHOT_PLAYWRIGHT_VERSION="${WEBSHOT_PLAYWRIGHT_VERSION:-1.63.0}"

# Usage: webshot_venv_dir; prints the venv directory webshot uses.
webshot_venv_dir() {
  echo "${WEBSHOT_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/nr-webshot/venv}"
}

# Usage: webshot_python; prints a Python that can import playwright, or
# returns 3. WEBSHOT_PYTHON, when set, is the only candidate considered.
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

# Usage: webshot_pdf <input.html> <output.pdf> [--format Letter|A4|Legal]
#                    [--landscape] [--footer TEXT] [--wait-ms N]
# Prints an HTML file with backgrounds. CSS @page size and margins win when
# the document sets them. --footer adds "TEXT  page / total" at the bottom.
webshot_pdf() {
  local in="${1:-}" out="${2:-}" format="Letter" landscape="0" footer="" wait_ms="500" py
  if [[ -z "$in" || -z "$out" ]]; then
    _webshot_log_error "usage: webshot_pdf <input.html> <output.pdf> [--format F] [--landscape] [--footer TEXT] [--wait-ms N]"
    return 2
  fi
  shift 2
  while [[ $# -gt 0 ]]; do
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
        browser = p.chromium.launch()
        try:
            for shot in spec["shots"]:
                name = shot["name"]
                vp = shot.get("viewport") or default_vp
                ctx_opts = {
                    "viewport": {"width": int(vp["width"]), "height": int(vp["height"])},
                    "device_scale_factor": float(shot.get("device_scale_factor", default_dsf)),
                    "color_scheme": shot.get("color_scheme", spec.get("color_scheme", "light")),
                    "locale": spec.get("locale", "en-US"),
                }
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


{"capture": capture, "pdf": pdf}[os.environ["WEBSHOT_MODE"]]()
PY
}

# --- internal logging shims (use the logging module if present) -------------
_webshot_log_info()  { if type log_info  >/dev/null 2>&1; then log_info  "$*"; else echo "[webshot] $*" >&2; fi; }
_webshot_log_error() { if type log_error >/dev/null 2>&1; then log_error "$*"; else echo "[webshot][ERROR] $*" >&2; fi; }
