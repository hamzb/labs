#!/usr/bin/env bash
# Runs the containerized concurrent order-processing workload against the primary.

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

for variable in MYSQL_APP_USER MYSQL_APP_PASSWORD; do
  if [[ ! -v "${variable}" || -z "${!variable}" ]]; then
    echo "${variable} must be set to a non-empty value in ${LAB_DIR}/.env." >&2
    exit 1
  fi
done

if ! docker compose ps --status running --services | grep -qx primary; then
  echo "The primary service is not running. Start the lab with: docker compose up -d" >&2
  exit 1
fi

docker compose --profile tools run --rm --build workload "$@"
