#!/usr/bin/env bash
# Verifies end-to-end replication by writing on the primary and reading the result on the replica.

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

for service in primary replica; do
  if ! docker compose ps --status running --services | grep -qx "${service}"; then
    echo "The ${service} service is not running. Start the lab with: docker compose up -d" >&2
    exit 1
  fi
done

mysql_service() {
  local service="$1"
  shift

  docker compose exec -T \
    -e MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" \
    "${service}" mysql --user="${MYSQL_ADMIN_USER}" "$@"
}

replica_status="$(mysql_service replica --vertical --execute='SHOW REPLICA STATUS')"
io_state="$(sed -n 's/^[[:space:]]*Replica_IO_Running: //p' <<<"${replica_status}")"
sql_state="$(sed -n 's/^[[:space:]]*Replica_SQL_Running: //p' <<<"${replica_status}")"

if [[ "${io_state}" != "Yes" || "${sql_state}" != "Yes" ]]; then
  echo "Replication is not healthy. Run ./scripts/replication-status.sh for details." >&2
  exit 1
fi

test_token="smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$"

mysql_service primary <<SQL
CREATE DATABASE IF NOT EXISTS replication_lab;
CREATE TABLE IF NOT EXISTS replication_lab.replication_smoke_test (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  test_token VARCHAR(64) NOT NULL,
  test_state VARCHAR(32) NOT NULL,
  source_created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uq_replication_smoke_test_token (test_token)
) ENGINE = InnoDB;

INSERT INTO replication_lab.replication_smoke_test (test_token, test_state)
VALUES ('${test_token}', 'inserted');

UPDATE replication_lab.replication_smoke_test
SET test_state = 'updated'
WHERE test_token = '${test_token}';
SQL

replicated_state=""

for _ in {1..30}; do
  replicated_state="$(
    mysql_service replica --batch --skip-column-names \
      --execute="SELECT test_state FROM replication_lab.replication_smoke_test WHERE test_token = '${test_token}';" \
      2>/dev/null || true
  )"

  if [[ "${replicated_state}" == "updated" ]]; then
    echo "Replication smoke test passed."
    echo "  Test token: ${test_token}"
    echo "  Replica state: ${replicated_state}"
    exit 0
  fi

  sleep 1
done

echo "The test row did not reach the replica in its final state within 30 seconds." >&2
echo "Test token: ${test_token}" >&2
exit 1
