# Round 2 — CNP + Reloader + Platform Alerts

Three PRs on `iaac-talos-flux-platform` `op-dev`. Independent; can land in any order.

| PR | Title | Files | INFRA |
|---|---|---|---|
| B1 | stakater/reloader HelmRelease | `infrastructure/reloader/{namespace,helmrepository,release}.yaml` + `clusters/bm-dev/flux-system/infra.yaml` (Kustomization entry) | INFRA-1502 (cert rotation auto-restart enabler) |
| B2 | CiliumNetworkPolicy allow-list (corp VPN 10.11.0.0/19) | `infrastructure/istio-ingress/cnp-allow-corp-vpn.yaml` + `infrastructure/network-policies/cnp-risingwave-2-default-deny.yaml` (new dir) | INFRA-1496 Phase 3 |
| B3 | PrometheusRule manifests for platform health | `infrastructure/prometheus-rules/{namespace,*.yaml}` | INFRA-1503 |

## CIDR allow-list (B2)

Decided 2026-06-01:

| Source | Reason |
|---|---|
| 10.11.0.0/19 | Corp VPN (Cisco AnyConnect pool) — confirmed from `ipconfig.exe` on Doke's laptop |
| 10.10.82.0/24 | Cluster worker node CIDR — so node→node + intra-cluster control plane traffic isn't accidentally blocked |
| 10.244.0.0/16 | Cluster pod CIDR — internal mesh + health probes |
| 10.96.0.0/12 | Cluster Service CIDR — kube-proxy / Cilium service routes |

## Alerts in B3

Single source of truth for platform health. Routes by severity into existing Alertmanager.

| Rule | Severity | Triggers |
|---|---|---|
| CertificateExpiringSoon | warning | cert-manager Certificate < 7d to expiry |
| CertificateRenewalFailed | critical | cert-manager Certificate Ready=False > 30m |
| FluxKustomizationFailed | warning | flux Kustomization Ready=False > 10m |
| FluxHelmReleaseFailed | critical | flux HelmRelease Ready=False > 10m |
| ExternalDNSErrors | warning | external-dns errors_total increasing |
| GatewayMissing | critical | known Gateway resource gone |
| PodCrashLoopBackOffPlatformNS | critical | pod CrashLoopBackOff > 5m in {istio-ingress, risingwave-2, cert-manager, external-dns, flux-system, reloader} |
| GhostunnelDown | critical | ghostunnel pod count < 2 for > 5m |
| TCPListener4567Missing | critical | no listener bound on hostport 4567 across workers > 5m |

The `monitoring-stack` PrometheusRule selector grabs anything labelled `release: prometheus-stack`. We label our rules accordingly.

## Sequence

B1 first (enables reloader annotations that landed in Round 1 PR #8 to actually do something). Then B3 (alerts on platform state). Then B2 (network policy — DOES carry slight risk so land last + verify carefully).

## Risk on B2

CNP wrong → corp VPN clients lose access to the gateway. Mitigation:
1. Start in `audit` mode (CNP `policyTypes` only logs, doesn't drop)
2. After 24h of logs prove no false positives, flip to enforcement
3. Have a `kubectl delete cnp ...` runbook ready
