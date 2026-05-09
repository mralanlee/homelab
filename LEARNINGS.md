# Homelab Learnings

Things we hit during the GitOps homelab build. Each section is a problem + how it was solved + why.

## Provisioning

### LXC for K8s control plane needs special features
**Problem:** kubeadm in unprivileged LXC fails. Even privileged LXC needs more.
**Fix:** `pct create` with `--unprivileged 0 --features nesting=1,keyctl=1`. Plus add to `/etc/pve/lxc/<CTID>.conf`:
```
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
```
**Why:** kubeadm needs cgroup access, capability passthrough, and AppArmor disabled to manage containers.

### LXC inherits host kernel — sysctl/modules go on host
**Problem:** Pod networking failed, `bridge-nf-call-iptables` not set.
**Fix:** Set sysctl/load kernel modules on the **Proxmox host**, not inside LXC. Created `prep-proxmox-host.sh`.
**Why:** Containers share kernel with host. Setting sysctl inside LXC doesn't affect anything.

### Kubelet refuses to start in LXC due to swap
**Problem:** `running with swap on is not supported`. Can't `swapoff` host swap from inside LXC.
**Fix:** Use kubeadm config with `KubeletConfiguration: failSwapOn: false`. CLI flag `--fail-swap-on=false` is overridden by config file.
**Why:** Kubelet hardcodes swap check; modern kubelet config file takes precedence over CLI flags.

### kubeadm init partial failures don't recover
**Problem:** wait-control-plane phase failed; manual fix made kubelet healthy but join token / addons never installed.
**Fix:** Re-run remaining init phases manually (`kubeadm init phase upload-config all`, `bootstrap-token`, `kubelet-finalize`, `addon coredns`).
**Why:** kubeadm doesn't resume from a partial init. Each phase is idempotent on its own but needs explicit invocation.

### kubeadm 1.29+ admin.conf has limited RBAC
**Problem:** `kubectl` from admin.conf got "forbidden" creating secrets.
**Fix:** Use `/etc/kubernetes/super-admin.conf` for cluster-admin operations. Or run remaining init phases to bind RBAC properly.
**Why:** kubeadm split admin into "cluster admin" (super-admin.conf, system:masters) and "view" (admin.conf, kubeadm:cluster-admins).

### Worker VMs from cloud-init can mismatch OS
**Problem:** k8s-w-2 came up as Debian bookworm; Docker repo URL hardcoded `linux/ubuntu` failed.
**Fix:** Use `ansible_distribution | lower` in URL.
**Why:** Mixed-OS clusters happen. Always parameterize OS in package repo URLs.

### LXC has no `/etc/iscsi`; democratic-csi DaemonSet fails
**Problem:** `MountVolume.SetUp failed for volume "iscsi-dir" : hostPath type check failed: /etc/iscsi is not a directory` on LXC node and missing-iscsi worker.
**Fix:** Install `open-iscsi` + `nfs-common` via Ansible common role. Taint control-plane LXC `NoSchedule` so DaemonSet skips it.
**Why:** Cloud images may or may not include iscsi tools. LXC kernel modules can't be loaded so iscsi inside it doesn't work — exclude it from CSI.

## Networking

### Cilium kube-proxy replacement needs explicit API server
**Problem:** Cilium pods CrashLoopBackOff, can't reach `10.96.0.1:443`.
**Fix:** Set `k8sServiceHost: 10.22.6.100` and `k8sServicePort: 6443` in Cilium values.
**Why:** Without kube-proxy, ClusterIPs only work after Cilium is up. Bootstrap chicken-and-egg — Cilium needs direct API endpoint.

### DHCPv6 injects bad search domain
**Problem:** Pods got `search shimmerlabs.xyz xyz` in resolv.conf. `xyz` was being added separately.
**Fix:** systemd-networkd drop-in on each VM:
```
[DHCPv6]
UseDomains=no
[IPv6AcceptRA]
UseDomains=no
```
Bake into Ansible common role.
**Why:** OPNsense DHCPv6 RA was advertising a search domain. systemd-networkd applied it even with static IP via netplan. LXCs don't have systemd-networkd so they didn't hit this.

### Wildcard DNS at apex domain hijacks pod resolution
**Problem:** ESO pulling 1Password failed with TLS cert for `cashnow.com`. DNS for `my.1password.com.shimmerlabs.xyz` resolved via `*.shimmerlabs.xyz` Cloudflare wildcard → 10.22.0.107 (then later via tld TLD `.xyz` to a real public domain `com.xyz`).
**Fix:** Remove apex wildcard `*.shimmerlabs.xyz`. Use specific subdomain wildcards (`*.k8s`, `*.int`).
**Why:** With `ndots:5`, pod resolver tries `name.<search-domain>` before bare `name`. If wildcard catches it, you get hijacked traffic. **Don't use root-domain wildcards in homelab DNS** unless you've stripped search domains.

### Cilium hairpin works; MetalLB hairpin doesn't
**Problem:** Pod connecting to LoadBalancer IP got "operation not permitted" with MetalLB. Hardcoded hostAliases needed for OIDC discovery.
**Fix:** Switched to Cilium L2 Announcements. Pod-to-LoadBalancer-to-pod hairpin works natively.
**Why:** MetalLB + Cilium kube-proxy replacement had eBPF hairpin issues in LXC. Cilium's own LB IPAM doesn't have this problem.

### MetalLB rejects Cilium-created EndpointSlice
**Problem:** Gateway IP not announced. MetalLB log: `endpointSlice missing the kubernetes.io/service-name label`.
**Fix:** Switched to Cilium L2. Or manually `kubectl label endpointslice ... kubernetes.io/service-name=...`.
**Why:** Cilium creates synthetic EndpointSlice for Gateway with placeholder endpoint `192.192.192.192`. Doesn't add the standard service-name label, MetalLB skips it. Open Cilium issues since 2024.

### externalTrafficPolicy: Local + Cilium L2 announcer mismatch
**Problem:** bind9 LoadBalancer IP `10.22.6.53` reachable via ARP but TCP/UDP refused/dropped from clients. Worker logs showed traffic landing on the L2 announcer node, not the bind9 pod node.
**Fix:** Set `externalTrafficPolicy: Cluster` on the LB Service. Set `Local` only when pods run on every potential announcer (DaemonSet-style).
**Why:** Cilium L2 announces the LB IP from a leader-elected node, independent of where backend pods run. With `Local`, traffic landing on an announcer without a local backend gets dropped. `Cluster` lets eBPF forward to the pod on any node (SNATs source — fine for TSIG-authed paths).

### Cilium L2 statedb empty after node reboot
**Problem:** After a worker reboot, lease objects (`cilium-l2announce-*`) showed correct holders but `cilium-dbg shell -- db/show l2-announce` was empty. Wire-level ARP silent for both LB IPs.
**Fix:** `kubectl -n kube-system rollout restart ds/cilium`. If that hangs on a stuck terminating pod, force-delete it (`--force --grace-period=0`). Recheck statedb across all pods (`exec ds/cilium` only hits one).
**Why:** Agents don't always rebuild announce state from leases on partial reconcile. A clean DS restart re-emits gratuitous ARP and repopulates statedb.

## Ingress / Gateway

### Cilium Gateway API needs experimental CRDs
**Problem:** Cilium operator fatal: `no matches for kind "TLSRoute" in version "gateway.networking.k8s.io/v1alpha2"`.
**Fix:** Install Gateway API CRDs from **experimental channel** (not standard). Has v1alpha2 served for TLSRoute.
**Why:** Cilium operator hardcodes v1alpha2 client for TLSRoute. Standard channel CRDs only serve v1 of stable kinds.

### Storage version constraint on CRD upgrade
**Problem:** Switching to experimental CRDs failed: `status.storedVersions[0]: Invalid value: "v1": missing from spec.versions`.
**Fix:** Delete the CRD if no resources of that kind exist, then resync.
**Why:** K8s requires storedVersions to remain in spec.versions until you migrate stored data. Can't just remove a version.

### Cilium ingress controller conflicts with Traefik
**Problem:** Traefik LoadBalancer `<pending>` — `kube-system/cilium-ingress` already claiming 10.22.6.10.
**Fix:** Disable `cilium.ingressController.enabled: false` if using something else.
**Why:** Cilium ships with optional ingress controller that auto-creates a LoadBalancer service competing for the same IP pool.

### Traefik dashboard etc. depend on each chart's Ingress
**Problem:** Migrating from Traefik to Cilium Gateway: ingresses scattered across 6 charts.
**Fix:** For each chart: disable `ingress.enabled` in values.yaml, add `templates/httproute.yaml` with HTTPRoute resource pointing to shared Gateway.
**Why:** Most upstream charts don't have HTTPRoute templates. Easier to add custom templates than override the chart's ingress.

## Helm + ArgoCD

### Custom resources race with their own CRDs in same chart
**Problem:** `helm install` of MetalLB chart failed: `no matches for kind "IPAddressPool"`. CRDs and CRs applied simultaneously.
**Fix:** Either `--no-hooks` install + apply CRs separately, OR use ArgoCD sync waves to order CRD-providing apps before consumers.
**Why:** Helm applies templates in one pass. CRDs in `templates/crds/` race with CRs in `templates/`. CRDs in upstream chart's `crds/` dir get applied first by Helm but custom CRs in same chart still race.

### kube-prometheus-stack CRDs exceed annotation limit
**Problem:** ArgoCD `Too long: may not be more than 262144 bytes` on CRD apply.
**Fix:** Install `prometheus-operator-crds` chart out-of-band. Disable CRDs in kube-prometheus-stack (`crds.enabled: false`). Use `ServerSideApply=true` for the CRD-only chart.
**Why:** ArgoCD adds `kubectl.kubernetes.io/last-applied-configuration` with full manifest content. Big CRDs like kps's exceed K8s annotation size limit.

### Helm hooks don't work well with ArgoCD
**Problem:** `helm.sh/hook: post-install` annotations got skipped or ran in wrong order under ArgoCD.
**Fix:** Use `argocd.argoproj.io/sync-wave` annotations instead. ArgoCD honors sync waves natively; helm hooks are application-level shortcuts.
**Why:** ArgoCD uses `helm template` (not `helm install`), so hook annotations are kept but ArgoCD runs its own ordering.

### MetalLB validating webhook unreachable from LXC API server
**Problem:** Service creation failed via webhook timeout/connection-refused.
**Fix:** Set `crds.validationFailurePolicy: Ignore` and `controller.webhookMode: disabled`. Or delete the validatingwebhookconfiguration.
**Why:** API server in LXC can't reach pod-network webhook services. Same for ESO webhooks. Cilium hairpin issue we eventually fixed by dropping MetalLB.

### CRD with operator-mutated fields drifts forever in ArgoCD
**Problem:** authentik OutOfSync — cn-pg `Cluster` resource keeps getting modified.
**Fix:** Add `ignoreDifferences` per Application:
```yaml
ignoreDifferences:
  - group: postgresql.cnpg.io
    kind: Cluster
    jsonPointers: [/spec/bootstrap, /spec/storage]
    managedFieldsManagers: [cnpg-controller-manager]
```
**Why:** Operators write back to spec for state. ArgoCD sees as drift. ignoreDifferences excludes specific paths.

## Secrets

### 1Password SDK has SNI/parser quirks
**Problem 1:** ESO connects to 1Password but TLS cert is for `cashnow.com` (not 1password). Caused by DNS hijack via wildcard search domain (see DNS section).
**Problem 2:** SDK rejects `op://` references with dots in item names: "invalid character in secret reference".
**Problem 3:** SDK rejects `op://vault/uuid/file` references because of nested slashes in field name.
**Fix:** Use `<item>/<field>` format (no `op://`). Items with dots in name DO work in this format. Use field name without extension (rename `driver.yaml` to `driver`).
**Why:** ESO's onepasswordSDK provider validation regex differs from `op` CLI's. Stricter on certain chars.

### Documents in 1Password need filename as field
**Problem:** ESO couldn't pull attached document.
**Fix:** Reference as `<item>/<filename-without-extension>`. The "field" for an attached document is the filename label.
**Why:** 1Password SDK exposes documents via field-style access using the filename.

### ESO `template.data` renders full file content; avoids init-container chown dance
**Problem:** bind9 needed a `tsig.key` block (full BIND syntax) built from a raw secret. First attempt: init container read raw secret, wrote `/etc/bind/tsig.key`, `chown 100:101`. Failed with `open: /etc/bind/tsig.key: permission denied` — image's `bind` user UID didn't match the hardcoded `100:101`.
**Fix:** Use ExternalSecret `spec.target.template.data` (engine v2) to render the full key block at sync time. Mount the resulting Secret directly with `defaultMode: 0444` and a subPath. Helm escapes ESO Go templates with backticks: `{{ ` `` `{{ .secret }}` `` ` }}`.
**Why:** Init containers + chown couple chart to specific image user IDs. ESO templates produce ready-to-mount files; `0444` is readable by any container user, no chown needed.

## Authentication

### authentik fresh install needs OIDC application setup
**Problem:** ArgoCD Dex got 404 from `/application/o/argo-cd/`.
**Fix:** Post-install: log into authentik, create OAuth2/OIDC Provider + Application with slug `argo-cd`. Bootstrap akadmin via `/if/flow/initial-setup/`.
**Why:** Authentik doesn't auto-create applications. Configuration is UI-driven (or via Blueprints — future work).

### OIDC groups claim needs explicit scope mapping
**Problem:** ArgoCD got tokens but no groups → no admin access.
**Fix:** Create a custom Property Mapping in authentik:
```python
return {"groups": [g.name for g in request.user.ak_groups.all()]}
```
Add the mapping to provider's Scopes. Add user to a group whose name matches ArgoCD RBAC (`ArgoCD Admins`).
**Why:** Default authentik install may not include the OpenID groups mapping. Have to create + assign.

### Dex OIDC discovery hits LoadBalancer hairpin
**Problem:** Dex pod fails to fetch `https://authentik.k8s.shimmerlabs.xyz/.well-known/openid-configuration`.
**Fix (initial):** hostAliases on Dex pod mapping authentik hostname to internal ClusterIP (brittle).
**Fix (final):** Cilium Gateway hairpin works. Drop hostAliases.
**Why:** OIDC issuer URL must match between Dex config and JWT iss claim. Can't use internal URL for issuer. Need pod → external URL → ingress → service → pod to work. MetalLB couldn't; Cilium can.

## ArgoCD Specifics

### admin password can be reset via secret patch
```bash
HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'newpass', bcrypt.gensalt(10)).decode())")
kubectl -n argocd patch secret argocd-secret --patch-file=<(cat <<EOF
stringData:
  admin.password: $HASH
  admin.passwordMtime: "$(date +%FT%T%Z)"
EOF
)
kubectl -n argocd rollout restart deployment argocd-server
```
**Watch out for:** Shell `$2b$` expansion — use single quotes or YAML file patch.

### app-of-apps doesn't manage ArgoCD itself
ArgoCD is installed manually via helm. App-of-apps generates Applications for the rest. Updating ArgoCD = `helm upgrade argocd charts/argocd -n argocd`.

## DNS

### CoreDNS forwards to node's resolv.conf
Pod DNS path: pod → CoreDNS (10.96.0.10) → node's `/etc/resolv.conf` upstream → external resolver. ndots:5 set per-pod.

### Cluster has no internal DNS for arbitrary k8s hostnames
Workaround: deploy `k8s-gateway` (CoreDNS plugin) or run authoritative DNS server + external-dns RFC2136. OPNsense Unbound is recursive only.

### OPNsense Unbound Query Forwarding entry needs Apply
**Problem:** Added Domain Override (`k8s.shimmerlabs.xyz` → `10.22.6.53`). Entry visible + enabled in UI but `dig @10.22.0.1` returned empty. Direct `dig @10.22.6.53` worked.
**Fix:** Click **Apply** on the Query Forwarding page. Restart Unbound if still stale.
**Why:** Saving a row doesn't reload Unbound's running config. UI shows the row as enabled before it's actually in the running zone list.

### CoreDNS loop after upstream resolver change
**Problem:** `[FATAL] plugin/loop: Loop (127.0.0.1:xxxxx -> :53) detected for zone "."`. CoreDNS Corefile uses `forward . /etc/resolv.conf`; pod's resolv.conf pointed back at CoreDNS service IP after host resolver state shifted.
**Fix:** Replace `forward . /etc/resolv.conf` with explicit upstream: `forward . 10.22.0.1 8.8.8.8`. `kubectl -n kube-system rollout restart deploy/coredns`.
**Why:** `dnsPolicy: Default` means CoreDNS pod inherits node resolv.conf. If that ever resolves the cluster IP (or if `dnsPolicy` is misconfigured to `ClusterFirst`), CoreDNS forwards to itself.

## Anti-Patterns to Avoid

1. **Apex wildcard DNS** in domains used as pod search domains.
2. **Helm hooks for CRs that need their own CRDs from same chart** — use ArgoCD sync waves.
3. **Hardcoded ClusterIPs in hostAliases** — service IPs change on recreate.
4. **kubeadm init in LXC without prep** — needs apparmor/cgroup/mount tweaks.
5. **MetalLB with Cilium kube-proxy replacement in LXC** — hairpin broken; use Cilium L2 instead.
6. **`*` in Cloudflare** for any domain that's a search-suffix — pod resolution breaks.
7. **ServiceMonitors enabled before kube-prometheus-stack** — CRD doesn't exist yet, helm install fails.
8. **Trying to delete PVC pods before democratic-csi controller is happy** — gets stuck in lock state.

## Key Repos / Resources

- [Cilium Gateway API](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)
- [Gateway API experimental CRDs](https://github.com/kubernetes-sigs/gateway-api/releases)
- [external-secrets onepasswordSDK](https://external-secrets.io/latest/provider/1password-sdk/)
- [k8s-gateway (deprecated, see forks)](https://github.com/k8s-gateway/k8s_gateway)
- [Cilium L2 Announcements](https://docs.cilium.io/en/stable/network/l2-announcements/)
