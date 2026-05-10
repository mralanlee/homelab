# Paperless Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `charts/paperless/` deploying paperless-ngx + paperless-gpt + Valkey + cn-pg Postgres + Authentik OIDC blueprint, all wired through ESO/1Password and Gateway API HTTPRoute.

**Architecture:** Combined Helm chart wraps `paperless-ngx 0.24.1` (gabe565). Custom templates add Valkey broker, cn-pg cluster, paperless-gpt deployment, ESO secrets, OIDC provider config (rendered server-side by ESO templating), and a cross-namespace ConfigMap mounted into the existing Authentik release for declarative SSO bootstrap.

**Tech Stack:** Helm 3, paperless-ngx v2.20.15, paperless-gpt v0.25.1, Valkey 8, cnpg-operator v18, external-secrets.io v1, 1Password ClusterSecretStore `onepassword-sdk`, Cilium Gateway API, Authentik blueprints.

**Spec:** `docs/superpowers/specs/2026-05-09-paperless-chart-design.md`

**Note on TDD:** This work produces declarative YAML templates rather than executable code. The closest analogue to tests is `helm dependency update`, `helm lint`, `helm template`, and `kubectl apply --dry-run=server`. Each task verifies via these commands plus `grep` assertions on rendered output. Final acceptance is in-cluster smoke testing.

---

## Pre-work (manual, one-time, before Task 1)

- [ ] **Create 1Password items** in vault `shimmer-labs`:
  - `paperless-superuser`: fields `username`, `password`, `email`
  - `paperless-oidc`: fields `client_id` (32-hex), `client_secret` (32-hex). Generate locally:
    ```bash
    echo "client_id: $(openssl rand -hex 32)"
    echo "client_secret: $(openssl rand -hex 32)"
    ```
  - `paperless-gpt`: fields `openai_api_key`, `paperless_api_token` (leave empty for now; populated post-bootstrap)

---

## File Layout

**Create:**
- `charts/paperless/Chart.yaml`
- `charts/paperless/values.yaml`
- `charts/paperless/README.md`
- `charts/paperless/templates/_helpers.tpl`
- `charts/paperless/templates/pg.yaml`
- `charts/paperless/templates/db-password-generator.yaml`
- `charts/paperless/templates/db-password-external-secret.yaml`
- `charts/paperless/templates/superuser-external-secret.yaml`
- `charts/paperless/templates/oidc-external-secret.yaml`
- `charts/paperless/templates/oidc-for-authentik-external-secret.yaml`
- `charts/paperless/templates/authentik-blueprint.yaml`
- `charts/paperless/templates/valkey-deployment.yaml`
- `charts/paperless/templates/valkey-service.yaml`
- `charts/paperless/templates/gpt-external-secret.yaml`
- `charts/paperless/templates/gpt-deployment.yaml`
- `charts/paperless/templates/gpt-service.yaml`
- `charts/paperless/templates/httproute.yaml`

**Modify:**
- `charts/authentik/values.yaml` — add envFrom + volume/volumeMount on `server` and `worker`

---

### Task 1: Scaffold chart skeleton + dependency

**Files:**
- Create: `charts/paperless/Chart.yaml`
- Create: `charts/paperless/values.yaml` (placeholder)
- Create: `charts/paperless/templates/_helpers.tpl`
- Create: `charts/paperless/.helmignore`
- Modify: root `.gitignore` (verify `charts/*.tgz` already covered)

- [ ] **Step 1: Verify directory does not exist yet**

```bash
test ! -d charts/paperless && echo OK
```
Expected: `OK`

- [ ] **Step 2: Create `charts/paperless/Chart.yaml`**

```yaml
apiVersion: v2
name: paperless
description: paperless-ngx + paperless-gpt for the homelab
type: application
version: 0.1.0
appVersion: "2.20.15"
dependencies:
  - name: paperless-ngx
    version: 0.24.1
    repository: https://charts.gabe565.com
```

- [ ] **Step 3: Create `charts/paperless/.helmignore` (default content)**

```
# Patterns to ignore when building packages.
.DS_Store
.git/
.gitignore
.bzr/
.bzrignore
.hg/
.hgignore
.svn/
*.swp
*.bak
*.tmp
*.orig
*~
.project
.idea/
*.tmproj
.vscode/
```

- [ ] **Step 4: Create placeholder `charts/paperless/values.yaml`**

```yaml
# Full values surface populated in later tasks.
# Sub-chart key disabled here so `helm template` works at this stage.
paperless-ngx:
  enabled: false
```

- [ ] **Step 5: Create `charts/paperless/templates/_helpers.tpl`**

```text
{{/* Common labels */}}
{{- define "paperless.labels" -}}
app.kubernetes.io/name: paperless
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Selector labels for a given component */}}
{{- define "paperless.selectorLabels" -}}
app.kubernetes.io/name: paperless
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}
```

- [ ] **Step 6: Run dependency update**

```bash
helm dependency update charts/paperless
```
Expected: downloads `paperless-ngx-0.24.1.tgz` into `charts/paperless/charts/`, creates `Chart.lock`.

- [ ] **Step 7: Lint + render to verify**

```bash
helm lint charts/paperless
helm template paperless charts/paperless -n paperless
```
Expected: lint passes; render produces empty output (only `# Source:` comments) since no templates yet and sub-chart disabled.

- [ ] **Step 8: Commit**

```bash
git add charts/paperless/Chart.yaml charts/paperless/Chart.lock \
        charts/paperless/values.yaml charts/paperless/.helmignore \
        charts/paperless/templates/_helpers.tpl
git commit -m "feat(paperless): scaffold chart with paperless-ngx 0.24.1 dependency"
```

---

### Task 2: cn-pg Postgres cluster

**Files:**
- Create: `charts/paperless/templates/pg.yaml`

- [ ] **Step 1: Render before adding template, expect empty output**

```bash
helm template paperless charts/paperless -n paperless | grep -c "kind: Cluster" || echo 0
```
Expected: `0`

- [ ] **Step 2: Create `charts/paperless/templates/pg.yaml`**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {{ .Release.Name }}-pg
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
spec:
  description: "PostgreSQL Cluster for {{ .Release.Name }}"
  imageName: ghcr.io/cloudnative-pg/postgresql:18
  instances: 1
  storage:
    size: {{ .Values.postgres.storageSize | default "5Gi" }}
    storageClass: {{ .Values.postgres.storageClass | default "truenas-iscsi" }}
  postgresql:
    parameters:
      shared_buffers: 256MB
      max_connections: "100"
  managed:
    roles:
      - name: paperless
        inherit: true
        connectionLimit: -1
        ensure: present
        superuser: false
        login: true
        passwordSecret:
          name: {{ .Release.Name }}-db-auth
          key: password
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: {{ .Release.Name }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
spec:
  name: {{ .Release.Name }}
  owner: paperless
  cluster:
    name: {{ .Release.Name }}-pg
```

- [ ] **Step 3: Add postgres section to `charts/paperless/values.yaml`**

Replace the file contents with:

```yaml
paperless-ngx:
  enabled: false

postgres:
  storageSize: 5Gi
  storageClass: truenas-iscsi
```

- [ ] **Step 4: Render and assert**

```bash
helm template paperless charts/paperless -n paperless | tee /tmp/paperless-render.yaml | grep -E "kind: Cluster|kind: Database" | wc -l
```
Expected: `2`

- [ ] **Step 5: Verify Cluster name and storage**

```bash
grep -A2 "name: paperless-pg$" /tmp/paperless-render.yaml | head
grep "size: 5Gi" /tmp/paperless-render.yaml
```
Expected: cluster name found; `size: 5Gi` present.

- [ ] **Step 6: Commit**

```bash
git add charts/paperless/templates/pg.yaml charts/paperless/values.yaml
git commit -m "feat(paperless): add cn-pg Cluster + Database for paperless"
```

---

### Task 3: ESO password generator + db-password ExternalSecret

**Files:**
- Create: `charts/paperless/templates/db-password-generator.yaml`
- Create: `charts/paperless/templates/db-password-external-secret.yaml`

- [ ] **Step 1: Create `charts/paperless/templates/db-password-generator.yaml`**

```yaml
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: {{ .Release.Name }}-db-password
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
spec:
  length: 32
  symbols: 0
```

- [ ] **Step 2: Create `charts/paperless/templates/db-password-external-secret.yaml`**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .Release.Name }}-db-auth
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
spec:
  refreshPolicy: CreatedOnce
  target:
    name: {{ .Release.Name }}-db-auth
    creationPolicy: Owner
    template:
      data:
        username: paperless
        password: "{{ `{{ .password }}` }}"
        # ngx envFrom convenience keys
        PAPERLESS_DBUSER: paperless
        PAPERLESS_DBPASS: "{{ `{{ .password }}` }}"
  dataFrom:
    - sourceRef:
        generatorRef:
          kind: Password
          apiVersion: generators.external-secrets.io/v1alpha1
          name: {{ .Release.Name }}-db-password
```

- [ ] **Step 3: Render and assert**

```bash
helm template paperless charts/paperless -n paperless > /tmp/paperless-render.yaml
grep -E "kind: Password|kind: ExternalSecret" /tmp/paperless-render.yaml | wc -l
```
Expected: `2`

- [ ] **Step 4: Verify generator name referenced from ExternalSecret**

```bash
grep -A2 "generatorRef" /tmp/paperless-render.yaml | grep "name: paperless-db-password"
```
Expected: matches the generator name.

- [ ] **Step 5: Commit**

```bash
git add charts/paperless/templates/db-password-generator.yaml \
        charts/paperless/templates/db-password-external-secret.yaml
git commit -m "feat(paperless): generate db password via ESO and emit envFrom keys"
```

---

### Task 4: Superuser ExternalSecret (1Password)

**Files:**
- Create: `charts/paperless/templates/superuser-external-secret.yaml`

- [ ] **Step 1: Create `charts/paperless/templates/superuser-external-secret.yaml`**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .Release.Name }}-superuser
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: {{ .Values.externalSecrets.store | default "onepassword-sdk" }}
  target:
    name: {{ .Release.Name }}-superuser
    creationPolicy: Owner
    template:
      data:
        # ngx envFrom keys
        PAPERLESS_ADMIN_USER: "{{ `{{ .username }}` }}"
        PAPERLESS_ADMIN_PASSWORD: "{{ `{{ .password }}` }}"
        PAPERLESS_ADMIN_MAIL: "{{ `{{ .email }}` }}"
  data:
    - secretKey: username
      remoteRef:
        key: paperless-superuser/username
    - secretKey: password
      remoteRef:
        key: paperless-superuser/password
    - secretKey: email
      remoteRef:
        key: paperless-superuser/email
```

- [ ] **Step 2: Add `externalSecrets` block to `values.yaml`**

Append to `charts/paperless/values.yaml`:

```yaml
externalSecrets:
  store: onepassword-sdk
```

- [ ] **Step 3: Render + assert**

```bash
helm template paperless charts/paperless -n paperless | grep -c "name: paperless-superuser$"
```
Expected: at least `1`.

- [ ] **Step 4: Commit**

```bash
git add charts/paperless/templates/superuser-external-secret.yaml \
        charts/paperless/values.yaml
git commit -m "feat(paperless): pull superuser bootstrap creds from 1Password"
```

---

### Task 5: OIDC ExternalSecret with templated providers JSON

**Files:**
- Create: `charts/paperless/templates/oidc-external-secret.yaml`

This Secret carries three keys: `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` (consumed by gpt and any debug tooling), and `PAPERLESS_SOCIALACCOUNT_PROVIDERS` (the full JSON consumed directly by the ngx allauth/socialaccount layer via envFrom).

- [ ] **Step 1: Create `charts/paperless/templates/oidc-external-secret.yaml`**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .Release.Name }}-oidc
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: {{ .Values.externalSecrets.store | default "onepassword-sdk" }}
  target:
    name: {{ .Release.Name }}-oidc
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        OIDC_CLIENT_ID: "{{ `{{ .client_id }}` }}"
        OIDC_CLIENT_SECRET: "{{ `{{ .client_secret }}` }}"
        PAPERLESS_SOCIALACCOUNT_PROVIDERS: |
          {"openid_connect":{"APPS":[{"provider_id":"authentik","name":"Authentik","client_id":"{{ `{{ .client_id }}` }}","secret":"{{ `{{ .client_secret }}` }}","settings":{"server_url":"{{ .Values.oidc.authentikUrl }}/application/o/{{ .Values.oidc.applicationSlug }}/.well-known/openid-configuration"}}],"OAUTH_PKCE_ENABLED":true}}
  data:
    - secretKey: client_id
      remoteRef:
        key: paperless-oidc/client_id
    - secretKey: client_secret
      remoteRef:
        key: paperless-oidc/client_secret
```

- [ ] **Step 2: Add `oidc` block to `values.yaml`**

Append:

```yaml
oidc:
  enabled: true
  authentikUrl: https://authentik.k8s.shimmerlabs.xyz
  providerSlug: paperless
  applicationSlug: paperless
```

- [ ] **Step 3: Render + assert JSON shape**

```bash
helm template paperless charts/paperless -n paperless > /tmp/paperless-render.yaml
grep "PAPERLESS_SOCIALACCOUNT_PROVIDERS" /tmp/paperless-render.yaml
grep "openid-configuration" /tmp/paperless-render.yaml
```
Expected: both grep hits succeed; URL contains `authentik.k8s.shimmerlabs.xyz/application/o/paperless/`.

- [ ] **Step 4: Commit**

```bash
git add charts/paperless/templates/oidc-external-secret.yaml \
        charts/paperless/values.yaml
git commit -m "feat(paperless): render OIDC providers JSON via ESO template"
```

---

### Task 6: Cross-namespace OIDC ExternalSecret for Authentik

The Authentik blueprint in Task 7 uses `!Env` tags that resolve from environment variables on the authentik server + worker pods. Create the Secret backing those env vars in the `authentik` namespace.

**Files:**
- Create: `charts/paperless/templates/oidc-for-authentik-external-secret.yaml`

- [ ] **Step 1: Create `charts/paperless/templates/oidc-for-authentik-external-secret.yaml`**

```yaml
{{- if .Values.oidc.enabled }}
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: paperless-oidc-for-authentik
  namespace: {{ .Values.oidc.authentikNamespace | default "authentik" }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: {{ .Values.externalSecrets.store | default "onepassword-sdk" }}
  target:
    name: paperless-oidc-for-authentik
    creationPolicy: Owner
    template:
      data:
        # Consumed by the Authentik blueprint via !Env tags
        PAPERLESS_OIDC_CLIENT_ID: "{{ `{{ .client_id }}` }}"
        PAPERLESS_OIDC_CLIENT_SECRET: "{{ `{{ .client_secret }}` }}"
  data:
    - secretKey: client_id
      remoteRef:
        key: paperless-oidc/client_id
    - secretKey: client_secret
      remoteRef:
        key: paperless-oidc/client_secret
{{- end }}
```

- [ ] **Step 2: Add `authentikNamespace` to `values.yaml` under `oidc:`**

Replace the `oidc` block in `values.yaml`:

```yaml
oidc:
  enabled: true
  authentikUrl: https://authentik.k8s.shimmerlabs.xyz
  authentikNamespace: authentik
  providerSlug: paperless
  applicationSlug: paperless
```

- [ ] **Step 3: Render + assert namespace**

```bash
helm template paperless charts/paperless -n paperless > /tmp/paperless-render.yaml
awk '/name: paperless-oidc-for-authentik/{found=1} found{print; if(/^---$/){exit}}' /tmp/paperless-render.yaml | grep "namespace: authentik"
```
Expected: `namespace: authentik` present.

- [ ] **Step 4: Commit**

```bash
git add charts/paperless/templates/oidc-for-authentik-external-secret.yaml \
        charts/paperless/values.yaml
git commit -m "feat(paperless): publish OIDC creds into authentik ns for blueprint env"
```

---

### Task 7: Authentik blueprint ConfigMap (cross-namespace)

**Files:**
- Create: `charts/paperless/templates/authentik-blueprint.yaml`

- [ ] **Step 1: Create `charts/paperless/templates/authentik-blueprint.yaml`**

```yaml
{{- if .Values.oidc.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: paperless-blueprint
  namespace: {{ .Values.oidc.authentikNamespace | default "authentik" }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
    goauthentik.io/blueprint: "true"
data:
  paperless.yaml: |
    version: 1
    metadata:
      name: paperless
      labels:
        blueprints.goauthentik.io/instantiate: "true"
    entries:
      - model: authentik_providers_oauth2.scopemapping
        identifiers:
          managed: goauthentik.io/providers/oauth2/scope-openid
        id: scope-openid
      - model: authentik_providers_oauth2.scopemapping
        identifiers:
          managed: goauthentik.io/providers/oauth2/scope-email
        id: scope-email
      - model: authentik_providers_oauth2.scopemapping
        identifiers:
          managed: goauthentik.io/providers/oauth2/scope-profile
        id: scope-profile
      - model: authentik_providers_oauth2.oauth2provider
        identifiers:
          name: {{ .Values.oidc.providerSlug }}
        id: provider
        attrs:
          name: {{ .Values.oidc.providerSlug }}
          client_type: confidential
          client_id: !Env PAPERLESS_OIDC_CLIENT_ID
          client_secret: !Env PAPERLESS_OIDC_CLIENT_SECRET
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          property_mappings:
            - !KeyOf scope-openid
            - !KeyOf scope-email
            - !KeyOf scope-profile
          redirect_uris:
            - matching_mode: strict
              url: https://{{ .Values.ingress.hostname }}/accounts/oidc/authentik/login/callback/
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, "authentik Self-signed Certificate"]]
      - model: authentik_core.application
        identifiers:
          slug: {{ .Values.oidc.applicationSlug }}
        attrs:
          name: Paperless
          slug: {{ .Values.oidc.applicationSlug }}
          provider: !KeyOf provider
          meta_launch_url: https://{{ .Values.ingress.hostname }}
{{- end }}
```

- [ ] **Step 2: Add `ingress.hostname` to `values.yaml`**

Append:

```yaml
ingress:
  hostname: paperless.k8s.shimmerlabs.xyz
  gatewayName: homelab
  gatewayNamespace: gateway
  gatewaySectionName: https
```

- [ ] **Step 3: Render + assert**

```bash
helm template paperless charts/paperless -n paperless > /tmp/paperless-render.yaml
grep "name: paperless-blueprint" /tmp/paperless-render.yaml
grep "goauthentik.io/blueprint" /tmp/paperless-render.yaml
grep "!Env PAPERLESS_OIDC_CLIENT_ID" /tmp/paperless-render.yaml
grep "redirect_uris" /tmp/paperless-render.yaml
```
Expected: all four hits succeed.

- [ ] **Step 4: Commit**

```bash
git add charts/paperless/templates/authentik-blueprint.yaml \
        charts/paperless/values.yaml
git commit -m "feat(paperless): declarative Authentik OIDC provider via blueprint"
```

---

### Task 8: Valkey Deployment + Service

**Files:**
- Create: `charts/paperless/templates/valkey-deployment.yaml`
- Create: `charts/paperless/templates/valkey-service.yaml`

- [ ] **Step 1: Create `charts/paperless/templates/valkey-deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-valkey
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
    app.kubernetes.io/component: valkey
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: paperless
      app.kubernetes.io/instance: {{ .Release.Name }}
      app.kubernetes.io/component: valkey
  template:
    metadata:
      labels:
        app.kubernetes.io/name: paperless
        app.kubernetes.io/instance: {{ .Release.Name }}
        app.kubernetes.io/component: valkey
    spec:
      containers:
        - name: valkey
          image: {{ .Values.valkey.image | default "valkey/valkey:8-alpine" }}
          args:
            - --save
            - ""
            - --appendonly
            - "no"
          ports:
            - name: redis
              containerPort: 6379
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: {}
```

- [ ] **Step 2: Create `charts/paperless/templates/valkey-service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-valkey
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
    app.kubernetes.io/component: valkey
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: paperless
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: valkey
  ports:
    - name: redis
      port: 6379
      targetPort: redis
```

- [ ] **Step 3: Add `valkey` block to `values.yaml`**

Append:

```yaml
valkey:
  image: valkey/valkey:8-alpine
```

- [ ] **Step 4: Render + assert**

```bash
helm template paperless charts/paperless -n paperless > /tmp/paperless-render.yaml
grep -E "kind: (Deployment|Service)" /tmp/paperless-render.yaml | grep -c valkey || true
grep "valkey/valkey:8-alpine" /tmp/paperless-render.yaml
```
Expected: at least one `valkey` Deployment + Service line; image string present.

- [ ] **Step 5: Commit**

```bash
git add charts/paperless/templates/valkey-deployment.yaml \
        charts/paperless/templates/valkey-service.yaml \
        charts/paperless/values.yaml
git commit -m "feat(paperless): Valkey broker for celery (drop-in Redis replacement)"
```

---

### Task 9: paperless-gpt ExternalSecret + Deployment + Service

**Files:**
- Create: `charts/paperless/templates/gpt-external-secret.yaml`
- Create: `charts/paperless/templates/gpt-deployment.yaml`
- Create: `charts/paperless/templates/gpt-service.yaml`

- [ ] **Step 1: Create `charts/paperless/templates/gpt-external-secret.yaml`**

```yaml
{{- if .Values.gpt.enabled }}
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .Release.Name }}-gpt
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: {{ .Values.externalSecrets.store | default "onepassword-sdk" }}
  target:
    name: {{ .Release.Name }}-gpt
    creationPolicy: Owner
    template:
      data:
        OPENAI_API_KEY: "{{ `{{ .openai_api_key }}` }}"
        PAPERLESS_API_TOKEN: "{{ `{{ .paperless_api_token }}` }}"
  data:
    - secretKey: openai_api_key
      remoteRef:
        key: paperless-gpt/openai_api_key
    - secretKey: paperless_api_token
      remoteRef:
        key: paperless-gpt/paperless_api_token
{{- end }}
```

- [ ] **Step 2: Create `charts/paperless/templates/gpt-deployment.yaml`**

```yaml
{{- if .Values.gpt.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-gpt
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
    app.kubernetes.io/component: gpt
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: paperless
      app.kubernetes.io/instance: {{ .Release.Name }}
      app.kubernetes.io/component: gpt
  template:
    metadata:
      labels:
        app.kubernetes.io/name: paperless
        app.kubernetes.io/instance: {{ .Release.Name }}
        app.kubernetes.io/component: gpt
    spec:
      containers:
        - name: paperless-gpt
          image: "{{ .Values.gpt.image.repository }}:{{ .Values.gpt.image.tag }}"
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: PAPERLESS_BASE_URL
              value: "http://{{ .Release.Name }}-paperless-ngx:8000"
            - name: LLM_PROVIDER
              value: {{ .Values.gpt.provider | quote }}
            - name: LLM_MODEL
              value: {{ .Values.gpt.model | quote }}
            {{- if eq .Values.gpt.provider "ollama" }}
            - name: OLLAMA_HOST
              value: {{ .Values.gpt.ollamaHost | quote }}
            {{- end }}
          envFrom:
            - secretRef:
                name: {{ .Release.Name }}-gpt
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 1Gi
{{- end }}
```

- [ ] **Step 3: Create `charts/paperless/templates/gpt-service.yaml`**

```yaml
{{- if .Values.gpt.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-gpt
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
    app.kubernetes.io/component: gpt
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: paperless
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: gpt
  ports:
    - name: http
      port: 8080
      targetPort: http
{{- end }}
```

- [ ] **Step 4: Add `gpt` block to `values.yaml`**

Append:

```yaml
gpt:
  enabled: true
  image:
    repository: icereed/paperless-gpt
    tag: v0.25.1
  provider: openai
  model: gpt-4o-mini
  ollamaHost: ""
  ingress:
    enabled: false
    hostname: paperless-gpt.k8s.shimmerlabs.xyz
```

- [ ] **Step 5: Render + assert**

```bash
helm template paperless charts/paperless -n paperless > /tmp/paperless-render.yaml
grep "icereed/paperless-gpt:v0.25.1" /tmp/paperless-render.yaml
grep "PAPERLESS_BASE_URL" /tmp/paperless-render.yaml
```
Expected: both hits.

- [ ] **Step 6: Commit**

```bash
git add charts/paperless/templates/gpt-external-secret.yaml \
        charts/paperless/templates/gpt-deployment.yaml \
        charts/paperless/templates/gpt-service.yaml \
        charts/paperless/values.yaml
git commit -m "feat(paperless): add paperless-gpt deployment + secrets"
```

---

### Task 10: HTTPRoute (ngx + optional gpt)

**Files:**
- Create: `charts/paperless/templates/httproute.yaml`

- [ ] **Step 1: Create `charts/paperless/templates/httproute.yaml`**

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .Release.Name }}-ngx
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
spec:
  parentRefs:
    - name: {{ .Values.ingress.gatewayName | default "homelab" }}
      namespace: {{ .Values.ingress.gatewayNamespace | default "gateway" }}
      sectionName: {{ .Values.ingress.gatewaySectionName | default "https" }}
  hostnames:
    - {{ .Values.ingress.hostname }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {{ .Release.Name }}-paperless-ngx
          port: 8000
{{- if and .Values.gpt.enabled .Values.gpt.ingress.enabled }}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .Release.Name }}-gpt
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "paperless.labels" . | nindent 4 }}
spec:
  parentRefs:
    - name: {{ .Values.ingress.gatewayName | default "homelab" }}
      namespace: {{ .Values.ingress.gatewayNamespace | default "gateway" }}
      sectionName: {{ .Values.ingress.gatewaySectionName | default "https" }}
  hostnames:
    - {{ .Values.gpt.ingress.hostname }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {{ .Release.Name }}-gpt
          port: 8080
{{- end }}
```

- [ ] **Step 2: Render + assert ngx route only (gpt ingress disabled by default)**

```bash
helm template paperless charts/paperless -n paperless > /tmp/paperless-render.yaml
grep -c "kind: HTTPRoute" /tmp/paperless-render.yaml
grep "paperless.k8s.shimmerlabs.xyz" /tmp/paperless-render.yaml
```
Expected: count `1`; hostname present.

- [ ] **Step 3: Render with gpt ingress enabled and assert two routes**

```bash
helm template paperless charts/paperless -n paperless --set gpt.ingress.enabled=true > /tmp/paperless-render.yaml
grep -c "kind: HTTPRoute" /tmp/paperless-render.yaml
```
Expected: `2`.

- [ ] **Step 4: Commit**

```bash
git add charts/paperless/templates/httproute.yaml
git commit -m "feat(paperless): HTTPRoute for ngx with optional gpt route"
```

---

### Task 11: Wire paperless-ngx sub-chart values

This is the largest values block. Enable the sub-chart, point it at the cn-pg service, the Valkey service, the single PVC with subPaths, and feed it the four `envFrom` secrets.

**Files:**
- Modify: `charts/paperless/values.yaml`

Verify upstream value keys against the actual sub-chart before editing — read `charts/paperless/charts/paperless-ngx/values.yaml` for the canonical knobs.

- [ ] **Step 1: Inspect sub-chart values**

```bash
sed -n '1,200p' charts/paperless/charts/paperless-ngx/values.yaml
```
Note the keys exposed for: `image.tag`, `env`, `envFrom`, `persistence.*`, `service.*`, `ingress.*`. The chart is built on `bjw-s/common`. The persistence keys are usually `persistence.<name>.{enabled, type, storageClass, size, existingClaim, advancedMounts}`. If the chart only supports a single PVC out of the box without subPath knobs, plan to override via `persistence.<name>.advancedMounts` (bjw-s common) — see `https://bjw-s.github.io/helm-charts/docs/common-library/persistence/`. The exact override is finalized in this step based on what the inspection reveals.

- [ ] **Step 2: Replace `paperless-ngx` block in `values.yaml`**

Replace `paperless-ngx: { enabled: false }` with:

```yaml
paperless-ngx:
  enabled: true

  image:
    repository: ghcr.io/paperless-ngx/paperless-ngx
    tag: "2.20.15"

  # Disable upstream ingress; we use Gateway API HTTPRoute.
  ingress:
    main:
      enabled: false

  service:
    main:
      ports:
        http:
          port: 8000

  env:
    PAPERLESS_URL: https://paperless.k8s.shimmerlabs.xyz
    PAPERLESS_REDIS: redis://paperless-valkey:6379
    PAPERLESS_DBHOST: paperless-pg-rw
    PAPERLESS_DBNAME: paperless
    PAPERLESS_TIME_ZONE: America/Los_Angeles
    PAPERLESS_OCR_LANGUAGE: eng
    PAPERLESS_APPS: allauth.socialaccount.providers.openid_connect
    PAPERLESS_DISABLE_REGULAR_LOGIN: "false"

  envFrom:
    - secretRef:
        name: paperless-db-auth
    - secretRef:
        name: paperless-superuser
    - secretRef:
        name: paperless-oidc

  persistence:
    data:
      enabled: true
      type: persistentVolumeClaim
      storageClass: truenas-iscsi
      accessMode: ReadWriteOnce
      size: 50Gi
      advancedMounts:
        main:
          main:
            - path: /usr/src/paperless/data
              subPath: data
            - path: /usr/src/paperless/media
              subPath: media
            - path: /usr/src/paperless/consume
              subPath: consume
            - path: /usr/src/paperless/export
              subPath: export
    media:
      enabled: false
    consume:
      enabled: false
    export:
      enabled: false

  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: "2"
      memory: 2Gi
```

- [ ] **Step 3: Render and verify the sub-chart picks up overrides**

```bash
helm template paperless charts/paperless -n paperless > /tmp/paperless-render.yaml
grep "ghcr.io/paperless-ngx/paperless-ngx:2.20.15" /tmp/paperless-render.yaml
grep "PAPERLESS_REDIS" /tmp/paperless-render.yaml
grep "paperless-pg-rw" /tmp/paperless-render.yaml
grep "subPath: consume" /tmp/paperless-render.yaml
```
Expected: image tag pinned, env vars + DB host present, subPath mounts present.

- [ ] **Step 4: If the persistence subPath shape does not match upstream**

If grep for `subPath: consume` fails, the chart's persistence schema differs. Two options:
- Update `advancedMounts` to the exact key shape used by the sub-chart's `bjw-s/common` version (the values file is authoritative).
- Fall back to four PVCs by enabling each persistence key and letting the chart create separate volumes; document the deviation in `charts/paperless/README.md`.

Pick the first option unless it costs more than 30 minutes of fiddling.

- [ ] **Step 5: Lint + dry-run against the cluster API server**

```bash
helm lint charts/paperless
helm template paperless charts/paperless -n paperless | kubectl apply --dry-run=server -f -
```
Expected: lint passes; dry-run reports `created (server dry run)` for each resource. CRD-backed resources (Cluster, Database, ExternalSecret, HTTPRoute) should all validate.

- [ ] **Step 6: Commit**

```bash
git add charts/paperless/values.yaml
git commit -m "feat(paperless): wire paperless-ngx sub-chart to pg, valkey, esos"
```

---

### Task 12: Update Authentik chart to mount blueprint

**Files:**
- Modify: `charts/authentik/values.yaml`

- [ ] **Step 1: Read the current authentik values**

```bash
sed -n '1,60p' charts/authentik/values.yaml
```

- [ ] **Step 2: Patch the `server:` and `worker:` blocks**

Modify `charts/authentik/values.yaml`. Existing `volumes`/`volumeMounts` lists already exist on both `server` and `worker`. Append the blueprint volume + mount and add an `envFrom` entry on each.

For `authentik.server`, append to `volumes` and `volumeMounts`, and add `envFrom`:

```yaml
authentik:
  server:
    envFrom:
      - secretRef:
          name: paperless-oidc-for-authentik
          optional: true
    volumes:
      - name: postgres-creds
        secret:
          secretName: authentik-db-auth
      - name: paperless-blueprint
        configMap:
          name: paperless-blueprint
          optional: true
    volumeMounts:
      - name: postgres-creds
        mountPath: /postgres-creds
        readOnly: true
      - name: paperless-blueprint
        mountPath: /blueprints/paperless
        readOnly: true
```

For `authentik.worker`, the same `envFrom` + `volumes` + `volumeMounts` additions:

```yaml
  worker:
    envFrom:
      - secretRef:
          name: paperless-oidc-for-authentik
          optional: true
    volumes:
      - name: postgres-creds
        secret:
          secretName: authentik-db-auth
      - name: paperless-blueprint
        configMap:
          name: paperless-blueprint
          optional: true
    volumeMounts:
      - name: postgres-creds
        mountPath: /postgres-creds
        readOnly: true
      - name: paperless-blueprint
        mountPath: /blueprints/paperless
        readOnly: true
```

- [ ] **Step 3: Lint + render Authentik chart**

```bash
helm lint charts/authentik
helm template authentik charts/authentik -n authentik > /tmp/authentik-render.yaml
grep -c "paperless-blueprint" /tmp/authentik-render.yaml
grep -c "paperless-oidc-for-authentik" /tmp/authentik-render.yaml
```
Expected: each grep reports at least `2` (one for server, one for worker).

- [ ] **Step 4: Commit**

```bash
git add charts/authentik/values.yaml
git commit -m "feat(authentik): mount paperless blueprint and OIDC envFrom"
```

---

### Task 13: README with bootstrap order

**Files:**
- Create: `charts/paperless/README.md`

- [ ] **Step 1: Create `charts/paperless/README.md`**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add charts/paperless/README.md
git commit -m "docs(paperless): bootstrap and verification README"
```

---

### Task 14: Final whole-chart render + lint + dry-run

- [ ] **Step 1: Lint both charts**

```bash
helm lint charts/paperless
helm lint charts/authentik
```
Expected: no errors.

- [ ] **Step 2: Render both charts to a single combined manifest**

```bash
helm template paperless charts/paperless -n paperless > /tmp/paperless-render.yaml
helm template authentik charts/authentik -n authentik > /tmp/authentik-render.yaml
wc -l /tmp/paperless-render.yaml /tmp/authentik-render.yaml
```
Expected: non-zero, no errors.

- [ ] **Step 3: Server-side dry-run of paperless against the live cluster**

```bash
kubectl config current-context  # confirm correct cluster
helm template paperless charts/paperless -n paperless | kubectl apply --dry-run=server -f -
```
Expected: every resource validates. Failures should be tracked back to a specific template in earlier tasks.

- [ ] **Step 4: Inspect the planned diff (if `helm-diff` plugin installed)**

```bash
helm diff upgrade paperless charts/paperless -n paperless --allow-unreleased || true
helm diff upgrade authentik charts/authentik -n authentik || true
```
Expected: clean diff covering only the new/changed resources.

- [ ] **Step 5: No commit needed; this task is verification only**

---

## In-cluster acceptance (after the human runs `helm upgrade --install`)

These steps live outside the plan as runtime smoke tests. They do not produce commits but block "done".

- `kubectl -n paperless get cluster paperless-pg -o jsonpath='{.status.phase}'` → `Cluster in healthy state`.
- `kubectl -n paperless get externalsecret -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[0].reason}{"\n"}{end}'` → all `SecretSynced`.
- `kubectl -n paperless logs deploy/paperless-paperless-ngx -c server` shows no DB/Redis errors and migrations applied.
- Browser hits `https://paperless.k8s.shimmerlabs.xyz`, local login as superuser succeeds.
- `kubectl -n authentik logs deploy/authentik-worker | grep -i "applying blueprint.*paperless"` returns at least one line.
- Authentik admin shows provider `paperless` and application `paperless`.
- SSO round-trip: log out, click "Sign in with Authentik", arrive back logged in.
- After populating `paperless_api_token` and restarting gpt: `kubectl -n paperless logs deploy/paperless-gpt` shows `Successfully connected to Paperless API`.

---

## Self-Review Notes

- All spec sections covered: §1 PG, §2 ESO secrets (db, superuser, OIDC, gpt), §3 Valkey, §4 ngx, §5 OIDC providers JSON via ESO template, §6 paperless-gpt, §7 HTTPRoute, §8 Authentik blueprint + cross-ns ESO, plus authentik chart wiring + bootstrap docs.
- No "TBD"/"add validation"/"similar to" placeholders. Where the gabe565 chart's persistence shape is the only uncertain detail (Task 11 Step 4), the fallback path is fully specified.
- Service DNS name consistency: ngx Service is `<release>-paperless-ngx` (sub-chart pattern), Valkey is `<release>-valkey`, gpt is `<release>-gpt`. References in `PAPERLESS_REDIS` and `PAPERLESS_BASE_URL` use the `<release>-` prefix throughout. Release name in install instructions is `paperless`, so `paperless-paperless-ngx`/`paperless-valkey`/`paperless-gpt` are the actual resolved DNS names.
- Type/key consistency: `PAPERLESS_OIDC_CLIENT_ID` / `PAPERLESS_OIDC_CLIENT_SECRET` used consistently in Task 6 ExternalSecret keys and Task 7 blueprint `!Env` tags. ngx-side uses `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` (different keys, same Secret) since ngx doesn't need the `PAPERLESS_OIDC_*` prefix.
