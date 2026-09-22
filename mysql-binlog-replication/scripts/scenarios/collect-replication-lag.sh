#!/usr/bin/env bash
# Samples Seconds_Behind_Source and replica thread state into a timestamped CSV file.

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

if [[ ! "${MYSQL_REPLICA_PORT}" =~ ^[1-9][0-9]*$ ]] || (( MYSQL_REPLICA_PORT > 65535 )); then
  echo "MYSQL_REPLICA_PORT must be an integer between 1 and 65535." >&2
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
)

if ! MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" "${mysql_command[@]}" \
  --execute='SELECT 1;' >/dev/null; then
  echo "Unable to connect to the replica at ${MYSQL_REPLICA_HOST}:${MYSQL_REPLICA_PORT}." >&2
  exit 1
fi

printf 'timestamp_utc,elapsed_seconds,seconds_behind_source,replica_io_running,replica_sql_running\n' \
  > "${resolved_output}"

started_at="$(date +%s)"
next_sample_at="${started_at}"
peak_lag=0

while true; do
  current_time="$(date +%s)"
  if (( next_sample_at > current_time )); then
    sleep $((next_sample_at - current_time))
  fi

  replica_status="$(
    MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" "${mysql_command[@]}" \
      --vertical --execute='SHOW REPLICA STATUS'
  )"

  if [[ -z "${replica_status}" ]]; then
    echo "Replication is not configured on ${MYSQL_REPLICA_HOST}:${MYSQL_REPLICA_PORT}." >&2
    exit 1
  fi

  lag="$(sed -n 's/^[[:space:]]*Seconds_Behind_Source: //p' <<<"${replica_status}")"
  io_state="$(sed -n 's/^[[:space:]]*Replica_IO_Running: //p' <<<"${replica_status}")"
  sql_state="$(sed -n 's/^[[:space:]]*Replica_SQL_Running: //p' <<<"${replica_status}")"
  sampled_at="$(date +%s)"
  elapsed=$((sampled_at - started_at))
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -z "${lag}" || -z "${io_state}" || -z "${sql_state}" ]]; then
    echo "Unable to parse replica status returned by the MySQL client." >&2
    exit 1
  fi

  printf '%s,%s,%s,%s,%s\n' \
    "${timestamp}" "${elapsed}" "${lag}" "${io_state}" "${sql_state}" \
    >> "${resolved_output}"

  if [[ "${lag}" =~ ^[0-9]+$ ]] && (( lag > peak_lag )); then
    peak_lag="${lag}"
  fi
  if (( elapsed >= duration )); then
    break
  fi

  next_sample_at=$((sampled_at + interval))
done

echo "Replication lag samples written to ${resolved_output}"
echo "Peak Seconds_Behind_Source: ${peak_lag}"
