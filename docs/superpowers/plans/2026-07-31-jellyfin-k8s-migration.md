# Jellyfin → Kubernetes Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Jellyfin on the k8s cluster with Intel iGPU hardware transcoding, reusing existing TrueNAS NFS media and the current Jellyfin config, replacing the Dockge compose stack.

**Architecture:** Two layers. Layer 1 (manual Proxmox) passes the Intel iGPU from the Dockge LXC to the `k8s-w-2` VM. Layer 2 (repo) adds a core-infra `intel-device-plugin` chart that advertises `gpu.intel.com/i915`, and a leaf `jellyfin` chart (wraps the official `jellyfin/jellyfin` chart like `charts/paperless` wraps `paperless-ngx`) that requests the GPU, mounts the config on iSCSI, media over direct NFS, and exposes the UI via a Gateway API HTTPRoute.

**Tech Stack:** Helm, ArgoCD app-of-apps, official `jellyfin/jellyfin` chart v3.2.0 (appVersion overridden to 10.11.11), `intel/intel-device-plugins-operator` + `intel/intel-device-plugins-gpu` 0.36.0, Gateway API (Cilium), democratic-csi `truenas-iscsi` StorageClass, TrueNAS NFS.

## Global Constraints

- Domain: all services under `k8s.shimmerlabs.xyz`. Jellyfin host: `jellyfin.k8s.shimmerlabs.xyz`.
- Ingress is **Gateway API HTTPRoute** only (parent gateway `homelab` in namespace `gateway`, `sectionName: https`). No upstream chart Ingress objects.
- iSCSI StorageClass: `truenas-iscsi` (RWO).
- Chart tarballs (`charts/*/charts/*.tgz`) are gitignored; run `helm dependency update` after editing `Chart.yaml`. Commit `Chart.lock`.
- Core infra is registered in `charts/argocd-apps/values.yaml`; leaf workloads are not required to be.
- Jellyfin runs as `runAsUser: 1000`, `runAsGroup: 1000`, `supplementalGroups: [44, <RENDER_GID>]`, `fsGroup: 1000`. `<RENDER_GID>` = the group GID of `/dev/dri/renderD128` inside `k8s-w-2`, captured in Task 1.
- No DLNA (`1900/udp`, `7359/udp` dropped).

---

## File Structure

- `charts/intel-device-plugin/Chart.yaml` — deps: operator + gpu plugin (0.36.0).
- `charts/intel-device-plugin/values.yaml` — pin plugin DaemonSet to `k8s-w-2`, disable NFD.
- `charts/intel-device-plugin/Chart.lock` — generated.
- `charts/argocd-apps/values.yaml` — add `intel-device-plugin` app entry.
- `charts/jellyfin/Chart.yaml` — dep: `jellyfin/jellyfin` v3.2.0.
- `charts/jellyfin/values.yaml` — config PVC, emptyDir cache, 3 NFS media mounts, GPU request, securityContext, published URL.
- `charts/jellyfin/templates/httproute.yaml` — Gateway API HTTPRoute (adapted from paperless).
- `charts/jellyfin/templates/_helpers.tpl` — labels helper.
- `charts/jellyfin/Chart.lock` — generated.
- `docs/runbooks/jellyfin-gpu-passthrough.md` — Layer 1 manual steps (Task 1).
- `docs/runbooks/jellyfin-config-migration.md` — config seed steps (Task 6).

---

## Task 1: Proxmox iGPU passthrough to `k8s-w-2` (manual runbook)

**Files:**
- Create: `docs/runbooks/jellyfin-gpu-passthrough.md`

**Interfaces:**
- Produces: `/dev/dri` inside `k8s-w-2`; the `<RENDER_GID>` value (group GID of `renderD128`) used by Task 4's `supplementalGroups`; node label `intel.feature.node.kubernetes.io/gpu=true` on `k8s-w-2` consumed by Task 3's plugin `nodeSelector`.

This task is manual infrastructure work on Proxmox `pve1` and the k8s node. It produces a runbook and leaves the node GPU-ready. There is no unit test; verification is command output.

- [ ] **Step 1: Stop the source Jellyfin and release the iGPU from the Dockge LXC**

On Dockge, stop the `jellyfin` compose stack. Then on `pve1`, edit the Dockge LXC config (`/etc/pve/lxc/<DOCKGE_CTID>.conf`) and remove the `/dev/dri` passthrough lines (the `lxc.mount.entry` for `/dev/dri` and the `lxc.cgroup2.devices.allow` for major `226`). Keep a copy of the removed lines in the runbook for rollback.

- [ ] **Step 2: VFIO-bind the iGPU and attach it to `k8s-w-2`**

On `pve1`, identify the iGPU PCI address:

```bash
lspci -nn | grep -Ei 'VGA|Display'   # note the address, e.g. 00:02.0, and the [8086:xxxx] id
```

Ensure IOMMU is enabled (kernel cmdline `intel_iommu=on iommu=pt`; already required for any passthrough). Add the device to the VM (replace `<VMID>` for `k8s-w-2` and `<PCI_ADDR>`):

```bash
qm set <VMID> -hostpci0 <PCI_ADDR>,pcie=1
```

Document in the runbook that this dedicates the iGPU to `k8s-w-2` (host + other guests lose it), and that rollback is `qm set <VMID> -delete hostpci0` plus restoring the LXC lines from Step 1.

- [ ] **Step 3: Reboot the VM and verify the GPU is present**

```bash
qm stop <VMID> && qm start <VMID>
# then SSH into k8s-w-2:
ls -l /dev/dri            # expect card0 + renderD128
stat -c '%g' /dev/dri/renderD128   # RECORD THIS NUMBER = <RENDER_GID>
```

Write the observed `<RENDER_GID>` into the runbook and into Task 4's values (the compose used `104`, but use the value observed here).

- [ ] **Step 4: Label the node for the Intel GPU plugin**

```bash
kubectl label node k8s-w-2 intel.feature.node.kubernetes.io/gpu=true --overwrite
kubectl get node k8s-w-2 --show-labels | tr ',' '\n' | grep intel
```
Expected: the `intel.feature.node.kubernetes.io/gpu=true` label is present.

- [ ] **Step 5: Commit the runbook**

```bash
git add docs/runbooks/jellyfin-gpu-passthrough.md
git commit -m "docs(jellyfin): runbook for intel igpu passthrough to k8s-w-2"
```

---

## Task 2: Scaffold `charts/intel-device-plugin`

**Files:**
- Create: `charts/intel-device-plugin/Chart.yaml`, `charts/intel-device-plugin/values.yaml`
- Generate: `charts/intel-device-plugin/Chart.lock`

**Interfaces:**
- Consumes: node label from Task 1 Step 4.
- Produces: cluster resource `gpu.intel.com/i915` advertised by `k8s-w-2` (once deployed in Task 3/7). Chart path `charts/intel-device-plugin` consumed by Task 3.

- [ ] **Step 1: Write `Chart.yaml`**

```yaml
apiVersion: v2
name: intel-device-plugin
description: Intel GPU Device Plugin (operator + gpu plugin) for iGPU transcoding
type: application
version: 0.1.0
appVersion: "0.36.0"
dependencies:
  - name: intel-device-plugins-operator
    version: 0.36.0
    repository: https://intel.github.io/helm-charts
  - name: intel-device-plugins-gpu
    version: 0.36.0
    repository: https://intel.github.io/helm-charts
    condition: intel-device-plugins-gpu.enabled
```

- [ ] **Step 2: Write `values.yaml`**

```yaml
# Operator installs the GpuDevicePlugin CRD + controller.
intel-device-plugins-operator:
  # Intel operator admission webhook is served with a cert-manager Certificate;
  # cluster already runs cert-manager (wave 0).
  manager:
    devices:
      gpu: true

# GpuDevicePlugin CR: single known GPU node, so skip NFD and pin by label.
intel-device-plugins-gpu:
  enabled: true
  name: gpudeviceplugin
  # sharedDevNum=1 => one pod may claim the iGPU at a time (single Jellyfin consumer).
  sharedDevNum: 1
  # No Node Feature Discovery in this cluster; we hand-label the node in Task 1.
  nodeFeatureRule: false
  nodeSelector:
    intel.feature.node.kubernetes.io/gpu: 'true'
```

- [ ] **Step 3: Resolve dependencies and lock**

```bash
helm dependency update charts/intel-device-plugin
```
Expected: two `.tgz` files downloaded under `charts/intel-device-plugin/charts/` and `Chart.lock` written.

- [ ] **Step 4: Lint and template-render**

```bash
helm lint charts/intel-device-plugin
helm template intel-device-plugin charts/intel-device-plugin -n intel-device-plugin | grep -E 'kind: (GpuDevicePlugin|Deployment|CustomResourceDefinition)'
```
Expected: renders without error; output includes `kind: GpuDevicePlugin` and the operator `Deployment`.

- [ ] **Step 5: Verify the plugin CR carries the node pin**

```bash
helm template intel-device-plugin charts/intel-device-plugin -n intel-device-plugin | grep -A3 'nodeSelector'
```
Expected: shows `intel.feature.node.kubernetes.io/gpu: 'true'` under the GpuDevicePlugin spec, and no NodeFeatureRule object is rendered.

- [ ] **Step 6: Commit**

```bash
git add charts/intel-device-plugin/Chart.yaml charts/intel-device-plugin/values.yaml charts/intel-device-plugin/Chart.lock
git commit -m "feat(intel-device-plugin): add Intel GPU device plugin chart"
```

---

## Task 3: Register `intel-device-plugin` in argocd-apps

**Files:**
- Modify: `charts/argocd-apps/values.yaml` (the `apps:` list, "Wave 0: core infrastructure" section)

**Interfaces:**
- Consumes: chart at `charts/intel-device-plugin` (Task 2).
- Produces: ArgoCD Application `intel-device-plugin` targeting namespace `intel-device-plugin`.

- [ ] **Step 1: Add the app entry**

Under the `# Wave 0: core infrastructure` block in `charts/argocd-apps/values.yaml`, add:

```yaml
  # Wave 0: Intel GPU device plugin — advertises gpu.intel.com/i915 on k8s-w-2.
  # serverSideApply: operator ships CRDs (GpuDevicePlugin) that exceed the
  # client-side last-applied annotation limit.
  - name: intel-device-plugin
    namespace: intel-device-plugin
    path: charts/intel-device-plugin
    serverSideApply: true
```

- [ ] **Step 2: Render argocd-apps and confirm the Application is present**

```bash
helm template argocd-apps charts/argocd-apps -n argocd | grep -A6 'name: intel-device-plugin'
```
Expected: an `Application` block with `path: charts/intel-device-plugin`, `destination` namespace `intel-device-plugin`, and the ServerSideApply sync option.

- [ ] **Step 3: Commit**

```bash
git add charts/argocd-apps/values.yaml
git commit -m "feat(argocd-apps): register intel-device-plugin core app"
```

---

## Task 4: Scaffold `charts/jellyfin` (chart + values)

**Files:**
- Create: `charts/jellyfin/Chart.yaml`, `charts/jellyfin/values.yaml`, `charts/jellyfin/templates/_helpers.tpl`
- Generate: `charts/jellyfin/Chart.lock`

**Interfaces:**
- Consumes: `<RENDER_GID>` (Task 1 Step 3); `truenas-iscsi` StorageClass; `gpu.intel.com/i915` (Task 2); TrueNAS NFS server address `<NFS_SERVER>` and export paths (obtained in Step 2 below).
- Produces: Deployment `jellyfin-jellyfin` and Service `jellyfin-jellyfin` on port `8096` (consumed by Task 5's HTTPRoute). Helper `jellyfin.labels` template consumed by Task 5.

- [ ] **Step 1: Write `Chart.yaml`**

```yaml
apiVersion: v2
name: jellyfin
description: Jellyfin media server for the homelab (Intel iGPU transcoding)
type: application
version: 0.1.0
appVersion: "10.11.11"
dependencies:
  - name: jellyfin
    version: 3.2.0
    repository: https://jellyfin.github.io/jellyfin-helm
    condition: jellyfin.enabled
```

- [ ] **Step 2: Obtain the TrueNAS NFS server + export paths**

The NFS server address is not stored in plaintext in this repo (democratic-csi reads it from a secret). Obtain it from the TrueNAS UI (Shares → NFS) or from the current Dockge host mounts:

```bash
# On the Dockge LXC host, inspect the existing NFS mounts backing /mnt/media:
findmnt -t nfs,nfs4 | grep -Ei 'movies|series|private|media'
```
Record the server IP/hostname as `<NFS_SERVER>` and the three export paths as `<EXPORT_MOVIES>`, `<EXPORT_SERIES>`, `<EXPORT_PRIVATE>` for the next step.

- [ ] **Step 3: Write `values.yaml`**

Substitute `<RENDER_GID>`, `<NFS_SERVER>`, and the three export paths with the real values from Task 1 Step 3 and Step 2 above.

```yaml
# Wraps the official jellyfin/jellyfin chart. Upstream Ingress is disabled;
# ingress is a Gateway API HTTPRoute in templates/httproute.yaml.
jellyfin:
  enabled: true

  image:
    tag: "10.11.11"

  # GPU: request one Intel i915 device. The scheduler auto-places the pod on the
  # node advertising gpu.intel.com/i915 (k8s-w-2), so no workload nodeSelector is needed.
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: "4"
      memory: 4Gi
      gpu.intel.com/i915: 1

  # user 1000:1000 + supplemental groups: 44 (video), <RENDER_GID> (render).
  podSecurityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    supplementalGroups:
      - 44
      - <RENDER_GID>

  service:
    port: 8096

  # We use a custom HTTPRoute, not the chart Ingress.
  ingress:
    enabled: false

  jellyfin:
    enableDLNA: false
    env:
      - name: JELLYFIN_PublishedServerUrl
        value: https://jellyfin.k8s.shimmerlabs.xyz

  persistence:
    # Config on iSCSI (RWO); node-pinned by the GPU anyway. Seeded in Task 6.
    config:
      enabled: true
      storageClass: truenas-iscsi
      accessMode: ReadWriteOnce
      size: 10Gi
    # Cache is ephemeral -> emptyDir (regenerates). Disable the bundled PVC.
    cache:
      enabled: false
    # Disable the single bundled media PVC; we mount 3 NFS shares below.
    media:
      enabled: false

  # Direct NFS mounts to the existing TrueNAS exports (no reprovisioning).
  volumes:
    - name: movies
      nfs:
        server: <NFS_SERVER>
        path: <EXPORT_MOVIES>
    - name: series
      nfs:
        server: <NFS_SERVER>
        path: <EXPORT_SERIES>
        readOnly: true
    - name: private
      nfs:
        server: <NFS_SERVER>
        path: <EXPORT_PRIVATE>
  volumeMounts:
    - name: movies
      mountPath: /movies
    - name: series
      mountPath: /series
      readOnly: true
    - name: private
      mountPath: /private

# Ingress values consumed by templates/httproute.yaml (Task 5).
ingress:
  hostname: jellyfin.k8s.shimmerlabs.xyz
  gatewayName: homelab
  gatewayNamespace: gateway
  gatewaySectionName: https
```

- [ ] **Step 4: Write `templates/_helpers.tpl`**

```yaml
{{- define "jellyfin.labels" -}}
app.kubernetes.io/name: jellyfin
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
```

- [ ] **Step 5: Resolve dependencies and lock**

```bash
helm dependency update charts/jellyfin
```
Expected: `jellyfin-3.2.0.tgz` under `charts/jellyfin/charts/` and `Chart.lock` written.

- [ ] **Step 6: Lint and verify the rendered Deployment has GPU + NFS + securityContext**

```bash
helm lint charts/jellyfin
helm template jellyfin charts/jellyfin -n jellyfin > /tmp/jf-render.yaml
grep -E 'gpu.intel.com/i915' /tmp/jf-render.yaml
grep -E 'server: <NFS_SERVER>|mountPath: /movies|mountPath: /series|mountPath: /private' /tmp/jf-render.yaml
grep -E 'supplementalGroups|runAsUser: 1000|fsGroup: 1000' /tmp/jf-render.yaml
grep -E 'storageClassName: truenas-iscsi' /tmp/jf-render.yaml
```
Expected: `gpu.intel.com/i915: "1"` in container resources; all three NFS mounts present; the pod securityContext block present; the config PVC uses `truenas-iscsi`. (Replace `<NFS_SERVER>` in the grep with the real value.)

- [ ] **Step 7: Commit**

```bash
git add charts/jellyfin/Chart.yaml charts/jellyfin/values.yaml charts/jellyfin/templates/_helpers.tpl charts/jellyfin/Chart.lock
git commit -m "feat(jellyfin): add jellyfin chart with iGPU transcoding + NFS media"
```

---

## Task 5: Add the Gateway API HTTPRoute to `charts/jellyfin`

**Files:**
- Create: `charts/jellyfin/templates/httproute.yaml`

**Interfaces:**
- Consumes: `jellyfin.labels` helper (Task 4); Service `jellyfin-jellyfin:8096` (Task 4); `.Values.ingress.*` (Task 4 values).
- Produces: HTTPRoute routing `jellyfin.k8s.shimmerlabs.xyz` → Jellyfin service.

- [ ] **Step 1: Confirm the rendered Service name and port**

```bash
helm template jellyfin charts/jellyfin -n jellyfin | grep -B2 -A8 'kind: Service'
```
Expected: a Service named `jellyfin-jellyfin` (release name + chart name) exposing port `8096`. Use the exact name observed here as the backend `name` in Step 2 (adjust if the upstream chart names it differently).

- [ ] **Step 2: Write `templates/httproute.yaml`**

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "jellyfin.labels" . | nindent 4 }}
spec:
  parentRefs:
    - name: {{ .Values.ingress.gatewayName | default "homelab" }}
      namespace: {{ .Values.ingress.gatewayNamespace | default "gateway" }}
      sectionName: {{ .Values.ingress.gatewaySectionName | default "https" }}
  hostnames:
    - {{ .Values.ingress.hostname }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {{ .Release.Name }}-jellyfin
          port: 8096
```

- [ ] **Step 3: Render and verify the HTTPRoute**

```bash
helm template jellyfin charts/jellyfin -n jellyfin | grep -A18 'kind: HTTPRoute'
```
Expected: HTTPRoute with `hostnames: [jellyfin.k8s.shimmerlabs.xyz]`, parent `homelab`/`gateway`/`https`, and `backendRefs` name `jellyfin-jellyfin` port `8096`. Confirm the backend name matches Step 1.

- [ ] **Step 4: Commit**

```bash
git add charts/jellyfin/templates/httproute.yaml
git commit -m "feat(jellyfin): expose UI via Gateway API HTTPRoute"
```

---

## Task 6: Config migration runbook (seed the iSCSI config PVC)

**Files:**
- Create: `docs/runbooks/jellyfin-config-migration.md`

**Interfaces:**
- Consumes: the `jellyfin` release deployed in Task 7 (the config PVC it creates); source config at `/apps/jellyfin/config` on the Dockge LXC.
- Produces: the config PVC populated with the existing Jellyfin database/settings.

Because the config PVC is RWO on iSCSI, the Jellyfin pod and the seed helper cannot mount it at the same time. Seed with Jellyfin scaled to zero. This runbook is executed as part of Task 7 (between deploy and final verification).

- [ ] **Step 1: Package the source config on the Dockge LXC**

```bash
# On the Dockge LXC host:
systemctl stop docker-compose@jellyfin 2>/dev/null || true   # ensure source is stopped
tar -C /apps/jellyfin -czf /tmp/jellyfin-config.tgz config
```
Copy `/tmp/jellyfin-config.tgz` to the workstation that runs `kubectl` (e.g. `scp`).

- [ ] **Step 2: Scale Jellyfin to zero so the PVC is free**

```bash
kubectl -n jellyfin scale deploy jellyfin-jellyfin --replicas=0
kubectl -n jellyfin wait --for=delete pod -l app.kubernetes.io/name=jellyfin --timeout=120s
```

- [ ] **Step 3: Launch a helper pod mounting the config PVC**

```bash
# Find the config PVC name:
kubectl -n jellyfin get pvc
# Run a helper (replace <CONFIG_PVC> with the observed name):
kubectl -n jellyfin run jf-seed --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"jf-seed","image":"busybox:1.36","command":["sleep","3600"],"volumeMounts":[{"name":"c","mountPath":"/config"}]}],"volumes":[{"name":"c","persistentVolumeClaim":{"claimName":"<CONFIG_PVC>"}}]}}'
kubectl -n jellyfin wait --for=condition=Ready pod/jf-seed --timeout=120s
```

- [ ] **Step 4: Copy the config in and fix ownership**

```bash
kubectl -n jellyfin cp /tmp/jellyfin-config.tgz jf-seed:/tmp/jellyfin-config.tgz
kubectl -n jellyfin exec jf-seed -- sh -c 'cd /config && tar --strip-components=1 -xzf /tmp/jellyfin-config.tgz && chown -R 1000:1000 /config && rm /tmp/jellyfin-config.tgz && ls -la /config'
```
Expected: the extracted config (e.g. `data/`, `config/`, `*.db`) is listed under `/config`, owned by `1000:1000`.

- [ ] **Step 5: Remove the helper and scale Jellyfin back up**

```bash
kubectl -n jellyfin delete pod jf-seed
kubectl -n jellyfin scale deploy jellyfin-jellyfin --replicas=1
```

- [ ] **Step 6: Commit the runbook**

```bash
git add docs/runbooks/jellyfin-config-migration.md
git commit -m "docs(jellyfin): runbook for seeding config PVC from dockge"
```

---

## Task 7: Deploy and cutover verification

**Files:** none (operational task; uses charts from Tasks 2–5 and runbooks from Tasks 1 & 6).

**Interfaces:**
- Consumes: everything above.
- Produces: a running, GPU-accelerated Jellyfin reachable at `https://jellyfin.k8s.shimmerlabs.xyz`.

- [ ] **Step 1: Confirm the GPU is schedulable (depends on Task 1)**

```bash
kubectl describe node k8s-w-2 | grep -A2 Allocatable | grep 'gpu.intel.com/i915'
```
Expected: `gpu.intel.com/i915: 1`. If missing, the Intel plugin app (Task 3) has not synced or Task 1 passthrough is incomplete — resolve before continuing.

- [ ] **Step 2: Deploy Jellyfin**

Via ArgoCD (add a leaf Application) or directly:

```bash
helm dependency update charts/jellyfin
helm upgrade --install jellyfin charts/jellyfin -n jellyfin --create-namespace
kubectl -n jellyfin rollout status deploy/jellyfin-jellyfin --timeout=300s
```
Expected: rollout completes; the pod is scheduled on `k8s-w-2`.

- [ ] **Step 3: Seed the config PVC**

Execute `docs/runbooks/jellyfin-config-migration.md` (Task 6 Steps 1–5). After scaling back up, wait for the pod:

```bash
kubectl -n jellyfin rollout status deploy/jellyfin-jellyfin --timeout=300s
```

- [ ] **Step 4: Verify the HTTPRoute is accepted and the UI loads**

```bash
kubectl -n jellyfin get httproute jellyfin -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}'
curl -sS -o /dev/null -w '%{http_code}\n' https://jellyfin.k8s.shimmerlabs.xyz/health
```
Expected: HTTPRoute Accepted `True`; health endpoint returns `200`. The UI shows the migrated users/libraries (config seed worked).

- [ ] **Step 5: Verify hardware transcoding**

In the Jellyfin web UI → Dashboard → check that VAAPI is available (Playback settings show the `/dev/dri/renderD128` device). Play a title that forces a transcode, then:

```bash
kubectl -n jellyfin exec deploy/jellyfin-jellyfin -- sh -c 'ls -l /dev/dri && (ps -ef | grep -i ffmpeg | grep -i vaapi || echo "no vaapi ffmpeg yet")'
```
Expected: `/dev/dri/renderD128` visible in the pod; during a transcode the dashboard "Playback" panel reports hardware (VAAPI) transcoding.

- [ ] **Step 6: Repoint clients and decommission the source**

- Update Infuse (Apple TV) and browser bookmarks to `https://jellyfin.k8s.shimmerlabs.xyz`.
- Once confirmed stable, remove the Dockge Jellyfin compose stack and its `/apps/jellyfin` data (after a final backup).

---

## Self-Review

**Spec coverage:**
- Layer 1 passthrough → Task 1. ✅
- Intel device plugin (core, argocd-apps) → Tasks 2–3. ✅
- Jellyfin chart wrapping official chart, GPU request, securityContext, config PVC, emptyDir cache, NFS media → Task 4. ✅
- HTTPRoute ingress + published URL → Tasks 4–5. ✅
- Config migration → Task 6. ✅
- Cutover order + HW-transcode verification + client repoint → Task 7. ✅
- DLNA dropped → `jellyfin.enableDLNA: false`, no udp ports (Task 4). ✅
- Open items (NFS server/paths, render GID, chart value-key confirmation) → resolved in Task 1 Step 3 and Task 4 Steps 2/3/6. ✅

**Placeholder scan:** The only `<...>` tokens (`<RENDER_GID>`, `<NFS_SERVER>`, export paths, `<VMID>`, `<CONFIG_PVC>`, `<DOCKGE_CTID>`) are real environment values the operator must supply; each has an explicit step showing how to obtain it. No "TBD"/"handle edge cases"/vague steps.

**Type/name consistency:** Service/Deployment name `jellyfin-jellyfin` used consistently in Tasks 4, 5, 6, 7; HTTPRoute backend `{{ .Release.Name }}-jellyfin` = `jellyfin-jellyfin` (Task 5 Step 1 verifies). Node label `intel.feature.node.kubernetes.io/gpu=true` matches between Task 1 Step 4 and Task 2 plugin `nodeSelector`. `<RENDER_GID>` flows Task 1 → Task 4.
