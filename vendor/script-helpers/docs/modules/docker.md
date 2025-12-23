# docker

Docker/Docker Compose helpers: compose command detection, wrappers, waiting, and status.

Functions
---------

- get_docker_compose_cmd
  - Purpose: Prefer `docker compose` (v2) and fallback to `docker-compose` (v1).
  - Returns: prints the command to stdout; non-zero if neither is available.

- docker_compose args...
  - Purpose: Wrapper that runs the detected compose command with given args.
  - Example: `docker_compose ps`.

- run_docker_compose args...
  - Purpose: Compatibility alias for `docker_compose`.

- run_docker_compose_command "subcommand and args"
  - Purpose: Helper that accepts a single combined string (compatibility with some callers).

- check_docker
  - Purpose: Verify Docker is installed and the daemon is running/reachable.
  - Behavior: Checks the Docker CLI exists, then runs `docker info`; provides specific errors for missing CLI, permission denied, or a stopped daemon.

- check_project_root
  - Purpose: Ensure `docker-compose.yml` is present in the current directory.

- wait_for_service service_name [max_wait=60]
  - Purpose: Wait until a compose service appears as running.
  - Behavior: Prints progress (every ~10s) and errors on timeout.

- docker_status
  - Purpose: Show running containers and compose services summary with glyphs.
  - Output:
    - From `docker ps`: name, image, status, running-for, ports.
    - From `docker compose`: for each service: `✅` running (with since), `💥` failed, or `✖️` not running.

Dependencies
------------

- Docker CLI and either `docker compose` or `docker-compose`.
