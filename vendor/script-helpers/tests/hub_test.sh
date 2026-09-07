#!/usr/bin/env bash
# SCRIPT: hub_test.sh
# DESCRIPTION: Tests for lib/hub.sh -- the corpus-hub setup dialog, probe, key check, bootstrap and update offer.
# USAGE: ./tests/hub_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/hub_test.sh
# ----------------------------------------------------
#
# The hub is a small Python HTTP server on 127.0.0.1 answering /v1/service and
# /v1/documents (401 for any key but "good-key"); the hub's own scripts
# (start, install-service, update) are stubs in a temporary git repository
# that log how they were called. Nothing here needs a network, a device, or
# `dialog` -- the UI layer is forced to `none` or `plain` through HUB_UI and
# fed answers on stdin.
#
# The behaviours worth pinning are the ones a careless implementation gets
# wrong while looking right: a non-TTY run that prompts (and hangs a systemd
# unit), a wrong key reported as a missing hub, a symlinked .env replaced by a
# regular file, an update run without a person saying yes, and a remote hub
# "updated" from a client.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[hub_test] $*"; }
error() { echo "[hub_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[hub_test]   ok  $*"; }

tmp="$(mktemp -d)"
server_pid=""
# Invoked only by the EXIT trap, so shellcheck reads it as unreachable.
# shellcheck disable=SC2317
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import hub

# --- a fake hub ----------------------------------------------------------------
cat >"$tmp/hub_server.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

VERSION = sys.argv[2] if len(sys.argv) > 2 else "0.1.0"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/v1/service":
            self._send(200, {"name": "corpus-hub", "version": VERSION,
                             "api_version": "v1",
                             "instance_id": "6f1d2c3b-4a5e-4f60-9a8b-7c6d5e4f3a2b",
                             "schema_versions": {"document": "1"}})
        elif path == "/v1/documents":
            if self.headers.get("X-API-Key") == "good-key":
                self._send(200, {"count": 0, "results": []})
            else:
                self._send(401, {"type": "about:blank", "title": "Unauthorized", "code": "unauthorized"})
        else:
            self._send(404, {"code": "not_found"})

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

pick_port() {
  python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
}

start_hub() {
  local version="${1:-0.1.0}"
  port="$(pick_port)"
  python3 "$tmp/hub_server.py" "$port" "$version" &
  server_pid=$!
  local _attempt
  for _attempt in $(seq 1 50); do
    curl -fsS --max-time 1 "http://127.0.0.1:$port/v1/service" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  error "fake hub did not come up on $port"
  return 1
}
stop_hub() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  server_pid=""
}

# --- UI mode precedence ---------------------------------------------------------
note "ui mode"
if [[ "$(HUB_UI=none hub_ui_mode)" == "none" ]]; then ok "HUB_UI=none wins"; else error "HUB_UI=none ignored: $(HUB_UI=none hub_ui_mode)"; fi
if [[ "$(HUB_UI=plain hub_ui_mode)" == "plain" ]]; then ok "HUB_UI=plain wins"; else error "HUB_UI=plain ignored"; fi
# This test file runs with stdin redirected by `make test` or a terminal; force
# the no-TTY case explicitly so the assertion does not depend on how it was run.
if [[ "$(unset HUB_UI; hub_ui_mode </dev/null)" == "none" ]]; then ok "no TTY means no prompts"; else error "non-TTY did not resolve to none: $(unset HUB_UI; hub_ui_mode </dev/null)"; fi
if [[ "$(HUB_UI=dialog HUB_SETUP_PLAIN=1 hub_ui_mode)" == "plain" ]]; then ok "HUB_SETUP_PLAIN=1 downgrades dialog to plain"; else error "HUB_SETUP_PLAIN not honoured"; fi
if HUB_UI=bogus hub_ui_mode >/dev/null 2>&1; then error "an unknown HUB_UI must fail"; else ok "unknown HUB_UI rejected"; fi

# --- hub_write_env ---------------------------------------------------------------
note "hub_write_env"
env_file="$tmp/.env"
hub_write_env "$env_file" HUB_URL "http://localhost:8000"
if grep -q '^HUB_URL=http://localhost:8000$' "$env_file"; then ok "creates the file and writes the key"; else error "write failed: $(cat "$env_file")"; fi
printf 'OTHER=keep\nHUB_URL=old\n# comment\n' >"$env_file"
hub_write_env "$env_file" HUB_URL "http://203.0.113.7:8000"
if [[ "$(grep -c '^HUB_URL=' "$env_file")" == "1" && "$(grep '^HUB_URL=' "$env_file")" == "HUB_URL=http://203.0.113.7:8000" ]]; then ok "upserts in place, once"; else error "upsert wrong: $(cat "$env_file")"; fi
if grep -q '^OTHER=keep$' "$env_file" && grep -q '^# comment$' "$env_file"; then ok "keeps every other line"; else error "other lines lost"; fi
real="$tmp/real.env"; printf 'A=1\n' >"$real"; ln -s "$real" "$tmp/link.env"
inode_before="$(stat -c %i "$real" 2>/dev/null || stat -f %i "$real")"
hub_write_env "$tmp/link.env" HUB_API_KEY "abc"
inode_after="$(stat -c %i "$real" 2>/dev/null || stat -f %i "$real")"
if [[ -L "$tmp/link.env" && "$inode_after" == "$inode_before" && "$(grep -c '^HUB_API_KEY=abc$' "$real")" == "1" ]]; then ok "writes through a symlink, keeps the inode"; else error "symlink replaced or target untouched"; fi
if hub_write_env "$env_file" "hub-url" "x" 2>/dev/null; then error "a lowercase/dashed key must be refused"; else ok "bad key name refused"; fi
if hub_write_env "$env_file" HUB_URL $'a\nb' 2>/dev/null; then error "a value with a newline must be refused"; else ok "newline in value refused"; fi
if hub_write_env "$env_file" HUB_URL $'a\rb' 2>/dev/null; then error "a value with a carriage return must be refused"; else ok "carriage return in value refused"; fi
if hub_write_env "" HUB_URL x 2>/dev/null; then error "empty path must fail"; else ok "empty path refused"; fi

# --- hub_probe / hub_probe_field / hub_check_key ----------------------------------
note "probe and key check"
start_hub "0.1.0"
url="http://127.0.0.1:$port"
body="$(hub_probe "$url" 3)" || error "hub_probe failed against a serving hub"
if [[ "$(hub_probe_field "$body" version)" == "0.1.0" ]]; then ok "hub_probe_field reads version"; else error "version not read: $(hub_probe_field "$body" version)"; fi
if [[ "$(hub_probe_field "$body" instance_id)" == "6f1d2c3b-4a5e-4f60-9a8b-7c6d5e4f3a2b" ]]; then ok "hub_probe_field reads instance_id"; else error "instance_id not read"; fi
if [[ -z "$(hub_probe_field "$body" nonexistent)" ]]; then ok "a missing field is empty, not an error string"; else error "missing field produced output"; fi
# The no-python3 fallback: same contract, forced by shadowing `command -v`.
# Invoked only inside the subshell below, so shellcheck reads it as unreachable.
# shellcheck disable=SC2317
probe_field_no_py() (
  command() { if [[ "${1:-}" == "-v" && "${2:-}" == "python3" ]]; then return 1; fi; builtin command "$@"; }
  hub_probe_field "$@"
)
pretty="$(printf '{\n  "api_version": "9.9.9",\n  "version": "0.1.0"\n}\n')"
if [[ "$(probe_field_no_py "$body" version)" == "0.1.0" ]]; then ok "fallback reads compact JSON"; else error "fallback compact read: $(probe_field_no_py "$body" version)"; fi
if [[ "$(probe_field_no_py "$pretty" version)" == "0.1.0" ]]; then ok "fallback reads pretty-printed JSON"; else error "fallback pretty read: $(probe_field_no_py "$pretty" version)"; fi
if [[ "$(probe_field_no_py "$pretty" api_version)" == "9.9.9" ]]; then ok "fallback keeps api_version and version apart"; else error "fallback key confusion: $(probe_field_no_py "$pretty" api_version)"; fi
rc=0; probe_field_no_py "$pretty" nonexistent >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "0" ]]; then ok "fallback missing field is exit 0 (pipefail-safe)"; else error "fallback missing field exited $rc"; fi
if hub_probe_field "$body" 'ver.*' >/dev/null 2>&1; then error "a key with regex metacharacters must be refused"; else ok "regex metacharacters in key refused"; fi
if hub_check_key "$url" good-key; then ok "the right key is accepted"; else error "good key rejected"; fi
rc=0; hub_check_key "$url" wrong-key 2>/dev/null || rc=$?
if [[ "$rc" == "2" ]]; then ok "a wrong key is exit 2, distinct from an unreachable hub"; else error "wrong key returned $rc"; fi
# A trailing slash must not produce //v1/service.
if hub_probe "$url/" 3 >/dev/null; then ok "trailing slash tolerated"; else error "trailing slash broke the probe"; fi
dead_port="$(pick_port)"
if hub_probe "http://127.0.0.1:$dead_port" 1 >/dev/null 2>&1; then error "probe of a closed port must fail"; else ok "closed port fails"; fi
rc=0; hub_check_key "http://127.0.0.1:$dead_port" good-key 2>/dev/null || rc=$?
if [[ "$rc" == "1" ]]; then ok "an unreachable hub is exit 1 on the key check"; else error "unreachable key check returned $rc"; fi
# A key with a CR or LF would be header injection; it must never reach curl.
if hub_check_key "$url" $'good\nkey' 2>/dev/null; then error "a key with LF must be refused"; else ok "LF in key refused"; fi
if hub_check_key "$url" $'good\rkey' 2>/dev/null; then error "a key with CR must be refused"; else ok "CR in key refused"; fi

# --- URL validation ---------------------------------------------------------------
note "url validation"
if _hub__url_ok "http://[::1]:8000"; then ok "bracketed IPv6 URL accepted"; else error "http://[::1]:8000 rejected"; fi
if _hub__url_ok "http://::1:8000"; then error "unbracketed IPv6 must be refused (curl needs brackets)"; else ok "unbracketed IPv6 refused"; fi
if _hub__url_is_loopback "http://[::1]:8000"; then ok "[::1] is loopback"; else error "[::1] not seen as loopback"; fi
if _hub__url_is_loopback "http://[2001:db8::7]:8000"; then error "a non-loopback IPv6 host read as loopback"; else ok "non-loopback IPv6 is not loopback"; fi
if _hub__url_is_loopback "http://localhost:8000"; then ok "localhost is loopback"; else error "localhost not seen as loopback"; fi
if _hub__url_ok "http://localhost:0"; then error "port 0 must be refused"; else ok "port 0 refused"; fi
if _hub__url_ok "http://localhost:99999"; then error "port 99999 must be refused"; else ok "port 99999 refused"; fi
if _hub__url_ok "http://localhost:08000"; then ok "a leading-zero port is not read as octal"; else error "leading-zero port broke validation"; fi
if _hub__url_ok "http://localhost:65535"; then ok "port 65535 accepted"; else error "port 65535 refused"; fi
if _hub__url_ok "http://localhost"; then ok "a URL without a port is accepted"; else error "portless URL refused"; fi

# --- hub_setup_dialog, remote, no TTY --------------------------------------------
note "hub_setup_dialog remote (no TTY)"
env_file="$tmp/remote.env"; rm -f "$env_file"
if HUB_UI=none hub_setup_dialog "$env_file" --mode remote --url "$url" --key good-key --client test-client >"$tmp/out.txt" 2>&1; then
  ok "flags answer every prompt"
else
  error "remote setup with flags failed: $(cat "$tmp/out.txt")"
fi
for kv in "HUB_MODE=remote" "HUB_URL=$url" "HUB_API_KEY=good-key" "HUB_INSTANCE_ID=6f1d2c3b-4a5e-4f60-9a8b-7c6d5e4f3a2b"; do
  if grep -q "^$kv\$" "$env_file"; then ok "wrote $kv"; else error "missing $kv in $(cat "$env_file")"; fi
done
rc=0; HUB_UI=none hub_setup_dialog "$tmp/bad.env" --mode remote --url "$url" --key wrong-key >"$tmp/out.txt" 2>&1 || rc=$?
if [[ "$rc" != "0" ]] && grep -qi "key" "$tmp/out.txt" && ! grep -qi "not serving\|unreachable" "$tmp/out.txt"; then ok "a wrong key is reported as a wrong key"; else error "wrong key: rc=$rc out=$(cat "$tmp/out.txt")"; fi
if [[ ! -f "$tmp/bad.env" ]] || ! grep -q "wrong-key" "$tmp/bad.env"; then ok "a rejected key is not written"; else error "rejected key written to .env"; fi
rc=0; HUB_UI=none hub_setup_dialog "$tmp/nomode.env" >"$tmp/out.txt" 2>&1 || rc=$?
if [[ "$rc" != "0" ]] && grep -q "HUB_MODE" "$tmp/out.txt"; then ok "no TTY and no mode fails naming HUB_MODE"; else error "no-mode failure wrong: rc=$rc $(cat "$tmp/out.txt")"; fi
rc=0; HUB_UI=none hub_setup_dialog "$tmp/nourl.env" --mode remote >"$tmp/out.txt" 2>&1 || rc=$?
if [[ "$rc" != "0" ]] && grep -q "HUB_URL" "$tmp/out.txt"; then ok "no TTY and no URL fails naming HUB_URL"; else error "no-url failure wrong: rc=$rc $(cat "$tmp/out.txt")"; fi
# Values already in .env are enough; no flags needed.
printf 'HUB_MODE=remote\nHUB_URL=%s\nHUB_API_KEY=good-key\n' "$url" >"$tmp/prefilled.env"
if HUB_UI=none hub_setup_dialog "$tmp/prefilled.env" >"$tmp/out.txt" 2>&1 && grep -q '^HUB_INSTANCE_ID=' "$tmp/prefilled.env"; then ok "a prefilled .env needs no prompts and gains HUB_INSTANCE_ID"; else error "prefilled .env path failed: $(cat "$tmp/out.txt")"; fi
# A URL that is not a URL.
rc=0; HUB_UI=none hub_setup_dialog "$tmp/badurl.env" --mode remote --url "localhost:8000" --key good-key >"$tmp/out.txt" 2>&1 || rc=$?
if [[ "$rc" != "0" ]] && grep -qi "http" "$tmp/out.txt"; then ok "a URL without a scheme is refused"; else error "bad URL accepted: rc=$rc"; fi
# A flag with no value must fail loudly, not misparse.
rc=0; HUB_UI=none hub_setup_dialog "$tmp/noval.env" --mode remote --url >"$tmp/out.txt" 2>&1 || rc=$?
if [[ "$rc" == "2" ]] && grep -q -- "--url requires a value" "$tmp/out.txt"; then ok "a trailing valueless flag is refused"; else error "valueless flag: rc=$rc out=$(cat "$tmp/out.txt")"; fi
rc=0; HUB_UI=none hub_setup_dialog "$tmp/noval.env" --url --key good-key >"$tmp/out.txt" 2>&1 || rc=$?
if [[ "$rc" == "2" ]] && grep -q -- "--url requires a value" "$tmp/out.txt"; then ok "a flag followed by a flag is refused"; else error "flag-as-value: rc=$rc out=$(cat "$tmp/out.txt")"; fi

# --- hub_setup_dialog, remote, plain prompts on stdin ----------------------------
note "hub_setup_dialog remote (plain)"
env_file="$tmp/plain.env"; rm -f "$env_file"
# Answers: mode, URL, key.
if printf 'remote\n%s\ngood-key\n' "$url" | HUB_UI=plain hub_setup_dialog "$env_file" >"$tmp/out.txt" 2>&1; then
  if grep -q "^HUB_URL=$url\$" "$env_file" && grep -q '^HUB_API_KEY=good-key$' "$env_file"; then ok "plain prompts read answers from stdin"; else error "plain answers not written: $(cat "$env_file")"; fi
else
  error "plain remote setup failed: $(cat "$tmp/out.txt")"
fi
# A wrong key, then the right one on retry.
env_file="$tmp/plain2.env"; rm -f "$env_file"
if printf 'remote\n%s\nwrong-key\ny\ngood-key\n' "$url" | HUB_UI=plain hub_setup_dialog "$env_file" >"$tmp/out.txt" 2>&1 && grep -q '^HUB_API_KEY=good-key$' "$env_file"; then ok "plain mode offers a retry after a wrong key"; else error "retry path failed: $(cat "$tmp/out.txt")"; fi
# The key must never be echoed back.
if grep -q "good-key" "$tmp/out.txt"; then error "the API key was printed"; else ok "the key is never echoed"; fi
stop_hub

# --- a fake hub repository: start / install-service / update stubs ---------------
note "hub_bootstrap"
make_fake_hub_repo() {
  local src="$1"
  mkdir -p "$src"
  for s in start install-service update; do
    cat >"$src/$s" <<EOS
#!/usr/bin/env bash
echo "$s\${*:+ \$*}" >>"\$(dirname "\$0")/calls.log"
EOS
    chmod +x "$src/$s"
  done
  printf 'BACKEND_PORT=%s\n' "${2:-8000}" >"$src/env.example"
  printf '0.1.0\n' >"$src/VERSION"
  git -C "$src" init -q
  git -C "$src" add -A
  git -C "$src" -c user.name=t -c user.email=t@example.org commit -q -m init
  git -C "$src" tag 0.1.0
}
make_fake_hub_repo "$tmp/origin"
clone_dir="$tmp/clients/hub"
if HUB_UI=none hub_bootstrap "$clone_dir" "$tmp/origin" >"$tmp/out.txt" 2>&1; then ok "bootstrap clones an absent hub"; else error "bootstrap failed: $(cat "$tmp/out.txt")"; fi
if [[ -x "$clone_dir/start" ]]; then ok "clone landed at the given directory"; else error "no clone at $clone_dir"; fi
if grep -q '^start --configure-superuser$' "$clone_dir/calls.log" && grep -q '^install-service$' "$clone_dir/calls.log"; then ok "ran the hub's own start --configure-superuser and install-service"; else error "wrong calls: $(cat "$clone_dir/calls.log" 2>/dev/null)"; fi
if grep -q "enable-linger" "$tmp/out.txt"; then ok "prints the linger step rather than running it"; else error "linger hint missing"; fi
if grep -q "docker compose" "$clone_dir/calls.log" 2>/dev/null; then error "bootstrap must never run compose"; else ok "no compose"; fi
: >"$clone_dir/calls.log"
if HUB_UI=none hub_bootstrap "$clone_dir" "$tmp/origin" >"$tmp/out.txt" 2>&1; then ok "bootstrap with a present clone succeeds"; else error "second bootstrap failed: $(cat "$tmp/out.txt")"; fi
if grep -q '^install-service --dry-run$' "$clone_dir/calls.log" && ! grep -q 'configure-superuser' "$clone_dir/calls.log"; then ok "a present clone is only dry-run checked"; else error "present clone touched: $(cat "$clone_dir/calls.log")"; fi
if hub_bootstrap "$tmp/clients/other" "" 2>/dev/null; then error "bootstrap without a clone URL must fail"; else ok "no URL, no clone"; fi
# A repo URL starting with a dash must reach git as a URL, never as an option.
if hub_bootstrap "$tmp/clients/inj" "--upload-pack=/bin/true" 2>/dev/null; then error "a dashed repo URL must not be treated as a git option"; else ok "dashed repo URL refused as a URL, not an option"; fi
if [[ ! -d "$tmp/clients/inj" ]]; then ok "no clone directory from the dashed URL"; else error "dashed URL produced a clone directory"; fi

# --- hub_latest_tag ---------------------------------------------------------------
note "hub_latest_tag"
git -C "$tmp/origin" tag 0.2.0
git -C "$tmp/origin" tag 0.10.0
if [[ "$(hub_latest_tag "$clone_dir")" == "0.10.0" ]]; then ok "newest tag by version order, fetched from origin"; else error "latest tag: $(hub_latest_tag "$clone_dir")"; fi
git -C "$tmp/origin" tag v0.11.0
if [[ "$(hub_latest_tag "$clone_dir")" == "0.11.0" ]]; then ok "a v prefix is stripped"; else error "v-prefixed tag: $(hub_latest_tag "$clone_dir")"; fi
if [[ -z "$(hub_latest_tag "$tmp/nowhere" 2>/dev/null)" ]]; then ok "a missing clone yields nothing"; else error "missing clone produced a tag"; fi

# --- hub_offer_update ------------------------------------------------------------
note "hub_offer_update"
start_hub "0.1.0"
url="http://127.0.0.1:$port"
: >"$clone_dir/calls.log"
HUB_UI=none hub_offer_update "$url" "$clone_dir" >"$tmp/out.txt" 2>&1 || error "offer_update (none) returned non-zero"
rc=0; HUB_UI=bogus hub_offer_update "$url" "$clone_dir" >/dev/null 2>&1 || rc=$?
if [[ "$rc" != "0" ]]; then ok "an invalid HUB_UI surfaces instead of acting as none"; else error "invalid HUB_UI silently treated as none"; fi
if grep -q "0.11.0" "$tmp/out.txt" && ! grep -q '^update' "$clone_dir/calls.log"; then ok "no TTY: prints the newer version and runs nothing"; else error "none mode: out=$(cat "$tmp/out.txt") calls=$(cat "$clone_dir/calls.log")"; fi
: >"$clone_dir/calls.log"
printf 'n\n' | HUB_UI=plain hub_offer_update "$url" "$clone_dir" >"$tmp/out.txt" 2>&1 || error "offer_update (plain, no) returned non-zero"
if ! grep -q '^update' "$clone_dir/calls.log"; then ok "plain, answer no: nothing runs"; else error "update ran after 'n'"; fi
: >"$clone_dir/calls.log"
# `yes` execs the hub's update, so run in a subshell.
( printf 'y\n' | HUB_UI=plain hub_offer_update "$url" "$clone_dir" >"$tmp/out.txt" 2>&1 ) || true
if grep -q '^update$' "$clone_dir/calls.log"; then ok "plain, answer yes: execs the hub's own ./update"; else error "update did not run after 'y': $(cat "$tmp/out.txt")"; fi
: >"$clone_dir/calls.log"
( printf 'y\n' | HUB_UI=plain HUB_MODE=remote hub_offer_update "$url" "$clone_dir" >"$tmp/out.txt" 2>&1 ) || true
if ! grep -q '^update' "$clone_dir/calls.log" && grep -qi "remote" "$tmp/out.txt"; then ok "remote mode never updates, says so"; else error "remote mode ran update or said nothing: $(cat "$tmp/out.txt")"; fi
stop_hub
start_hub "0.11.0"
url="http://127.0.0.1:$port"
: >"$clone_dir/calls.log"
( printf 'y\n' | HUB_UI=plain hub_offer_update "$url" "$clone_dir" >"$tmp/out.txt" 2>&1 ) || true
if ! grep -q '^update' "$clone_dir/calls.log" && ! grep -qi "available" "$tmp/out.txt"; then ok "an up-to-date hub gets no offer"; else error "offered an update to a current hub: $(cat "$tmp/out.txt")"; fi
# A clone that is not a clone must be "nothing to offer", not a set -e death.
# `bash -e` because set -e is suppressed inside any || context, which would
# hide exactly the failure this pins.
rc=0; bash -ec 'source ./helpers.sh >/dev/null; shlib_import hub; HUB_UI=none hub_offer_update "$1" "$2" >/dev/null 2>&1' _ "$url" "$tmp/no-such-clone" || rc=$?
if [[ "$rc" == "0" ]]; then ok "a missing clone under set -e is not a failure"; else error "offer_update with a bad clone exited $rc under set -e"; fi

# --- hub_setup_dialog, local, no TTY ----------------------------------------------
note "hub_setup_dialog local (no TTY)"
local_dir="$tmp/clients2/hub"
env_file="$tmp/local.env"; rm -f "$env_file"
# The fake hub answers on $port; tell the dialog that is where localhost's hub is.
if HUB_UI=none hub_setup_dialog "$env_file" --mode local --hub-dir "$local_dir" --repo-url "$tmp/origin" --url "$url" --key good-key --client test-client >"$tmp/out.txt" 2>&1; then ok "local mode with flags bootstraps and records"; else error "local setup failed: $(cat "$tmp/out.txt")"; fi
if [[ -x "$local_dir/install-service" ]] && grep -q '^HUB_MODE=local$' "$env_file" && grep -q '^HUB_INSTANCE_ID=' "$env_file"; then ok "clone made, .env written"; else error "local outcome wrong: $(cat "$env_file" 2>/dev/null)"; fi
rc=0; HUB_UI=none hub_setup_dialog "$tmp/local2.env" --mode local --hub-dir "$tmp/clients3/hub" >"$tmp/out.txt" 2>&1 || rc=$?
if [[ "$rc" != "0" ]] && grep -q "HUB_REPO_URL" "$tmp/out.txt"; then ok "local mode with no clone and no URL fails naming HUB_REPO_URL"; else error "local no-url: rc=$rc $(cat "$tmp/out.txt")"; fi
stop_hub

# --- no private-range literals in this file or the module ------------------------
if bash scripts/check_no_private_ips.sh --path lib >/dev/null 2>&1 && bash scripts/check_no_private_ips.sh --path tests >/dev/null 2>&1; then ok "no RFC 1918 literals"; else error "private-range literal found"; fi

if [[ $failures -eq 0 ]]; then
  note "all hub tests passed"
  exit 0
fi
note "$failures failure(s)"
exit 1
