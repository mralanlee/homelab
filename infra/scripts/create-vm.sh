#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# create-vm.sh — Create a Proxmox VM from an Ubuntu 24.04 cloud image
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/create-vm.sh \
#     | bash -s -- --name k8s-w-1 --ip 10.22.6.101/16
# -------------------------------------------------------------------

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

usage() {
  cat <<EOF
Usage: $0 --name <hostname> --ip <cidr> [options]

Required:
  --name          VM hostname (e.g. k8s-w-1)
  --ip            Static IP in CIDR notation (e.g. 10.22.6.101/16)

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

if [[ -z "$NAME" ]]; then
  echo "Error: --name is required"
  usage
fi
if [[ -z "$IP" ]]; then
  echo "Error: --ip is required"
  usage
fi

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

  qm create "$TEMPLATE_ID" \
    --name ubuntu-2404-template \
    --ostype l26 \
    --cpu host \
    --cores 2 \
    --memory 2048 \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-single \
    --agent enabled=1

  qm set "$TEMPLATE_ID" --scsi0 "${STORAGE}:0,import-from=${img_path}"
  qm set "$TEMPLATE_ID" --ide2 "${STORAGE}:cloudinit"
  qm set "$TEMPLATE_ID" --boot order=scsi0
  qm template "$TEMPLATE_ID"

  echo "Template VM $TEMPLATE_ID created."
}

create_vm() {
  if [[ -z "$VMID" ]]; then
    VMID=$(pvesh get /cluster/nextid)
    echo "Auto-assigned VMID: $VMID"
  fi

  if qm status "$VMID" &>/dev/null; then
    echo "Error: VM $VMID already exists. Use a different --vmid or remove the existing VM."
    exit 1
  fi

  echo "Cloning template $TEMPLATE_ID -> VM $VMID ($NAME)..."
  qm clone "$TEMPLATE_ID" "$VMID" \
    --name "$NAME" \
    --full true \
    --storage "$STORAGE"

  echo "Configuring resources: ${CORES} cores, ${MEMORY}MB RAM, ${DISK}GB disk..."
  qm set "$VMID" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --net0 "virtio,bridge=${BRIDGE}"

  qm disk resize "$VMID" scsi0 "${DISK}G"

  echo "Configuring cloud-init..."
  qm set "$VMID" \
    --ciuser "$USER" \
    --ipconfig0 "ip=${IP},gw=${GW}" \
    --nameserver "8.8.8.8 8.8.4.4"

  if [[ -f "$SSH_KEY_FILE" ]]; then
    qm set "$VMID" --sshkeys "$SSH_KEY_FILE"
  else
    echo "Warning: SSH key file $SSH_KEY_FILE not found. VM will not have SSH keys configured."
  fi

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

ensure_template
create_vm
