# Jellyfin → Kubernetes Migration Design

**Date:** 2026-07-31
**Status:** Approved (pending spec review)

## Goal

Migrate Jellyfin from a Docker Compose stack on Dockge (running in a Proxmox LXC) to
the Kubernetes homelab cluster, preserving Intel iGPU hardware transcoding, existing
media (TrueNAS NFS), and the current Jellyfin configuration/library database.

## Current State (source)

- **Runtime:** `jellyfin/jellyfin:10.11.11` via Docker Compose on Dockge, inside a Proxmox LXC on host `pve1`.
- **GPU:** Intel iGPU, VAAPI. Delivered by bind-mounting host `/dev/dri` into the LXC/container.
  Container runs as `user 1000:1000` with `group_add: [44 (video), 104 (render)]`.
- **Volumes:**
  - `/apps/jellyfin/config` → `/config` (local bind)
  - `/apps/jellyfin/cache` → `/cache` (local bind)
  - `/mnt/media/movies` → `/movies` (TrueNAS NFS, RW)
  - `/mnt/media/series` → `/series` (TrueNAS NFS, **read-only**)
  - `/mnt/media/private` → `/private` (TrueNAS NFS, RW)
- **Networking:** `8096/tcp` (web/API) via Traefik at `jellyfin.docker.int.shimmerlabs.xyz`;
  `1900/udp` + `7359/udp` (DLNA / LAN auto-discovery).
- **Clients:** Web UI + Infuse (Apple TV). Both use the Jellyfin HTTP API via the server URL —
  **neither needs DLNA**, so the udp ports are dropped in the migration.

## Target State (destination)

- **k8s node:** `k8s-w-2` — a KVM VM on `pve1`. Confirmed today it has **no `/dev/dri`**; the iGPU
  does not yet reach the VM. This is the migration's gating dependency.
- **Domain:** `jellyfin.k8s.shimmerlabs.xyz`, HTTPS via Gateway API (existing `homelab` gateway).

## Architecture — Two Layers

### Layer 1 — Proxmox (manual, out-of-repo)

Move the Intel iGPU from the Dockge LXC to the `k8s-w-2` VM via PCIe passthrough.

1. Stop the Dockge Jellyfin container (frees `/dev/dri`).
2. Remove the `/dev/dri` bind mount + cgroup device allow from the Dockge LXC config.
3. On `pve1`: VFIO-bind the iGPU and add it as a PCI device to VM `k8s-w-2`; reboot the VM.
4. Verify inside `k8s-w-2`:
   - `ls -l /dev/dri` shows `card0` + `renderD128`.
   - Capture the render device group GID: `stat -c '%g' /dev/dri/renderD128`.
     This GID feeds the pod's `supplementalGroups` (compose used `104`, but the VM's GID
     must be confirmed — distros vary, e.g. `render` = 993/104/106).

**Risk:** Intel iGPU VFIO passthrough can be finicky — IOMMU group isolation and host
framebuffer holding the device are the usual culprits. `pve1` is headless, which makes it
likely to work, but this is the step most likely to fight back. Fully reversible: detach the
PCI device and re-add the LXC bind mount.

**Chosen GPU delivery:** PCIe passthrough + Intel GPU Device Plugin (k8s-native scheduling).
Rejected alternatives: hostPath `/dev/dri` + privileged pod (requires the same passthrough
step but loses scheduler awareness); converting the worker to LXC (painful with the Cilium
eBPF stack; the cluster standardizes on VMs).

### Layer 2 — Kubernetes (in-repo, two charts)

#### `charts/intel-device-plugin` — core infrastructure

- Registered in `charts/argocd-apps/values.yaml` under `apps:` (per the app-of-apps
  convention: cluster capabilities like Cilium/CSI live in the app-of-apps; leaf workloads
  do not). Namespace `intel-device-plugin` (or `kube-system`), wave `0`.
- Wraps `intel/intel-device-plugins-operator` (0.36.0) + `intel/intel-device-plugins-gpu`
  (0.36.0), which deploys a `GpuDevicePlugin` custom resource.
- Node targeting: single known GPU node, so pin the plugin's DaemonSet via `nodeSelector`
  to `k8s-w-2` and **disable NFD dependency** (no cluster-wide Node Feature Discovery needed
  for one hand-labeled node). Label the node (e.g. `intel.feature.node.kubernetes.io/gpu: "true"`
  or a simple custom label) as part of deploy.
- Result: `k8s-w-2` advertises `gpu.intel.com/i915: 1`. `sharedDevNum` left at default (1 consumer);
  can be raised later if another workload needs the iGPU.

#### `charts/jellyfin` — leaf workload (bare Helm chart, like `charts/paperless`)

- **Dependency:** official `jellyfin/jellyfin` chart (v3.2.0). Override image tag to `10.11.11`
  to match the current version. Upstream ingress disabled (we use a custom HTTPRoute template).
- **GPU:** pod resource request/limit `gpu.intel.com/i915: 1`. This makes the scheduler
  auto-place the pod on `k8s-w-2` — no manual `nodeSelector` on the workload required. No
  privileged pod.
- **securityContext:** `runAsUser: 1000`, `runAsGroup: 1000`,
  `supplementalGroups: [44, <render-gid-from-Layer-1-step-4>]`, `fsGroup: 1000`.
- **Storage:**

  | Source (compose) | k8s target |
  |---|---|
  | `/config` (local bind) | iSCSI PVC, StorageClass `truenas-iscsi`, RWO, ~10Gi, `retain: true` |
  | `/cache` (local bind) | `emptyDir` (ephemeral; transcode/image cache regenerates) |
  | `/movies` (NFS RW) | direct **NFS volume** → existing TrueNAS export, RW |
  | `/series` (NFS RO) | direct **NFS volume** → existing TrueNAS export, `readOnly: true` |
  | `/private` (NFS RW) | direct **NFS volume** → existing TrueNAS export, RW |

  Media uses **direct NFS volumes pointed at the existing TrueNAS exports** — no
  democratic-csi, no reprovisioning. Existing data stays in place. NFS server + export paths
  to be captured from the current TrueNAS config during planning.

- **Ingress:** custom Gateway API `HTTPRoute` template (copied from `charts/paperless/templates/httproute.yaml`):
  - hostname `jellyfin.k8s.shimmerlabs.xyz`
  - `parentRefs` → gateway `homelab` in namespace `gateway`, `sectionName: https`
  - backend → jellyfin service port `8096`
- **Env:** `JELLYFIN_PublishedServerUrl=https://jellyfin.k8s.shimmerlabs.xyz`.
- **Dropped:** `1900/udp` + `7359/udp` (DLNA/discovery) — not needed by web UI or Infuse.

## Config Migration (preserve existing setup)

Before decommissioning the Dockge Jellyfin, copy `/apps/jellyfin/config` from the Dockge LXC
into the new iSCSI `config` PVC. Method: a temporary helper pod mounting the PVC, then `rsync`
(or `kubectl cp`) the old config in. This preserves users, library definitions, metadata,
playback state, and API keys. Skipping this yields a blank Jellyfin install.

Cache is intentionally **not** migrated (emptyDir; regenerates on first use).

## Cutover Order

1. Layer 1: Proxmox iGPU passthrough to `k8s-w-2`; verify `/dev/dri` + capture render GID.
2. Deploy `charts/intel-device-plugin`; label the node; verify
   `kubectl describe node k8s-w-2` shows `gpu.intel.com/i915: 1` allocatable.
3. Provision the `config` iSCSI PVC and seed it with the old config (helper pod + rsync).
4. Deploy `charts/jellyfin` (register in argocd-apps only if desired; otherwise bare `helm`/ArgoCD app —
   leaf workloads are not required to be in app-of-apps).
5. Verify: web UI loads; play a file and confirm the Jellyfin dashboard shows **VAAPI hardware
   transcoding** active.
6. Repoint Infuse (Apple TV) + browser bookmarks to `https://jellyfin.k8s.shimmerlabs.xyz`.
7. Decommission the Dockge Jellyfin stack.

## Decisions (settled)

- **Cache volume:** `emptyDir` (simple; regenerates).
- **Device plugin placement:** registered in `argocd-apps` (core-infra convention).
- **Jellyfin chart:** official `jellyfin/jellyfin` (no jellyfin chart exists under gabe565).
- **GPU delivery:** PCIe passthrough + Intel GPU Device Plugin.

## Open Items to Resolve During Planning

- Exact TrueNAS NFS server address + export paths for movies / series / private.
- The render device GID inside `k8s-w-2` (post-passthrough), for `supplementalGroups`.
- Confirm the official `jellyfin/jellyfin` chart's value keys for: arbitrary NFS volumes +
  volumeMounts, `gpu.intel.com/i915` resource request, and pod `supplementalGroups`
  (fall back to bjw-s `app-template` or a hand-written Deployment only if the official chart
  can't express one of these).
- Node labeling scheme for the Intel plugin (custom label vs NFD).

## Out of Scope

- DLNA / LAN auto-discovery (dropped).
- Media storage reprovisioning (existing TrueNAS NFS reused as-is).
- Multi-node GPU / multiple GPU consumers (single iGPU, single consumer for now).
