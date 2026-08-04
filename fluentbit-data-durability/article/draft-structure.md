# How Durable Are Your Kubernetes Logs?

## Stress-testing Fluent Bit buffering, backpressure, and data-loss boundaries

## Article objective

This article will examine what happens after a Kubernetes application writes a
log record to standard output and identify the exact failure boundaries at which
that record can still be lost.

The article will assume that readers already understand Fluent Bit's purpose,
basic configuration model, and Kubernetes deployment pattern. It will focus on
buffering, persistence, backpressure, retry behavior, and the trade-offs between
performance, resource consumption, and durability.

The central question is:

> Once an application writes a log line to stdout, under exactly which failures
> can that record still disappear?

## 1. Introduction: durability is an end-to-end property

Open with the complete record path:

```text
application stdout
    -> container runtime log file
    -> Fluent Bit Tail input
    -> Fluent Bit chunk
    -> memory or filesystem buffer
    -> output retry queue
    -> logging-backend acknowledgement
    -> backend storage
```

Establish that "Fluent Bit read the record" and "the record is durable" are
different claims.

Introduce the delivery models relevant to the discussion:

- Best effort
- At-most-once delivery
- At-least-once delivery, including the possibility of duplicates
- Why the complete pipeline does not provide a general exactly-once guarantee

Distinguish the failure domains that will be tested:

- Fluent Bit process crash
- Fluent Bit container restart
- Pod replacement
- Node reboot
- Node loss
- Logging-backend outage
- Buffer capacity exhaustion
- Abrupt power loss

Emphasize that a configuration can survive one failure domain while remaining
vulnerable to another.

## 2. What Fluent Bit is actually buffering

Clarify three mechanisms that are frequently conflated.

### 2.1 Tail file buffers

Explain that `buffer_chunk_size` and `buffer_max_size` concern reading an
individual file and accommodating individual records. They do not define how
much undelivered output Fluent Bit can retain during a backend outage.

Discuss long-line behavior and why per-file buffers affect memory calculations
when many container log files are watched.

### 2.2 The Tail position database

Explain the SQLite database that maps files and inodes to read offsets. Cover:

- `DB`
- `DB.Sync`
- `DB.Journal_Mode`
- `DB.Locking`
- `Read_From_Head`
- `Rotate_Wait`

Make the key distinction:

> The Tail database is a checkpoint. It is not a durable copy of the records
> that Fluent Bit has read.

Explain why persisting the Tail database without persisting queued chunks does
not automatically provide durable delivery.

### 2.3 Fluent Bit chunks

Describe how parsed records are serialized into MessagePack chunks, associated
with a tag, routed to outputs, and tracked as the unit of flushing and retry.

Introduce chunk states:

- `up`: available in memory; filesystem-backed chunks also have disk storage
- `down`: retained only in filesystem storage until needed
- `busy`: currently being processed by an output

## 3. Memory-only buffering under backpressure

Cover:

- Default in-memory chunk behavior
- `Mem_Buf_Limit`
- Input pause and resume behavior
- Memory protection during an output outage
- What is lost when Fluent Bit terminates with undelivered memory chunks
- Memory usage versus maximum outage duration

Emphasize an important Tail-input nuance: pausing ingestion is not necessarily
immediate data loss. The container runtime log file can temporarily act as an
upstream buffer, provided that it remains available and is not rotated or
deleted before Tail resumes.

Connect Fluent Bit backpressure to kubelet/container-runtime log rotation and
retention. Show that source retention is part of the durability budget.

## 4. Filesystem buffering and crash recovery

Introduce the relevant configuration areas:

```ini
[SERVICE]
    storage.path              /var/lib/fluent-bit/storage
    storage.sync              normal
    storage.checksum          off
    storage.max_chunks_up     128
    storage.backlog.mem_limit 32M

[INPUT]
    Name         tail
    storage.type filesystem
```

Explain:

- How filesystem-backed chunks differ from memory-only chunks
- Recovery of backlog chunks after Fluent Bit restarts
- `storage.max_chunks_up` as memory control rather than disk capacity
- `storage.backlog.mem_limit` and how recovered backlog enters memory
- `storage.sync normal` versus `storage.sync full`
- CRC32 integrity checking with `storage.checksum`
- I/O latency, CPU overhead, disk utilization, and disk-wear trade-offs

Avoid describing filesystem buffering as an absolute guarantee. Relate it to
the durability of the underlying Kubernetes volume and storage device.

## 5. Kubernetes storage changes the guarantee

Compare the storage choices used for the Tail database and Fluent Bit chunks:

| Storage location | Container restart | Pod replacement | Node reboot | Node loss |
|---|---:|---:|---:|---:|
| Container writable layer | Usually no | No | No useful guarantee | No |
| `emptyDir` | Yes | No | Depends on pod lifetime | No |
| Node `hostPath` | Yes | Yes on the same node | Usually | No |
| PersistentVolume | Yes | Yes | Backend-dependent | Backend-dependent |

Explain that the lab's `hostPath` profile demonstrates node-local persistence,
not protection against permanent node loss.

Discuss why both the Tail database and chunk storage must have explicitly chosen
persistence semantics, while remaining separate mechanisms.

## 6. Output retries are a data-loss policy

Cover:

- `Retry_Limit no_retries`
- A finite retry limit
- Unlimited retries with `False` or `no_limits`
- `scheduler.base` and `scheduler.cap`
- Exponential backoff and jitter
- Transient versus unrecoverable output errors
- What happens after retry exhaustion
- Queue growth when retries are unlimited

Emphasize:

> Filesystem buffering cannot prevent loss if the output policy eventually
> instructs Fluent Bit to discard a failed chunk.

Discuss how backend HTTP responses influence whether an output reports success,
retry, or an unrecoverable error.

## 7. Bounded storage means bounded durability

Explain `storage.total_limit_size` as a per-logical-output filesystem queue
limit. Describe the oldest-chunk eviction behavior after the limit is reached.

Introduce a capacity-planning approximation:

```text
required buffer
    = peak encoded ingest rate
    * maximum expected outage duration
    * safety factor
```

For an outage during which no data can drain:

```text
outage tolerance = usable queue capacity / encoded ingest rate
```

Explain why raw application log bytes are only an approximation. Account for:

- MessagePack encoding
- Kubernetes metadata enrichment
- Chunk and filesystem overhead
- Multiple output routes
- Filesystem reserved space
- A recovery period in which ingestion may still exceed drain throughput

Frame disk limits as an explicit policy decision: drop the oldest data, allow
unbounded disk consumption, or stop accepting new data elsewhere in the system.

## 8. Experimental setup

Present the local k3s topology:

```text
logger-steady --\
                 +-> container runtime logs -> Fluent Bit DaemonSet
logger-burst  --/                              | Tail input
                                                | Kubernetes filter
                                                | buffer profile
                                                v
                                               Loki -> Grafana
```

Describe the deterministic JSON records:

```json
{
  "app": "steady",
  "run_id": "fs-buffer-pod-restart-01",
  "boot_id": "b372...",
  "seq": 18421,
  "emitted_at": "2026-08-04T12:34:56.123Z",
  "payload": "..."
}
```

Explain why `run_id`, `boot_id`, and `seq` are needed to detect exact missing
ranges, application restarts, and duplicate delivery.

Document the two workloads:

- A continuous, steady-rate logger
- A configurable burst logger with adjustable record rate and payload size

State all pinned versions, resource limits, node properties, runtime log
rotation settings, volume paths, and storage capacity so that results are
reproducible.

## 9. Configuration profiles

Keep the input, filters, output, and workload constant while changing only the
settings relevant to the hypothesis.

### 9.1 Memory-only

- Memory-only chunks
- Small `Mem_Buf_Limit`
- Persistent Tail database
- Unlimited output retries

### 9.2 Filesystem with normal synchronization

- `storage.type filesystem`
- `storage.sync normal`
- Persistent `hostPath`
- Unlimited retries

### 9.3 Filesystem with full synchronization

- Same persistent storage
- `storage.sync full`
- Optional checksum validation

### 9.4 Bounded retries

- Filesystem buffering
- A deliberately small finite `Retry_Limit`

### 9.5 Bounded filesystem queue

- Filesystem buffering
- A deliberately small `storage.total_limit_size`

## 10. Failure experiments and results

Run a no-fault baseline before introducing failures. The baseline must prove
that the generation and validation method accounts for every sequence ID.

Use the following experiment matrix:

| Experiment | Injected fault | Main question |
|---|---|---|
| Baseline | None | Can every generated sequence ID be accounted for? |
| Short outage | Scale Loki to zero | Can Fluent Bit absorb and drain a temporary backlog? |
| Pod replacement | Delete the Fluent Bit pod during the outage | Do undelivered chunks survive replacement? |
| Process crash | Abruptly terminate Fluent Bit | What changes between memory and filesystem buffering? |
| Long outage | Exceed the memory buffer duration | Does Tail pause, and does source retention prevent loss? |
| Retry exhaustion | Configure a small retry limit | Are persisted chunks discarded after retries expire? |
| Queue exhaustion | Configure a small disk queue | Which sequence ranges are evicted? |
| Rotation pressure | Combine high volume, pause, and low runtime retention | Are unread source records rotated away? |
| Node restart | Restart k3s or reboot the node | Does node-local state recover correctly? |
| Sync comparison | Abrupt termination under `normal` and `full` | What durability and performance differences are observable? |

For each experiment, record:

- Exact configuration and image versions
- Fault-injection command and timeline
- Records generated
- Unique records found in Loki
- Missing sequence IDs and ranges
- Duplicate sequence IDs
- Recovery and backlog-drain duration
- Peak Fluent Bit memory usage
- Peak buffer disk usage
- Output retry and dropped-record metrics
- Fluent Bit warnings and errors

Clarify that `SIGKILL` tests process-crash recovery but does not reproduce a
power failure. Claims about dirty pages reaching storage require a node or VM
power-loss experiment.

## 11. Observability and validation

Use Fluent Bit's HTTP monitoring endpoint to inspect:

- Ingested input records
- Successfully processed output records
- Output retries, errors, and dropped records
- Input pause or over-limit state
- Memory and filesystem chunk counts
- Filesystem chunks in `up`, `down`, and `busy` states

Use Grafana to visualize behavior over time, but use a validation tool as the
source of evidence. The validator should query Loki by `run_id`, extract record
identities, and report results such as:

```text
generated:       50,000
received unique: 49,982
missing:         18
duplicates:      7
first gap:       12,441-12,458
```

Explain why aggregate counters alone cannot identify which records disappeared
or prove that there were no duplicates.

## 12. Interpreting the results

Separate observed facts from inferred explanations. For each profile, answer:

- Which failure domains did it survive?
- Where was the last durable copy of an undelivered record?
- What condition caused actual loss?
- Did recovery introduce duplicates?
- What resource cost bought the additional durability?
- What was the measurable recovery time?

Include a consolidated results table only after all tests have been run.

## 13. Production decision framework

Translate the results into several operational profiles rather than presenting
one universal configuration:

- Cost-optimized, best-effort collection
- Restart-safe node-local buffering
- Higher crash durability with stronger synchronization
- Bounded storage with an explicit acceptable recovery-point objective
- Workloads that require an application-level durable event pipeline instead of
  relying on stdout logs

Discuss how to choose values from measured inputs:

- Peak ingest rate
- Expected backend outage duration
- Drain throughput after recovery
- Container-runtime log retention
- Available node disk
- Acceptable record age and loss window
- Acceptable duplicate rate

## 14. Conclusion

Return to the end-to-end pipeline. Summarize that no single Fluent Bit setting
makes logs durable by itself.

The final conclusion should emphasize:

- The Tail database protects read position, not queued record contents.
- Memory limits control resource usage but shift buffering pressure upstream.
- Filesystem buffering extends recovery across selected failure domains only.
- The Kubernetes volume determines what "persistent" means.
- Retry limits and disk limits are explicit data-discard policies.
- At-least-once recovery can produce duplicates.
- Container-runtime retention and backend acknowledgement semantics remain part
  of the end-to-end durability guarantee.

Close with the principle that production configurations should be based on an
explicit failure model, recovery-point objective, outage budget, and verified
experiments rather than copied defaults.

## Evidence and references to collect

Prefer primary sources and pin each citation to the Fluent Bit version used by
the lab. Collect references for:

- Tail buffers and the SQLite position database
- Buffering and filesystem storage
- Backpressure behavior
- Scheduling and output retries
- Output queue limits and eviction
- Monitoring metrics and storage endpoints
- Kubernetes DaemonSet deployment
- Loki output acknowledgement and retry behavior
- k3s/containerd log rotation and retention
- Kubernetes volume lifecycle guarantees

Screenshots, metric snapshots, configurations, validation reports, and raw
experiment metadata should be retained under `article/assets/` and `experiments/results/`
so every substantive durability claim can be traced to documentation or a
repeatable lab result.
