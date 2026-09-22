# Workload Generator

The Python workload generator simulates an order-processing application that sends concurrent
transactions to the MySQL primary. The shell scripts operate and observe the lab; this program
represents the application producing load.

Run it through `scripts/scenarios/run-workload.sh`. The wrapper loads credentials from `.env`, verifies that
the primary is running, builds the workload image, and starts the generator in a temporary
container.

```bash
./scripts/scenarios/run-workload.sh --concurrency 16 --duration 30 --order-count 100000
```

## Command-Line Inputs

| Input | Default | Description |
| --- | ---: | --- |
| `--concurrency` | `16` | Number of parallel worker threads. Each worker opens its own connection to the primary. |
| `--duration` | `30` | Number of seconds for which workers generate transactions. Positive decimal values are accepted. Cannot be combined with `--transactions`. |
| `--transactions` | none | Exact total number of transactions distributed across all workers. Cannot be combined with `--duration`. |
| `--order-count` | `100000` | Expected number of rows in `order_management.orders`. This must match the value used by `scripts/setup/init-workload.sh`. |
| `--updates-per-transaction` | `1` | Number of order rows updated and committed in each transaction. |
| `--report-interval` | `1` | Number of seconds between progress reports containing committed transactions, interval TPS, and errors. Positive decimal values are accepted. |
| `--mode` | `independent` | Row-selection strategy. Valid values are `independent` and `hotspot`. |
| `--hotspot-size` | `16` | Number of order IDs shared by all workers in `hotspot` mode. It has no effect in `independent` mode. |

All numeric inputs must be greater than zero. The generator also requires each worker's order
partition to contain at least `--updates-per-transaction` rows and requires `--hotspot-size` not
to exceed `--order-count`. When neither run limit is supplied, `--duration 30` is used.

Use a fixed transaction count when experiments need identical backlog sizes:

```bash
./scripts/scenarios/run-workload.sh \
  --mode independent \
  --concurrency 1 \
  --transactions 1000 \
  --updates-per-transaction 100 \
  --order-count 100000
```

Use the built-in help to list the accepted arguments:

```bash
./scripts/scenarios/run-workload.sh --help
```

## Workload Modes

### Independent

In `independent` mode, the generator divides the configured order range into non-overlapping
partitions. Each worker updates only its own partition. This minimizes row-lock contention on the
primary and creates transactions with independent write sets.

Use this mode for the main `COMMIT_ORDER` versus `WRITESET` comparison. It allows the experiment
to focus on how dependency tracking affects replica parallelism without introducing genuine row
conflicts between workers.

```bash
./scripts/scenarios/run-workload.sh \
  --mode independent \
  --concurrency 32 \
  --duration 60 \
  --order-count 100000
```

### Hotspot

In `hotspot` mode, every worker selects rows from the same range, starting at order ID 1 and
ending at `--hotspot-size`. The shared range creates overlapping write sets and row-lock
contention.

Use this mode as a secondary scenario to demonstrate that dependency tracking cannot parallelize
transactions that genuinely conflict. It can reduce primary throughput, and multi-row
transactions can also produce lock waits or deadlocks.

```bash
./scripts/scenarios/run-workload.sh \
  --mode hotspot \
  --hotspot-size 16 \
  --concurrency 32 \
  --duration 60 \
  --order-count 100000
```

## Environment Inputs

Docker Compose supplies the connection settings to the generator:

| Variable | Requirement | Description |
| --- | --- | --- |
| `MYSQL_APP_USER` | Required | Application user used to connect to the primary. |
| `MYSQL_APP_PASSWORD` | Required | Password for the application user. |
| `MYSQL_HOST` | Defaults to `primary` | MySQL hostname. Compose sets this to the primary service name. |
| `MYSQL_PORT` | Defaults to `3306` | MySQL port inside the Compose network. |

Set the credentials in the repository's `.env` file. Do not pass passwords as command-line
arguments.

## Output

During a run, the generator reports cumulative commits, interval transaction throughput, and
errors. It finishes with a machine-readable `RESULT` JSON object containing:

- workload mode and concurrency
- requested fixed transaction count, when one was supplied
- measured duration
- committed transactions and updated rows
- error count
- average transactions per second
- p50, p95, and p99 transaction latency

The process exits with a nonzero status if dataset validation fails, a worker cannot start, or any
worker encounters an error.
