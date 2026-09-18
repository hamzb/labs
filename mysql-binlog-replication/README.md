# MySQL Binlog Replication Lab

This repository will contain a reproducible MySQL binary log replication lab and the GitHub-facing article for the project.

The lab will focus on MySQL 8.0 replication behavior, with particular attention to parallel replication and transaction dependency tracking.

## Local MySQL Servers

Start the lab servers:

```bash
docker compose up -d
```

The Compose setup starts two MySQL 8.0.34 containers:

| Server | Container | Host port | MySQL port |
| --- | --- | ---: | ---: |
| Primary | `mysql-primary` | `33060` | `3306` |
| Replica | `mysql-replica` | `33061` | `3306` |

Create the local environment file and set every password before starting the servers:

```bash
cp .env.example .env
```

The lab does not provide default passwords. Compose and the lab scripts exit when a required value is missing or empty.

```bash
mysql -h 127.0.0.1 -P 33060 -u labadmin -p
mysql -h 127.0.0.1 -P 33061 -u labadmin -p
```

The primary also creates a dedicated replication user. Replication itself is configured separately so the setup steps remain explicit and observable.

Configure GTID-based replication and wait for both replica threads to start:

```bash
./scripts/setup-replication.sh
```

Running the script again replaces the existing replica connection settings and starts replication from the replica's current GTID position.

Inspect replication health and the current lag reported by MySQL:

```bash
./scripts/replication-status.sh
```

Verify the complete replication path with a small write on the primary:

```bash
./scripts/smoke-test.sh
```

The smoke test creates `replication_lab.replication_smoke_test`, inserts and updates a uniquely tagged row on the primary, and waits for the final value to appear on the replica.

## Order Management Workload

Create a deterministic order-management dataset on the primary and wait for it to replicate:

```bash
./scripts/init-workload.sh
```

The default dataset contains 100,000 orders distributed across 16 tenants. The order and tenant counts can be supplied explicitly:

```bash
./scripts/init-workload.sh 250000 32
```

The initializer drops and recreates only the `order_management` database. It applies `workload/schema.sql`, seeds deterministic rows, and verifies the same dataset signature on the primary and replica.

MySQL data and binary log files are bind-mounted from the host:

```text
data/primary
data/replica
```

These directories are ignored by git and survive container restarts.
