# A Practical Deep Dive into MySQL Binlog Replication Performance

## Introduction

In many MySQL deployments, binary logs replication runs without any issues under normal load. This tends to change when the workload becomes heavier. If the replica cannot apply transactions as
quickly as the primary produces them, replication lag starts to grow.

At that point, the common reaction is to add more server resources or increase the number of replica
workers used by the SQL applier thread. Those actions can help, but they do not explain the full
replication performance picture.

The questions we need to answer are more specific. Which settings actually influence replication
apply performance? Is increasing `replica_parallel_workers` enough? How can we measure whether a
setting improved the replica's ability to apply transactions?

This article works through those questions. We first cover the high-level concepts of MySQL binary log
replication, then use a practical lab to compare the settings that influence parallel apply
performance. Finally, we look at the metrics, interpret the results, and call out the caveats that
matter when applying the same reasoning to real workloads.

## MySQL Binary Log Replication Basics

Database systems use replication to maintain copies of the same data on multiple database servers.
These copies improve resiliency by providing a server that can take over if the main server becomes
unavailable. They can also improve scalability for suitable workloads by serving reads, reports, or
other operations from replica servers instead of sending every request to the main server.

In MySQL, native replication is built around the binary log. When binary logging is enabled, the
primary server records committed database changes in binary log files. A replica server can then
retrieve those events and apply them locally, keeping its data aligned with the primary server.

MySQL binary log replication is asynchronous by nature. The primary server can confirm a transaction
commit without waiting for a replica to receive or apply it. This keeps replica processing out of the
application's commit path, but it also means that a replica can fall behind when it cannot apply
changes quickly enough.

### The MySQL Binary Log

A MySQL server continuously receives requests from client applications to insert, update, and delete
data. These requests produce a growing flow of committed database transactions. Instead of writing
all changes to one endlessly growing file, MySQL stores the binary log as an ordered series of
numbered files:

```text
mysql-bin.000001
mysql-bin.000002
mysql-bin.000003
```

MySQL rotates to a new binary log file when the current file reaches its configured maximum size,
the server restarts, or the logs are flushed.

### How Transactions Are Recorded in the Binary Log

MySQL supports different binary logging formats, but this article focuses on row-based logging,
which is the default in MySQL 8.0. In row-based logging, the binary log records events that describe
the row changes produced by a transaction. A replica reads those events and applies the same row
changes locally.

The [MySQL binary log documentation](https://dev.mysql.com/doc/refman/8.0/en/binary-log.html)
describes the files and their role in replication.

### How Binary Log Transactions Are Identified

A replica needs to know which transactions it has already processed and where it should continue
from after a restart, reconnect, or topology change. MySQL can track this in two ways: with binary
log coordinates or with GTIDs.

- **Non-GTID replication:** A replica tracks progress using a binary log file name and position.
  These coordinates tell it where to continue reading, but they point to a location in one primary
  server's binary log.
- **GTID replication:** MySQL assigns each committed transaction a global transaction identifier made
  from the originating server's UUID and a sequence number, such as
  `3E11FA47-71CA-11E1-9E33-C80AA9429562:23`. The identifier stays with the transaction as it moves
  through the replication topology. If replication stops and reconnects, the replica does not need to
  resume from a specific binary log file and position. It can tell the primary server which GTIDs it
  already has, and the primary server can send the missing transactions.

For this lab and demo, we use GTID-based binary log replication.

The [GTID documentation](https://dev.mysql.com/doc/refman/8.0/en/replication-gtids-concepts.html)
and [auto-positioning documentation](https://dev.mysql.com/doc/refman/8.0/en/replication-gtids-auto-positioning.html)
describe this behavior in detail.

### How the Replica Receives and Applies the Binary Log

Once transactions are available in the primary server's binary log, the replica server retrieves
and applies them through two separate stages:

```text
Application
    |
    v
+-----------------------------------+
| MySQL primary server              |
|                                   |
|  Database changes                 |
|          |                        |
|          v                        |
|  Binary log                       |
+----------+------------------------+
           |
           | binary log events
           | retrieved by the replica I/O thread
           v
+-----------------------------------+
| MySQL replica server              |
|                                   |
|  I/O receiver thread              |
|          |                        |
|          v                        |
|  Relay log                        |
|          |                        |
|          v                        |
|  SQL applier thread               |
|          |                        |
|          v                        |
|  Replica database                 |
+-----------------------------------+
```

The replica server uses these components to receive and apply the primary server's binary log:

- **I/O thread:** Also called the receiver thread, it connects to the primary server and requests
  binary log events. The primary server sends the events through a binlog dump thread, and the I/O
  thread writes them to the replica server's relay log.
- **Relay log:** This local log holds the events retrieved from the primary server until they are
  applied. It sits between the receiver side and the applier side of replication.
- **SQL thread:** Also called the applier thread, it reads transactions from the relay log and
  applies their changes to the replica database.

Since the I/O thread and SQL thread are separate replication components, with the relay log acting as
a buffer between them, they can move at different paces. Under a heavy workload, the I/O thread may
continue receiving events from the primary server while the SQL thread applies them more slowly.
When that happens, transactions accumulate in the relay log and replication lag grows even though
event delivery is working normally.

The [replication implementation documentation](https://dev.mysql.com/doc/refman/8.0/en/replication-implementation.html)
and [replication threads documentation](https://dev.mysql.com/doc/refman/8.0/en/replication-threads.html)
describe these components in more detail.

In a MySQL replica, multiple workers can be used to apply binary log transactions in parallel.
However, configuring multiple workers does not guarantee that all transactions can be parallelized
at all times. The next section looks more closely at the replica applier and its worker
configuration.

## How MySQL Replicas Apply Transactions in Parallel

Looking closer at the SQL/applier stage, a replica can be configured to run multiple worker threads
for better apply performance. In that mode, MySQL uses a coordinator thread to read transactions
from the relay log and assign eligible transactions to worker threads.

```text
Relay log
    |
    v
Coordinator thread
    |
    +--> Worker 1 --> applies assigned transactions
    |
    +--> Worker 2 --> applies assigned transactions
    |
    +--> Worker 3 --> applies assigned transactions
    |
    +--> Worker N --> applies assigned transactions
```

The important detail is that workers are not independent executors that can run any transaction in
any order. The replica must preserve the same logical result as the primary server, so the
coordinator has to decide which transactions are independent enough to apply at the same time. A
dependency means that one transaction must be applied before another, for example because both
transactions changed the same row or because MySQL recorded an ordering relationship between them.

### Replica-Side Settings That Influence Apply Performance

Three replica-side settings matter for this discussion: how many workers exist, how the coordinator
schedules transactions, and whether worker commits preserve the relay-log order.

#### Replica Worker Capacity

The main setting that controls the number of available applier workers is
`replica_parallel_workers`.

- `replica_parallel_workers=0` disables the coordinator/worker applier model and uses a single SQL
  applier thread.
- `replica_parallel_workers=1` uses one coordinator thread and one worker thread. This is a
  single-worker baseline, but it still uses the coordinator/worker applier model.
- `replica_parallel_workers=N`, where `N` is greater than one, creates `N` worker threads and one
  coordinator thread.

The configured value is the maximum apply capacity available to the replica. It is not a guarantee
that all workers will be busy. Increasing `replica_parallel_workers` gives MySQL more worker slots,
but the coordinator can only use those slots when it has transactions that are eligible to run in
parallel.

#### Logical Clock Scheduling

After worker threads are configured, MySQL still needs a scheduling mode that tells the coordinator
how to distribute transactions across those workers. This is controlled by
`replica_parallel_type`.

For this article, we use `replica_parallel_type=LOGICAL_CLOCK`. In this mode, the coordinator uses
dependency information recorded in the binary log to decide which transactions can be assigned to
workers at the same time. We use `LOGICAL_CLOCK` because the article focuses on transaction
dependencies and how they affect replica parallelism.

The source of that dependency information is covered in the next section. For now, the key point is
that the replica worker count, scheduling policy, and dependency information solve different parts
of the problem:

- `replica_parallel_workers` controls how many worker threads are available.
- `replica_parallel_type=LOGICAL_CLOCK` controls the scheduling policy used by the coordinator.
- The dependency information in the binary log controls how much parallel work the coordinator can
  actually find.

#### Preserving Commit Order

Parallel apply changes how transactions execute on the replica, but it should not make the replica
commit transactions in an order that changes the observed transaction history. The setting
`replica_preserve_commit_order=ON` keeps worker commits aligned with the relay-log order while still
allowing eligible transactions to execute in parallel.

This setting does not make transactions independent. If the coordinator sees a dependency chain,
preserving commit order does not break that chain or make more workers useful.

### Configured Workers vs Active Workers

When evaluating parallel replication, the configured worker count is only one side of the picture.
What matters during a workload is how many workers actually receive transactions and spend time
applying them.

A replica can be configured with four or eight workers and still behave close to a single-worker
replica if the coordinator cannot find independent transactions to schedule. In that case, the extra
workers exist, but they spend most of their time idle.

This distinction gives the experiment its first measurement target. We need to measure not only how
many workers are configured, but how many workers become active while the replica catches up.

The [replication threads documentation](https://dev.mysql.com/doc/refman/8.0/en/replication-threads.html)
describes the coordinator and worker model. The
[replica server options documentation](https://dev.mysql.com/doc/refman/8.0/en/replication-options-replica.html)
describes `replica_parallel_workers`, `replica_parallel_type`, and
`replica_preserve_commit_order`.

At this point, the replica side of the configuration is clear: workers provide capacity, and the
coordinator uses dependency information to decide whether that capacity can be used. The next step
is to look at where that dependency information comes from, because that part is controlled by the
primary server.

## How the Primary Influences Replica Parallelism

With `replica_parallel_type=LOGICAL_CLOCK`, the replica coordinator uses dependency metadata stored
with transactions in the binary log. That metadata is written by the primary server, which means the
primary influences how much parallelism the replica can discover later.

```text
Primary server
    |
    | binlog_transaction_dependency_tracking
    v
Binary log dependency metadata
    |
    v
Replica coordinator
    |
    v
Worker scheduling decisions
```

The source-side setting that controls this behavior is
`binlog_transaction_dependency_tracking`. It tells MySQL how to compute the dependency information
written into the binary log for multithreaded replicas.

### Dependency Tracking Modes

For this article, the important values are `COMMIT_ORDER` and `WRITESET`.

- **`COMMIT_ORDER`:** MySQL computes dependency information from transaction commit timing. This is
  the default value in MySQL 8.0. It can expose some parallelism when transactions overlap during
  commit, but it can also be conservative when the workload reaches the primary in a mostly
  sequential order.
- **`WRITESET`:** MySQL computes dependency information using the rows changed by each transaction.
  When transactions update different rows, MySQL can mark them as independent even if commit-order
  tracking would not expose as much parallelism.

MySQL also supports `WRITESET_SESSION`, which keeps the write-set behavior but treats transactions
from the same client session as dependent. This article does not use it because the experiment
compares the default `COMMIT_ORDER` behavior with `WRITESET`.

### COMMIT_ORDER

With `COMMIT_ORDER`, the primary records dependency information based on transaction commit timing.
If transactions overlap in the right part of their commit lifecycle, MySQL can mark them as
independent enough for parallel apply.

This works well when the primary workload naturally has enough concurrent transactions. It is less
helpful when transactions arrive and commit in a mostly sequential pattern. In that case, the binary
log can describe a dependency chain even if many transactions updated different rows.

That distinction matters for the experiment. A replica with multiple workers can still use only one
worker at a time if the binary log metadata tells the coordinator that transactions must be applied
in order.

### WRITESET

With `WRITESET`, the primary looks at the rows changed by each transaction and computes a write set
for the transaction. If two transactions have non-overlapping write sets, MySQL can record them as
independent for replica scheduling.

This gives the replica coordinator better information. The coordinator still uses
`replica_parallel_type=LOGICAL_CLOCK`, but the logical clock metadata in the binary log now reflects
row-level independence instead of relying only on commit timing.

`WRITESET` does not make every workload parallel. Transactions that change the same rows still need
to preserve the required order. Workloads with foreign keys, DDL, missing useful keys, or other
serialization points can also reduce the amount of parallelism MySQL can expose.

### How These Settings Fit Together

To summarize what we covered in this section and the previous one, the settings fit
together this way:

- `replica_parallel_workers` controls available execution capacity on the replica.
- `replica_parallel_type=LOGICAL_CLOCK` tells the replica to schedule work using binary log
  dependency metadata.
- `binlog_transaction_dependency_tracking` controls how the primary generates that metadata.

The replica-side settings are easier to reason about: `replica_parallel_workers` defines worker
capacity, and `replica_parallel_type=LOGICAL_CLOCK` tells the coordinator how to use dependency
metadata. The less obvious question is how much the primary-side setting
`binlog_transaction_dependency_tracking` affects replica apply performance. The experiment compares
the available dependency tracking values, shows how replica apply performance is measured, and checks
whether one value is always better or whether the result depends on the workload. Before running that
experiment, the next section introduces the setup we will use.

The [MySQL binary logging options documentation](https://dev.mysql.com/doc/refman/8.0/en/replication-options-binary-log.html)
describes `binlog_transaction_dependency_tracking`, `COMMIT_ORDER`, and `WRITESET` in more detail.

> **Version note:** The availability of these settings, and their default values, depends on the
> MySQL version.
>
> This lab uses MySQL 8.0.34 because it is the last 8.0 release before
> `binlog_transaction_dependency_tracking` is deprecated. Starting with MySQL 8.0.35, the setting is
> deprecated, but it still exists in MySQL 8.0. In MySQL 8.4, the setting is removed and MySQL uses
> write-set based dependency tracking internally when multithreaded replicas are used.
>
> If newer versions move this behavior into MySQL itself, why should we still care about these
> settings? Many MySQL environments still run versions where these settings exist and directly affect
> replica apply performance. Upgraded environments can also carry forward older configuration values,
> such as `COMMIT_ORDER`, which can limit replica parallelism even when workers are configured
> correctly.
>
> For versions such as MySQL 8.4, the tuning question shifts away from choosing `COMMIT_ORDER` or
> `WRITESET`, but replica-side settings such as `replica_parallel_workers` still matter. The
> practical point is to be aware of the MySQL version you run and to verify the actual runtime
> values of the replication settings.

## Lab Scenario and Scope

This lab uses a simple replication topology, a deterministic, repeatable dataset, and a controlled
load generator to make replica apply behavior measurable without turning the article into a general
MySQL benchmark.

The lab files are available in the
[`mysql-binlog-replication`](https://github.com/hamzb/labs/tree/main/mysql-binlog-replication)
directory of the public lab repository.

### Replication Topology

The topology is intentionally small so the experiment can focus on replica apply behavior. There is
one MySQL primary server, one MySQL replica server, and one workload generator that represents the
application writing to the primary.

This setup is enough to observe the behavior we care about: how quickly the replica applies
transactions after they have been written to the primary's binary log and fetched into the
replica's relay log.

### Application Scenario

The application model is an order-management system. The primary server owns an `order_management`
database with one main table, `order_management.orders`. Each row represents an order, and the
workload updates existing orders rather than inserting new data during the experiment.

This keeps the comparison focused on how the replica applies a controlled stream of transactions,
not on schema growth, insert patterns, or general MySQL throughput.

### Workload Dataset

The schema is defined in
[`workload/schema.sql`](https://github.com/hamzb/labs/blob/main/mysql-binlog-replication/workload/schema.sql).
For the article scenarios,
[`scripts/setup/init-workload.sh`](https://github.com/hamzb/labs/blob/main/mysql-binlog-replication/scripts/setup/init-workload.sh)
creates 1,000,000 deterministic orders across 16 tenants:

```bash
./scripts/setup/init-workload.sh 1000000 16
```

The deterministic dataset matters because every scenario starts from the same database shape. The
script also verifies the expected row count and tenant distribution on both the primary and replica
before the experiment begins.

### Scope of the Experiment

The experiment is designed to compare how MySQL settings affect replica apply behavior. It is not a
maximum-throughput benchmark for MySQL.

The controlled parts of the lab are:

- the same primary and replica containers
- the same `order_management.orders` table
- the same deterministic dataset
- the same transaction count and row-update pattern
- the same metric collection method

The experiment focuses on replica apply duration, worker activity, and replication lag while the
replica applies a known backlog. It intentionally does not cover storage tuning, network capacity,
failover, semi-synchronous replication, large transactions, schema changes, or general MySQL
capacity planning.

This scope keeps the comparison narrow: when two runs behave differently, the difference should come
from the replication settings being changed, not from a different dataset or workload shape.

### Repository Structure

The lab repo is structured in a way that keeps the MySQL setup, workload generator, and scenario
scripts easy to find and reuse:

```text
mysql-binlog-replication/
├── docker-compose.yml
├── mysql/
│   ├── primary/
│   └── replica/
├── scripts/
│   ├── setup/
│   └── scenarios/
└── workload/
```

- [`docker-compose.yml`](https://github.com/hamzb/labs/blob/main/mysql-binlog-replication/docker-compose.yml)
  defines the MySQL primary, MySQL replica, and workload container.
- [`mysql/`](https://github.com/hamzb/labs/tree/main/mysql-binlog-replication/mysql) contains the
  MySQL configuration files and initialization scripts for both servers.
- [`scripts/setup/`](https://github.com/hamzb/labs/tree/main/mysql-binlog-replication/scripts/setup)
  contains scripts that prepare the lab: dependency installation, replication setup, status checks,
  smoke testing, and workload initialization.
- [`scripts/scenarios/`](https://github.com/hamzb/labs/tree/main/mysql-binlog-replication/scripts/scenarios)
  contains the scripts that run the experiment and collect replica lag and worker activity.
- [`workload/`](https://github.com/hamzb/labs/tree/main/mysql-binlog-replication/workload) contains
  the schema, workload generator, Dockerfile, and workload documentation.

## Workload Generator and Experiment Controls

Before comparing replication settings, the experiment needs a repeatable workload and a controlled way to measure how the replica applies it.

### Experiment Parameters

Each experiment run uses the same fixed-size workload against the `order_management.orders` table. The source
side uses two application workers, generates 10,000 transactions, and updates 100 existing order rows
per transaction. In total, each run produces 1,000,000 row updates.

The workload is intentionally spread across non-overlapping parts of the order ID range. That avoids
intentional row conflicts in the application workload and lets the experiment focus on how MySQL
records and uses dependency information for replica apply.

The comparison keeps these inputs constant across all runs:

- 1,000,000 seeded orders
- two source-side workload workers
- 10,000 generated transactions
- 100 updates per transaction
- 1,000,000 total row updates
- `independent` row-selection mode (each workload worker updates a separate range of rows)

### Workload Generator

The workload generator simulates application traffic using the parameters described above. It
creates transactions that update existing rows in `order_management.orders`, reports progress while
it runs, and exits with a structured result summary.

The generator lives in
[`workload/generator.py`](https://github.com/hamzb/labs/blob/main/mysql-binlog-replication/workload/generator.py).
We build the workload generator into a container image and run it through a Docker Compose service.
This keeps the generator isolated from the host and makes experiment re-runs reproducible.

The documented generator inputs are in
[`workload/README.md`](https://github.com/hamzb/labs/blob/main/mysql-binlog-replication/workload/README.md).

### Experiment Execution and Control Steps

The experiment is run with
[`scripts/scenarios/run-experiment.sh`](https://github.com/hamzb/labs/blob/main/mysql-binlog-replication/scripts/scenarios/run-experiment.sh).
This is the main experiment orchestration script. It runs the workload generator and performs the
control steps around it: setting the dependency tracking mode, configuring the replica worker count,
stopping and restarting the replica SQL thread, and collecting metrics.

Stopping only the replica SQL thread is what separates transaction delivery from transaction apply
in this experiment. The I/O thread keeps running, so it continues receiving binary log events from
the primary and stores them in the relay log, but the replica does not apply them yet.

This creates a fixed backlog for the apply phase. If the replica SQL thread stayed fully active
while the workload ran, the replica might apply each transaction soon after it arrived.

When the replica keeps up with the primary, only a few transactions are waiting in the relay log.
Extra workers may stay idle because the relay log has too little queued work. That makes it harder
to isolate the effect of `binlog_transaction_dependency_tracking`.

So during the experiment, we ensure that the receiver has fetched all transactions from the source
MySQL server before re-enabling the replica SQL thread, to measure how quickly the replica applies
the backlog.

### Metrics Collected During the Experiment

The experiment collects the metrics needed to measure both replica apply performance and worker
utilization:

- `Seconds_Behind_Source`, collected by
  [`scripts/scenarios/collect-replication-lag.sh`](https://github.com/hamzb/labs/blob/main/mysql-binlog-replication/scripts/scenarios/collect-replication-lag.sh)
  and written to `lag.csv`.
- Replica I/O and SQL thread state, collected by `collect-replication-lag.sh` together with
  `Seconds_Behind_Source`.
- Replica worker slots, active workers, applying transactions, commit waits, and coordinator waits,
  collected by
  [`scripts/scenarios/collect-worker-activity.sh`](https://github.com/hamzb/labs/blob/main/mysql-binlog-replication/scripts/scenarios/collect-worker-activity.sh)
  and written to `worker-activity.csv`.
- Apply duration for the target GTID set, measured by `run-experiment.sh`.
- Calculated transaction throughput and row throughput, written by
  `run-experiment.sh` to the run metadata.
- Initial and final replication status, workload output, run metadata, and the target GTID set.

## Running the Three Scenarios

At this point, the lab has a primary server, a replica server, a seeded `order_management.orders`
table, and a workload generator. The remaining step is to run the same backlog under three
replication configurations.

The comparison uses three scenarios:

- primary: `binlog_transaction_dependency_tracking=COMMIT_ORDER`; replica:
  `replica_parallel_workers=1`
- primary: `binlog_transaction_dependency_tracking=COMMIT_ORDER`; replica:
  `replica_parallel_workers=4`
- primary: `binlog_transaction_dependency_tracking=WRITESET`; replica:
  `replica_parallel_workers=4`

The goal is to show that replica apply performance is influenced by both sides of the setup: how
much parallel apply capacity is available on the replica, and how the primary records transaction
dependencies in the binary log.

The first run gives us the baseline: one replica worker applying the backlog serially. The second
run answers whether adding more replica workers is enough on its own. The third run keeps the same
replica worker count but changes the primary-side dependency tracking mode to `WRITESET`.

### Running the Experiment

The experiment is executed through
[`scripts/scenarios/run-experiment.sh`](https://github.com/hamzb/labs/blob/main/mysql-binlog-replication/scripts/scenarios/run-experiment.sh).
Each run writes its output to a separate directory under a common result root:

```bash
RESULT_ROOT="results/replica-apply-$(date -u +%Y%m%dT%H%M%SZ)"
```

Then we run the three scenarios:

```bash
./scripts/scenarios/run-experiment.sh \
  COMMIT_ORDER "${RESULT_ROOT}/commit-order-1-worker" \
  1 10000 100 2 1000000

./scripts/scenarios/run-experiment.sh \
  COMMIT_ORDER "${RESULT_ROOT}/commit-order-4-workers" \
  4 10000 100 2 1000000

./scripts/scenarios/run-experiment.sh \
  WRITESET "${RESULT_ROOT}/writeset-4-workers" \
  4 10000 100 2 1000000
```

The arguments after the result directory configure the run. For example, in the first scenario:

```bash
./scripts/scenarios/run-experiment.sh \
  COMMIT_ORDER "${RESULT_ROOT}/commit-order-1-worker" \
  1 10000 100 2 1000000
```

The meaning of the arguments passed to the script is:

- `COMMIT_ORDER`: set `binlog_transaction_dependency_tracking=COMMIT_ORDER` on the primary
- `${RESULT_ROOT}/commit-order-1-worker`: write this run's output files under this directory
- `1`: configure the replica with `replica_parallel_workers=1`, a single-worker baseline that still
  uses the coordinator/worker applier model
- `10000`: generate 10,000 workload transactions
- `100`: update 100 order rows per transaction
- `2`: run 2 source-side workload workers
- `1000000`: use the seeded dataset size of 1,000,000 orders

### What the Script Controls

The scenario script performs the same control steps for each run:

- sets `binlog_transaction_dependency_tracking` on the primary
- sets `replica_parallel_workers` on the replica
- verifies that replication is healthy before generating the workload
- stops only the replica SQL thread, while leaving the I/O thread running
- runs the workload generator
- waits until the replica has fetched the complete backlog into the relay log
- starts metric collection
- restarts the replica SQL thread
- waits until the target GTID set has been applied
- records the final replication status and calculated apply metrics

This keeps the comparison focused. The workload shape stays the same, and the replica always starts the
apply phase with the same size of transactions backlog. The variables that change are the dependency
tracking mode and the number of replica workers.

Now that the test runs are defined, we can look at the results and what they show about replica workers,
dependency tracking, and apply performance.

## Results: Workers, Throughput, and Lag

Each scenario produced many samples for the metrics discussed earlier, especially replica lag and
worker activity over time. To keep the results readable, we will not list every raw data point here.
The table below aggregates the main numbers from each run.

| Scenario | Dependency tracking mode | Replica workers number | Apply duration on the replica | Replica apply TPS | Replica row throughput | Avg applying transactions | Max applying transactions | Avg coordinator waits |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Scenario 1 | `COMMIT_ORDER` | 1 | 210.076 s | 47.60 | 4,760.18 rows/s | 0.98 | 1 | 0.01 |
| Scenario 2 | `COMMIT_ORDER` | 4 | 183.138 s | 54.60 | 5,460.36 rows/s | 1.21 | 2 | 2.78 |
| Scenario 3 | `WRITESET` | 4 | 83.854 s | 119.25 | 11,925.49 rows/s | 3.73 | 4 | 0.31 |

The workload generator produced the same shape of workload in all three runs: 10,000 transactions,
100 row updates per transaction, and 1,000,000 total row updates. The source-side workload rate was
also close across the runs: 29.75 TPS, 28.59 TPS, and 31.21 TPS. That makes the replica apply phase
the part worth comparing.

The table shows the final 1,000,000-row-update run used for the article, but the result pattern did
not come from a single execution. The same comparison was run multiple times during the lab,
including earlier runs with a smaller workload size. The exact numbers changed between runs, but the
pattern remained consistent: adding workers under `COMMIT_ORDER` helped only modestly, while
`WRITESET` made the four replica workers much more active.

### More Workers Helped, but Not Enough

The first comparison is between `Scenario 1` and `Scenario 2`.

In `Scenario 1`, the replica applied the backlog in about 210 seconds. In `Scenario 2`, it applied
the same size of backlog in about 183 seconds. That is an improvement, but not a large one
considering that `Scenario 2` had four worker threads available instead of one.

The worker activity explains why. In `Scenario 2` (`COMMIT_ORDER` + 4 workers), the replica averaged only
1.21 applying transactions at a time, with a maximum of 2. At the same time, the average number of
workers waiting for the coordinator was 2.78. In other words, the extra workers existed, but most of
them were waiting on the coordinator instead of applying transactions.

This is the first point the experiment is meant to show: increasing
`replica_parallel_workers` increases replica apply capacity, but it does not guarantee that the
replica can use that capacity.

### WRITESET Made the Workers Useful

`Scenario 3` keeps the replica worker count fixed at 4 and changes only the dependency tracking mode
on the primary.

`Scenario 2` took about 183 seconds. `Scenario 3` took about 84 seconds. Apply throughput increased
from about 55 transactions per second to about 119 transactions per second.

The worker activity changed as well. In `Scenario 3`, the replica averaged 3.73 applying
transactions at a time, and all 4 workers were applying in some samples. Coordinator waits also
dropped sharply compared with `Scenario 2`.

That is the important result. `WRITESET` did not add more replica workers. It changed the dependency
metadata written by the primary, which gave the replica coordinator more room to schedule
transactions in parallel.

### Lag Recovered Faster in Scenario 3

The experiment also tracked `Seconds_Behind_Source`, which shows how far in time the replica is
behind the primary. Since the experiment intentionally stops the replica SQL thread while the
workload runs, the useful question is how quickly the metric returns to 0 once the SQL thread starts
again.

| Scenario | Initial `Seconds_Behind_Source` | Max `Seconds_Behind_Source` | Time until it returned to 0 |
| --- | ---: | ---: | ---: |
| Scenario 1 | 339 | 339 | about 211 seconds |
| Scenario 2 | 352 | 353 | about 184 seconds |
| Scenario 3 | 323 | 323 | about 85 seconds |

This follows the same pattern as the apply-duration numbers. `Scenario 3` recovered lag much faster
because the replica was able to apply the backlog faster. `Seconds_Behind_Source` is still not a
perfect throughput metric, but in this test it gives a useful operational view of the same behavior:
the replica caught up sooner when `WRITESET` made better use of the worker threads.

### What the Results Show

The experiment supports two practical conclusions:

- More replica workers do not automatically mean more parallel apply. In `Scenario 2`, most workers
  spent much of the apply phase waiting.
- `WRITESET` improved apply performance because it made more transaction independence visible to
  the replica. In `Scenario 3`, the replica applied more transactions at the same time and finished
  the backlog much faster than in `Scenario 2`.

The main lesson is not that one setting is magically faster in every situation. The lesson is that
replication performance depends on both the capacity configured on the replica and the dependency
information produced by the primary.

Next, we will look at what these results mean in practice and where the experiment's conclusions
should be applied carefully.

## Interpreting the Results and Their Limits

The results raise a few practical questions. How should we approach replication performance tuning
in a real setup? Does the better result in `Scenario 3` mean that `WRITESET` always gives the best
performance? Which metrics are the most useful when judging replica apply behavior?

### Check Worker Activity, Not Only Worker Count

When a replica is lagging, it is tempting to first increase `replica_parallel_workers`. That can
help, but only if the replica can actually schedule work across those workers.

The worker count tells us how much parallel apply capacity is configured. It does not tell us how
much parallel apply is happening. For that, we need to look at worker activity: how many workers are
applying transactions, how many are waiting, and whether the coordinator is the bottleneck.

In this experiment, `Scenario 2` had 4 configured workers but averaged only 1.21 applying
transactions at a time. That is the diagnostic signal. The replica had more workers available, but
the dependency information did not let the coordinator keep them busy.

### WRITESET Exposes Independence, It Does Not Create It

`WRITESET` helped in this demo because the workload updated non-overlapping ranges of rows. The
transactions were independent enough that the replica could apply many of them in parallel once the
primary recorded better dependency metadata.

That does not mean `WRITESET` can make every workload parallel. If transactions update the same rows
or otherwise conflict, they cannot safely be applied at the same time. In that case, more accurate
dependency tracking will still respect those conflicts.

A good way to think about it is this: `WRITESET` helps MySQL see independence that already exists in
the workload. It does not manufacture independence when the workload itself is dependent.

### Workload Nature Can Limit the Use of WRITESET

There is another limit to keep in mind: some workloads and schemas do not give MySQL enough usable
dependency information for `WRITESET` to help.

For example, `WRITESET` depends on MySQL being able to identify which rows a transaction changed.
Tables without primary or unique keys make that harder. Transactions that mix schema changes with
data changes, or workloads with foreign-key relationships that create wider dependencies, can also
reduce the amount of safe parallelism available to the replica. Large transactions have a similar
effect: even if they are valid, they can keep workers busy for longer and force later work to wait.

In those cases, MySQL may handle the transaction using non-write-set dependency tracking, which gives
the replica less precise dependency information and can reduce parallel apply opportunities.

This experiment does not prove that `WRITESET` is always the best answer for every workload. We did
not test workloads dominated by conflicting row updates, hot rows, long-running transactions, or
transactions with heavy execution time on the replica. Those patterns can reduce parallel apply even
when write-set tracking is enabled.

The test workload also used low client-side concurrency. A workload with higher source-side
concurrency can create larger commit windows on the primary, which may allow `COMMIT_ORDER` to
expose more parallelism than it did in this lab. That does not invalidate the result; it defines its
scope.

We chose this workload because it represents a common OLTP-style application pattern: short
transactions that update existing business records, where most requests touch different rows instead of intentionally targeting the same hot row.

The practical point is simple: before expecting `WRITESET` to improve replica apply performance,
look at the workload and schema. Tables should have stable primary or unique keys, schema changes
should not be mixed into heavy write periods, and large batch changes should be split into smaller
transactions when possible. Otherwise, the replica may still have little dependency freedom even when
the setting looks correct.

## Conclusion

The experiment started from a common replication tuning question: when a MySQL replica falls behind,
is increasing the number of replica workers enough?

In this lab, the answer was no. Moving from one worker to four workers under `COMMIT_ORDER` added
capacity, but it did not create meaningful parallel apply. The replica still averaged close to one
active worker.

Changing the source-side dependency tracking to `WRITESET` changed the result. With the same four
workers and the same workload shape, the replica used its workers more effectively, applied the
backlog faster, and recovered replication lag sooner.

The main lesson is that replica workers provide execution capacity, but dependency tracking
determines whether that capacity is usable. More workers do not automatically mean more parallel
apply, and `WRITESET` helps only when the workload contains transactions that can safely run in
parallel.

For real systems, the useful signal is not the configured worker count alone. Check worker activity,
the dependency tracking mode, and the workload shape. Together, those explain replica apply
performance better than replication lag alone.

The lab repository contains the Docker Compose setup, MySQL configuration, workload generator, and
scenario scripts used to reproduce the comparison.
