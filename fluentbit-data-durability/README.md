# Fluent Bit Data Durability Lab

An experiment-driven Kubernetes lab for studying Fluent Bit buffering,
backpressure, retry behavior, and log-loss boundaries.

## Repository layout

- `article/`: article drafts, publication assets, lab notes, and roadmap.
- `k8s/base/`: shared namespace and Kubernetes resources.
- `k8s/logger/`: deterministic steady-rate and burst logger workloads.
- `k8s/fluent-bit/base/`: common Fluent Bit DaemonSet and configuration.
- `k8s/fluent-bit/profiles/`: durability configuration variants.
- `k8s/loki/`: Loki deployment configuration.
- `k8s/grafana/`: Grafana deployment and provisioning.
- `experiments/scenarios/`: repeatable fault-injection definitions.
- `experiments/results/`: evidence organized by experiment run.
- `scripts/`: deployment, metrics collection, and result validation helpers.

## Planned workflow

1. Deploy Loki, Grafana, and two deterministic logger workloads to local k3s.
2. Establish a no-fault baseline and verify every generated sequence ID.
3. Apply one Fluent Bit durability profile at a time.
4. Inject controlled backend, process, pod, storage, and node failures.
5. Compare missing records, duplicates, recovery time, memory, and disk usage.
6. Use the captured results as evidence for the technical article.

Implementation and version pins will be added incrementally as the lab is built.
