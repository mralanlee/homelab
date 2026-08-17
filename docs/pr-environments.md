# PR Environment System

This document describes the automated PR environment system for repositories in the RedCrayon/mralanlee ecosystem.

## Overview

Pull requests automatically get preview environments deployed to Kubernetes, accessible via deterministic URLs following the pattern:

```
https://<namespace>-<repo>-pr-<number>.glyphix.ai
```

For example:
- `https://mralanlee-lace-pr-1337.glyphix.ai`
- `https://redcrayon-api-pr-42.glyphix.ai`

## Infrastructure

The PR environment infrastructure consists of:

1. **Gateway API**: Cilium Gateway API with a dedicated preview gateway
2. **Cloudflare Tunnel**: `preview-tunnel` chart routes `*.glyphix.ai` traffic
3. **Namespace Isolation**: Each PR environment runs in its own namespace
4. **Automatic TLS**: Cloudflare handles TLS termination at the edge

### Gateway Configuration

The preview gateway is configured in `charts/gateway/templates/preview-gateway.yaml`:

- Listens on HTTP port 80 (TLS terminates at Cloudflare)
- Hostname: `*.glyphix.ai`
- Load Balancer IP: `10.22.6.11`
- Only accepts routes from namespaces labeled `preview: "true"`

### Cloudflare Tunnel

The `preview-tunnel` chart runs cloudflared connectors that route `*.glyphix.ai` traffic to the preview gateway:

- Tunnel ID: `ff3551dd-95a0-48ac-a2c1-3ea48a7519de`
- Replica count: 2 (for zero-downtime rollouts)
- Routes all `*.glyphix.ai` traffic to `cilium-gateway-preview.gateway.svc.cluster.local:80`

## Deploying a PR Environment

### 1. Create Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mralanlee-lace-pr-1337
  labels:
    preview: "true"  # Required for gateway access
```

### 2. Deploy Your Application

Standard Kubernetes resources (Deployment, Service, etc.) in the PR namespace.

### 3. Create HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: pr-1337
  namespace: mralanlee-lace-pr-1337
spec:
  parentRefs:
    - name: preview
      namespace: gateway
  hostnames:
    - mralanlee-lace-pr-1337.glyphix.ai
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: your-service
          port: 80
```

## GitHub Integration

### Automatic PR Comments

Use the reusable workflow to automatically comment on PRs with the environment URL.

Reference workflows are provided in `docs/workflows/`:
- `pr-environment-comment.yml`: Reusable workflow for commenting on PRs
- `example-pr-environment.yml`: Example showing how to use the reusable workflow

#### In Your Repository

Copy `docs/workflows/pr-environment-comment.yml` to your repository's `.github/workflows/` directory, then create `.github/workflows/pr-environment.yml`:

```yaml
name: PR Environment

on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy to Kubernetes
        run: |
          # Your deployment logic here
          kubectl apply -f k8s/

  notify:
    needs: deploy
    uses: ./.github/workflows/pr-environment-comment.yml
    with:
      namespace: mralanlee  # Your GitHub username/org
      repo: lace            # Your repository name
    permissions:
      pull-requests: write
```

The workflow will:
1. Calculate the deterministic URL based on PR number
2. Post a comment on the PR with the environment link
3. Update the same comment on subsequent pushes (no spam)

### Workflow Features

- **Idempotent**: Only posts one comment per PR, updates it on subsequent runs
- **Deterministic URLs**: No need to wait for deployment status
- **Automatic**: Triggers on PR open, sync, or reopen

## Example: preview-smoke

The `charts/preview-smoke` chart demonstrates a minimal PR environment:

- Namespace: `preview-smoke`
- Hostname: `smoke-preview.glyphix.ai`
- Simple nginx deployment for testing

View the chart for a complete working example.

## Cleanup

PR environments should be cleaned up when the PR is closed or merged. Add a workflow:

```yaml
on:
  pull_request:
    types: [closed]

jobs:
  cleanup:
    runs-on: ubuntu-latest
    steps:
      - name: Delete namespace
        run: |
          kubectl delete namespace ${{ github.event.repository.owner.login }}-${{ github.event.repository.name }}-pr-${{ github.event.pull_request.number }}
```

## Architecture Notes

See `charts/preview-tunnel/values.yaml` for implementation details. Key decisions:

- **Separate tunnel**: Preview traffic uses its own Cloudflare tunnel (not the lace tunnel)
- **Separate zone**: `glyphix.ai` keeps `*.shimmerlabs.xyz` free of apex wildcards
- **HTTP only**: TLS terminates at Cloudflare edge, not in-cluster
- **Namespace labels**: Gateway access controlled via namespace label selectors

## Troubleshooting

### Environment not accessible

1. Check namespace has `preview: "true"` label
2. Verify HTTPRoute references correct gateway (`preview` in `gateway` namespace)
3. Check cloudflared tunnel is running: `kubectl -n preview-tunnel get pods`
4. Verify DNS: `dig mralanlee-lace-pr-1337.glyphix.ai` should return Cloudflare IPs

### Comment not posted

1. Ensure workflow has `pull-requests: write` permission
2. Check GitHub Actions logs for API errors
3. Verify `actions/github-script@v7` is available

## See Also

- `LEARNINGS.md`: DNS search domain issues with apex wildcards
- `charts/gateway/`: Gateway API configuration
- `charts/preview-tunnel/`: Cloudflare tunnel setup
- `charts/preview-smoke/`: Minimal example implementation
