#!/usr/bin/env bash
# Installs the host-side MySQL client required by the replication lag collector.

set -euo pipefail

if command -v mysql >/dev/null 2>&1; then
  echo "MySQL client is already installed: $(mysql --version)"
  exit 0
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Automatic installation currently supports apt-based systems only." >&2
  echo "Install a MySQL 8 compatible client and rerun this script." >&2
  exit 1
fi

if (( EUID == 0 )); then
  apt-get update
  apt-get install --yes mysql-client
elif command -v sudo >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install --yes mysql-client
else
  echo "Installing mysql-client requires root privileges or sudo." >&2
  exit 1
fi

mysql --version
