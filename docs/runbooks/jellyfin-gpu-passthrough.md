# Jellyfin Intel iGPU Passthrough to k8s-w-2

This runbook documents the manual procedure to pass through an Intel iGPU from the Proxmox host to the Kubernetes worker node `k8s-w-2`. This allows Jellyfin to use hardware-accelerated transcoding inside Kubernetes.

## Prerequisites

- Proxmox host `pve1` with IOMMU enabled (kernel cmdline: `intel_iommu=on iommu=pt`)
- Running Dockge LXC (CTID: `<DOCKGE_CTID>`)
- Kubernetes worker node `k8s-w-2` (VMID: `<VMID>`)
- SSH access to Proxmox and k8s-w-2
- kubectl access to the cluster

## Overview

Passthrough moves the iGPU from the Dockge LXC to the k8s-w-2 VM. Once complete, the GPU will be available at `/dev/dri/card0` and `/dev/dri/renderD128` inside k8s-w-2, and the node will be labeled for the Intel GPU plugin.

## Risk

VFIO passthrough is a host-level operation. The iGPU will be **dedicated exclusively to k8s-w-2** once attached. The Proxmox host and other guests will lose access to the GPU. Revert all steps (in reverse order) to restore access.

---

## Step 1: Stop Jellyfin and Release iGPU from Dockge LXC

### Procedure

1. **Stop the Jellyfin compose stack on Dockge:**

   ```bash
   ssh dockge
   cd /dockge
   docker-compose down jellyfin
   ```

   Expected: Jellyfin container stops cleanly.

2. **On Proxmox (`pve1`), edit the Dockge LXC configuration:**

   ```bash
   vi /etc/pve/lxc/<DOCKGE_CTID>.conf
   ```

3. **Locate and remove the `/dev/dri` passthrough lines:**

   Search for and delete the following lines (exact format may vary):

   ```
   lxc.mount.entry: /dev/dri dev/dri none bind,create=dir 0 0
   lxc.cgroup2.devices.allow: c 226:* rwm
   ```

   After removal, save and exit the editor.

4. **Verify the lines are removed:**

   ```bash
   grep -E "dev/dri|226" /etc/pve/lxc/<DOCKGE_CTID>.conf
   ```

   Expected: No output (lines successfully removed).

### Expected Output

- Jellyfin service stops without errors
- Editor closes cleanly after removal
- `grep` returns no results confirming removal

### Rollback

If the GPU must be returned to Dockge, add these lines back to `/etc/pve/lxc/<DOCKGE_CTID>.conf`:

```
lxc.mount.entry: /dev/dri dev/dri none bind,create=dir 0 0
lxc.cgroup2.devices.allow: c 226:* rwm
```

Then restart the Dockge LXC:

```bash
pct stop <DOCKGE_CTID> && pct start <DOCKGE_CTID>
```

---

## Step 2: VFIO-Bind the iGPU and Attach to k8s-w-2

### Procedure

1. **On Proxmox (`pve1`), identify the iGPU PCI address:**

   ```bash
   lspci -nn | grep -Ei 'VGA|Display'
   ```

   Example output:

   ```
   00:02.0 VGA compatible controller [0300]: Intel Corporation UHD Graphics 730 [8086:4692] (rev 07)
   ```

   Note the PCI address (e.g., `00:02.0`) and the device ID (e.g., `8086:4692`).

2. **Attach the iGPU to the k8s-w-2 VM:**

   Replace `<VMID>` with the VM ID of k8s-w-2 and `<PCI_ADDR>` with the address from step 1:

   ```bash
   qm set <VMID> -hostpci0 <PCI_ADDR>,pcie=1
   ```

   Example:

   ```bash
   qm set 201 -hostpci0 00:02.0,pcie=1
   ```

   Expected: Command completes without error.

3. **Verify the attachment:**

   ```bash
   qm config <VMID> | grep hostpci
   ```

   Expected output (example):

   ```
   hostpci0: 00:02.0,pcie=1
   ```

### Expected Output

- `lspci` shows the iGPU with its PCI address and device ID
- `qm set` completes silently
- `qm config` confirms the hostpci line is present

### Rollback

To remove the GPU attachment and return it to Proxmox/Dockge:

1. **Delete the hostpci0 entry:**

   ```bash
   qm set <VMID> -delete hostpci0
   ```

2. **Verify removal:**

   ```bash
   qm config <VMID> | grep hostpci
   ```

   Expected: No output.

3. **Restore the Dockge LXC config** (see Step 1 rollback) and restart the LXC.

---

## Step 3: Reboot the VM and Verify GPU Presence

### Procedure

1. **Stop and start the k8s-w-2 VM:**

   ```bash
   qm stop <VMID> && qm start <VMID>
   ```

   Expected: VM stops and restarts cleanly. Wait ~30 seconds for it to come up.

2. **SSH into k8s-w-2 and verify `/dev/dri` is present:**

   ```bash
   ssh k8s-w-2
   ls -l /dev/dri
   ```

   Expected output (example):

   ```
   total 0
   crw-rw---- 1 root video    226,   0 Jul 31 10:15 card0
   crw-rw---- 1 root render  226, 128 Jul 31 10:15 renderD128
   ```

   If you see `card0` and `renderD128`, the GPU is present.

3. **Record the render group GID (required for Task 4):**

   ```bash
   stat -c '%g' /dev/dri/renderD128
   ```

   Example output:

   ```
   113
   ```

   **Record this number as `<RENDER_GID>`** (in this example, `113`). This value is needed for the Jellyfin pod's `supplementalGroups` in Task 4. Note: the original Dockge compose used GID `104`, but use the observed value here.

### Expected Output

- VM reboots and SSH is available
- `/dev/dri/card0` and `/dev/dri/renderD128` are present
- `stat` returns the render device group ID

### Rollback

If the GPU is not present after reboot:

1. Verify the VM has the correct hostpci0 entry:
   ```bash
   qm config <VMID> | grep hostpci
   ```

2. Check kernel messages for IOMMU/VFIO errors:
   ```bash
   dmesg | grep -Ei 'IOMMU|VFIO|iGPU|0000:00:02'
   ```

3. If the attachment failed, revert Step 2 and troubleshoot IOMMU enablement on Proxmox.

---

## Step 4: Label the Node for the Intel GPU Plugin

### Procedure

1. **Add the Intel GPU node label to k8s-w-2:**

   ```bash
   kubectl label node k8s-w-2 intel.feature.node.kubernetes.io/gpu=true --overwrite
   ```

   Expected: `node/k8s-w-2 labeled` (or similar).

2. **Verify the label is present:**

   ```bash
   kubectl get node k8s-w-2 --show-labels | tr ',' '\n' | grep intel
   ```

   Expected output (example):

   ```
   intel.feature.node.kubernetes.io/gpu=true
   ```

   If the label appears, the node is properly labeled.

### Expected Output

- kubectl returns success message
- Label query confirms the presence of `intel.feature.node.kubernetes.io/gpu=true`

### Rollback

To remove the label:

```bash
kubectl label node k8s-w-2 intel.feature.node.kubernetes.io/gpu- --overwrite
```

---

## Verification Checklist

Before proceeding to Task 3 (Jellyfin Helm deployment):

- [ ] Dockge Jellyfin stack is stopped
- [ ] `/dev/dri` passthrough removed from Dockge LXC config
- [ ] `qm config <VMID>` shows `hostpci0: <PCI_ADDR>,pcie=1`
- [ ] k8s-w-2 VM has rebooted successfully
- [ ] `/dev/dri/card0` and `/dev/dri/renderD128` are present on k8s-w-2
- [ ] `<RENDER_GID>` value is recorded (from `stat -c '%g' /dev/dri/renderD128`)
- [ ] `kubectl get node k8s-w-2 --show-labels` includes `intel.feature.node.kubernetes.io/gpu=true`

---

## Notes for Downstream Tasks

- **Task 3 (Jellyfin Helm)**: Use the node label `intel.feature.node.kubernetes.io/gpu=true` in the plugin `nodeSelector`.
- **Task 4 (Jellyfin values)**: Update `supplementalGroups[0]` with the `<RENDER_GID>` value recorded in Step 3.

---

## Troubleshooting

### GPU not visible after reboot

1. Verify IOMMU is enabled on Proxmox:
   ```bash
   cat /proc/cmdline | grep intel_iommu
   ```
   Expected: Should show `intel_iommu=on iommu=pt`.

2. Check for VFIO driver conflicts:
   ```bash
   dmesg | grep -i vfio
   ```

3. Re-check hostpci0 entry:
   ```bash
   qm config <VMID> | grep hostpci
   ```

### Dockge LXC fails to restart after rollback

1. Ensure the `/dev/dri` passthrough lines are correctly re-added (check syntax).
2. Restart the Dockge LXC:
   ```bash
   pct stop <DOCKGE_CTID> && pct start <DOCKGE_CTID>
   ```
3. Check Dockge logs for cgroup or device errors.

### kubectl label command fails

1. Ensure kubectl is configured for the correct cluster context.
2. Verify k8s-w-2 node is in `Ready` state:
   ```bash
   kubectl get node k8s-w-2
   ```

---
