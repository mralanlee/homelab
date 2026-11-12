# otel-collector

Wraps the upstream `opentelemetry-collector` chart (0.178.3, collector 0.163.2) twice,
shipping to OpenObserve (`charts/openobserve`), org `default`:

- **agent** (DaemonSet, every worker node): pod container logs → stream `k8s`;
  `kubeletstats` (node/pod/container CPU, memory, network, fs) and `hostmetrics`
  (node CPU, load, memory, disk, network; hardened, mounts only /proc and /sys)
  → metrics streams named after each metric (`k8s_*`, `system_*`)
- **cluster** (`otel-cluster` alias, one-replica Deployment): `k8s_cluster` metrics
  (deployment/pod/node state, restarts, quotas) and Kubernetes events → stream
  `k8s_events`. One replica because these watch the API server; per node they would
  duplicate

- Logs, metrics and events; no traces. No OTLP/Jaeger/Zipkin listeners and no hostPorts: applications that
  speak OTLP push straight to OpenObserve, as its README says
- Each record carries `k8s.namespace.name`, `k8s.pod.name`, `k8s.container.name`,
  `k8s.job.name`, … (the `k8s_attributes` processor)
- Read offsets are kept on the node (`/var/lib/otelcol`), so a restarted agent
  neither re-sends nor skips lines. A new agent starts at the end of each file:
  nothing older than its first start is shipped
- Not on the control-plane node (no toleration)
- Credentials: external-secrets builds the Basic auth header from the 1Password
  item `openobserve-ingest` (the dedicated ingest user, not root) into Secret
  `otel-collector-openobserve`. Both collectors read it at start only: restart
  the DaemonSet and the `otel-cluster` Deployment after the Secret changes

## Why it exists

Pods that cannot push telemetry themselves still need their logs kept. The case
that prompted it: lace worker Jobs are deleted 5 minutes after they finish and
have no route to OpenObserve, so their container log was lost. Lace redacts
secret values from that log at the source (mralanlee/lace `harness/shared/redact.mjs`).

## Exclusions

`alternateConfig.receivers.file_log.exclude` in `values.yaml`:

- the agent's own log
- OpenObserve's own pods: it logs every ingest request, so shipping that log
  back to it loops (seen: ~3,000 lines a minute)
- lace's `control-plane` container, which exports its own structured logs over
  OTLP; tailing it too would store every line twice

## Volume

Everything else on the worker nodes is collected. OpenObserve's retention is its
default (no `ZO_COMPACT_DATA_RETENTION_DAYS` set) on a 50Gi PVC, so watch the
`k8s` stream's size, and add a namespace to the exclude list if one is noisy.

## Deploy

Synced by ArgoCD (app-of-apps, namespace `otel-collector`, wave 11). Push to `main` deploys.
