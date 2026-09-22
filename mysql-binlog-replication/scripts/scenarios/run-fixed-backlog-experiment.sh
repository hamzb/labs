#!/usr/bin/env bash
# Builds a fixed relay-log backlog, then measures isolated replica apply performance.

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
  MYSQL_APP_PASSWORD \
  MYSQL_REPLICA_HOST \
  MYSQL_REPLICA_PORT; do
  if [[ ! -v "${variable}" || -z "${!variable}" ]]; then
    echo "${variable} must be set to a non-empty value in ${LAB_DIR}/.env." >&2
    exit 1
  fi
done

tracking="${1:-}"
result_dir="${2:-}"
replica_workers="${3:-8}"
transactions="${4:-1000}"
updates_per_transaction="${5:-100}"
concurrency="${6:-1}"
order_count="${7:-100000}"

if [[ "${tracking}" != "COMMIT_ORDER" && "${tracking}" != "WRITESET" ]]; then
  echo "Dependency tracking must be COMMIT_ORDER or WRITESET." >&2
  echo "Usage: $0 <tracking> <result-dir> [workers] [transactions] [updates] [concurrency] [orders]" >&2
  exit 1
fi

if [[ -z "${result_dir}" ]]; then
  echo "A result directory is required." >&2
  echo "Usage: $0 <tracking> <result-dir> [workers] [transactions] [updates] [concurrency] [orders]" >&2
  exit 1
fi

for numeric_value in \
  "${replica_workers}" \
  "${transactions}" \
  "${updates_per_transaction}" \
  "${concurrency}" \
  "${order_count}"; do
  if [[ ! "${numeric_value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Worker, transaction, update, concurrency, and order values must be positive integers." >&2
    exit 1
  fi
done

if ! command -v mysql >/dev/null 2>&1; then
  echo "MySQL client is not installed. Run: ./scripts/setup/install-host-dependencies.sh" >&2
  exit 1
fi

resolved_result_dir="$(realpath -m "${result_dir}")"
if [[ -d "${resolved_result_dir}" ]] && find "${resolved_result_dir}" -mindepth 1 -print -quit | grep -q .; then
  echo "Result directory is not empty: ${resolved_result_dir}" >&2
  exit 1
fi
mkdir -p "${resolved_result_dir}"

primary_host="${MYSQL_PRIMARY_HOST:-127.0.0.1}"
primary_port="${MYSQL_PRIMARY_PORT:-33060}"

primary_mysql=(
  mysql --protocol=TCP --host="${primary_host}" --port="${primary_port}"
  --user="${MYSQL_ADMIN_USER}" --batch --raw
)
replica_mysql=(
  mysql --protocol=TCP --host="${MYSQL_REPLICA_HOST}" --port="${MYSQL_REPLICA_PORT}"
  --user="${MYSQL_ADMIN_USER}" --batch --raw
)

primary_query() {
  MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" "${primary_mysql[@]}" "$@"
}

replica_query() {
  MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" "${replica_mysql[@]}" "$@"
}

status_value() {
  local status="$1"
  local field="$2"
  sed -n "s/^[[:space:]]*${field}: //p" <<<"${status}"
}

lag_pid=""
activity_pid=""
sql_thread_stopped=false

stop_collectors() {
  local pid
  for pid in "${lag_pid}" "${activity_pid}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill -TERM "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  lag_pid=""
  activity_pid=""
}

cleanup() {
  stop_collectors
  if [[ "${sql_thread_stopped}" == true ]]; then
    replica_query --execute='START REPLICA SQL_THREAD;' >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

source_gtid_before="$(
  primary_query --skip-column-names --execute='SELECT @@GLOBAL.gtid_executed;'
)"
if [[ "$(replica_query --skip-column-names --execute="SELECT GTID_SUBSET('${source_gtid_before}', @@GLOBAL.gtid_executed);")" != "1" ]]; then
  echo "Replica must be fully caught up before the experiment." >&2
  exit 1
fi

primary_query --execute="SET GLOBAL binlog_transaction_dependency_tracking = '${tracking}';"
replica_query --execute="STOP REPLICA; SET GLOBAL replica_parallel_workers = ${replica_workers}; START REPLICA;"

if [[ "$(replica_query --skip-column-names --execute="SELECT WAIT_FOR_EXECUTED_GTID_SET('${source_gtid_before}', 300);")" != "0" ]]; then
  echo "Replica did not reach the pre-experiment GTID set." >&2
  exit 1
fi

replica_status="$(replica_query --vertical --execute='SHOW REPLICA STATUS')"
if [[ "$(status_value "${replica_status}" Replica_IO_Running)" != "Yes" || \
      "$(status_value "${replica_status}" Replica_SQL_Running)" != "Yes" || \
      "$(status_value "${replica_status}" Seconds_Behind_Source)" != "0" ]]; then
  echo "Replication is not healthy and caught up before backlog generation." >&2
  exit 1
fi

primary_query --execute="
SELECT
  @@GLOBAL.binlog_transaction_dependency_tracking AS dependency_tracking,
  @@GLOBAL.transaction_write_set_extraction AS write_set_extraction;
SHOW MASTER STATUS;
" > "${resolved_result_dir}/initial-primary-status.txt"
replica_query --execute="
SELECT
  @@GLOBAL.replica_parallel_workers AS parallel_workers,
  @@GLOBAL.replica_parallel_type AS parallel_type,
  @@GLOBAL.replica_preserve_commit_order AS preserve_commit_order;
SHOW REPLICA STATUS\G
" > "${resolved_result_dir}/initial-replica-status.txt"

replica_query --execute='STOP REPLICA SQL_THREAD;'
sql_thread_stopped=true

stopped_status="$(replica_query --vertical --execute='SHOW REPLICA STATUS')"
if [[ "$(status_value "${stopped_status}" Replica_IO_Running)" != "Yes" || \
      "$(status_value "${stopped_status}" Replica_SQL_Running)" != "No" ]]; then
  echo "Expected the receiver to run with the SQL thread stopped." >&2
  exit 1
fi
printf '%s\n' "${stopped_status}" > "${resolved_result_dir}/applier-stopped-status.txt"

workload_started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set +e
./scripts/scenarios/run-workload.sh \
  --mode independent \
  --concurrency "${concurrency}" \
  --transactions "${transactions}" \
  --order-count "${order_count}" \
  --updates-per-transaction "${updates_per_transaction}" \
  --report-interval 1 \
  2>&1 | tee "${resolved_result_dir}/workload.log"
workload_status=${PIPESTATUS[0]}
set -e
workload_finished_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if (( workload_status != 0 )); then
  echo "Workload failed with status ${workload_status}." >&2
  exit "${workload_status}"
fi

target_gtid="$(primary_query --skip-column-names --execute='SELECT @@GLOBAL.gtid_executed;')"
read -r target_log target_position _ < <(
  primary_query --skip-column-names --execute='SHOW MASTER STATUS;'
)

receiver_deadline=$(( $(date +%s) + 300 ))
while true; do
  replica_status="$(replica_query --vertical --execute='SHOW REPLICA STATUS')"
  read_log="$(status_value "${replica_status}" Source_Log_File)"
  read_position="$(status_value "${replica_status}" Read_Source_Log_Pos)"

  if [[ "${read_log}" > "${target_log}" || \
        ( "${read_log}" == "${target_log}" && "${read_position}" =~ ^[0-9]+$ && \
          ${read_position} -ge ${target_position} ) ]]; then
    break
  fi
  if (( $(date +%s) >= receiver_deadline )); then
    echo "Replica receiver did not fetch the complete backlog within 300 seconds." >&2
    exit 1
  fi
  sleep 1
done

printf '%s\n' "${replica_status}" > "${resolved_result_dir}/backlog-ready-status.txt"
printf '%s\n' "${target_gtid}" > "${resolved_result_dir}/target-gtid.txt"

./scripts/scenarios/collect-replication-lag.sh \
  "${resolved_result_dir}/lag.csv" 1800 1 \
  > "${resolved_result_dir}/lag-collector.log" 2>&1 &
lag_pid=$!
./scripts/scenarios/collect-worker-activity.sh \
  "${resolved_result_dir}/worker-activity.csv" 1800 1 \
  > "${resolved_result_dir}/worker-collector.log" 2>&1 &
activity_pid=$!
sleep 2

if ! kill -0 "${lag_pid}" 2>/dev/null || ! kill -0 "${activity_pid}" 2>/dev/null; then
  echo "A metric collector failed to start." >&2
  exit 1
fi

apply_started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
apply_started_ns="$(date +%s%N)"
replica_query --execute='START REPLICA SQL_THREAD;'
sql_thread_stopped=false

wait_result="$(
  replica_query --skip-column-names \
    --execute="SELECT WAIT_FOR_EXECUTED_GTID_SET('${target_gtid}', 1800);"
)"
apply_finished_ns="$(date +%s%N)"
apply_finished_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "${wait_result}" != "0" ]]; then
  echo "Replica did not execute the target GTID set within 1800 seconds." >&2
  exit 1
fi

sleep 3
stop_collectors

apply_duration_seconds="$(
  awk -v start="${apply_started_ns}" -v finish="${apply_finished_ns}" \
    'BEGIN { printf "%.3f", (finish - start) / 1000000000 }'
)"
apply_tps="$(
  awk -v transactions="${transactions}" -v duration="${apply_duration_seconds}" \
    'BEGIN { printf "%.2f", transactions / duration }'
)"
apply_rows_per_second="$(
  awk -v transactions="${transactions}" -v updates="${updates_per_transaction}" \
      -v duration="${apply_duration_seconds}" \
    'BEGIN { printf "%.2f", transactions * updates / duration }'
)"

replica_query --execute="SHOW REPLICA STATUS\G" \
  > "${resolved_result_dir}/final-replica-status.txt"

{
  printf 'dependency_tracking=%s\n' "${tracking}"
  printf 'replica_workers=%s\n' "${replica_workers}"
  printf 'source_concurrency=%s\n' "${concurrency}"
  printf 'transactions=%s\n' "${transactions}"
  printf 'updates_per_transaction=%s\n' "${updates_per_transaction}"
  printf 'order_count=%s\n' "${order_count}"
  printf 'workload_started_utc=%s\n' "${workload_started_utc}"
  printf 'workload_finished_utc=%s\n' "${workload_finished_utc}"
  printf 'apply_started_utc=%s\n' "${apply_started_utc}"
  printf 'apply_finished_utc=%s\n' "${apply_finished_utc}"
  printf 'apply_duration_seconds=%s\n' "${apply_duration_seconds}"
  printf 'apply_transactions_per_second=%s\n' "${apply_tps}"
  printf 'apply_rows_per_second=%s\n' "${apply_rows_per_second}"
  printf 'target_log=%s\n' "${target_log}"
  printf 'target_position=%s\n' "${target_position}"
} > "${resolved_result_dir}/metadata.env"

echo "Fixed-backlog experiment complete."
echo "  Tracking:          ${tracking}"
echo "  Replica workers:   ${replica_workers}"
echo "  Apply duration:    ${apply_duration_seconds} seconds"
echo "  Apply throughput:  ${apply_tps} transactions/second"
echo "  Row throughput:    ${apply_rows_per_second} rows/second"
