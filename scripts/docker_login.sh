#!/usr/bin/env bash
# SCRIPT: docker_login.sh
# DESCRIPTION: Log the docker CLI in to a registry with the credential read
#              from the environment and handed to `docker login
#              --password-stdin`, so it is in no argument list and no log;
#              no third-party action. `--logout` ends the session again. An
#              Amazon ECR host is refused: the replaced action exchanged an
#              access key for a login password there, which this script does
#              not do; run `aws ecr get-login-password` in the caller and pass
#              the result as the token.
# USAGE: REGISTRY_PASSWORD=... bash scripts/docker_login.sh [--logout]
# PARAMETERS:
#   --logout     Run `docker logout` for REGISTRY instead of logging in.
#   -h, --help   Show this help message.
# ENVIRONMENT:
#   REGISTRY           Registry host (empty: Docker Hub).
#   REGISTRY_USERNAME  Login user (required for a login).
#   REGISTRY_PASSWORD  Password or token (required for a login; never printed).
# EXIT CODES:
#   0  Logged in (or out).
#   1  docker login or logout failed.
#   2  No docker on PATH, an empty username or password, an ECR host, or a
#      usage error.
# ----------------------------------------------------
set -euo pipefail

registry="${REGISTRY:-}"
username="${REGISTRY_USERNAME:-}"
logout=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logout) logout=true; shift ;;
    -h|--help) grep '^#[^!]' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "::error::docker is not on PATH." >&2; exit 2; }

if [[ "$registry" =~ [[:space:]] ]]; then
  echo "::error::REGISTRY '$registry' holds whitespace; name one host." >&2
  exit 2
fi

if [[ "$logout" == true ]]; then
  if [[ -n "$registry" ]]; then
    docker logout "$registry" || { echo "::error::docker logout $registry failed." >&2; exit 1; }
  else
    docker logout || { echo "::error::docker logout failed." >&2; exit 1; }
  fi
  exit 0
fi

ecr_re='^([0-9]{12}\.dkr\.ecr(-fips)?\.[a-z0-9-]+\.amazonaws\.com(\.cn)?|public\.ecr\.aws)$'
if [[ "$registry" =~ $ecr_re ]]; then
  echo "::error::'$registry' is an Amazon ECR host. This step runs docker login with the token as given; get one with 'aws ecr get-login-password' in the caller and pass it as registry_token with registry_username AWS." >&2
  exit 2
fi
[[ -n "$username" ]] || { echo "::error::REGISTRY_USERNAME is empty." >&2; exit 2; }
[[ -n "${REGISTRY_PASSWORD:-}" ]] || { echo "::error::REGISTRY_PASSWORD is empty; pass the registry token as a secret." >&2; exit 2; }

args=(login --username "$username" --password-stdin)
if [[ -n "$registry" ]]; then
  args+=("$registry")
  echo "Logging in to $registry as $username"
else
  echo "Logging in to Docker Hub as $username"
fi
# The password reaches docker on stdin only: not in argv, not in this log.
if ! printf '%s' "$REGISTRY_PASSWORD" | docker "${args[@]}"; then
  echo "::error::docker login ${registry:-Docker Hub} as $username failed." >&2
  exit 1
fi
