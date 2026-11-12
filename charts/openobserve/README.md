# openobserve

Wraps `openobserve-standalone` (openobserve chart 1.1.5, image v1.1.2), single-node
local-disk mode — no MinIO, no HA dependencies.

- 50Gi PVC on `truenas-iscsi` (`allowVolumeExpansion: true` — bump `size` to grow)
- 30-day retention for all streams (`ZO_COMPACT_DATA_RETENTION_DAYS`)
- Root credentials pulled from 1Password by external-secrets (item `openobserve-root`
  → Secret `openobserve-root`), never stored in git
- HTTPRoute on `openobserve.k8s.shimmerlabs.xyz` via the shared `homelab` gateway
- ServiceMonitor labeled `release: kube-prometheus-stack` so Prometheus scrapes OO's metrics

## Auth: no SSO

OpenObserve OSS v1.x has no OIDC path — the old Dex integration (`ZO_DEX_*`) was
removed and native OIDC is enterprise-only. Login is the root user stored in the
1Password item `openobserve-root` (vault `shimmer-labs`). Create it once:

```sh
op item create --vault shimmer-labs --category login --title openobserve-root \
  --generate-password='letters,digits,symbols,32' username=openobserve@shimmerlabs.xyz
```

OpenObserve refuses to start unless the password has a lowercase letter, an uppercase
letter, a digit and a special character.

## Ingesting telemetry (OTLP)

The service speaks OTLP in-cluster; applications need no collector in between
(pod logs are tailed by `charts/otel-collector`):

- HTTP: `http://openobserve.openobserve:5080/api/default/v1/traces` (and `/v1/logs`, `/v1/metrics`)
- gRPC: `openobserve.openobserve:5081`

Auth is basic auth as the ingest user `ingest@shimmerlabs.xyz` (1Password item
`openobserve-ingest`), not root. The user was created by hand through
`POST /api/default/users` with role `admin`: the open-source build rejects every
lower role ("Custom roles not allowed").

## Deploy

Synced by ArgoCD (app-of-apps, namespace `openobserve`, wave 10). Push to `main` deploys.
