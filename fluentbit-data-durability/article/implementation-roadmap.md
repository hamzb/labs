# Implementation Roadmap

Complete the lab and article over focused sessions. Build evidence first, write
supported sections as results become available, and postpone strong conclusions
until experiments validate them.

## Session 1: Freeze scope and assumptions

Create `article/lab-design.md`. Record all component versions, host resources,
node count, runtime log rotation, and included and excluded failure scenarios.

Begin with Loki outage, Fluent Bit pod replacement during an outage, filesystem
queue exhaustion, and retry exhaustion. Defer node loss, corruption, and actual
power-loss testing until the core lab is reliable.

**Deliverable:** fixed version list and experiment matrix.

## Session 2: Build the deterministic logger

Implement one configurable logger image and deploy it as `logger-steady` and
`logger-burst`. Include `app`, `run_id`, `boot_id`, `seq`, `emitted_at`, and a
configurable payload in every record. Verify unbuffered, one-line JSON output,
monotonic sequences, configurable rate and size, and known generated counts.

**Deliverable:** both logger deployments running in k3s.

## Session 3: Deploy Loki and Grafana

Deploy a small single-instance Loki, local persistence if practical, and Grafana
with a provisioned Loki datasource. Verify test ingestion and querying.

**Deliverable:** test logs visible and queryable through Grafana.

## Session 4: Establish the basic Fluent Bit pipeline

Configure only the Tail input, CRI parser, Tail position database, Kubernetes
filter, Loki output, and HTTP monitoring endpoint. Verify collection from both
loggers, parsing, enrichment, controlled label cardinality, sequence queries,
and monitoring endpoints.

**Deliverable:** a minimal working end-to-end pipeline.

## Session 5: Build the validator and baseline

Create a validator that accepts a `run_id` and reports expected, received,
unique, missing, and duplicate records plus missing ranges. Save experiment
metadata, exact configuration, generated counts, validation, before/after
metrics, and notes under `experiments/results/<run-id>/`.

Do not inject failures until repeated baseline runs report zero missing records
and the expected duplicate count.

**Deliverable:** a trustworthy baseline and repeatable validator.

## Session 6: Test memory-only buffering

Test a short Loki outage, an outage long enough to reach `Mem_Buf_Limit`, and a
Fluent Bit pod deletion with pending records. Capture pause state, memory use,
runtime log growth, retries, missing and duplicate sequences, and drain time.

**Deliverable:** memory-only results and an evidence-backed article subsection.

## Session 7: Test filesystem buffering

Add `storage.path`, `storage.type filesystem`, persistent `hostPath`,
`storage.sync normal`, and unlimited retries. Repeat Session 6 without changing
other relevant settings.

**Deliverable:** a memory-versus-filesystem comparison backed by validation and
metrics.

## Session 8: Test explicit discard policies

Test a small finite `Retry_Limit`, then a small `storage.total_limit_size`.
Determine when retries expire, whether drop metrics rise, which sequences
disappear, whether oldest records are evicted, and whether ingestion continues.

**Deliverable:** evidence that filesystem buffering cannot prevent policy-driven
discard.

## Session 9: Test Kubernetes persistence boundaries

Compare the container writable layer, `emptyDir`, and node-local `hostPath`.
Test container restart and pod replacement first; add node reboot after those
comparisons are reliable.

**Deliverable:** a verified persistence matrix.

## Session 10: Complete the article

Write in this order:

1. Experimental setup
2. Results
3. Tail buffers, position database, and chunks
4. Memory-only behavior
5. Filesystem behavior
6. Retry and capacity loss policies
7. Kubernetes persistence boundaries
8. Production recommendations
9. Introduction
10. Conclusion

Write the introduction and conclusion last so they reflect actual evidence.

**Deliverable:** an evidence-backed draft ready for publication editing.

## Experiment discipline

Define every run before executing it:

```yaml
run_id: fs-pod-restart-001
hypothesis: Filesystem-backed chunks survive Fluent Bit pod replacement.
profile: filesystem-normal
record_count: 50000
logger_rate_per_second: 200
payload_bytes: 256
fault:
  type: delete-fluent-bit-pod
  after_seconds: 30
backend_outage_seconds: 120
success_criteria:
  missing_records: 0
```

Change one independent variable per comparison. Preserve versions, the complete
Fluent Bit configuration, logger settings, fault timeline, metrics, validation,
and observations.

## End-of-session checklist

- Ensure the deliverable works or record why it does not.
- Save configurations, results, and notes.
- Record assumptions and unresolved questions.
- Update the article section supported by the evidence.
- Identify one concrete next action.
- Commit the completed unit when appropriate.

## Immediate next action

Create `article/lab-design.md`; collect installed k3s, Kubernetes, containerd,
Helm, and host-resource details; and pin component versions before implementing
the deterministic logger.
