# Homelab Capacity Dashboard — Design

**Date:** 2026-07-22
**Status:** Approved (design), pending implementation plan

## Goal

A Grafana dashboard showing how much cluster compute is allocated and how much
headroom remains, delivered via GitOps as its own ArgoCD application. "Headroom"
covers both meanings:

- **Schedulable headroom** = node allocatable − sum(pod requests). What the
  scheduler cares about ("can I fit more pods").
- **Live usage headroom** = allocatable − actual usage right now. What's
  physically free.

Both are shown side by side so the user can see over-provisioned requests vs
genuinely exhausted metal.

## Context (current state)

- Grafana runs as a standalone chart (`charts/grafana`), already registered as a
  core ArgoCD app in `charts/argocd-apps/values.yaml`.
- Grafana currently fetches the dotdc dashboard set via `download_dashboards.sh`
  (URL-fetch pattern). The dashboard **sidecar is not enabled**.
- **No Prometheus datasource is provisioned in GitOps.** Existing dashboards rely
  on a datasource added manually via the UI (persisted on the 10Gi PVC). This is
  fragile — a fresh install / PVC loss yields blank dashboards.
- Prometheus: `http://kube-prometheus-stack-prometheus.monitoring.svc:9090`.
- kube-state-metrics: `monitoring` namespace (provides `kube_*` metrics).
- node-exporter (kube-prometheus-stack) provides `node_*` metrics.
- metrics-server present (not used by this dashboard; Prometheus is the source).

## Architecture

Three units, each independently understandable:

### 1. `charts/homelab-dashboards` — new chart (own ArgoCD app)

- Bare Helm chart, **no upstream dependency** — templates only.
- `Chart.yaml` (v0.1.0, type application).
- `values.yaml` — dashboard folder name (`Homelab`), datasource uid
  (`prometheus`).
- `templates/cluster-capacity.yaml` — a ConfigMap:
  - labeled `grafana_dashboard: "1"` (sidecar discovery),
  - annotated `grafana_folder: Homelab` (folder placement),
  - data key `cluster-capacity.json` = the dashboard JSON.
- Deployed to the `grafana` namespace so the in-namespace sidecar discovers it.
- Registered in `charts/argocd-apps/values.yaml`: name `homelab-dashboards`,
  path `charts/homelab-dashboards`, namespace `grafana`, `syncWave` after grafana.

Rationale for a separate app (vs embedding in the grafana chart): decouples
dashboard edits from grafana releases and scales to future custom dashboards —
any labeled ConfigMap is auto-discovered.

### 2. `charts/grafana/values.yaml` — enable sidecar + provision datasource

One-time additions to the grafana chart values:

- **Dashboard sidecar:**
  - `sidecar.dashboards.enabled: true`
  - `sidecar.dashboards.label: grafana_dashboard`
  - `sidecar.dashboards.folderAnnotation: grafana_folder`
  - `sidecar.dashboards.searchNamespace: grafana` (or `ALL`)
  - keep `sidecar.dashboards.provider.foldersFromFilesStructure` off; folder comes
    from the annotation.
- **Datasource provisioning** (`datasources.datasources.yaml`):
  - name `Prometheus`, uid `prometheus`, type `prometheus`, `isDefault: true`,
    url `http://kube-prometheus-stack-prometheus.monitoring.svc:9090`, access
    `proxy`.

The existing URL-fetched dotdc dashboards remain unaffected (they load via the
existing file provider). New dashboard binds to datasource uid `prometheus`.

### 3. Dashboard JSON — `cluster-capacity.json`

Datasource: uid `prometheus`. Sections:

**A. Cluster rollup** (stat + gauge panels)

CPU and Memory, each: allocatable / requested / used, plus two headroom gauges —
schedulable and live.

Cluster PromQL:
- alloc CPU: `sum(kube_node_status_allocatable{resource="cpu"})`
- req CPU: `sum(kube_pod_container_resource_requests{resource="cpu"})`
- used CPU (cores): `sum(rate(node_cpu_seconds_total{mode!="idle"}[5m]))`
- alloc Mem: `sum(kube_node_status_allocatable{resource="memory"})`
- req Mem: `sum(kube_pod_container_resource_requests{resource="memory"})`
- used Mem: `sum(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)`
- schedulable headroom % CPU: `100 * (1 - <reqCPU>/<allocCPU>)`
- live headroom % CPU: `100 * (1 - <usedCPU>/<allocCPU>)` (same shape for Mem)

**B. Timeseries**
- CPU requested vs used over time.
- Mem requested vs used over time.

**C. Per-node table** (instant queries, joined by node)

Row per node: allocatable, requested, used, % committed (requests/allocatable),
headroom cores / headroom GiB.
- allocatable by node: `kube_node_status_allocatable{resource="cpu"|"memory"}`
  (has `node` label).
- requests by node: `sum by (node)(kube_pod_container_resource_requests{resource=...})`.
- **usage by node** requires joining node-exporter (`instance` = IP:port) to the
  `node` label. Approach: `label_replace` / join through `kube_node_info` (or
  node-exporter recording rules from the kube-prometheus-stack mixin if present).
  **This is the one real implementation risk** — the plan must pin the exact join
  expression and verify against the live cluster.

**D. Capacity projection** (labeled as an estimate)
- "≈ N more average-size pods fit" =
  `floor(min(cpuHeadroom / avgCpuReq, memHeadroom / avgMemReq))`, where
  `avgCpuReq = sum(requests cpu) / count(running pods)` (same for mem);
  running pods via `count(kube_pod_status_phase{phase="Running"} == 1)`.
- pods running vs capacity per node: `count by (node)(kube_pod_info)` vs
  `kube_node_status_capacity{resource="pods"}`.

## Caveats / non-goals

- Projection is deliberately approximate — average pod size hides bimodal
  workloads. Panel is labeled "estimate."
- Dashboard reflects Kubernetes allocatable, not raw Proxmox host capacity.
  Adding a VM raises node allocatable; that is the lever this dashboard informs.
- No alerting in scope — visualization only.

## Success criteria

- ArgoCD syncs `homelab-dashboards` cleanly; dashboard appears in Grafana under
  the `Homelab` folder with live data.
- All cluster rollup panels render non-empty values.
- Per-node table shows one row per node with usage populated (join verified).
- Datasource survives a grafana pod restart / fresh install (provisioned, not
  UI-added).
