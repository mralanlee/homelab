# Jellyfin Config Migration Runbook

This runbook documents how to seed the Jellyfin Kubernetes config PVC with the existing configuration from the Dockge LXC container host.

## Prerequisites

- Access to the Dockge LXC host where the source Jellyfin config lives at `/apps/jellyfin/config`
- Access to a workstation where `kubectl` is configured for cluster access (kubeconfig available)
- `kubectl` CLI tool installed on the workstation
- The Jellyfin Helm chart deployed in the `jellyfin` namespace with a `jellyfin` deployment and config PVC

## Important Notes

- **Cache is NOT migrated:** The Jellyfin cache (`cache/` directory) is mounted as an emptyDir volume and intentionally excluded from this migration. Cache will regenerate on first startup and subsequent library scans.
- **RWO constraint:** The config PVC is ReadWriteOnce (RWO) on iSCSI, so it cannot be mounted by both the Jellyfin pod and the seed helper simultaneously. Jellyfin is scaled to zero during the migration.
- **Jellyfin will be unavailable** during this procedure. Plan accordingly and notify users before starting.

## Procedure

### Step 1: Package the source config on the Dockge LXC

On the Dockge LXC host, package the existing Jellyfin config:

```bash
# Stop the Jellyfin compose stack to ensure a clean state
ssh dockge
cd /dockge
docker-compose down jellyfin || true

# Create a gzipped tar of the config directory
tar -C /apps/jellyfin -czf /tmp/jellyfin-config.tgz config
```

Copy the tarball to your kubectl workstation (replace `<WORKSTATION>` and `<PATH>` as needed):

```bash
scp dockge-host:/tmp/jellyfin-config.tgz <PATH>/jellyfin-config.tgz
```

Verify the tarball exists and is non-empty on the workstation before proceeding.

### Step 2: Scale Jellyfin to zero

Scale the Jellyfin deployment to zero replicas to release the config PVC:

```bash
kubectl -n jellyfin scale deploy jellyfin --replicas=0
```

Wait for the pod to be deleted:

```bash
kubectl -n jellyfin wait --for=delete pod -l app.kubernetes.io/name=jellyfin --timeout=120s
```

Verify all Jellyfin pods are gone:

```bash
kubectl -n jellyfin get pods -l app.kubernetes.io/name=jellyfin
```

Expected output: No pods should be listed.

### Step 3: Launch a helper pod mounting the config PVC

First, identify the config PVC name:

```bash
kubectl -n jellyfin get pvc
```

Look for a PVC named something like `jellyfin` or similar. Replace `<CONFIG_PVC>` in the command below with the actual PVC name.

Launch a busybox helper pod that mounts the config PVC:

```bash
kubectl -n jellyfin run jf-seed --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"jf-seed","image":"busybox:1.36","command":["sleep","3600"],"volumeMounts":[{"name":"c","mountPath":"/config"}]}],"volumes":[{"name":"c","persistentVolumeClaim":{"claimName":"<CONFIG_PVC>"}}]}}'
```

Wait for the helper pod to be ready:

```bash
kubectl -n jellyfin wait --for=condition=Ready pod/jf-seed --timeout=120s
```

Verify the pod is running:

```bash
kubectl -n jellyfin get pod jf-seed
```

### Step 4: Copy the config in and fix ownership

Copy the tarball from your workstation into the helper pod:

```bash
kubectl -n jellyfin cp /tmp/jellyfin-config.tgz jf-seed:/tmp/jellyfin-config.tgz
```

Extract the tarball, set correct ownership, and verify:

```bash
kubectl -n jellyfin exec jf-seed -- sh -c 'cd /config && tar --strip-components=1 -xzf /tmp/jellyfin-config.tgz && chown -R 1000:1000 /config && rm /tmp/jellyfin-config.tgz && ls -la /config'
```

Expected output: The extracted Jellyfin config directories and files (e.g., `data/`, `config/`, `.db` files) listed under `/config`, all owned by `1000:1000` (the Jellyfin user).

Example:

```
drwxr-xr-x    2 1000     1000          4096 Jul 31 12:34 data
drwxr-xr-x    2 1000     1000          4096 Jul 31 12:34 config
-rw-r--r--    1 1000     1000       1234567 Jul 31 12:34 jellyfin.db
```

### Step 5: Remove the helper and scale Jellyfin back up

Delete the helper pod:

```bash
kubectl -n jellyfin delete pod jf-seed
```

Scale the Jellyfin deployment back to one replica:

```bash
kubectl -n jellyfin scale deploy jellyfin --replicas=1
```

Wait for the Jellyfin pod to be ready:

```bash
kubectl -n jellyfin wait --for=condition=Ready pod -l app.kubernetes.io/name=jellyfin --timeout=300s
```

Verify the Jellyfin pod is running and healthy:

```bash
kubectl -n jellyfin get pods -l app.kubernetes.io/name=jellyfin
kubectl -n jellyfin logs -l app.kubernetes.io/name=jellyfin --tail=50
```

## Verification

Once Jellyfin has started:

1. **Verify the config was migrated:** Log into the Jellyfin web UI and confirm your libraries, users, and settings are present.
2. **Monitor early startup:** Watch the logs for any errors related to database migration or configuration loading.
3. **Test library access:** Scan a library and verify media is accessible and playback works.
4. **Cache regeneration:** The cache will rebuild on first library scan; this is expected and normal.

## Rollback

If the migration fails:

1. Scale Jellyfin to zero: `kubectl -n jellyfin scale deploy jellyfin --replicas=0`
2. Restore from the original Dockge container:
   ```bash
   ssh dockge
   cd /dockge
   docker-compose up -d jellyfin
   ```
3. Contact the administrator for assistance before re-attempting the migration

## Troubleshooting

### Helper pod stuck in Pending state
Check PVC availability and cluster events:
```bash
kubectl -n jellyfin describe pvc <CONFIG_PVC>
kubectl -n jellyfin describe pod jf-seed
```

### Ownership mismatch after extraction
Ensure the `chown` command completed successfully. Re-run:
```bash
kubectl -n jellyfin exec jf-seed -- chown -R 1000:1000 /config
```

### Jellyfin pod fails to start
Check the pod logs for database errors:
```bash
kubectl -n jellyfin logs jellyfin-<pod-id>
```
Verify the config tarball was extracted correctly by re-entering the helper pod before deletion.
