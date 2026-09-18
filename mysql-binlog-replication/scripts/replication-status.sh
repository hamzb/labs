#!/usr/bin/env bash
# Reports replication health, lag, GTID progress, and the most recent replication errors.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

cd "${LAB_DIR}"

if [[ ! -f .env ]]; then
  echo "Missing ${LAB_DIR}/.env. Create it from .env.example and set every required value." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

for variable in MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD; do
  if [[ ! -v "${variable}" || -z "${!variable}" ]]; then
    echo "${variable} must be set to a non-empty value in ${LAB_DIR}/.env." >&2
    exit 1
  fi
done

if ! docker compose ps --status running --services | grep -qx replica; then
  echo "The replica service is not running. Start the lab with: docker compose up -d" >&2
  exit 1
fi

replica_mysql() {
  docker compose exec -T \
    -e MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" \
    replica mysql --user="${MYSQL_ADMIN_USER}" "$@"
}

replica_status="$(replica_mysql --vertical --execute='SHOW REPLICA STATUS')"

if [[ -z "${replica_status}" ]]; then
  echo "Replication is not configured. Run: ./scripts/setup-replication.sh" >&2
  exit 1
fi

status_value() {
  local field="$1"

  sed -n "s/^[[:space:]]*${field}: //p" <<<"${replica_status}"
}

io_state="$(status_value Replica_IO_Running)"
sql_state="$(status_value Replica_SQL_Running)"
retrieved_gtid_set="$(
  replica_mysql --batch --skip-column-names \
    --execute="SELECT COALESCE(REPLACE(RECEIVED_TRANSACTION_SET, CHAR(10), ' '), '') FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME = '';"
)"
executed_gtid_set="$(
  replica_mysql --batch --skip-column-names \
    --execute="SELECT REPLACE(@@GLOBAL.gtid_executed, CHAR(10), ' ');"
)"

for field in \
  Source_Host \
  Source_Port \
  Source_User \
  Replica_IO_Running \
  Replica_SQL_Running \
  Seconds_Behind_Source \
  Last_IO_Error \
  Last_SQL_Error; do
  printf '%-28s %s\n' "${field}:" "$(status_value "${field}")"
done

printf '%-28s %s\n' "Retrieved_Gtid_Set:" "${retrieved_gtid_set}"
printf '%-28s %s\n' "Executed_Gtid_Set:" "${executed_gtid_set}"

if [[ "${io_state}" != "Yes" || "${sql_state}" != "Yes" ]]; then
  exit 1
fi
