#!/usr/bin/env bash
# SCRIPT: ci_wp_phpunit.sh
# DESCRIPTION: Run a WordPress plugin's PHPUnit tests against the WordPress test suite, in CI or locally.
# USAGE: scripts/ci_wp_phpunit.sh [options]
# PARAMETERS:
#   --wp-version <version>        Full X.Y.Z, a minor like 7.1, or "latest" (default: latest).
#   --wp-tests-dir <path>         Absolute path for the test library (default: /tmp/wordpress-tests-lib).
#   --wp-core-dir <path>          Absolute path for WordPress core (default: /tmp/wordpress).
#   --multisite <0|1>             Run the suite as multisite (default: 0).
#   --db-host <host>              Database host (default: 127.0.0.1).
#   --db-port <port>              Database port (default: 3306).
#   --db-name <name>              Database name (default: wordpress_test).
#   --db-user <user>              Database user (default: wordpress).
#   --db-password <password>      Database password (default: wordpress).
#   --db-image <image>            Start this database in Docker and stop it afterwards. Empty means
#                                 the database already exists (default: empty).
#   --db-wait-seconds <seconds>   Max seconds to wait for a started database (default: 60).
#   --workdir <path>              Plugin directory to run the tests from (default: .).
#   --php-image <image>           Run the tests in this PHP image instead of on the host. Empty
#                                 uses the host's PHP (default: empty).
#   --docker-user <user>          User for --php-image, as uid:gid or a name. Empty runs as the
#                                 image's default, usually root (default: the invoking user).
#   --test-command <command>      Command that runs the tests (default: ./vendor/bin/phpunit).
#   --skip-provision <true|false> Reuse an existing test library rather than downloading (default: false).
#   -h, --help                    Show this help message.
# ----------------------------------------------------
#
# A plugin's tests/bootstrap.php is written against the WordPress test library,
# which expects WP_TESTS_DIR to hold includes/functions.php and a
# wp-tests-config.php naming a real database. Plugins normally carry a
# bin/install-wp-tests.sh to provide that; this replaces it, so the same
# provisioning runs in CI and on a laptop.
#
# The library and core come from one wordpress-develop tarball, so they cannot
# disagree about the version under test. Fetching core from wordpress.org
# separately is how those two drift apart.
#
# With --db-image the database runs in Docker and is removed on exit, which is
# what makes this usable locally. In CI the database usually already exists, so
# the default starts nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help docker

usage() { show_help "${BASH_SOURCE[0]}"; }

wp_version="latest"
wp_tests_dir="/tmp/wordpress-tests-lib"
wp_core_dir="/tmp/wordpress"
multisite="0"
db_host="127.0.0.1"
db_port="3306"
db_name="wordpress_test"
db_user="wordpress"
db_password="wordpress"
db_image=""
db_wait_seconds="60"
workdir="."
php_image=""
docker_user="$(id -u):$(id -g)"
test_command="./vendor/bin/phpunit"
skip_provision="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wp-version) wp_version="$2"; shift 2 ;;
    --wp-tests-dir) wp_tests_dir="$2"; shift 2 ;;
    --wp-core-dir) wp_core_dir="$2"; shift 2 ;;
    --multisite) multisite="$2"; shift 2 ;;
    --db-host) db_host="$2"; shift 2 ;;
    --db-port) db_port="$2"; shift 2 ;;
    --db-name) db_name="$2"; shift 2 ;;
    --db-user) db_user="$2"; shift 2 ;;
    --db-password) db_password="$2"; shift 2 ;;
    --db-image) db_image="$2"; shift 2 ;;
    --db-wait-seconds) db_wait_seconds="$2"; shift 2 ;;
    --workdir) workdir="$2"; shift 2 ;;
    --php-image) php_image="$2"; shift 2 ;;
    --docker-user) docker_user="$2"; shift 2 ;;
    --test-command) test_command="$2"; shift 2 ;;
    --skip-provision) skip_provision="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

# Both are handed to `rm -rf` below and both are caller input. Requiring an
# absolute path, and refusing "/" and the working directory, is what stops
# `--wp-tests-dir .` from deleting the plugin being tested.
for d in "$wp_tests_dir" "$wp_core_dir"; do
  case "$d" in
    /?*) : ;;
    *) log_error "--wp-tests-dir and --wp-core-dir must be absolute paths; got '${d}'"; exit 2 ;;
  esac
  if [[ "$d" == "/" || "$d" == "$PWD" ]]; then
    log_error "Refusing to use '${d}' as a scratch directory."
    exit 2
  fi
done

if [[ ! -d "$workdir" ]]; then
  log_error "--workdir does not exist: ${workdir}"
  exit 2
fi

# ---------------------------------------------------------------------------
# Resolve the version to a real tag.
#
# wordpress-develop tags are always X.Y.Z. Requesting "7.1" answers 404 with a
# message about a missing ref, which says nothing about versions, so a bare
# minor is resolved here instead.
# ---------------------------------------------------------------------------
resolve_wp_tag() {
  local want="$1"
  if [[ "$want" == "latest" ]]; then
    curl -fsSL "https://api.wordpress.org/core/version-check/1.7/" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["offers"][0]["current"])'
    return
  fi
  if [[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$want"
    return
  fi
  curl -fsSL "https://api.github.com/repos/WordPress/wordpress-develop/tags?per_page=100" \
    | WANT="$want" python3 -c '
import json, os, sys
want = os.environ["WANT"]
tags = [t["name"] for t in json.load(sys.stdin)]
match = [t for t in tags if t == want or t.startswith(want + ".")]
if not match:
    sys.exit("no wordpress-develop tag matches " + want)
print(sorted(match, key=lambda v: [int(p) for p in v.split(".")])[-1])
'
}

# ---------------------------------------------------------------------------
# Optional database, so this is runnable without one already present.
# ---------------------------------------------------------------------------
db_container=""
db_network=""
cleanup() {
  if [[ -n "$db_container" ]]; then
    log_info "Removing database container ${db_container}"
    # -v as well as -f: the mysql and postgres images declare a VOLUME, so
    # `docker run -d` creates an anonymous volume for every container. Without
    # -v the container goes and the volume stays -- three runs of this script
    # left 612 MB of orphans on a laptop before anyone noticed. -v removes only
    # anonymous volumes; a named one passed by a caller is left alone.
    docker rm -f -v "$db_container" >/dev/null 2>&1 || true
  fi
  if [[ -n "$db_network" ]]; then
    docker network rm "$db_network" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

start_database() {
  db_container="wp-phpunit-db-$$"
  local net_args=()
  if [[ -n "$php_image" ]]; then
    # A user-defined network rather than --network host: the PHP container
    # reaches the database by container name, which works the same on Linux
    # and macOS. Publishing to loopback would only work on Linux.
    db_network="wp-phpunit-net-$$"
    docker network create "$db_network" >/dev/null
    net_args=(--network "$db_network")
  fi
  # Publish the port only when the tests run on the host and need to reach it.
  # With --php-image they reach the database by container name on the shared
  # network, and publishing anyway fails the whole run with "port is already
  # allocated" whenever something else holds that port -- for a port nothing
  # was going to use.
  local publish=()
  if [[ -z "$php_image" ]]; then
    publish=(-p "${db_host}:${db_port}:3306")
    log_info "Starting ${db_image} as ${db_container} on ${db_host}:${db_port}"
  else
    log_info "Starting ${db_image} as ${db_container} on the ${db_network} network"
  fi

  # ${arr[@]+"${arr[@]}"}: bash 3.2, which macOS still ships, treats an empty
  # array as an unbound variable under `set -u`. Both arrays are empty in one
  # mode or the other.
  docker run -d --name "$db_container" \
    ${net_args[@]+"${net_args[@]}"} \
    ${publish[@]+"${publish[@]}"} \
    -e MYSQL_DATABASE="$db_name" \
    -e MYSQL_USER="$db_user" \
    -e MYSQL_PASSWORD="$db_password" \
    -e MYSQL_ROOT_PASSWORD="root" \
    "$db_image" >/dev/null

  # Poll rather than sleep: the image is ready when it answers, and a fixed
  # sleep is either too short on a loaded machine or wasted time on a fast one.
  local waited=0
  while (( waited < db_wait_seconds )); do
    if docker exec "$db_container" sh -c 'mysqladmin ping -h 127.0.0.1 --silent' >/dev/null 2>&1; then
      log_info "Database ready after ${waited}s"
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  log_error "Database did not become ready within ${db_wait_seconds}s"
  exit 1
}

[[ -n "$db_image" ]] && start_database

# Where the tests will reach the database from. Inside a PHP container on the
# shared network that is the database container's name on 3306; on the host it
# is whatever was published. Writing 127.0.0.1 into the config and then running
# the tests in a container points them at the container itself.
if [[ -n "$php_image" && -n "$db_container" ]]; then
  config_db_host="${db_container}:3306"
else
  # Inside a container, 127.0.0.1 is that container, not the machine. A caller
  # running the tests in an image against their own database has to name a
  # host the container can reach, so refuse the combination rather than write
  # a config that points the tests at themselves and fails as "connection
  # refused" with nothing to say why.
  if [[ -n "$php_image" ]]; then
    case "$db_host" in
      127.0.0.1|localhost|::1)
        log_error "--php-image runs the tests in a container, where '${db_host}' is that container."
        log_error "Pass --db-image to have one started, or --db-host with an address the container can reach."
        exit 2
        ;;
    esac
  fi
  config_db_host="${db_host}:${db_port}"
fi

# ABSPATH as the tests will see it: the mount point inside the container, or
# the real path when they run on the host.
if [[ -n "$php_image" ]]; then
  config_core_dir="/wp-core"
else
  config_core_dir="$wp_core_dir"
fi

# ---------------------------------------------------------------------------
# Provision the test library and core.
# ---------------------------------------------------------------------------
if [[ "$skip_provision" == "true" ]]; then
  if [[ ! -f "${wp_tests_dir}/includes/functions.php" ]]; then
    log_error "--skip-provision was given but ${wp_tests_dir}/includes/functions.php is absent."
    exit 1
  fi
  log_info "Reusing the test library already in ${wp_tests_dir}"
else
  wp_tag="$(resolve_wp_tag "$wp_version")"
  log_info "WordPress under test: ${wp_tag} (requested '${wp_version}')"

  rm -rf "$wp_tests_dir" "$wp_core_dir"
  mkdir -p "$wp_tests_dir" "$wp_core_dir"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"; cleanup' EXIT
  curl -fsSL -o "${tmp}/wordpress-develop.tar.gz" \
    "https://github.com/WordPress/wordpress-develop/archive/refs/tags/${wp_tag}.tar.gz"
  tar -xzf "${tmp}/wordpress-develop.tar.gz" -C "$tmp"

  root="${tmp}/wordpress-develop-${wp_tag}"
  if [[ ! -d "${root}/tests/phpunit/includes" ]]; then
    log_error "${wp_tag} has no tests/phpunit/includes; the tarball layout changed."
    exit 1
  fi

  cp -R "${root}/tests/phpunit/." "${wp_tests_dir}/"
  cp -R "${root}/src/." "${wp_core_dir}/"

  # Written from the sample, so a constant added upstream is carried rather
  # than dropped. Values arrive as environment and are escaped for a PHP
  # single-quoted string: the sample writes them between single quotes, so a
  # password containing one ends the string early and the config stops parsing.
  cp "${root}/wp-tests-config-sample.php" "${wp_tests_dir}/wp-tests-config.php"
  WP_CORE_DIR="$config_core_dir" \
  WP_DB_NAME="$db_name" \
  WP_DB_USER="$db_user" \
  WP_DB_PASSWORD="$db_password" \
  WP_DB_HOST="$config_db_host" \
  python3 - "${wp_tests_dir}/wp-tests-config.php" <<'PY'
import os, sys

path = sys.argv[1]
text = open(path).read()


def php(value):
    """Escape for a PHP single-quoted string: only \\ and ' are special there."""
    return value.replace("\\", "\\\\").replace("'", "\\'")


subs = {
    "dirname( __FILE__ ) . '/src/'": "'%s/'" % php(os.environ["WP_CORE_DIR"].rstrip("/")),
    "youremptytestdbnamehere": php(os.environ["WP_DB_NAME"]),
    "yourusernamehere": php(os.environ["WP_DB_USER"]),
    "yourpasswordhere": php(os.environ["WP_DB_PASSWORD"]),
    "localhost": php(os.environ["WP_DB_HOST"]),
}
for old, new in subs.items():
    if old not in text:
        sys.exit("wp-tests-config-sample.php no longer contains %r" % old)
    text = text.replace(old, new, 1)
open(path, "w").write(text)
PY
  log_info "Test library in ${wp_tests_dir}, core in ${wp_core_dir}"
fi

# ---------------------------------------------------------------------------
# Run the tests.
# ---------------------------------------------------------------------------
export WP_TESTS_DIR="$wp_tests_dir"
export WP_CORE_DIR="$wp_core_dir"
export WP_TESTS_CONFIG_FILE_PATH="${wp_tests_dir}/wp-tests-config.php"
export WP_MULTISITE="$multisite"

log_info "Running: ${test_command}"
if [[ -z "$php_image" ]]; then
  (
    cd "$workdir"
    eval "$test_command"
  )
else
  abs_workdir="$(cd "$workdir" && pwd -P)"
  # As the invoking user, not root. PHPUnit writes .phpunit.cache into the
  # working directory; owned by root it cannot be deleted afterwards without
  # Docker, which leaves undeletable files in the caller's repository.
  # HOME with it: a uid the image does not know has no home, and composer and
  # phpunit both want somewhere to write.
  user_args=()
  if [[ -n "$docker_user" ]]; then
    user_args=(-u "$docker_user" -e HOME=/tmp)
  fi

  docker_args=(docker run --rm -t
    ${user_args[@]+"${user_args[@]}"}
    -v "${abs_workdir}":/work
    -v "${wp_tests_dir}":/wp-tests
    -v "${wp_core_dir}":/wp-core
    -w /work
    -e WP_TESTS_DIR=/wp-tests
    -e WP_CORE_DIR=/wp-core
    -e WP_TESTS_CONFIG_FILE_PATH=/wp-tests/wp-tests-config.php
    -e WP_MULTISITE="$multisite")
  [[ -n "$db_network" ]] && docker_args+=(--network "$db_network")
  # bash -c, not -lc: a login shell sources /etc/profile and replaces PATH with
  # a default built for a shell session. See ci_go.sh.
  "${docker_args[@]}" "$php_image" bash -c "$test_command"
fi
