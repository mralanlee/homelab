#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# create-lxc.sh — Create a Proxmox LXC container for K8s control plane
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/create-lxc.sh \
#     | bash -s -- --name k8s-cp-1 --ip 10.22.6.100/16
# -------------------------------------------------------------------

CTID=""
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
TEMPLATE_STORAGE="local"
TEMPLATE_NAME="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

usage() {
  cat <<EOF
Usage: $0 --name <hostname> --ip <cidr> [options]

Required:
  --name          Container hostname (e.g. k8s-cp-1)
  --ip            Static IP in CIDR notation (e.g. 10.22.6.100/16)

Optional:
  --ctid          Container ID (default: auto via pvesh get /cluster/nextid)
  --cores         CPU cores (default: 2)
  --memory        RAM in MB (default: 4096)
  --disk          Disk size in GB (default: 32)
  --gw            Gateway (default: 10.22.0.1)
  --bridge        Network bridge (default: vmbr0)
  --storage       Storage target (default: local-lvm)
  --user          Username to create (default: alan)
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
    --user)    USER="$2"; shift 2 ;;
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

  echo "Starting container $CTID..."
  pct start "$CTID"

  # Wait for container to be ready
  echo "Waiting for container to boot..."
  sleep 3

  configure_lxc
}

# -------------------------------------------------------------------
# Configure user, SSH, and security inside the container
# -------------------------------------------------------------------
configure_lxc() {
  echo "Configuring user and SSH access..."

  # Install sudo and openssh-server
  pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get install -y -qq sudo openssh-server > /dev/null 2>&1"

  # Create user with sudo
  pct exec "$CTID" -- bash -c "
    useradd -m -s /bin/bash $USER 2>/dev/null || true
    usermod -aG sudo $USER
    echo '$USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$USER
    chmod 440 /etc/sudoers.d/$USER
  "

  # Set up SSH key
  if [[ -f "$SSH_KEY_FILE" ]]; then
    local pub_key
    pub_key=$(cat "$SSH_KEY_FILE")
    pct exec "$CTID" -- bash -c "
      mkdir -p /home/$USER/.ssh
      echo '$pub_key' > /home/$USER/.ssh/authorized_keys
      chmod 700 /home/$USER/.ssh
      chmod 600 /home/$USER/.ssh/authorized_keys
      chown -R $USER:$USER /home/$USER/.ssh
    "
  else
    echo "Warning: SSH key file $SSH_KEY_FILE not found. No SSH key configured."
  fi

  # Disable password auth and lock root
  pct exec "$CTID" -- bash -c "
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl restart sshd
    passwd -l root
  "

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
  echo " User:     $USER"
  echo " Type:     Privileged (nesting+keyctl)"
  echo " Gateway:  $GW"
  echo "================================================"
}

ensure_template
create_lxc
