#!/usr/bin/env bash
# Resets, seeds, and verifies the deterministic order-management workload dataset.

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
  MYSQL_ADMIN_USER \
  MYSQL_ADMIN_PASSWORD \
  MYSQL_APP_USER \
  MYSQL_APP_PASSWORD; do
  if [[ ! -v "${variable}" || -z "${!variable}" ]]; then
    echo "${variable} must be set to a non-empty value in ${LAB_DIR}/.env." >&2
    exit 1
  fi
done

order_count="${1:-100000}"
tenant_count="${2:-16}"

if [[ ! "${order_count}" =~ ^[1-9][0-9]*$ ]] || (( order_count > 1000000 )); then
  echo "Order count must be an integer between 1 and 1000000." >&2
  exit 1
fi

if [[ ! "${tenant_count}" =~ ^[1-9][0-9]*$ ]] || (( tenant_count > order_count )); then
  echo "Tenant count must be a positive integer no greater than the order count." >&2
  exit 1
fi

for service in primary replica; do
  if ! docker compose ps --status running --services | grep -qx "${service}"; then
    echo "The ${service} service is not running. Start the lab with: docker compose up -d" >&2
    exit 1
  fi
done

if ! ./scripts/setup/replication-status.sh >/dev/null; then
  echo "Replication is not healthy. Run ./scripts/setup/replication-status.sh for details." >&2
  exit 1
fi

mysql_service() {
  local service="$1"
  shift

  docker compose exec -T \
    -e MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" \
    "${service}" mysql --user="${MYSQL_ADMIN_USER}" "$@"
}

sql_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\'/\'\'}"
  printf '%s' "${value}"
}

echo "Resetting order_management and seeding ${order_count} orders across ${tenant_count} tenants."

mysql_service primary --execute='DROP DATABASE IF EXISTS order_management;'
mysql_service primary < workload/schema.sql

app_user="$(sql_escape "${MYSQL_APP_USER}")"
app_password="$(sql_escape "${MYSQL_APP_PASSWORD}")"

mysql_service primary <<SQL
CREATE USER IF NOT EXISTS '${app_user}'@'%' IDENTIFIED BY '${app_password}';
ALTER USER '${app_user}'@'%' IDENTIFIED BY '${app_password}';
GRANT SELECT, UPDATE ON order_management.* TO '${app_user}'@'%';
SQL

mysql_service primary <<SQL
SET SESSION cte_max_recursion_depth = $((order_count + 1));

INSERT INTO order_management.orders (
  order_id,
  tenant_id,
  customer_id,
  status_code,
  total_amount_cents,
  version,
  payload
)
WITH RECURSIVE order_sequence (order_id) AS (
  SELECT 1
  UNION ALL
  SELECT order_id + 1
  FROM order_sequence
  WHERE order_id < ${order_count}
)
SELECT
  order_id,
  MOD(order_id - 1, ${tenant_count}) + 1,
  1000000 + order_id,
  0,
  1000 + MOD(order_id, 500000),
  0,
  RPAD(CONCAT('order-', order_id), 128, 'x')
FROM order_sequence;
SQL

signature_sql="SELECT CONCAT_WS('|', COUNT(*), MIN(order_id), MAX(order_id), COALESCE(SUM(version), 0), COUNT(DISTINCT tenant_id)) FROM order_management.orders;"
expected_signature="${order_count}|1|${order_count}|0|${tenant_count}"
primary_signature="$(
  mysql_service primary --batch --skip-column-names --execute="${signature_sql}"
)"

if [[ "${primary_signature}" != "${expected_signature}" ]]; then
  echo "Primary dataset verification failed: ${primary_signature}" >&2
  exit 1
fi

replica_signature=""

for _ in {1..120}; do
  replica_signature="$(
    mysql_service replica --batch --skip-column-names \
      --execute="${signature_sql}" 2>/dev/null || true
  )"

  if [[ "${replica_signature}" == "${expected_signature}" ]]; then
    echo "Workload dataset initialized and replicated."
    echo "  Orders:  ${order_count}"
    echo "  Tenants: ${tenant_count}"
    echo "  Dataset signature: ${replica_signature}"
    exit 0
  fi

  sleep 1
done

echo "The replica did not reach the expected dataset state within 120 seconds." >&2
echo "  Expected: ${expected_signature}" >&2
echo "  Replica:  ${replica_signature:-unavailable}" >&2
exit 1
