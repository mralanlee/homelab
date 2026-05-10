# paperless

Wraps `paperless-ngx` (gabe565 chart 0.24.1, image override 2.20.15) with:
- cn-pg PostgreSQL `paperless-pg`
- Valkey 8 (Redis-compatible broker)
- paperless-gpt v0.25.1
- Authentik OIDC via blueprint ConfigMap (cross-namespace)
- Single 50Gi PVC on `truenas-iscsi` with subPaths for data/media/consume/export
- HTTPRoute on `paperless.k8s.shimmerlabs.xyz`

## Prerequisites

1Password vault `shimmer-labs` must contain:

| Item | Fields |
|---|---|
| `paperless-superuser` | `username`, `password`, `email` |
| `paperless-oidc` | `client_id`, `client_secret` (32-hex each) |
| `paperless-gpt` | `openai_api_key`, `paperless_api_token` (start empty) |

Generate the OIDC creds locally:
```sh
openssl rand -hex 32  # client_id
openssl rand -hex 32  # client_secret
```

## Bootstrap

```sh
# 1. Update authentik to mount the blueprint volume and OIDC envFrom.
helm dependency update charts/authentik
helm upgrade --install authentik charts/authentik -n authentik

# 2. Install paperless. Creates cn-pg, ESOs, Valkey, ngx, gpt, blueprint CM.
helm dependency update charts/paperless
helm upgrade --install paperless charts/paperless -n paperless --create-namespace

# 3. Wait for ESO + cn-pg to settle.
kubectl -n paperless wait --for=condition=Ready cluster/paperless-pg --timeout=5m
kubectl -n paperless rollout status deploy/paperless-paperless-ngx --timeout=5m

# 4. Visit https://paperless.k8s.shimmerlabs.xyz, log in as the local superuser
#    (creds stored in 1Password item `paperless-superuser`).
#    SSO via Authentik should also work after the worker reconciles
#    `/blueprints/paperless/paperless.yaml`.

# 5. In paperless, generate an API token (Admin → Tokens) for the gpt service.
#    Save it into the 1Password item `paperless-gpt.paperless_api_token`.
#    ESO syncs; restart gpt:
kubectl -n paperless rollout restart deploy/paperless-gpt
```

## Verifying

```sh
kubectl -n paperless get cluster paperless-pg
kubectl -n paperless get externalsecrets
kubectl -n authentik get cm paperless-blueprint
kubectl -n authentik logs deploy/authentik-worker | grep -i blueprint
```

## Why Valkey

Valkey is the open-source Redis fork; it speaks the same RESP protocol, so
`PAPERLESS_REDIS=redis://paperless-valkey:6379` works without changes.
