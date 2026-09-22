#!/usr/bin/env bash
# Configures GTID-based replication and verifies that both replica threads are running.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

cd "${LAB_DIR}"

if [[ ! -f .env ]]; then
  echo "Missing ${LAB_DIR}/.env. Create it from .env.example and set every required value." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

for variable in \
  MYSQL_ROOT_PASSWORD \
  MYSQL_REPLICATION_USER \
  MYSQL_REPLICATION_PASSWORD; do
  if [[ ! -v "${variable}" || -z "${!variable}" ]]; then
    echo "${variable} must be set to a non-empty value in ${LAB_DIR}/.env." >&2
    exit 1
  fi
done

sql_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\'/\'\'}"
  printf '%s' "${value}"
}

replica_mysql() {
  docker compose exec -T \
    -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" \
    replica mysql --user=root "$@"
}

if ! docker compose ps --status running --services | grep -qx replica; then
  echo "The replica service is not running. Start the lab with: docker compose up -d" >&2
  exit 1
fi

replication_user="$(sql_escape "${MYSQL_REPLICATION_USER}")"
replication_password="$(sql_escape "${MYSQL_REPLICATION_PASSWORD}")"

configured_channels="$(
  replica_mysql --batch --skip-column-names \
    --execute='SELECT COUNT(*) FROM performance_schema.replication_connection_configuration;'
)"

if [[ "${configured_channels}" != "0" ]]; then
  replica_mysql --execute='STOP REPLICA;'
fi

replica_mysql <<SQL
RESET REPLICA ALL;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = 'primary',
  SOURCE_PORT = 3306,
  SOURCE_USER = '${replication_user}',
  SOURCE_PASSWORD = '${replication_password}',
  SOURCE_AUTO_POSITION = 1,
  SOURCE_CONNECT_RETRY = 2,
  GET_SOURCE_PUBLIC_KEY = 1;
START REPLICA;
SQL

io_state="Connecting"
sql_state="No"

for _ in {1..30}; do
  replica_status="$(replica_mysql --vertical --execute='SHOW REPLICA STATUS')"
  io_state="$(sed -n 's/^[[:space:]]*Replica_IO_Running: //p' <<<"${replica_status}")"
  sql_state="$(sed -n 's/^[[:space:]]*Replica_SQL_Running: //p' <<<"${replica_status}")"

  if [[ "${io_state}" == "Yes" && "${sql_state}" == "Yes" ]]; then
    echo "Replication is running."
    echo "  Replica_IO_Running:  ${io_state}"
    echo "  Replica_SQL_Running: ${sql_state}"
    exit 0
  fi

  sleep 1
done

echo "Replication did not become healthy within 30 seconds." >&2
sed -n \
  -e '/^[[:space:]]*Replica_IO_Running:/p' \
  -e '/^[[:space:]]*Replica_SQL_Running:/p' \
  -e '/^[[:space:]]*Last_IO_Error:/p' \
  -e '/^[[:space:]]*Last_SQL_Error:/p' \
  <<<"${replica_status}" >&2
exit 1
