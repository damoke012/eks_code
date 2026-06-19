# `platform-app-expose` — cluster-wide service exposure pattern

**Ticket:** [INFRA-1527](https://usxpress.atlassian.net/browse/INFRA-1527)
**Status:** 🟢 Kicked off 2026-06-03. Files staged + ready for WSL2 push. Tim's RW dashboard goes live first (additive, no risk to existing NodePort); SQL HelmRelease lands suspended until ghostunnel sidecar is in place.

**Goal:** generalize the RW-2 ingress + TLS pattern (Phase 1 + Phase 2, closed 2026-06-01) into a reusable Helm chart any namespace can adopt. First consumer: Tim's `risingwave` namespace.

## Read order

1. **[PUSH-PATHS.md](PUSH-PATHS.md)** — exact file-path mapping codespace → target repos + PR sequence
2. [chart/](chart/) — the chart itself, ready to land at `iaac-talos-flux-platform/infrastructure/platform-app-expose/chart/`
3. [risingwave-exposure/](risingwave-exposure/) — Tim's HelmReleases, ready to land at `iaac-talos-flux-platform/infrastructure/risingwave-exposure/`
4. [cluster-kustomization-entry.yaml](cluster-kustomization-entry.yaml) — appendable Kustomization for `iaac-talos-flux-cluster/clusters/bm-dev/flux-system/infra.yaml`

## Why generalize

We solved this problem twice already (RW-2 Phase 1 + Phase 2, both closed 2026-06-01). About to do it a third time for Tim's RW. Without a chart, every future app that wants on-prem DNS + TLS hand-authors VS + Cert + CNP + ghostunnel — doesn't scale to 157 apps.

Productizing it now:
- Tim's `risingwave` ns onboards via the chart (first consumer)
- Future Bento'd cloud workloads use the same chart (per Phase 8 observability checklist, INFRA-1523)
- Cloud back-port path is the same chart shipped to EKS

## What the chart provides

Inputs:

| Input | Required | Default |
|---|---|---|
| `hostname` | yes | — |
| `service.name` + `service.port` | yes | — |
| `protocol` | yes | `http` (also: `tcp-passthrough`, `tls-passthrough`) |
| `tls.backend` | no | `false` (true = expect ghostunnel sidecar upstream) |
| `certificate.create` | no | **`false`** — depth-1 wildcard already covers most hosts |
| `cnp.enabled` + allowlists | no | `false` — opt-in after consumer inventory |
| `externalDNS.target` | no | `rw-ingress.op-dev.usxpress.io` — verify against RW-2 before push |

Outputs:

1. **VirtualService** on either `istio-ingress/shared-http` (HTTP) or `istio-ingress/tcp-passthrough` (TCP/TLS)
2. **(optional) cert-manager Certificate** in `istio-ingress` ns (LE-prod via existing wildcard chain) — off by default
3. **(optional) CiliumNetworkPolicy** in target ns (default-deny ingress, allow-list) — off by default

**Chart does NOT inject the ghostunnel sidecar** — that's a Deployment concern owned by the consumer's chart. Pattern documented + RW-2 reference cited.

## First consumer — Tim's `risingwave` ns

- `rw-dashboard.op-dev.usxpress.io` → `risingwave-dashboard-ext.risingwave:5691` (HTTP) — **live on PR 1 merge**
- `rw-sql.op-dev.usxpress.io` → `risingwave-frontend.risingwave:4567` (TLS-passthrough) — **suspended until sidecar lands**

## What's staged in this dir (ready for push)

```
wip/platform-app-expose/
├── README.md                          # this file
├── PUSH-PATHS.md                      # exact paths + PR sequence + validation commands
├── chart/                             # Chart files, ready to land in iaac-talos-flux-platform
│   ├── Chart.yaml
│   ├── values.yaml                    # Cert opt-in; externalDNS target configurable
│   └── templates/
│       ├── _helpers.tpl
│       ├── virtualservice.yaml        # HTTP or TLS-passthrough VS
│       ├── certificate.yaml           # gated on certificate.create
│       └── cnp.yaml                   # gated on cnp.enabled
├── risingwave-exposure/               # Kustomization wrapper + Tim's HelmReleases
│   ├── kustomization.yaml
│   ├── rw-dashboard-helmrelease.yaml  # HTTP, live on land
│   └── rw-sql-helmrelease.yaml        # TLS-passthrough, suspend: true
└── cluster-kustomization-entry.yaml   # append to iaac-talos-flux-cluster bm-dev/flux-system/infra.yaml
```

## Status checklist

- [x] Pattern proven on RW-2 (Phase 1 + Phase 2 closed)
- [x] Tim's ask captured ([tim_rw_ns_dns_ingress_ask_jun03](../../../home/codespace/.claude/projects/-workspaces-eks-code/memory/tim_rw_ns_dns_ingress_ask_jun03.md))
- [x] Idris green-lit ("its possible") — track separation respected
- [x] Chart drafted (this dir)
- [x] Tim's HelmReleases drafted (dashboard live, SQL suspended)
- [x] Cluster Kustomization entry drafted
- [x] PUSH-PATHS guide written
- [x] INFRA-1527 filed; Steve as watcher
- [ ] WSL2 push PR 1 (chart + Tim's exposure)
- [ ] WSL2 push PR 2 (cluster wiring)
- [ ] Dashboard live + reachable from corp VPN
- [ ] Ghostunnel sidecar on `risingwave-frontend` (Tim/Idris coordination)
- [ ] SQL HelmRelease unsuspended
- [ ] Tim inventories consumers → CNP enabled
- [ ] Tim retires NodePort
- [ ] Migrate RW-2's hand-authored VS to same chart (drift reduction)

## What can wait for Tim's confirmation

These don't block PR 1:

- Exact endpoint set (dashboard only? + postgres meta? + SQL?) — dashboard goes live first regardless; SQL is suspended; other endpoints are 1-line HelmRelease additions.
- DNS names (`rw-dashboard.op-dev.usxpress.io` vs alternates) — easy rename in HelmRelease values.
- Consumer inventory — only blocks CNP enable, which is gated as a future change anyway.

## Refs

- INFRA-1527 (this work)
- INFRA-1499 (parent ingress umbrella Epic)
- INFRA-1494 (Phase 1 — TCP/SNI listeners)
- INFRA-1495 (Phase 2 — backend TLS via ghostunnel)
- INFRA-1523 (Phase 8 observability ride-along — composes with this)
- [`feedback_externaldns_v020_target_required`](../../../home/codespace/.claude/projects/-workspaces-eks-code/memory/feedback_externaldns_v020_target_required.md) — why `externalDNS.target` is required
- [`phase1_tcp_sni_listeners_done_jun01`](../../../home/codespace/.claude/projects/-workspaces-eks-code/memory/phase1_tcp_sni_listeners_done_jun01.md)
- [`phase2_backend_tls_done_jun01`](../../../home/codespace/.claude/projects/-workspaces-eks-code/memory/phase2_backend_tls_done_jun01.md)
- [`tim_rw_ns_dns_ingress_ask_jun03`](../../../home/codespace/.claude/projects/-workspaces-eks-code/memory/tim_rw_ns_dns_ingress_ask_jun03.md)
- [`platform_app_expose_chart_jun03`](../../../home/codespace/.claude/projects/-workspaces-eks-code/memory/platform_app_expose_chart_jun03.md)
