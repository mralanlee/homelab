#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# prep-proxmox-host.sh — Prepare a Proxmox host for K8s LXC control plane
#
# Run on the Proxmox node that will host the K8s control plane LXC.
# Required because LXC shares kernel with host — sysctl and modules
# must be set on host, not inside container.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/mralanlee/homelab/main/infra/scripts/prep-proxmox-host.sh | bash
# -------------------------------------------------------------------

echo "Loading kernel modules..."
cat > /etc/modules-load.d/kubernetes.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

echo "Setting sysctl params..."
cat > /etc/sysctl.d/99-kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

sysctl --system

echo ""
echo "================================================"
echo " Proxmox host prepared for K8s LXC"
echo "================================================"
echo " Kernel modules: overlay, br_netfilter"
echo " Sysctl: bridge-nf-call-iptables, ip_forward"
echo "================================================"
