# browser

Open URLs and optionally wait for a frontend service to become available.

Functions
---------

- check_port port [host=localhost]
  - Purpose: TCP connect test using `nc` or `telnet`.
  - Returns: success when the port is reachable.

- open_url url
  - Purpose: Open a URL in the default browser (Linux/macOS/Windows shells).
  - Behavior: Tries `xdg-open`, `open`, `gio`, or `cmd.exe /c start`.

- open_frontend_when_ready [max_wait_seconds=120]
  - Purpose: Wait for a `frontend` compose service to be running and its port to accept connections, then open the URL.
  - Env:
    - `FRONTEND_HOST` (default `localhost`)
    - `FRONTEND_PORT` (default `3000`)
    - `COMPOSE_ARGS` (optional array) — additional args for `docker_compose`.
  - Behavior: Waits up to `max_wait_seconds` and logs progress; opens the URL even on timeout.

Dependencies
------------

- `nc` or `telnet` for port checks; `docker compose`/`docker-compose` for service checks; platform opener.

