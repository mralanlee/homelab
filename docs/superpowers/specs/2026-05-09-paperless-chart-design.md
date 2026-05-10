# Paperless-ngx + Paperless-gpt Helm Chart Design

**Date:** 2026-05-09
**Status:** Draft — pending review
**Author:** alanleunglee@gmail.com (with Claude)

## Goal

Deploy paperless-ngx and paperless-gpt into the homelab cluster via a single
Helm chart `charts/paperless/`, following established patterns: cn-pg
PostgreSQL, ESO/1Password secrets, Gateway API HTTPRoute, Authentik OIDC.

## Scope

In scope:
- New chart `charts/paperless/` wrapping the gabe565 paperless-ngx chart.
- Hand-rolled templates for paperless-gpt, Valkey broker, cn-pg cluster, ESO
  resources, HTTPRoutes, and an Authentik blueprint ConfigMap.
- Authentik chart values update to mount the blueprint ConfigMap.
- Documentation in chart `README.md` describing the bootstrap order.

Out of scope:
- Backups, monitoring dashboards, alerts (separate work).
- ArgoCD `Application` manifests — manual `helm upgrade --install` first; ArgoCD
  wiring later.
- High availability for Valkey or paperless-ngx.

## Architecture

```
                     Gateway (Cilium)
                          │
              ┌───────────┴───────────┐
              ▼                       ▼
     paperless.k8s....         paperless-gpt.k8s....   (optional)
              │                       │
              ▼                       ▼
     Service paperless-ngx     Service paperless-gpt
              │                       │
              ▼                       ▼
   ┌────────────────────┐    ┌──────────────────┐
   │  paperless-ngx pod │    │ paperless-gpt    │
   │  (Django + celery) │    │ (Go service)     │
   └────────┬─────────┬─┘    └─────────┬────────┘
            │         │                │
            ▼         ▼                ▼
      cn-pg         Valkey       paperless-ngx API
   paperless-pg-rw  6379         (in-cluster)
            │         │                │
            ▼         ▼                ▼
       PVC 5Gi     emptyDir       OpenAI / Ollama
                                  (egress)

   PVC 50Gi (truenas-iscsi) mounted on ngx with subPaths:
     - /usr/src/paperless/data       (data)
     - /usr/src/paperless/media      (media)
     - /usr/src/paperless/consume    (consume)
     - /usr/src/paperless/export     (export)

   OIDC: paperless-ngx → Authentik (provider/application reconciled from
   blueprint ConfigMap mounted into authentik server pod).
```

## File Layout

```
charts/paperless/
├── Chart.yaml
├── Chart.lock
├── values.yaml
├── README.md
└── templates/
    ├── pg.yaml                          # cn-pg Cluster
    ├── db-password-generator.yaml       # ESO Password (auto-generated)
    ├── db-password-external-secret.yaml # ESO ExternalSecret -> ngx envFrom
    ├── superuser-external-secret.yaml   # 1Password -> superuser bootstrap
    ├── oidc-external-secret.yaml        # 1Password -> OIDC client_secret
    ├── oidc-providers-configmap.yaml    # PAPERLESS_SOCIALACCOUNT_PROVIDERS
    ├── valkey-deployment.yaml
    ├── valkey-service.yaml
    ├── gpt-external-secret.yaml         # 1Password -> OpenAI key + ngx token
    ├── gpt-deployment.yaml
    ├── gpt-service.yaml
    ├── httproute.yaml                   # ngx + optional gpt
    └── authentik-blueprint.yaml         # ConfigMap in `authentik` ns
```

`Chart.yaml` declares one dependency:

```yaml
dependencies:
  - name: paperless-ngx
    version: 0.24.1
    repository: https://charts.gabe565.com
```

## Components

### 1. PostgreSQL (cn-pg)

`Cluster` resource named `paperless-pg`:
- 1 instance, storage 5Gi `truenas-iscsi`.
- Bootstrap initdb: database `paperless`, owner `paperless`.
- Owner password sourced from ExternalSecret `paperless-db-password-secret`.
- Service `paperless-pg-rw` consumed by ngx via `PAPERLESS_DBHOST`.

### 2. Secrets (ESO + 1Password)

| Resource | Source | Consumer |
|---|---|---|
| `paperless-db-password` | `external-secrets.io` `Password` (auto-gen 32 chars) | cn-pg Cluster (initdb), ngx envFrom |
| `paperless-superuser` | 1Password item `paperless-superuser` (`username`, `password`, `email`) | ngx envFrom (`PAPERLESS_ADMIN_*`) |
| `paperless-oidc` | 1Password item `paperless-oidc` (`client_id`, `client_secret`) | ngx envFrom + Authentik blueprint |
| `paperless-gpt` | 1Password item `paperless-gpt` (`openai_api_key`, `paperless_api_token`, optional `ollama_url`) | gpt envFrom |

ClusterSecretStore `onepassword-sdk` already in cluster; vault `shimmer-labs`.

### 3. Valkey

Plain Deployment (no subchart):
- image `valkey/valkey:8-alpine`
- 1 replica, emptyDir on `/data`
- args: `--save ""` (broker queue, no persistence needed)
- resources: 50m/64Mi requests, 200m/256Mi limits
- Service `valkey:6379` ClusterIP

ngx env: `PAPERLESS_REDIS=redis://valkey:6379`. Drop-in replacement for Redis;
celery and ngx are protocol-only consumers.

### 4. paperless-ngx (gabe565 chart)

Override values.yaml:
- `image.tag` aligned to chart appVersion (currently 2.14.7).
- `persistence.data` single PVC 50Gi `truenas-iscsi`, ReadWriteOnce. Other
  persistence keys (`media`, `consume`, `export`) point at the same PVC with
  distinct `subPath` values.
- `envFrom` references the four secrets above plus the OIDC providers
  ConfigMap.
- `env`:
  - `PAPERLESS_REDIS=redis://valkey:6379`
  - `PAPERLESS_DBHOST=paperless-pg-rw`
  - `PAPERLESS_DBNAME=paperless`
  - `PAPERLESS_DBUSER=paperless`
  - `PAPERLESS_URL=https://paperless.k8s.shimmerlabs.xyz`
  - `PAPERLESS_APPS=allauth.socialaccount.providers.openid_connect`
  - `PAPERLESS_SOCIALACCOUNT_PROVIDERS` from ConfigMap (see §5)
  - `PAPERLESS_DISABLE_REGULAR_LOGIN=false` (admin can still log in via local)
- `resources`: 200m/512Mi requests, 2/2Gi limits.
- `service.type=ClusterIP`, port 8000.

### 5. OIDC providers via ESO template

`PAPERLESS_SOCIALACCOUNT_PROVIDERS` must be a single JSON env var containing
the OIDC client_id and client_secret. Helm cannot read 1Password secrets at
render time, so use ESO's templating feature: the ExternalSecret pulls
`client_id` and `client_secret` from the 1Password item `paperless-oidc` and
emits a Kubernetes Secret with one key `PAPERLESS_SOCIALACCOUNT_PROVIDERS`
holding the fully rendered JSON.

ExternalSecret template (sketch):

```yaml
spec:
  target:
    name: paperless-oidc
    template:
      data:
        PAPERLESS_SOCIALACCOUNT_PROVIDERS: |
          {"openid_connect":{"APPS":[{"provider_id":"authentik","name":"Authentik","client_id":"{{ .client_id }}","secret":"{{ .client_secret }}","settings":{"server_url":"https://authentik.k8s.shimmerlabs.xyz/application/o/paperless/.well-known/openid-configuration"}}],"OAUTH_PKCE_ENABLED":true}}
        OIDC_CLIENT_ID: "{{ .client_id }}"
        OIDC_CLIENT_SECRET: "{{ .client_secret }}"
  data:
    - secretKey: client_id
      remoteRef: { key: paperless-oidc, property: client_id }
    - secretKey: client_secret
      remoteRef: { key: paperless-oidc, property: client_secret }
```

ngx pod consumes the rendered Secret via `envFrom.secretRef`. Single source
of truth = 1Password.

### 6. paperless-gpt

Deployment:
- image: `icereed/paperless-gpt:v0.16.0` (pin a tag; bump deliberately).
- 1 replica, no PVC, ephemeral.
- envFrom secret `paperless-gpt`:
  - `LLM_PROVIDER=openai`
  - `LLM_MODEL=gpt-4o-mini` (configurable in values)
  - `OPENAI_API_KEY` (always present)
  - `OLLAMA_HOST` (only when `gpt.provider=ollama`)
  - `PAPERLESS_BASE_URL=http://paperless-ngx:8000`
  - `PAPERLESS_API_TOKEN`
- Service ClusterIP 8080.
- Optional HTTPRoute on `paperless-gpt.k8s.shimmerlabs.xyz` toggled by
  `gpt.ingress.enabled`.
- Resources: 100m/128Mi requests, 1/1Gi limits.

### 7. HTTPRoute

Single template covering ngx + optional gpt route. Parents reference the
shared `gateway` Gateway in the `gateway` namespace (existing pattern). TLS
terminated at Gateway via cert-manager + Cloudflare DNS-01.

### 8. Authentik Blueprint

Rendered as a `ConfigMap` in the `authentik` namespace (cross-namespace, owned
by the paperless release), labeled `goauthentik.io/blueprint: "true"`. One
data key `paperless.yaml` containing entries:
  - `authentik_providers_oauth2.scopemapping` references for `openid`, `email`,
    `profile`, `offline_access` (or `!Find` existing default scope mappings).
  - `authentik_providers_oauth2.oauth2provider` named `paperless`:
    - `client_type: confidential`
    - `client_id: !Env PAPERLESS_OIDC_CLIENT_ID`
    - `client_secret: !Env PAPERLESS_OIDC_CLIENT_SECRET`
    - `redirect_uris: https://paperless.k8s.shimmerlabs.xyz/accounts/oidc/authentik/login/callback/`
    - `signing_key: !Find [authentik_crypto.certificatekeypair, [name, "authentik Self-signed Certificate"]]`
  - `authentik_core.application` slug `paperless` referencing the provider via
    `!KeyOf`.

The authentik server + worker pods must (a) mount the ConfigMap, and (b)
have `PAPERLESS_OIDC_CLIENT_ID` and `PAPERLESS_OIDC_CLIENT_SECRET` available as
env so the blueprint's `!Env` tags resolve.

The paperless chart creates an ExternalSecret in the `authentik` namespace,
`paperless-oidc-for-authentik`, pulling the same 1Password item that ngx
uses, and emitting a Secret with keys `PAPERLESS_OIDC_CLIENT_ID` and
`PAPERLESS_OIDC_CLIENT_SECRET`.

Update `charts/authentik/values.yaml`:

```yaml
authentik:
  server:
    envFrom:
      - secretRef:
          name: paperless-oidc-for-authentik
    volumes:
      - name: paperless-blueprint
        configMap:
          name: paperless-blueprint
          optional: true
    volumeMounts:
      - name: paperless-blueprint
        mountPath: /blueprints/paperless
        readOnly: true
  worker:
    envFrom:
      - secretRef:
          name: paperless-oidc-for-authentik
    volumes:
      - name: paperless-blueprint
        configMap:
          name: paperless-blueprint
          optional: true
    volumeMounts:
      - name: paperless-blueprint
        mountPath: /blueprints/paperless
        readOnly: true
```

`optional: true` lets authentik start cleanly when the paperless release has
not been applied yet. The authentik worker reconciles blueprints in the mount
path automatically.

## Bootstrap Order

1. Create 1Password items in vault `shimmer-labs`:
   - `paperless-superuser` (`username`, `password`, `email`)
   - `paperless-oidc` (`client_id`, `client_secret` — generate manually, e.g.
     `openssl rand -hex 32` for both)
   - `paperless-gpt` (`openai_api_key`, optional `ollama_url`,
     `paperless_api_token` left empty for now)
2. `helm dependency update charts/paperless`.
3. `helm upgrade --install authentik charts/authentik -n authentik` to mount
   the blueprint volume (the ConfigMap will be missing on first run; volume
   mount tolerates absence with `optional: true` set on the volume).
4. `helm upgrade --install paperless charts/paperless -n paperless --create-namespace`
   to create cn-pg, secrets, ngx, gpt, Valkey, blueprint ConfigMap.
5. authentik worker reconciles blueprint → OAuth2 provider + application
   exist with the ESO-supplied `client_secret`.
6. Browse `https://paperless.k8s.shimmerlabs.xyz`, log in via local admin
   superuser. Open admin → tokens → create API token for the user the gpt
   service should impersonate.
7. Update 1Password `paperless-gpt.paperless_api_token`. ESO syncs; restart
   gpt Deployment (`kubectl rollout restart deploy paperless-gpt -n paperless`).
8. Test SSO login as a non-admin Authentik user.

## Values Surface (proposed)

```yaml
paperless-ngx:
  image:
    tag: "2.14.7"
  persistence:
    data:
      enabled: true
      storageClass: truenas-iscsi
      size: 50Gi
    media:
      enabled: false  # use data PVC subPath
    # ... etc
  env: { ... }
  envFrom: [ ... ]
  ingress:
    enabled: false  # we use Gateway API HTTPRoute

postgres:
  storageSize: 5Gi

valkey:
  image: valkey/valkey:8-alpine
  resources: { ... }

oidc:
  enabled: true
  authentikUrl: https://authentik.k8s.shimmerlabs.xyz
  providerSlug: paperless
  applicationSlug: paperless

gpt:
  enabled: true
  image:
    repository: icereed/paperless-gpt
    tag: v0.16.0
  provider: openai           # openai | ollama
  model: gpt-4o-mini
  ingress:
    enabled: false
    hostname: paperless-gpt.k8s.shimmerlabs.xyz

ingress:
  hostname: paperless.k8s.shimmerlabs.xyz
  gatewayName: gateway
  gatewayNamespace: gateway

externalSecrets:
  store: onepassword-sdk
  vault: shimmer-labs
```

## Risks and Caveats

- **gabe565 chart persistence shape.** Need to confirm the chart exposes the
  `data`/`media`/`consume`/`export` keys with `existingClaim` + `subPath`
  knobs. If not, fall back to four PVCs or override the chart's volume
  rendering via inline patches in `values.yaml`. Verify during implementation.
- **OIDC env JSON.** Resolved by ESO templating (§5): the ExternalSecret
  renders the full JSON with substituted secrets into a Secret key the ngx
  pod consumes via `envFrom`. No initContainer needed.
- **Authentik blueprint secret material.** Resolved by the `!Env` tag pattern
  (§8): blueprint references `PAPERLESS_OIDC_CLIENT_ID` and
  `PAPERLESS_OIDC_CLIENT_SECRET` env vars, sourced from a Secret rendered by a
  cross-namespace ExternalSecret. Result: 1Password is the single source of
  truth; no secret material in git or in plain ConfigMaps.
- **Cross-namespace resource ownership.** Helm permits a release in `paperless`
  to create resources in `authentik` if the manifests carry explicit
  `metadata.namespace`. ArgoCD AppProject permissions must allow it (revisit
  when wiring ArgoCD).
- **paperless-gpt API token.** Bootstrapped manually post-install (step 6
  above). Acceptable for homelab; document clearly in README.
- **`PAPERLESS_URL` change.** Once the OIDC redirect URI is registered with
  Authentik, the hostname is sticky. Changing the public hostname requires a
  blueprint update and a paperless restart.

## Testing

- `helm template paperless charts/paperless -n paperless` renders cleanly with
  no missing required values.
- `helm template authentik charts/authentik -n authentik` after the blueprint
  mount addition renders cleanly.
- Smoke tests post-install:
  - `kubectl -n paperless get cluster paperless-pg -o yaml` shows healthy
    primary.
  - `kubectl -n paperless logs deploy/paperless-ngx-server` shows celery worker
    connected to Valkey, DB migrations applied.
  - Browser login via local admin works.
  - Authentik admin shows the `paperless` provider + application reconciled.
  - SSO login round-trips successfully.
  - Drop a PDF into `consume` (via web UI upload), confirm consumption.
  - paperless-gpt logs show successful auth against ngx and at least one
    OpenAI request when a doc is uploaded with the gpt-relevant tag.

## Open Questions / Deferred

- Backup of the PVC and Postgres (out of scope; will follow project-wide
  backup decisions).
- Monitoring (ServiceMonitors): defer until kube-prometheus-stack discovery
  pattern is needed.
- ArgoCD `Application`: defer until manual install verified.
- HA for Valkey or paperless-ngx: not needed for homelab.
