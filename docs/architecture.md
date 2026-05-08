# Homelab Architecture

End-to-end architecture for the homelab Kubernetes cluster running on Proxmox.

## High-Level Topology

```mermaid
graph TB
    Internet[fa:fa-globe Internet]
    Mac[fa:fa-laptop Mac<br/>nix flake + direnv]

    subgraph Cloudflare
        CFDNS[Cloudflare DNS]
        CFTunnel[Cloudflare Tunnel<br/>future]
    end

    subgraph Home["Home Network 10.22.0.0/16"]
        OPN[OPNsense<br/>Router/Firewall]
        UNB[Unbound DNS<br/>OPNsense]

        subgraph Proxmox["Proxmox Hosts"]
            singed[singed]
            pve1[pve1]
            pve2[pve2]
            powder[powder]
        end
    end

    subgraph K8s["Kubernetes Cluster"]
        CP[k8s-cp-1<br/>LXC<br/>10.22.6.100]
        W1[k8s-w-1<br/>VM<br/>10.22.6.101]
        W2[k8s-w-2<br/>VM<br/>10.22.6.102]
        W3[k8s-w-3<br/>VM<br/>10.22.6.103]
        W4[k8s-w-4<br/>VM<br/>10.22.6.104]
    end

    Mac -->|kubectl, helm, ansible| CP
    Internet -->|argocd.shimmerlabs.app<br/>future| CFDNS
    CFDNS -.->|future tunnel| CFTunnel
    CFTunnel -.-> K8s

    Mac -->|*.k8s.shimmerlabs.xyz| CFDNS
    CFDNS -->|10.22.6.10| OPN
    OPN -->|LAN routing| K8s

    UNB -->|forward k8s.shimmerlabs.xyz| BIND[bind9<br/>10.22.6.53<br/>authoritative]
    EDNS[external-dns<br/>RFC2136 / TSIG] -.->|writes records| BIND
    EDNS -.->|watches| K8s

    singed -->|hosts| CP
    singed -->|hosts| W1
    pve1 -->|hosts| W2
    pve2 -->|hosts| W3
    powder -->|hosts| W4
```

## Provisioning Pipeline

```mermaid
graph LR
    Repo[GitHub<br/>homelab repo]
    Bash[infra/scripts/<br/>create-lxc.sh<br/>create-vm.sh]
    Ansible[infra/ansible/<br/>playbooks]
    Helm[charts/<br/>helm wrappers]
    ArgoCD[ArgoCD<br/>app-of-apps]

    Repo -->|"curl bash on Proxmox host"| Bash
    Repo -->|"ansible-playbook from Mac"| Ansible
    Repo -->|"helm install"| Helm

    Bash -->|qm/pct + cloud-init| Nodes[VMs/LXCs]
    Ansible -->|kubeadm, containerd, sysctl| Nodes
    Helm -->|"4 manual installs"| Bootstrap[Cilium → Gateway →<br/>cert-manager → ArgoCD]
    Bootstrap -->|installs| ArgoCD
    ArgoCD -->|syncs all charts/| Workloads
```

## Network & Ingress

```mermaid
graph TB
    Client[Client<br/>browser/curl]

    subgraph DNS
        CFDNS[Cloudflare<br/>*.k8s.shimmerlabs.xyz<br/>→ 10.22.6.10]
        Unbound[OPNsense Unbound<br/>forward k8s.shimmerlabs.xyz]
        BIND[bind9<br/>10.22.6.53<br/>authoritative]
        EDNS[external-dns<br/>RFC2136 / TSIG]
    end

    Client -->|public DNS| CFDNS
    Client -->|home network| Unbound
    Unbound -->|forward zone| BIND
    EDNS -->|writes records via TSIG| BIND
    EDNS -.->|watches HTTPRoute / Gateway / Service| Cluster

    subgraph Cluster
        Gateway[Cilium Gateway<br/>10.22.6.10<br/>port 443 TLS]
        Envoy[cilium-envoy DaemonSet<br/>per-node L7 proxy]

        HTTPRoutes
        subgraph HTTPRoutes
            R1[argocd HTTPRoute]
            R2[authentik HTTPRoute]
            R3[grafana HTTPRoute]
            R4[hubble-ui HTTPRoute]
            R5[prometheus HTTPRoute]
            R6[alertmanager HTTPRoute]
        end

        subgraph Backends
            B1[argocd-server svc]
            B2[authentik-server svc]
            B3[grafana svc]
            B4[hubble-ui svc]
            B5[prometheus svc]
            B6[alertmanager svc]
        end
    end

    CFDNS -->|10.22.6.10| Gateway
    Gateway --> Envoy
    Envoy --> R1 --> B1
    Envoy --> R2 --> B2
    Envoy --> R3 --> B3
    Envoy --> R4 --> B4
    Envoy --> R5 --> B5
    Envoy --> R6 --> B6

    style Gateway fill:#88c,color:#fff
    style Envoy fill:#88c,color:#fff
```

## LoadBalancer IP Assignment (Cilium L2)

```mermaid
sequenceDiagram
    participant SVC as Service<br/>type=LoadBalancer
    participant Pool as CiliumLoadBalancerIPPool
    participant Op as Cilium Operator
    participant Agent as Cilium Agent<br/>per node
    participant Net as LAN
    participant Client

    SVC->>Pool: allocate IP from pool
    Pool->>Op: assigns IP (e.g. 10.22.6.10)
    Op->>SVC: status.loadBalancer.ingress = 10.22.6.10
    Op->>Agent: announce IP via L2 leader election
    Note over Agent: One agent per IP wins lease
    Agent->>Net: ARP reply for 10.22.6.10 = node MAC
    Client->>Net: who has 10.22.6.10?
    Net->>Client: at node MAC
    Client->>Agent: traffic to 10.22.6.10
    Agent->>SVC: eBPF datapath delivers
```

## Auth Flow (ArgoCD via Authentik OIDC)

```mermaid
sequenceDiagram
    participant U as User Browser
    participant A as ArgoCD
    participant D as Dex
    participant Auth as Authentik
    participant ESO as External Secrets

    Note over ESO,Auth: OIDC client creds synced from 1Password to Dex secret
    U->>A: login
    A->>U: redirect /api/dex/auth
    U->>D: auth request
    D->>U: redirect to Authentik
    U->>Auth: auth + consent
    Auth->>U: authorization code
    U->>D: callback with code
    D->>Auth: exchange code (internal via Cilium hairpin)
    Auth->>D: ID token + groups claim
    D->>U: ArgoCD JWT
    U->>A: API calls with JWT
    A->>A: RBAC: ArgoCD Admins → role:admin
```

## Secret Flow (1Password → Pods)

```mermaid
graph LR
    OP[1Password<br/>Vault: shimmer-labs]
    Token[op-service-account-token<br/>Secret in external-secrets ns]
    CSS[ClusterSecretStore<br/>onepassword-sdk]
    ES[ExternalSecret<br/>per chart]
    K8s[K8s Secret]
    Pod

    Token -->|auth| CSS
    CSS -->|provider| ES
    OP -->|fetch via SDK| ES
    ES -->|sync| K8s
    K8s -->|mount/env| Pod

    style OP fill:#0078d4,color:#fff
```

## ArgoCD Sync Wave Order

```mermaid
graph TB
    W30["Wave -30<br/>Gateway API CRDs<br/>experimental channel"]
    W20["Wave -20<br/>prometheus-operator-crds"]
    W10["Wave -10<br/>kube-prometheus-stack<br/>cn-pg"]
    W0["Wave 0<br/>Cilium, gateway, bind9, external-dns,<br/>cert-manager, external-secrets,<br/>democratic-csi, metrics-server, grafana"]
    W10p["Wave +10<br/>authentik (depends on cn-pg)"]

    W30 --> W20 --> W10 --> W0 --> W10p
```

## Repo Layout

```
homelab/
├── flake.nix                          # nix dev shell
├── infra/
│   ├── scripts/
│   │   ├── create-lxc.sh              # control plane LXC
│   │   ├── create-vm.sh               # worker VMs
│   │   └── prep-proxmox-host.sh       # host sysctl/modules
│   └── ansible/
│       ├── inventory/                 # 1 CP + 4 workers
│       ├── roles/{common,kubeadm,control-plane,worker}/
│       └── playbooks/
└── charts/
    ├── argocd/                        # ArgoCD + Dex OIDC
    ├── argocd-apps/                   # app-of-apps generator
    ├── authentik/                     # OIDC IdP
    ├── cert-manager/                  # TLS via LE DNS-01 Cloudflare
    ├── cilium/                        # CNI + Gateway API + L2 announce
    ├── cn-pg/                         # CloudNative-PG operator
    ├── democratic-csi/                # iSCSI to TrueNAS
    ├── external-secrets/              # 1Password sync
    ├── gateway/                       # Cilium Gateway resource + cert
    ├── gateway-api-crds/              # experimental channel CRDs
    ├── grafana/
    ├── bind9/                         # authoritative DNS for k8s.shimmerlabs.xyz
    ├── external-dns/                  # writes records to bind9 via RFC2136 TSIG
    ├── kube-prometheus-stack/         # Prom + Alertmanager
    ├── metrics-server/
    └── prometheus-operator-crds/      # out-of-band CRDs
```

## Bootstrap Order

```mermaid
graph TB
    A[Proxmox host prep<br/>prep-proxmox-host.sh]
    B[Create LXC<br/>create-lxc.sh on singed]
    C[Create VMs<br/>create-vm.sh on each host]
    D[bootstrap-control-plane.yml]
    E[bootstrap-worker.yml]
    F[helm install cilium]
    G[helm install gateway-api-crds]
    H[helm install gateway]
    I[helm install cert-manager]
    J[helm install external-secrets + ClusterSecretStore]
    K[helm install argocd]
    L[helm install argocd-apps]
    M[ArgoCD syncs everything]

    A --> B
    A --> C
    B --> D
    C --> E
    D --> F
    E --> F
    F --> G --> H --> I --> J --> K --> L --> M
```

## Key Design Decisions

| Decision | Why |
|---|---|
| LXC for control plane | Lighter than VM, existing pattern in homelab |
| VMs for workers | Better isolation, kubeadm doesn't fight kernel module limits |
| Cilium kube-proxy replacement | eBPF perf, single L4/L7 stack |
| Cilium Gateway API (not Ingress) | Modern K8s standard, drops Traefik dependency |
| Cilium L2 (not MetalLB) | Single tool, no EndpointSlice label hack |
| Gateway API experimental CRDs | Cilium needs v1alpha2 served (TLSRoute) |
| bind9 + external-dns (RFC2136 TSIG) | Same tool family for internal + future public DNS; standard pattern |
| 1Password ESO + service account token | Secrets stay in 1Password, K8s pulls on-demand |
| ServerSideApply for kube-prometheus-stack | CRDs exceed 262144 byte annotation limit |
| Out-of-band prometheus-operator-crds | Same annotation limit problem; install separately |
| ArgoCD sync waves | Order CRD-providing apps before consumers |
| ignoreDifferences for cn-pg | Operator mutates CR; ArgoCD would loop reconciles |

## Future Work

- **Public ingress** — second Gateway with separate IP, OPNsense DNAT, Cloudflare Tunnel or port-forward
- **external-dns + Cloudflare** — auto-create public DNS records from HTTPRoute hostnames
- **Authentik IaC** — blueprints for groups/providers/applications instead of UI clicks
- **Re-enable ServiceMonitors** — for charts disabled during bootstrap (cert-manager, grafana, argocd, traefik gone)
- **Backup strategy** — Velero for cluster state, cn-pg backups to S3-compatible
