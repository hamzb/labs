#!/usr/bin/env bash
# Samples replica worker service, transaction, and commit-wait activity into a CSV file.

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
  MYSQL_REPLICA_HOST \
  MYSQL_REPLICA_PORT; do
  if [[ ! -v "${variable}" || -z "${!variable}" ]]; then
    echo "${variable} must be set to a non-empty value in ${LAB_DIR}/.env." >&2
    exit 1
  fi
done

output_file="${1:-}"
duration="${2:-60}"
interval="${3:-1}"

if [[ -z "${output_file}" ]]; then
  echo "Usage: $0 <output.csv> [duration-seconds] [interval-seconds]" >&2
  exit 1
fi

if [[ ! "${duration}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Duration must be a positive integer." >&2
  exit 1
fi

if [[ ! "${interval}" =~ ^[1-9][0-9]*$ ]] || (( interval > 60 )); then
  echo "Interval must be an integer between 1 and 60 seconds." >&2
  exit 1
fi

if ! command -v mysql >/dev/null 2>&1; then
  echo "MySQL client is not installed. Run: ./scripts/setup/install-host-dependencies.sh" >&2
  exit 1
fi

resolved_output="$(realpath -m "${output_file}")"
mkdir -p "$(dirname -- "${resolved_output}")"

mysql_command=(
  mysql
  --protocol=TCP
  --host="${MYSQL_REPLICA_HOST}"
  --port="${MYSQL_REPLICA_PORT}"
  --user="${MYSQL_ADMIN_USER}"
  --batch
  --raw
  --skip-column-names
)

activity_query="
SELECT CONCAT_WS(
  CHAR(9),
  COUNT(*),
  COALESCE(SUM(w.SERVICE_STATE = 'ON'), 0),
  COALESCE(SUM(NULLIF(w.APPLYING_TRANSACTION, '') IS NOT NULL), 0),
  COALESCE(SUM(t.PROCESSLIST_STATE = 'Waiting for preceding transaction to commit'), 0),
  COALESCE(SUM(t.PROCESSLIST_STATE = 'Waiting for an event from Coordinator'), 0)
)
FROM performance_schema.replication_applier_status_by_worker AS w
LEFT JOIN performance_schema.threads AS t
  ON t.THREAD_ID = w.THREAD_ID;
"

printf 'timestamp_utc,elapsed_seconds,worker_slots,workers_on,applying_transactions,waiting_to_commit,waiting_for_coordinator\n' \
  > "${resolved_output}"

started_at="$(date +%s)"
next_sample_at="${started_at}"

while true; do
  current_time="$(date +%s)"
  if (( next_sample_at > current_time )); then
    sleep $((next_sample_at - current_time))
  fi

  activity="$(
    MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" "${mysql_command[@]}" \
      --execute="${activity_query}"
  )"
  IFS=$'\t' read -r worker_slots workers_on applying waiting_to_commit waiting_for_coordinator \
    <<<"${activity}"

  sampled_at="$(date +%s)"
  elapsed=$((sampled_at - started_at))
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -z "${worker_slots}" || -z "${workers_on}" || -z "${applying}" ]]; then
    echo "Unable to parse replica worker activity." >&2
    exit 1
  fi

  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "${timestamp}" \
    "${elapsed}" \
    "${worker_slots}" \
    "${workers_on}" \
    "${applying}" \
    "${waiting_to_commit}" \
    "${waiting_for_coordinator}" \
    >> "${resolved_output}"

  if (( elapsed >= duration )); then
    break
  fi

  next_sample_at=$((sampled_at + interval))
done

echo "Replica worker activity samples written to ${resolved_output}"
