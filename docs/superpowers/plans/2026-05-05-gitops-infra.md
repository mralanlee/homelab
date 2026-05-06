# GitOps Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the homelab from manually-created Proxmox VMs to a fully reproducible, GitOps'd Kubernetes cluster with automated VM provisioning, Ansible-based K8s bootstrap, and ArgoCD-managed workloads.

**Architecture:** Three layers — bash script for VM creation on Proxmox hosts, Ansible playbooks for K8s bootstrap and lifecycle (run from Mac), and ArgoCD app-of-apps for workload management. Nix flake provides reproducible dev environment.

**Tech Stack:** Bash, Proxmox `qm` CLI, cloud-init, Ansible, kubeadm, Helm, ArgoCD, Nix flakes, direnv

**Spec:** `docs/superpowers/specs/2026-05-05-gitops-infra-design.md`

---

## File Map

### New files to create

| File | Purpose |
|------|---------|
| `flake.nix` | Nix dev shell: ansible, argocd, cilium-cli |
| `.envrc` | direnv integration |
| `infra/scripts/create-lxc.sh` | LXC creation script for control plane |
| `infra/scripts/create-vm.sh` | VM creation script for workers |
| `infra/ansible/ansible.cfg` | Ansible configuration |
| `infra/ansible/inventory/hosts.yml` | Node inventory |
| `infra/ansible/inventory/group_vars/all.yml` | Shared variables |
| `infra/ansible/inventory/group_vars/control_plane.yml` | Control plane vars |
| `infra/ansible/inventory/group_vars/workers.yml` | Worker vars |
| `infra/ansible/roles/common/tasks/main.yml` | OS prereqs role |
| `infra/ansible/roles/kubeadm/tasks/main.yml` | kubeadm install role |
| `infra/ansible/roles/control-plane/tasks/main.yml` | Control plane init role |
| `infra/ansible/roles/worker/tasks/main.yml` | Worker join role |
| `infra/ansible/playbooks/bootstrap-control-plane.yml` | Control plane playbook |
| `infra/ansible/playbooks/bootstrap-worker.yml` | Worker playbook |
| `infra/ansible/playbooks/upgrade-k8s.yml` | K8s upgrade playbook |
| `charts/argocd-apps/Chart.yaml` | App-of-apps chart metadata |
| `charts/argocd-apps/values.yaml` | App list for ArgoCD |
| `charts/argocd-apps/templates/applications.yaml` | Application CR template |

### Existing files to modify

| File | Change |
|------|--------|
| `.gitignore` | Add `.direnv/`, `result`, `infra/ansible/.join-token`, `.superpowers/` |
| `README.md` | Full rewrite with usage docs |
| `charts/argocd/Chart.yaml` | Update dependency version |
| `charts/authentik/Chart.yaml` | Update dependency version |
| `charts/cert-manager/Chart.yaml` | Update dependency version |
| `charts/cilium/Chart.yaml` | Update dependency version |
| `charts/cn-pg/Chart.yaml` | Update dependency version |
| `charts/democratic-csi/Chart.yaml` | Update dependency version |
| `charts/external-secrets/Chart.yaml` | Update dependency version |
| `charts/grafana/Chart.yaml` | Update dependency version |
| `charts/kube-prometheus-stack/Chart.yaml` | Update dependency version |
| `charts/metallb/Chart.yaml` | Update dependency version |
| `charts/metrics-server/Chart.yaml` | Update dependency version |
| `charts/n8n/Chart.yaml` | Update dependency version |
| `charts/traefik/Chart.yaml` | Update dependency version |

---

### Task 1: Nix Flake & Dev Environment

**Files:**
- Create: `flake.nix`
- Create: `.envrc`
- Modify: `.gitignore`

- [ ] **Step 1: Create flake.nix**

```nix
{
  description = "Homelab development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            ansible
            argocd
            cilium-cli
          ];
        };
      });
}
```

- [ ] **Step 2: Create .envrc**

```bash
use flake
```

- [ ] **Step 3: Update .gitignore**

Append to existing `.gitignore`:

```
# Nix
.direnv/
result

# Ansible
infra/ansible/.join-token

# Brainstorm artifacts
.superpowers/
```

- [ ] **Step 4: Test flake builds**

Run: `nix develop --command bash -c "ansible --version && argocd version --client && cilium version --client"`

Expected: version output for all three tools, no errors.

- [ ] **Step 5: Allow direnv**

Run: `direnv allow`

Expected: direnv loads the flake, tools available in shell.

- [ ] **Step 6: Commit**

```bash
git add flake.nix flake.lock .envrc .gitignore
git commit -m "feat: add nix flake dev environment with ansible, argocd, cilium-cli"
```

---

### Task 2: VM Creation Script

**Files:**
- Create: `infra/scripts/create-vm.sh`

- [ ] **Step 1: Create directory**

Run: `mkdir -p infra/scripts`

- [ ] **Step 2: Write create-vm.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# create-vm.sh — Create a Proxmox VM from an Ubuntu 24.04 cloud image
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/create-vm.sh \
#     | bash -s -- --name k8s-cp-1 --ip 10.22.6.100/24
# -------------------------------------------------------------------

# Defaults
VMID=""
NAME=""
CORES=2
MEMORY=4096
DISK=32
IP=""
GW="10.22.0.1"
BRIDGE="vmbr0"
STORAGE="local-lvm"
USER="alan"
SSH_KEY_FILE="$HOME/.ssh/authorized_keys"
TEMPLATE_ID=9000
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
CLOUD_IMAGE_NAME="noble-server-cloudimg-amd64.img"

# -------------------------------------------------------------------
# Parse arguments
# -------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $0 --name <hostname> --ip <cidr> [options]

Required:
  --name          VM hostname (e.g. k8s-cp-1)
  --ip            Static IP in CIDR notation (e.g. 10.22.6.100/24)

Optional:
  --vmid          VM ID (default: auto via pvesh get /cluster/nextid)
  --cores         CPU cores (default: 2)
  --memory        RAM in MB (default: 4096)
  --disk          Disk size in GB (default: 32)
  --gw            Gateway (default: 10.22.0.1)
  --bridge        Network bridge (default: vmbr0)
  --storage       Storage target (default: local-lvm)
  --user          Cloud-init user (default: alan)
  --ssh-key       Path to SSH public key file (default: ~/.ssh/authorized_keys)
  --template-id   Base template VMID (default: 9000)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)        VMID="$2"; shift 2 ;;
    --name)        NAME="$2"; shift 2 ;;
    --cores)       CORES="$2"; shift 2 ;;
    --memory)      MEMORY="$2"; shift 2 ;;
    --disk)        DISK="$2"; shift 2 ;;
    --ip)          IP="$2"; shift 2 ;;
    --gw)          GW="$2"; shift 2 ;;
    --bridge)      BRIDGE="$2"; shift 2 ;;
    --storage)     STORAGE="$2"; shift 2 ;;
    --user)        USER="$2"; shift 2 ;;
    --ssh-key)     SSH_KEY_FILE="$2"; shift 2 ;;
    --template-id) TEMPLATE_ID="$2"; shift 2 ;;
    *)             echo "Unknown option: $1"; usage ;;
  esac
done

# Validate required args
if [[ -z "$NAME" ]]; then
  echo "Error: --name is required"
  usage
fi
if [[ -z "$IP" ]]; then
  echo "Error: --ip is required"
  usage
fi

# -------------------------------------------------------------------
# Ensure template exists
# -------------------------------------------------------------------
ensure_template() {
  if qm status "$TEMPLATE_ID" &>/dev/null; then
    echo "Template VM $TEMPLATE_ID already exists, skipping creation."
    return
  fi

  echo "Creating template VM $TEMPLATE_ID from Ubuntu 24.04 cloud image..."

  local img_path="/var/lib/vz/template/iso/${CLOUD_IMAGE_NAME}"

  if [[ ! -f "$img_path" ]]; then
    echo "Downloading Ubuntu 24.04 cloud image..."
    wget -q --show-progress -O "$img_path" "$CLOUD_IMAGE_URL"
  fi

  # Create the template VM
  qm create "$TEMPLATE_ID" \
    --name ubuntu-2404-template \
    --ostype l26 \
    --cpu host \
    --cores 2 \
    --memory 2048 \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-single \
    --agent enabled=1

  # Import the cloud image as the boot disk
  qm set "$TEMPLATE_ID" --scsi0 "${STORAGE}:0,import-from=${img_path}"

  # Add cloud-init drive
  qm set "$TEMPLATE_ID" --ide2 "${STORAGE}:cloudinit"

  # Set boot order
  qm set "$TEMPLATE_ID" --boot order=scsi0

  # Convert to template
  qm template "$TEMPLATE_ID"

  echo "Template VM $TEMPLATE_ID created."
}

# -------------------------------------------------------------------
# Create VM
# -------------------------------------------------------------------
create_vm() {
  # Auto-assign VMID if not provided
  if [[ -z "$VMID" ]]; then
    VMID=$(pvesh get /cluster/nextid)
    echo "Auto-assigned VMID: $VMID"
  fi

  # Check if VMID already exists
  if qm status "$VMID" &>/dev/null; then
    echo "Error: VM $VMID already exists. Use a different --vmid or remove the existing VM."
    exit 1
  fi

  echo "Cloning template $TEMPLATE_ID -> VM $VMID ($NAME)..."
  qm clone "$TEMPLATE_ID" "$VMID" \
    --name "$NAME" \
    --full true \
    --storage "$STORAGE"

  # Set resources
  echo "Configuring resources: ${CORES} cores, ${MEMORY}MB RAM, ${DISK}GB disk..."
  qm set "$VMID" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --net0 "virtio,bridge=${BRIDGE}"

  # Resize disk
  qm disk resize "$VMID" scsi0 "${DISK}G"

  # Configure cloud-init
  echo "Configuring cloud-init..."
  qm set "$VMID" \
    --ciuser "$USER" \
    --ipconfig0 "ip=${IP},gw=${GW}" \
    --nameserver "8.8.8.8 8.8.4.4"

  # Set SSH key if file exists
  if [[ -f "$SSH_KEY_FILE" ]]; then
    qm set "$VMID" --sshkeys "$SSH_KEY_FILE"
  else
    echo "Warning: SSH key file $SSH_KEY_FILE not found. VM will not have SSH keys configured."
  fi

  # Start VM
  echo "Starting VM $VMID..."
  qm start "$VMID"

  echo ""
  echo "================================================"
  echo " VM Created Successfully"
  echo "================================================"
  echo " VMID:     $VMID"
  echo " Name:     $NAME"
  echo " IP:       $IP"
  echo " Cores:    $CORES"
  echo " Memory:   ${MEMORY}MB"
  echo " Disk:     ${DISK}GB"
  echo " User:     $USER"
  echo " Gateway:  $GW"
  echo "================================================"
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
ensure_template
create_vm
```

- [ ] **Step 3: Make executable**

Run: `chmod +x infra/scripts/create-vm.sh`

- [ ] **Step 4: Validate script syntax**

Run: `bash -n infra/scripts/create-vm.sh`

Expected: no output (clean parse).

- [ ] **Step 5: Test help output**

Run: `bash infra/scripts/create-vm.sh`

Expected: usage text printed, exit 1 (missing required --name).

- [ ] **Step 6: Commit**

```bash
git add infra/scripts/create-vm.sh
git commit -m "feat: add VM creation script for Proxmox hosts"
```

---

### Task 2b: LXC Creation Script (Control Plane)

**Files:**
- Create: `infra/scripts/create-lxc.sh`

- [ ] **Step 1: Write create-lxc.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# create-lxc.sh — Create a Proxmox LXC container for K8s control plane
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/create-lxc.sh \
#     | bash -s -- --name k8s-cp-1 --ip 10.22.6.100/24
# -------------------------------------------------------------------

# Defaults
CTID=""
NAME=""
CORES=2
MEMORY=4096
DISK=32
IP=""
GW="10.22.0.1"
BRIDGE="vmbr0"
STORAGE="local-lvm"
SSH_KEY_FILE="$HOME/.ssh/authorized_keys"
TEMPLATE_STORAGE="local"
TEMPLATE_NAME="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

# -------------------------------------------------------------------
# Parse arguments
# -------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $0 --name <hostname> --ip <cidr> [options]

Required:
  --name          Container hostname (e.g. k8s-cp-1)
  --ip            Static IP in CIDR notation (e.g. 10.22.6.100/24)

Optional:
  --ctid          Container ID (default: auto via pvesh get /cluster/nextid)
  --cores         CPU cores (default: 2)
  --memory        RAM in MB (default: 4096)
  --disk          Disk size in GB (default: 32)
  --gw            Gateway (default: 10.22.0.1)
  --bridge        Network bridge (default: vmbr0)
  --storage       Storage target (default: local-lvm)
  --ssh-key       Path to SSH public key file (default: ~/.ssh/authorized_keys)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)    CTID="$2"; shift 2 ;;
    --name)    NAME="$2"; shift 2 ;;
    --cores)   CORES="$2"; shift 2 ;;
    --memory)  MEMORY="$2"; shift 2 ;;
    --disk)    DISK="$2"; shift 2 ;;
    --ip)      IP="$2"; shift 2 ;;
    --gw)      GW="$2"; shift 2 ;;
    --bridge)  BRIDGE="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --ssh-key) SSH_KEY_FILE="$2"; shift 2 ;;
    *)         echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "Error: --name is required"
  usage
fi
if [[ -z "$IP" ]]; then
  echo "Error: --ip is required"
  usage
fi

# -------------------------------------------------------------------
# Ensure LXC template is downloaded
# -------------------------------------------------------------------
ensure_template() {
  local template_path="/var/lib/vz/template/cache/${TEMPLATE_NAME}"
  if [[ -f "$template_path" ]]; then
    echo "LXC template already downloaded."
    return
  fi

  echo "Downloading Ubuntu 24.04 LXC template..."
  pveam update
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
}

# -------------------------------------------------------------------
# Create LXC container
# -------------------------------------------------------------------
create_lxc() {
  if [[ -z "$CTID" ]]; then
    CTID=$(pvesh get /cluster/nextid)
    echo "Auto-assigned CTID: $CTID"
  fi

  if pct status "$CTID" &>/dev/null; then
    echo "Error: Container $CTID already exists."
    exit 1
  fi

  echo "Creating LXC container $CTID ($NAME)..."

  # Build SSH key args
  local ssh_args=""
  if [[ -f "$SSH_KEY_FILE" ]]; then
    ssh_args="--ssh-public-keys $SSH_KEY_FILE"
  fi

  pct create "$CTID" \
    "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}" \
    --hostname "$NAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GW}" \
    --nameserver "8.8.8.8 8.8.4.4" \
    --unprivileged 0 \
    --features "nesting=1,keyctl=1" \
    --ostype ubuntu \
    --start false \
    $ssh_args

  # Start container
  echo "Starting container $CTID..."
  pct start "$CTID"

  echo ""
  echo "================================================"
  echo " LXC Container Created Successfully"
  echo "================================================"
  echo " CTID:     $CTID"
  echo " Name:     $NAME"
  echo " IP:       $IP"
  echo " Cores:    $CORES"
  echo " Memory:   ${MEMORY}MB"
  echo " Disk:     ${DISK}GB"
  echo " Type:     Privileged (nesting+keyctl)"
  echo " Gateway:  $GW"
  echo "================================================"
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
ensure_template
create_lxc
```

- [ ] **Step 2: Make executable**

Run: `chmod +x infra/scripts/create-lxc.sh`

- [ ] **Step 3: Validate script syntax**

Run: `bash -n infra/scripts/create-lxc.sh`

Expected: no output (clean parse).

- [ ] **Step 4: Test help output**

Run: `bash infra/scripts/create-lxc.sh`

Expected: usage text printed, exit 1 (missing required --name).

- [ ] **Step 5: Commit**

```bash
git add infra/scripts/create-lxc.sh
git commit -m "feat: add LXC creation script for control plane"
```

---

### Task 3: Ansible — Common Role

**Files:**
- Create: `infra/ansible/ansible.cfg`
- Create: `infra/ansible/inventory/hosts.yml`
- Create: `infra/ansible/inventory/group_vars/all.yml`
- Create: `infra/ansible/inventory/group_vars/control_plane.yml`
- Create: `infra/ansible/inventory/group_vars/workers.yml`
- Create: `infra/ansible/roles/common/tasks/main.yml`

- [ ] **Step 1: Create directory structure**

Run: `mkdir -p infra/ansible/{inventory/group_vars,playbooks,roles/common/tasks,roles/kubeadm/tasks,roles/control-plane/tasks,roles/worker/tasks}`

- [ ] **Step 2: Create ansible.cfg**

```ini
[defaults]
inventory = inventory/hosts.yml
remote_user = alan
private_key_file = ~/.ssh/id_ed25519
host_key_checking = false
retry_files_enabled = false

[privilege_escalation]
become = true
become_method = sudo
become_user = root
become_ask_pass = false
```

- [ ] **Step 3: Create inventory/hosts.yml**

```yaml
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

- [ ] **Step 4: Create inventory/group_vars/all.yml**

```yaml
---
# Kubernetes version — pin to specific version for reproducibility
kube_version: "1.33"
kube_package_version: "1.33.*"

# Pod network CIDR — Cilium default
pod_network_cidr: "10.244.0.0/16"

# Service CIDR
service_cidr: "10.96.0.0/12"

# Containerd version
containerd_version: "1.7.*"

# DNS
dns_servers:
  - 8.8.8.8
  - 8.8.4.4

# Kernel modules required for Kubernetes
kernel_modules:
  - overlay
  - br_netfilter

# Sysctl params required for Kubernetes
sysctl_params:
  net.bridge.bridge-nf-call-iptables: 1
  net.bridge.bridge-nf-call-ip6tables: 1
  net.ipv4.ip_forward: 1
```

- [ ] **Step 5: Create inventory/group_vars/control_plane.yml**

```yaml
---
# Control plane specific vars
kubeadm_role: control-plane
```

- [ ] **Step 6: Create inventory/group_vars/workers.yml**

```yaml
---
# Worker specific vars
kubeadm_role: worker
```

- [ ] **Step 7: Create roles/common/tasks/main.yml**

```yaml
---
- name: Disable swap
  ansible.builtin.command: swapoff -a
  changed_when: true

- name: Remove swap from fstab
  ansible.builtin.lineinfile:
    path: /etc/fstab
    regexp: '\sswap\s'
    state: absent

- name: Load required kernel modules
  ansible.builtin.modprobe:
    name: "{{ item }}"
    state: present
  loop: "{{ kernel_modules }}"

- name: Persist kernel modules
  ansible.builtin.copy:
    dest: /etc/modules-load.d/kubernetes.conf
    content: |
      {% for mod in kernel_modules %}
      {{ mod }}
      {% endfor %}
    mode: "0644"

- name: Set sysctl params
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/99-kubernetes.conf
    reload: true
  loop: "{{ sysctl_params | dict2items }}"

- name: Install required packages
  ansible.builtin.apt:
    name:
      - apt-transport-https
      - ca-certificates
      - curl
      - gnupg
      - software-properties-common
    state: present
    update_cache: true

- name: Add Docker GPG key (for containerd)
  ansible.builtin.apt_key:
    url: https://download.docker.com/linux/ubuntu/gpg
    state: present

- name: Add Docker repository (for containerd)
  ansible.builtin.apt_repository:
    repo: "deb https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable"
    state: present

- name: Install containerd
  ansible.builtin.apt:
    name: "containerd.io"
    state: present
    update_cache: true

- name: Create containerd config directory
  ansible.builtin.file:
    path: /etc/containerd
    state: directory
    mode: "0755"

- name: Generate default containerd config
  ansible.builtin.shell: containerd config default > /etc/containerd/config.toml
  changed_when: true

- name: Enable SystemdCgroup in containerd
  ansible.builtin.replace:
    path: /etc/containerd/config.toml
    regexp: 'SystemdCgroup = false'
    replace: 'SystemdCgroup = true'

- name: Restart and enable containerd
  ansible.builtin.systemd:
    name: containerd
    state: restarted
    enabled: true
    daemon_reload: true

# LXC-specific: kubelet needs /dev/kmsg
- name: Check if running in LXC
  ansible.builtin.stat:
    path: /dev/kmsg
  register: dev_kmsg

- name: Create /dev/kmsg symlink for LXC
  ansible.builtin.file:
    src: /dev/console
    dest: /dev/kmsg
    state: link
  when: not dev_kmsg.stat.exists

- name: Persist /dev/kmsg symlink via rc.local
  ansible.builtin.copy:
    dest: /etc/rc.local
    content: |
      #!/bin/bash
      if [ ! -e /dev/kmsg ]; then
        ln -s /dev/console /dev/kmsg
      fi
      exit 0
    mode: "0755"
  when: not dev_kmsg.stat.exists
```

- [ ] **Step 8: Validate syntax**

Run: `cd infra/ansible && ansible-inventory --list --yaml`

Expected: inventory output showing control_plane and workers groups with correct IPs.

- [ ] **Step 9: Commit**

```bash
git add infra/ansible/ansible.cfg infra/ansible/inventory/ infra/ansible/roles/common/
git commit -m "feat: add ansible config, inventory, and common role"
```

---

### Task 4: Ansible — kubeadm Role

**Files:**
- Create: `infra/ansible/roles/kubeadm/tasks/main.yml`

- [ ] **Step 1: Create roles/kubeadm/tasks/main.yml**

```yaml
---
- name: Add Kubernetes GPG key
  ansible.builtin.apt_key:
    url: "https://pkgs.k8s.io/core:/stable:/v{{ kube_version }}/deb/Release.key"
    state: present

- name: Add Kubernetes repository
  ansible.builtin.apt_repository:
    repo: "deb https://pkgs.k8s.io/core:/stable:/v{{ kube_version }}/deb/ /"
    state: present
    filename: kubernetes

- name: Install kubeadm, kubelet, kubectl
  ansible.builtin.apt:
    name:
      - "kubeadm={{ kube_package_version }}"
      - "kubelet={{ kube_package_version }}"
      - "kubectl={{ kube_package_version }}"
    state: present
    update_cache: true

- name: Hold kubeadm, kubelet, kubectl at current version
  ansible.builtin.dpkg_selections:
    name: "{{ item }}"
    selection: hold
  loop:
    - kubeadm
    - kubelet
    - kubectl

- name: Enable and start kubelet
  ansible.builtin.systemd:
    name: kubelet
    state: started
    enabled: true
```

- [ ] **Step 2: Commit**

```bash
git add infra/ansible/roles/kubeadm/
git commit -m "feat: add kubeadm install role"
```

---

### Task 5: Ansible — Control Plane Role & Playbook

**Files:**
- Create: `infra/ansible/roles/control-plane/tasks/main.yml`
- Create: `infra/ansible/playbooks/bootstrap-control-plane.yml`

- [ ] **Step 1: Create roles/control-plane/tasks/main.yml**

```yaml
---
- name: Check if kubeadm has already been initialized
  ansible.builtin.stat:
    path: /etc/kubernetes/admin.conf
  register: kubeadm_init_check

- name: Initialize control plane
  ansible.builtin.command: >
    kubeadm init
    --pod-network-cidr={{ pod_network_cidr }}
    --service-cidr={{ service_cidr }}
    --skip-phases=addon/kube-proxy
  when: not kubeadm_init_check.stat.exists
  register: kubeadm_init

- name: Create .kube directory for user
  ansible.builtin.file:
    path: "/home/{{ ansible_user }}/.kube"
    state: directory
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: "0755"

- name: Copy admin.conf to user's kubeconfig
  ansible.builtin.copy:
    src: /etc/kubernetes/admin.conf
    dest: "/home/{{ ansible_user }}/.kube/config"
    remote_src: true
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: "0600"

- name: Fetch kubeconfig to local machine
  ansible.builtin.fetch:
    src: /etc/kubernetes/admin.conf
    dest: "~/.kube/config"
    flat: true

- name: Generate join command
  ansible.builtin.command: kubeadm token create --print-join-command
  register: join_command
  changed_when: false

- name: Save join command locally
  ansible.builtin.copy:
    content: "{{ join_command.stdout }}"
    dest: "{{ playbook_dir }}/../.join-token"
    mode: "0600"
  delegate_to: localhost
  become: false
```

- [ ] **Step 2: Create playbooks/bootstrap-control-plane.yml**

```yaml
---
- name: Bootstrap Kubernetes control plane
  hosts: control_plane
  become: true
  roles:
    - common
    - kubeadm
    - control-plane
```

- [ ] **Step 3: Validate playbook syntax**

Run: `cd infra/ansible && ansible-playbook playbooks/bootstrap-control-plane.yml --syntax-check`

Expected: `playbook: playbooks/bootstrap-control-plane.yml` (no errors)

- [ ] **Step 4: Commit**

```bash
git add infra/ansible/roles/control-plane/ infra/ansible/playbooks/bootstrap-control-plane.yml
git commit -m "feat: add control plane role and bootstrap playbook"
```

---

### Task 6: Ansible — Worker Role & Playbook

**Files:**
- Create: `infra/ansible/roles/worker/tasks/main.yml`
- Create: `infra/ansible/playbooks/bootstrap-worker.yml`

- [ ] **Step 1: Create roles/worker/tasks/main.yml**

```yaml
---
- name: Read join command from local file
  ansible.builtin.set_fact:
    kubeadm_join_command: "{{ lookup('file', playbook_dir + '/../.join-token') }}"

- name: Check if node has already joined the cluster
  ansible.builtin.stat:
    path: /etc/kubernetes/kubelet.conf
  register: kubelet_conf

- name: Join the cluster
  ansible.builtin.command: "{{ kubeadm_join_command }}"
  when: not kubelet_conf.stat.exists
```

- [ ] **Step 2: Create playbooks/bootstrap-worker.yml**

```yaml
---
- name: Bootstrap Kubernetes worker nodes
  hosts: workers
  become: true
  roles:
    - common
    - kubeadm
    - worker
```

- [ ] **Step 3: Validate playbook syntax**

Run: `cd infra/ansible && ansible-playbook playbooks/bootstrap-worker.yml --syntax-check`

Expected: `playbook: playbooks/bootstrap-worker.yml` (no errors)

- [ ] **Step 4: Commit**

```bash
git add infra/ansible/roles/worker/ infra/ansible/playbooks/bootstrap-worker.yml
git commit -m "feat: add worker role and bootstrap playbook"
```

---

### Task 7: Ansible — K8s Upgrade Playbook

**Files:**
- Create: `infra/ansible/playbooks/upgrade-k8s.yml`

- [ ] **Step 1: Create playbooks/upgrade-k8s.yml**

```yaml
---
# Upgrade control plane first
- name: Upgrade control plane
  hosts: control_plane
  become: true
  serial: 1
  vars_prompt:
    - name: target_kube_version
      prompt: "Target Kubernetes minor version (e.g. 1.33)"
      private: false
    - name: target_kube_package_version
      prompt: "Target package version pattern (e.g. 1.33.*)"
      private: false
  tasks:
    - name: Update Kubernetes repository
      ansible.builtin.apt_repository:
        repo: "deb https://pkgs.k8s.io/core:/stable:/v{{ target_kube_version }}/deb/ /"
        state: present
        filename: kubernetes

    - name: Unhold kubeadm
      ansible.builtin.dpkg_selections:
        name: kubeadm
        selection: install

    - name: Upgrade kubeadm
      ansible.builtin.apt:
        name: "kubeadm={{ target_kube_package_version }}"
        state: present
        update_cache: true

    - name: Hold kubeadm
      ansible.builtin.dpkg_selections:
        name: kubeadm
        selection: hold

    - name: Plan upgrade
      ansible.builtin.command: "kubeadm upgrade plan"
      register: upgrade_plan
      changed_when: false

    - name: Show upgrade plan
      ansible.builtin.debug:
        var: upgrade_plan.stdout_lines

    - name: Apply upgrade
      ansible.builtin.command: "kubeadm upgrade apply v{{ target_kube_version }}.0 --yes"
      changed_when: true

    - name: Unhold kubelet and kubectl
      ansible.builtin.dpkg_selections:
        name: "{{ item }}"
        selection: install
      loop:
        - kubelet
        - kubectl

    - name: Upgrade kubelet and kubectl
      ansible.builtin.apt:
        name:
          - "kubelet={{ target_kube_package_version }}"
          - "kubectl={{ target_kube_package_version }}"
        state: present
        update_cache: true

    - name: Hold kubelet and kubectl
      ansible.builtin.dpkg_selections:
        name: "{{ item }}"
        selection: hold
      loop:
        - kubelet
        - kubectl

    - name: Restart kubelet
      ansible.builtin.systemd:
        name: kubelet
        state: restarted
        daemon_reload: true

# Upgrade workers one at a time
- name: Upgrade worker nodes
  hosts: workers
  become: true
  serial: 1
  tasks:
    - name: Drain node
      ansible.builtin.command: "kubectl drain {{ inventory_hostname }} --ignore-daemonsets --delete-emptydir-data"
      delegate_to: "{{ groups['control_plane'][0] }}"
      changed_when: true

    - name: Update Kubernetes repository
      ansible.builtin.apt_repository:
        repo: "deb https://pkgs.k8s.io/core:/stable:/v{{ hostvars[groups['control_plane'][0]]['target_kube_version'] }}/deb/ /"
        state: present
        filename: kubernetes

    - name: Unhold kubeadm
      ansible.builtin.dpkg_selections:
        name: kubeadm
        selection: install

    - name: Upgrade kubeadm
      ansible.builtin.apt:
        name: "kubeadm={{ hostvars[groups['control_plane'][0]]['target_kube_package_version'] }}"
        state: present
        update_cache: true

    - name: Hold kubeadm
      ansible.builtin.dpkg_selections:
        name: kubeadm
        selection: hold

    - name: Upgrade node config
      ansible.builtin.command: "kubeadm upgrade node"
      changed_when: true

    - name: Unhold kubelet and kubectl
      ansible.builtin.dpkg_selections:
        name: "{{ item }}"
        selection: install
      loop:
        - kubelet
        - kubectl

    - name: Upgrade kubelet and kubectl
      ansible.builtin.apt:
        name:
          - "kubelet={{ hostvars[groups['control_plane'][0]]['target_kube_package_version'] }}"
          - "kubectl={{ hostvars[groups['control_plane'][0]]['target_kube_package_version'] }}"
        state: present
        update_cache: true

    - name: Hold kubelet and kubectl
      ansible.builtin.dpkg_selections:
        name: "{{ item }}"
        selection: hold
      loop:
        - kubelet
        - kubectl

    - name: Restart kubelet
      ansible.builtin.systemd:
        name: kubelet
        state: restarted
        daemon_reload: true

    - name: Uncordon node
      ansible.builtin.command: "kubectl uncordon {{ inventory_hostname }}"
      delegate_to: "{{ groups['control_plane'][0] }}"
      changed_when: true
```

- [ ] **Step 2: Validate playbook syntax**

Run: `cd infra/ansible && ansible-playbook playbooks/upgrade-k8s.yml --syntax-check`

Expected: `playbook: playbooks/upgrade-k8s.yml` (no errors)

- [ ] **Step 3: Commit**

```bash
git add infra/ansible/playbooks/upgrade-k8s.yml
git commit -m "feat: add k8s upgrade playbook with rolling worker upgrades"
```

---

### Task 8: ArgoCD App-of-Apps Chart

**Files:**
- Create: `charts/argocd-apps/Chart.yaml`
- Create: `charts/argocd-apps/values.yaml`
- Create: `charts/argocd-apps/templates/applications.yaml`

- [ ] **Step 1: Create directory**

Run: `mkdir -p charts/argocd-apps/templates`

- [ ] **Step 2: Create Chart.yaml**

```yaml
apiVersion: v2
name: argocd-apps
description: App-of-apps pattern — generates ArgoCD Application CRs for all charts
type: application
version: 0.1.0
```

- [ ] **Step 3: Create values.yaml**

```yaml
# GitHub repository URL
repoURL: https://github.com/mralanlee/homelab.git
targetRevision: main

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

  - name: cn-pg
    namespace: cnpg-system
    path: charts/cn-pg

  - name: democratic-csi
    namespace: democratic-csi
    path: charts/democratic-csi

  - name: authentik
    namespace: authentik
    path: charts/authentik

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

- [ ] **Step 4: Create templates/applications.yaml**

```yaml
{{- range .Values.apps }}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name }}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: {{ $.Values.repoURL }}
    targetRevision: {{ $.Values.targetRevision }}
    path: {{ .path }}
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ .namespace }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
{{- end }}
```

- [ ] **Step 5: Validate template renders**

Run: `helm template argocd-apps charts/argocd-apps`

Expected: 12 ArgoCD Application manifests rendered, one per app entry. Each should have correct namespace, path, and sync policy.

- [ ] **Step 6: Commit**

```bash
git add charts/argocd-apps/
git commit -m "feat: add argocd app-of-apps chart"
```

---

### Task 9: Update All Helm Chart Dependencies

**Files:**
- Modify: All 13 `charts/*/Chart.yaml` files
- Regenerate: All 13 `charts/*/Chart.lock` files

This task looks up the latest version for each chart dependency and updates `Chart.yaml` accordingly. Since these are upstream public charts, use `helm search repo` to find latest versions.

- [ ] **Step 1: Add all Helm repos**

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add jetstack https://charts.jetstack.io
helm repo add cilium https://helm.cilium.io/
helm repo add metallb https://metallb.github.io/metallb
helm repo add traefik https://traefik.github.io/charts
helm repo add goauthentik https://charts.goauthentik.io
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo add democratic-csi https://democratic-csi.github.io/charts
helm repo add external-secrets https://charts.external-secrets.io
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
helm repo add community-charts https://community-charts.github.io/helm-charts
helm repo add stakater https://stakater.github.io/stakater-charts
helm repo update
```

- [ ] **Step 2: Look up latest versions**

```bash
helm search repo argo/argo-cd --versions -l | head -5
helm search repo jetstack/cert-manager --versions -l | head -5
helm search repo cilium/cilium --versions -l | head -5
helm search repo metallb/metallb --versions -l | head -5
helm search repo traefik/traefik --versions -l | head -5
helm search repo goauthentik/authentik --versions -l | head -5
helm search repo cnpg/cloudnative-pg --versions -l | head -5
helm search repo democratic-csi/democratic-csi --versions -l | head -5
helm search repo external-secrets/external-secrets --versions -l | head -5
helm search repo stakater/reloader --versions -l | head -5
helm search repo grafana/grafana --versions -l | head -5
helm search repo prometheus-community/kube-prometheus-stack --versions -l | head -5
helm search repo metrics-server/metrics-server --versions -l | head -5
helm search repo community-charts/n8n --versions -l | head -5
```

Record the latest stable version for each.

- [ ] **Step 3: Update each Chart.yaml with latest version**

For each chart, update the `version` field in the `dependencies` section of `Chart.yaml` to the latest version found in step 2. Example for argocd — change `version: 9.1.6` to the latest version.

Update all 13 charts (plus the reloader dependency in external-secrets).

- [ ] **Step 4: Regenerate all Chart.lock files**

```bash
for chart in argocd authentik cert-manager cilium cn-pg democratic-csi external-secrets grafana kube-prometheus-stack metallb metrics-server n8n traefik; do
  echo "Updating charts/$chart..."
  helm dependency update "charts/$chart"
done
```

Expected: each chart downloads its updated dependency tarball and regenerates `Chart.lock`.

- [ ] **Step 5: Review for breaking changes**

For each chart that had a major version bump, check the upstream changelog. Pay attention to:
- Renamed or removed values keys
- Changed default behavior
- CRD changes requiring manual migration

If any `values.yaml` changes are needed, make them now.

- [ ] **Step 6: Validate all charts template cleanly**

```bash
for chart in argocd authentik cert-manager cilium cn-pg democratic-csi external-secrets grafana kube-prometheus-stack metallb metrics-server n8n traefik; do
  echo "=== Templating charts/$chart ==="
  helm template test "charts/$chart" > /dev/null && echo "OK" || echo "FAILED"
done
```

Expected: all charts template without errors.

- [ ] **Step 7: Commit**

```bash
git add charts/*/Chart.yaml charts/*/Chart.lock
git commit -m "chore: update all helm chart dependencies to latest versions"
```

If any `values.yaml` files were modified for breaking changes:

```bash
git add charts/*/values.yaml
git commit -m "fix: update values for breaking changes in chart upgrades"
```

---

### Task 10: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite README.md**

```markdown
# Homelab

Kubernetes homelab on Proxmox. Fully reproducible — VMs provisioned via bash script, K8s bootstrapped via Ansible, workloads managed via ArgoCD.

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
# Control plane LXC (on singed)
curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/create-lxc.sh \
  | bash -s -- --name k8s-cp-1 --ip 10.22.6.100/24

# Worker VMs (on respective hosts)
curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/create-vm.sh \
  | bash -s -- --name k8s-w-1 --ip 10.22.6.101/24

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

```bash
# Install CNI, load balancer, and ArgoCD (one-time)
helm dependency update charts/cilium && helm install cilium charts/cilium -n kube-system
helm dependency update charts/metallb && helm install metallb charts/metallb -n metallb-system --create-namespace
helm dependency update charts/argocd && helm install argocd charts/argocd -n argocd --create-namespace

# Deploy app-of-apps — ArgoCD manages everything from here
helm dependency update charts/argocd-apps && helm install argocd-apps charts/argocd-apps -n argocd
```

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
curl -sL .../create-vm.sh | bash -s -- --name k8s-w-5 --ip 10.22.6.105/24
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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README with full setup and usage guide"
```

---

### Task 11: Final Validation

- [ ] **Step 1: Verify all new files exist**

```bash
ls -la flake.nix .envrc
ls -la infra/scripts/create-vm.sh
ls -la infra/ansible/ansible.cfg
ls -la infra/ansible/inventory/hosts.yml
ls -la infra/ansible/inventory/group_vars/{all,control_plane,workers}.yml
ls -la infra/ansible/roles/{common,kubeadm,control-plane,worker}/tasks/main.yml
ls -la infra/ansible/playbooks/{bootstrap-control-plane,bootstrap-worker,upgrade-k8s}.yml
ls -la charts/argocd-apps/{Chart.yaml,values.yaml,templates/applications.yaml}
```

Expected: all files present.

- [ ] **Step 2: Verify gitignore entries**

```bash
grep -c "direnv\|join-token\|superpowers\|result" .gitignore
```

Expected: 4 matches.

- [ ] **Step 3: Verify all ansible playbooks pass syntax check**

```bash
cd infra/ansible
ansible-playbook playbooks/bootstrap-control-plane.yml --syntax-check
ansible-playbook playbooks/bootstrap-worker.yml --syntax-check
ansible-playbook playbooks/upgrade-k8s.yml --syntax-check
```

Expected: all pass.

- [ ] **Step 4: Verify all helm charts template**

```bash
helm template argocd-apps charts/argocd-apps
for chart in argocd authentik cert-manager cilium cn-pg democratic-csi external-secrets grafana kube-prometheus-stack metallb metrics-server n8n traefik; do
  helm template test "charts/$chart" > /dev/null && echo "$chart: OK" || echo "$chart: FAILED"
done
```

Expected: all OK.

- [ ] **Step 5: Verify nix flake**

```bash
nix flake check
```

Expected: no errors.
