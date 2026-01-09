# ports

Port utilities to inspect listeners and detect conflicts for commonly used env-driven ports.

Environment
-----------

- `PORT_DETECTION_ALLOW_SUDO` — when `true`, attempts certain checks with sudo if the non-sudo command returns nothing. Default: `false`.

Functions
---------

- list_port_usage_details port
  - Purpose: Print human-friendly details like `process (PID 1234, user bob)` for listeners on a TCP port.
  - Behavior: Tries `lsof`, then `ss`, then `netstat`. With sudo (if allowed) as a fallback.
  - Returns: 0 and prints lines if any found; 1 if nothing could be determined.

- list_port_listener_pids port
  - Purpose: Print the PIDs that are listening on a TCP port.
  - Behavior: Similar detection strategy as above; prints unique PIDs found.

- port_in_use_by port
  - Purpose: Print process details for listeners on a TCP port, or nothing if unused.
  - Behavior: Wraps `list_port_usage_details` and prints detail lines when found.
  - Returns: 0 and prints details if any found; non-zero with no output if unused.

- check_required_ports_available [env_file=.env]
  - Purpose: Check a common set of env vars → ports for conflicts on the local machine.
  - Uses `REQUIRED_PORT_DEFAULTS` to know which variables to examine (with defaults):
    - `TRAEFIK_HTTP_PORT:80`, `TRAEFIK_DASHBOARD_PORT:8081`, `ELASTICSEARCH_PORT:9200`,
      `ELASTICSEARCH_TRANSPORT_PORT:9300`, `REDIS_PORT:6379`, `POSTGRES_PORT:5432`,
      `OLLAMA_PORT:11434`, `BACKEND_PORT:8000`, `FRONTEND_PORT:3000`, `API_PORT:8080`.
  - Side effects: Populates globals for callers to inspect and render:
    - `REQUIRED_PORT_CONFLICT_MESSAGES` — array of detailed messages.
    - `REQUIRED_PORT_CONFLICT_SUMMARIES` — array of short summaries.
    - `REQUIRED_PORT_CONFLICTS_JSON` — JSON array with `{port, variables[], details[]}`.
  - Returns: 0 if no conflicts detected; non-zero otherwise.

Dependencies
------------

- `lsof`/`ss`/`netstat`/`fuser` (any subset available), optional `sudo` when allowed.
