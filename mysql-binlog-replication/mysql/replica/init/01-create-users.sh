#!/usr/bin/env bash
# Creates the replica server's administrative account during first initialization.

set -euo pipefail

for variable in \
  MYSQL_ROOT_PASSWORD \
  MYSQL_ADMIN_USER \
  MYSQL_ADMIN_PASSWORD; do
  if [[ ! -v "${variable}" || -z "${!variable}" ]]; then
    echo "${variable} must be set to a non-empty value." >&2
    exit 1
  fi
done

sql_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\'/\'\'}"
  printf '%s' "${value}"
}

admin_user="$(sql_escape "${MYSQL_ADMIN_USER}")"
admin_password="$(sql_escape "${MYSQL_ADMIN_PASSWORD}")"

MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql --protocol=socket --user=root <<-EOSQL
CREATE USER IF NOT EXISTS '${admin_user}'@'%' IDENTIFIED BY '${admin_password}';
GRANT ALL PRIVILEGES ON *.* TO '${admin_user}'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
EOSQL
