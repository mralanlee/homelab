# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kubernetes homelab cluster managed with Helm charts. GitOps-ready infrastructure hosted on Proxmox, using ArgoCD for continuous deployment. All services live under the `k8s.shimmerlabs.xyz` domain.

## Repository Structure

All infrastructure is defined as Helm charts under `charts/`. Each chart wraps a public upstream dependency with local `values.yaml` overrides and optional custom templates in `templates/`.

## Common Commands

```bash
# Update chart dependencies
helm dependency update charts/<chart-name>

# Template a chart locally (dry-run)
helm template <release-name> charts/<chart-name> -n <namespace>

# Install/upgrade a chart
helm upgrade --install <release-name> charts/<chart-name> -n <namespace> --create-namespace

# Diff before applying
helm diff upgrade <release-name> charts/<chart-name> -n <namespace>
```

No Makefile, Taskfile, or CI/CD pipelines exist. Deploys are manual via `helm` or through ArgoCD sync.

## Architecture

### Networking Stack
- **CNI**: Cilium (eBPF-based, Gateway API enabled, Hubble UI for observability)
- **Load Balancer**: MetalLB in L2 mode, IP pool `10.22.6.10-10.22.6.254`
- **Ingress**: Traefik (default ingress class, LoadBalancer at `10.22.6.10`)

### Storage
- **democratic-csi** provisions iSCSI volumes from TrueNAS
- Default StorageClass: `truenas-iscsi`

### TLS & Certificates
- cert-manager with Let's Encrypt (staging + prod ClusterIssuers)
- DNS-01 challenge via Cloudflare API token (stored in 1Password)

### Authentication
- **Authentik** as OIDC provider, backed by CloudNative PostgreSQL (`cn-pg` operator)
- ArgoCD integrates via Dex OIDC connector

### Secrets Management
- **external-secrets** with 1Password backend (vault: `shimmer-labs`)
- ClusterSecretStore: `onepassword-sdk`
- DB passwords auto-generated via `external-secrets.io` Password resources
- ExternalSecret resources pull credentials into Kubernetes secrets

### Monitoring
- kube-prometheus-stack (Prometheus 15d retention/50Gi, AlertManager 10Gi)
- Standalone Grafana chart (Grafana disabled in kube-prometheus-stack)
- ServiceMonitor discovery label: `release: kube-prometheus-stack`

### Workflow Automation
- n8n with Redis cache and PostgreSQL backend, worker autoscaling enabled

## Key Patterns

- Each chart has `Chart.yaml` (with dependency), `Chart.lock`, `values.yaml`, and optionally `templates/` for custom resources (ClusterIssuers, IPPools, ExternalSecrets, PostgreSQL clusters, etc.)
- Downloaded chart tarballs (`charts/*.tgz`) are gitignored — run `helm dependency update` after cloning
- Proxmox infrastructure managed via MCP server (`proxmox-mcp-plus` configured in `.mcp.json`)

## GitHub

Remote: `https://github.com/mralanlee/homelab.git`
