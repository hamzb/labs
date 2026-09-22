# MySQL Binlog Replication Lab

This repository will contain a reproducible MySQL binary log replication lab and the GitHub-facing article for the project.

The lab will focus on MySQL 8.0 replication behavior, with particular attention to parallel replication and transaction dependency tracking.

Lab automation is grouped by responsibility:

- `scripts/setup/` installs host dependencies, configures replication, initializes data, and verifies the lab.
- `scripts/scenarios/` runs test workloads and collects experiment metrics.

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
./scripts/setup/setup-replication.sh
```

Running the script again replaces the existing replica connection settings and starts replication from the replica's current GTID position.

Inspect replication health and the current lag reported by MySQL:

```bash
./scripts/setup/replication-status.sh
```

Verify the complete replication path with a small write on the primary:

```bash
./scripts/setup/smoke-test.sh
```

The smoke test creates `replication_lab.replication_smoke_test`, inserts and updates a uniquely tagged row on the primary, and waits for the final value to appear on the replica.

## Order Management Workload

Create a deterministic order-management dataset on the primary and wait for it to replicate:

```bash
./scripts/setup/init-workload.sh 200000 16
```

The initializer drops and recreates only the `order_management` database. It applies
`workload/schema.sql`, seeds 200,000 deterministic orders across 16 tenants, and verifies the same
dataset signature on the primary and replica.

The workload uses the dedicated account configured by `MYSQL_APP_USER` and `MYSQL_APP_PASSWORD`. That account is limited to `SELECT` and `UPDATE` privileges on `order_management.*`.

Install the host-side MySQL client used by the metric collectors:

```bash
./scripts/setup/install-host-dependencies.sh
```

## Fixed-Backlog Experiment

Run the three article scenarios against identical fixed backlogs:

```bash
RESULT_ROOT="results/fixed-backlog-$(date -u +%Y%m%dT%H%M%SZ)"

./scripts/scenarios/run-fixed-backlog-experiment.sh \
  COMMIT_ORDER "${RESULT_ROOT}/commit-order-1-worker" \
  1 1000 100 1 200000

./scripts/scenarios/run-fixed-backlog-experiment.sh \
  COMMIT_ORDER "${RESULT_ROOT}/commit-order-4-workers" \
  4 1000 100 1 200000

./scripts/scenarios/run-fixed-backlog-experiment.sh \
  WRITESET "${RESULT_ROOT}/writeset-4-workers" \
  4 1000 100 1 200000
```

The positional values after the result directory are replica workers, transaction count, updates
per transaction, source concurrency, and order count. The runner stops only the replica SQL
thread while generating the exact backlog, waits for the receiver to fetch it, and then measures
replica-only apply time. It also collects lag and worker activity until the target GTID set is
executed.

Each run creates CSV time series for `Seconds_Behind_Source` and replica worker activity, plus
configuration snapshots, workload output, target GTID, and calculated apply metrics. See
`workload/README.md` for the workload generator's inputs and behavior.

MySQL data and binary log files are bind-mounted from the host:

```text
data/primary
data/replica
```

These directories are ignored by git and survive container restarts.
