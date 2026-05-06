# Homelab

Kubernetes homelab on Proxmox. Fully reproducible — control plane provisioned as LXC, workers as VMs, K8s bootstrapped via Ansible, workloads managed via ArgoCD.

## Prerequisites

- [Nix](https://nixos.org/download/) with flakes enabled
- [direnv](https://direnv.net/)

```bash
cd homelab
direnv allow   # loads ansible, argocd, cilium-cli
```

## Quick Start

### 1. Create Nodes (on Proxmox hosts)

```bash
# Prep the Proxmox host that will run the control plane LXC (sysctl + kernel modules)
curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/prep-proxmox-host.sh | bash

# Control plane LXC (on singed)
curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/create-lxc.sh \
  | bash -s -- --name k8s-cp-1 --ip 10.22.6.100/16

# Worker VMs (on respective hosts)
curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/create-vm.sh \
  | bash -s -- --name k8s-w-1 --ip 10.22.6.101/16

# Repeat for k8s-w-2, k8s-w-3, k8s-w-4 on desired hosts
```

See `infra/scripts/create-lxc.sh` and `infra/scripts/create-vm.sh` for all options.

### 2. Bootstrap Kubernetes (from your Mac)

```bash
cd infra/ansible

# Control plane first
ansible-playbook playbooks/bootstrap-control-plane.yml

# Then workers
ansible-playbook playbooks/bootstrap-worker.yml
```

### 3. Bootstrap ArgoCD

Order matters — each step depends on the previous being healthy.

```bash
# Step 1: Install Cilium (CNI). Without this no pods schedule.
helm dependency update charts/cilium
helm install cilium charts/cilium -n kube-system

# Wait until Cilium pods are running and nodes are Ready
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=cilium --timeout=300s

# Step 2: Install MetalLB (LoadBalancer IPs). Webhook needs networking from step 1.
helm dependency update charts/metallb
helm install metallb charts/metallb -n metallb-system --create-namespace

# Wait until MetalLB controller is ready
kubectl -n metallb-system wait --for=condition=Available deployment/metallb-controller --timeout=300s

# Step 3: Install ArgoCD
helm dependency update charts/argocd
helm install argocd charts/argocd -n argocd --create-namespace

# Wait until ArgoCD server is ready
kubectl -n argocd wait --for=condition=Available deployment/argocd-server --timeout=300s

# Step 4: Deploy app-of-apps — ArgoCD manages everything else from here
helm dependency update charts/argocd-apps
helm install argocd-apps charts/argocd-apps -n argocd
```

**Note:** MetalLB ServiceMonitor is disabled by default since it requires `kube-prometheus-stack` CRDs. Re-enable in `charts/metallb/values.yaml` after `kube-prometheus-stack` syncs via ArgoCD.

## Node Topology

| Host | Node | Type | Role | IP |
|------|------|------|------|----|
| singed | k8s-cp-1 | LXC | Control Plane | 10.22.6.100 |
| singed | k8s-w-1 | VM | Worker | 10.22.6.101 |
| pve1 | k8s-w-2 | VM | Worker | 10.22.6.102 |
| pve2 | k8s-w-3 | VM | Worker | 10.22.6.103 |
| powder | k8s-w-4 | VM | Worker | 10.22.6.104 |

## Common Commands

```bash
# Add a new worker
# 1. Create VM on a Proxmox host
curl -sL .../create-vm.sh | bash -s -- --name k8s-w-5 --ip 10.22.6.105/16
# 2. Add to infra/ansible/inventory/hosts.yml
# 3. Run bootstrap
cd infra/ansible && ansible-playbook playbooks/bootstrap-worker.yml --limit k8s-w-5

# Upgrade Kubernetes
cd infra/ansible && ansible-playbook playbooks/upgrade-k8s.yml

# Update nix dependencies
nix flake update

# Add a new app to ArgoCD
# 1. Create chart in charts/
# 2. Add entry to charts/argocd-apps/values.yaml
# 3. Push to main — ArgoCD syncs automatically
```

## Architecture

See [design doc](docs/superpowers/specs/2026-05-05-gitops-infra-design.md) for full details.

| Layer | Tool | Trigger |
|-------|------|---------|
| Control plane (LXC) | Bash + `pct` | `curl \| bash` on Proxmox host |
| Workers (VM) | Bash + `qm` + cloud-init | `curl \| bash` on Proxmox host |
| K8s bootstrap | Ansible | `ansible-playbook` from Mac |
| Workloads | Helm + ArgoCD | Git push (auto-sync) |
