# hub

Corpus-hub helpers for capture clients: ask whether the hub is local or
remote, prove the answer, write it to `.env`, bootstrap a local hub through
the hub's **own** scripts, and offer -- to a person -- to run the hub's own
`./update`. Implements the fleet's ADR-0013, ADR-0015 and the corpus-client
convention (recorded in the contracts repository): never compose, never stop the hub, never a prompt without a
terminal.

Three renderers behind one set of prompts: `dialog` when installed and both
stdin and stdout are terminals, plain `read -p` otherwise, and **no prompts at
all** when stdin or stdout is not a terminal -- then every value must already
be in the environment or the env file, and the failure names the variable it
wanted.

Functions
---------

- hub_ui_mode
  - Purpose: Which renderer applies: prints `dialog`, `plain` or `none`.
  - Behavior: `HUB_UI=dialog|plain|none` forces one (tests, scripted runs);
    `HUB_SETUP_PLAIN=1` downgrades `dialog` to `plain`; no terminal on stdin
    or stdout is `none`.
  - Returns: 0; 1 on an unknown `HUB_UI`.

- hub_probe url [timeout_seconds=5]
  - Purpose: One `GET url/v1/service` with a short deadline; prints the body.
  - Returns: 0 when the hub answered; 1 otherwise. A trailing slash on the
    URL is tolerated.

- hub_probe_field body key
  - Purpose: Print one top-level string field of a `/v1/service` body
    (`name`, `version`, `instance_id`); nothing when absent.
  - Dependencies: python3 when present; a sed fallback otherwise.

- hub_check_key url key
  - Purpose: Prove an API key with an authenticated read,
    `GET url/v1/documents?limit=1` under `X-API-Key`.
  - Returns: 0 accepted; **2** the hub answered 401/403 (a wrong key -- not a
    missing hub); 1 the hub did not answer or answered something else.

- hub_write_env file key value
  - Purpose: Upsert `KEY=value` in an env file, creating it when absent.
  - Behavior: Rewrites in place (follows a symlink, keeps the inode) rather
    than replacing the file; refuses a key that is not an environment
    variable name and a value containing a newline; keeps every other line.
  - Returns: 0; 1 on bad input or a write error.

- hub_latest_tag clone_dir
  - Purpose: Newest semver tag of a clone, fetched from origin first, a `v`
    prefix stripped. Offline, the local tags are what there is.
  - Returns: 0 and the tag; 1 when the directory is not a clone.

- hub_bootstrap clone_dir repo_url
  - Purpose: Make a local hub exist through the hub's own scripts.
  - Behavior: When `clone_dir` is absent: `git clone repo_url clone_dir`,
    then the hub's `./start --configure-superuser` (interactive, once) and
    `./install-service`; prints the `loginctl enable-linger` step rather
    than running it. When present: `./install-service --dry-run` only.
    Never runs compose. The repository URL is an argument -- this library
    names no repository.
  - Returns: 0; 1 when the URL is missing and the clone is absent, the clone
    fails, or the hub's scripts fail.

- hub_offer_update url clone_dir
  - Purpose: Compare the version the running hub reports with the newest
    tag in its clone and, when behind, offer the hub's own `./update`.
  - Behavior: With a person (`dialog` or `plain`): ask; on yes `exec
    clone_dir/update`. Without one (`none`): print the versions and the
    command. With `HUB_MODE=remote`: print only -- a remote hub is updated
    where it runs. An up-to-date hub gets no offer.
  - Returns: 0 (a declined or impossible offer is not a failure); 1 on
    missing arguments. Does not return when `./update` is exec'd.

- hub_setup_dialog env_file [--mode local|remote] [--url URL] [--key KEY] [--hub-dir DIR] [--repo-url URL] [--client NAME]
  - Purpose: The install-time question, end to end. Every answer comes from
    a flag, else the environment / `env_file` (`HUB_MODE`, `HUB_URL`,
    `HUB_API_KEY`, `HUB_DIR`, `HUB_REPO_URL`), else a prompt -- and with no
    terminal, nothing is asked and the run fails naming the variable.
  - Behavior:
    - **remote**: URL (validated as `http(s)://host[:port]`; a warning for
      plain http to a non-loopback host) -> `hub_probe` -> key ->
      `hub_check_key` (a 401 is reported as a wrong key and, with a person,
      offers another) -> writes `HUB_MODE`, `HUB_URL`, `HUB_API_KEY`,
      `HUB_INSTANCE_ID`.
    - **local**: `hub_bootstrap` (clone dir defaults to
      `../$HUB_CLONE_NAME` (default `../hub`) beside the env file's directory; the clone URL
      must be given when the clone is absent) -> URL defaults to
      `http://localhost:<BACKEND_PORT>` from the hub's `.env` or
      `env.example` -> the same probe and key steps; when no key is known it
      prints the hub's `./manage issue_api_key` command and asks for the
      result -> also writes `HUB_DIR`.
  - Returns: 0 with the hub answering and the key accepted; 1 otherwise
    (nothing is written before the key is accepted); 2 on an unknown option
    or a flag missing its value.
  - Dependencies: curl, git; `env` (`resolve_env_value`), `version`
    (`version_compare`), `dialog` (`dialog_init`) -- sourced automatically
    when not already imported.

Environment
-----------

- `HUB_UI` -- force `dialog`, `plain` or `none`.
- `HUB_SETUP_PLAIN` -- set to anything to prefer plain prompts over `dialog`.
- `HUB_MODE`, `HUB_URL`, `HUB_API_KEY`, `HUB_INSTANCE_ID`, `HUB_DIR`,
  `HUB_REPO_URL` -- read from the environment or the env file; the first
  four are what `hub_setup_dialog` writes.
- `HUB_CLIENT_NAME` -- default for `--client`, used in the `issue_api_key`
  hint.
- `HUB_CLONE_NAME` -- directory name of a local hub clone beside the client
  (default `hub`), when `--hub-dir` / `HUB_DIR` is not given.

Examples
--------

```bash
shlib_import hub

# Install time: ask, prove, record. Re-runnable.
HUB_CLONE_NAME=my-hub hub_setup_dialog .env --client "my-scanner" --repo-url "$HUB_REPO_URL"

# CI or a unit: no terminal, so everything comes from the environment.
HUB_MODE=remote HUB_URL=http://203.0.113.7:8000 HUB_API_KEY="$KEY" hub_setup_dialog .env

# Start time, local mode: offer the hub's own ./update when it is behind.
load_env .env
if [[ "${HUB_MODE:-}" == "local" ]]; then
  hub_offer_update "$HUB_URL" "${HUB_DIR:-../my-hub}"
fi
```
