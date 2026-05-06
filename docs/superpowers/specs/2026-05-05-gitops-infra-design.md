# GitOps Infrastructure Design

Fully GitOps'd Kubernetes homelab on Proxmox. Replaces manually-created nodes with reproducible, code-defined infrastructure.

## Architecture

Three layers:

| Layer | Tool | Runs from | Trigger |
|-------|------|-----------|---------|
| LXC creation (control plane) | Bash + `pct` | Proxmox host | `curl \| bash` |
| VM creation (workers) | Bash + `qm` + cloud-init | Proxmox host | `curl \| bash` |
| K8s bootstrap + lifecycle | Ansible | Mac (via nix flake) | `ansible-playbook` |
| K8s workloads | Helm + ArgoCD | In-cluster | GitOps (auto-sync on push) |

### Node Topology

- **singed**: control plane LXC (k8s-cp-1) + 1 worker VM (k8s-w-1)
- **pve1, pve2, powder**: worker VM targets (flexible placement)
- Total: 1 control plane (LXC) + 4 workers (VM)
- OS: Ubuntu 24.04 LTS
- K8s: kubeadm
- Control plane runs as privileged LXC container (nesting + keyctl features for kubeadm)

## Repository Structure

```
homelab/
├── flake.nix                    # dev shell: ansible, argocd, cilium-cli
├── .envrc                       # use flake
├── infra/
│   ├── scripts/
│   │   ├── create-lxc.sh        # LXC creation for control plane, run on Proxmox host
│   │   └── create-vm.sh         # VM creation for workers, run on Proxmox host
│   └── ansible/
│       ├── ansible.cfg
│       ├── inventory/
│       │   ├── hosts.yml
│       │   └── group_vars/
│       │       ├── all.yml      # k8s version, pod CIDR, etc.
│       │       ├── control_plane.yml
│       │       └── workers.yml
│       ├── playbooks/
│       │   ├── bootstrap-control-plane.yml
│       │   ├── bootstrap-worker.yml
│       │   └── upgrade-k8s.yml
│       ├── roles/
│       │   ├── common/          # swap off, kernel modules, sysctl, containerd
│       │   ├── kubeadm/         # install kubeadm, kubelet, kubectl
│       │   ├── control-plane/   # kubeadm init, save join token, copy kubeconfig
│       │   └── worker/          # kubeadm join
│       └── .join-token          # gitignored
├── charts/                      # existing Helm charts
│   ├── argocd-apps/             # NEW: app-of-apps chart
│   │   ├── Chart.yaml
│   │   ├── values.yaml          # list of all apps
│   │   └── templates/
│   │       └── applications.yaml
│   ├── argocd/
│   ├── authentik/
│   ├── cert-manager/
│   ├── cilium/
│   ├── cn-pg/
│   ├── democratic-csi/
│   ├── external-secrets/
│   ├── grafana/
│   ├── kube-prometheus-stack/
│   ├── metallb/
│   ├── metrics-server/
│   ├── n8n/
│   └── traefik/
└── docs/
```

## Layer 0: Node Creation Scripts

Two scripts: `create-lxc.sh` for the control plane LXC container, `create-vm.sh` for worker VMs.

### Control Plane LXC (`create-lxc.sh`)

```bash
# Minimal — just name and IP
curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/create-lxc.sh \
  | bash -s -- --name k8s-cp-1 --ip 10.22.6.100/24
```

| Param | Required | Default |
|-------|----------|---------|
| `--name` | yes | — |
| `--ip` | yes (CIDR) | — |
| `--ctid` | no | auto (`pvesh get /cluster/nextid`) |
| `--cores` | no | 2 |
| `--memory` | no | 4096 MB |
| `--disk` | no | 32 GB |
| `--gw` | no | 10.22.0.1 |
| `--bridge` | no | vmbr0 |
| `--storage` | no | local-lvm |
| `--ssh-key` | no | `~/.ssh/authorized_keys` (read from Proxmox host) |
| `--template` | no | `ubuntu-24.04-standard` (downloaded from Proxmox if missing) |

Script flow:
1. Download Ubuntu 24.04 LXC template if not cached (`pveam download`)
2. Get next available CTID (or use `--ctid`)
3. Create privileged LXC container with nesting and keyctl features
4. Configure: cores, memory, disk, network (static IP), SSH key
5. Enable required LXC features for Kubernetes: `nesting=1,keyctl=1`
6. Start container
7. Print summary

### Worker VMs (`create-vm.sh`)

```bash
# Minimal — just name and IP
curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/create-vm.sh \
  | bash -s -- --name k8s-w-1 --ip 10.22.6.101/24

# With overrides
curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/create-vm.sh \
  | bash -s -- --name k8s-w-3 --ip 10.22.6.103/24 --cores 4 --memory 8192 --disk 64
```

| Param | Required | Default |
|-------|----------|---------|
| `--name` | yes | — |
| `--ip` | yes (CIDR) | — |
| `--vmid` | no | auto (`pvesh get /cluster/nextid`) |
| `--cores` | no | 2 |
| `--memory` | no | 4096 MB |
| `--disk` | no | 32 GB |
| `--gw` | no | 10.22.0.1 |
| `--bridge` | no | vmbr0 |
| `--storage` | no | local-lvm |
| `--user` | no | alan |
| `--ssh-key` | no | `~/.ssh/authorized_keys` (read from Proxmox host) |
| `--template-id` | no | 9000 |

Script flow:
1. Check if template VM 9000 exists; if not, download Ubuntu 24.04 cloud image and create template
2. Get next available VMID (or use `--vmid`)
3. Clone template → new VM
4. Set cores, memory, resize disk
5. Configure cloud-init (user, SSH key, IP, gateway, DNS)
6. Start VM
7. Print summary (VMID, name, IP)

### Design Decisions

- **LXC for control plane**: lighter resource usage, existing pattern in this homelab. Privileged with nesting+keyctl for kubeadm compatibility.
- **VMs for workers**: better isolation for workloads, standard cloud-init provisioning.
- **Template-based**: LXC uses Proxmox appliance template, VMs clone from a cloud image template (VMID 9000).
- **Static IPs**: no DHCP dependency. Ansible inventory matches. Predictable from boot.
- **Idempotent-ish**: checks if CTID/VMID exists before creating. Templates reused if present.

## Layer 1: Ansible

Run from Mac. Handles everything inside the VMs: K8s bootstrap and day-2 lifecycle.

### Inventory

```yaml
# infra/ansible/inventory/hosts.yml
all:
  children:
    control_plane:
      hosts:
        k8s-cp-1:
          ansible_host: 10.22.6.100
    workers:
      hosts:
        k8s-w-1:
          ansible_host: 10.22.6.101
        k8s-w-2:
          ansible_host: 10.22.6.102
        k8s-w-3:
          ansible_host: 10.22.6.103
        k8s-w-4:
          ansible_host: 10.22.6.104
```

### Roles

**common** — OS prerequisites shared by all nodes:
- Disable swap
- Load kernel modules (overlay, br_netfilter)
- Set sysctl params (ip_forward, bridge-nf-call)
- Install and configure containerd
- LXC-specific: create `/dev/kmsg` symlink (needed for kubelet in LXC containers)

**kubeadm** — K8s tooling shared by all nodes:
- Install kubeadm, kubelet, kubectl
- Pin package versions
- Enable kubelet service

**control-plane** — Control plane init:
- `kubeadm init` with pod network CIDR (for Cilium)
- Copy kubeconfig to local `~/.kube/config`
- Generate join token
- Save join command to `infra/ansible/.join-token` (gitignored)

**worker** — Worker join:
- Read `.join-token`
- `kubeadm join`

### Playbooks

**bootstrap-control-plane.yml**: roles common → kubeadm → control-plane

**bootstrap-worker.yml**: roles common → kubeadm → worker

**upgrade-k8s.yml**: upgrade kubeadm/kubelet. Control plane first, then workers serially (drain → upgrade → uncordon).

### Usage

```bash
cd infra/ansible

# Bootstrap control plane
ansible-playbook playbooks/bootstrap-control-plane.yml

# Bootstrap all workers
ansible-playbook playbooks/bootstrap-worker.yml

# Bootstrap single new worker
ansible-playbook playbooks/bootstrap-worker.yml --limit k8s-w-4

# Upgrade K8s
ansible-playbook playbooks/upgrade-k8s.yml
```

### Join Token Handoff

Control plane playbook writes join command to `infra/ansible/.join-token`. Worker playbook reads it. File is gitignored. Only used during bootstrap — token expires after 24h by default, regenerate if needed.

## Layer 2: ArgoCD & App-of-Apps

### Bootstrap Order

ArgoCD can't manage itself or the networking it needs. Three manual helm installs first:

1. `helm dependency update charts/cilium && helm install cilium charts/cilium -n kube-system` — CNI, pods can't schedule without it
2. `helm dependency update charts/metallb && helm install metallb charts/metallb -n metallb-system --create-namespace` — LoadBalancer IPs
3. `helm dependency update charts/argocd && helm install argocd charts/argocd -n argocd --create-namespace` — GitOps controller
4. `helm dependency update charts/argocd-apps && helm install argocd-apps charts/argocd-apps -n argocd` — app-of-apps, syncs everything else

After initial install, ArgoCD adopts Cilium and MetalLB too — all future upgrades through git push.

### App-of-Apps Chart

New chart `charts/argocd-apps/` with a template that loops over a values list to generate ArgoCD Application CRs:

```yaml
# charts/argocd-apps/values.yaml
apps:
  - name: cilium
    namespace: kube-system
    path: charts/cilium
  - name: metallb
    namespace: metallb-system
    path: charts/metallb
  - name: traefik
    namespace: traefik
    path: charts/traefik
  - name: cert-manager
    namespace: cert-manager
    path: charts/cert-manager
  - name: external-secrets
    namespace: external-secrets
    path: charts/external-secrets
  - name: authentik
    namespace: authentik
    path: charts/authentik
  - name: cn-pg
    namespace: cnpg-system
    path: charts/cn-pg
  - name: democratic-csi
    namespace: democratic-csi
    path: charts/democratic-csi
  - name: grafana
    namespace: grafana
    path: charts/grafana
  - name: kube-prometheus-stack
    namespace: monitoring
    path: charts/kube-prometheus-stack
  - name: metrics-server
    namespace: kube-system
    path: charts/metrics-server
  - name: n8n
    namespace: n8n
    path: charts/n8n
```

Adding a new workload = add entry here, push to git, ArgoCD syncs.

## Dev Environment

Nix flake with direnv. `cd` into repo, tools available.

### Packages

- `ansible` — playbook execution
- `argocd` — ArgoCD CLI
- `cilium-cli` — Cilium status and connectivity tests

### Files

```nix
# flake.nix — pinned nixpkgs, reproducible
```

```bash
# .envrc
use flake
```

### Gitignore Additions

```
.direnv/
result
infra/ansible/.join-token
.superpowers/
```

## Chart Updates

All existing charts are ~5 months stale. Since this is a fresh cluster with no running workloads, update all chart dependencies to latest versions before deployment:

- Update `Chart.yaml` dependency versions to latest
- Run `helm dependency update` to regenerate `Chart.lock`
- Review changelogs for breaking changes in `values.yaml`
- Charts to update: argocd, authentik, cert-manager, cilium, cn-pg, democratic-csi, external-secrets, grafana, kube-prometheus-stack, metallb, metrics-server, n8n, traefik

This is done once during implementation, before the first deploy.

## README

README to include:
- Project overview
- Prerequisites (nix + direnv)
- Quick start: VM creation, K8s bootstrap, ArgoCD bootstrap
- Common commands reference
- Node topology / IP allocation table
- Link to this design doc
