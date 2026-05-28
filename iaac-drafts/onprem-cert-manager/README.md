# cert-manager on-prem IaC draft (Phase 0 of TCP/SNI ingress)

**Jira:** [INFRA-1493](https://usxpress.atlassian.net/browse/INFRA-1493) (sub-task of [INFRA-1492](https://usxpress.atlassian.net/browse/INFRA-1492))
**Design:** [`docs/designs/tcp-sni-ingress-design.md`](../../docs/designs/tcp-sni-ingress-design.md)
**Runbook:** [`RUNBOOK.md`](./RUNBOOK.md)

## What this directory contains

```
iam/
  cert-manager-role.tf       → append to iaac-talos/.../modules/irsa/main.tf
  cert-manager-output.tf     → append to iaac-talos/.../modules/irsa/outputs.tf
infrastructure/cert-manager/
  namespace.yaml             → iaac-talos-flux-platform op-dev (infrastructure/cert-manager/)
  repository.yaml
  release.yaml
clusterissuers/
  letsencrypt-staging.yaml   → iaac-talos-flux-platform op-dev (infrastructure/cert-manager-issuers/)
  letsencrypt-prod.yaml
wildcard-cert/
  wildcard-op-dev.yaml       → hand-apply via WSL after staging smoke succeeds
cluster-kustomization-snippet.yaml
                             → paste blocks into iaac-talos-flux-cluster master
                               (clusters/bm-dev/flux-system/infra.yaml)
RUNBOOK.md                   → apply order, smoke tests, rollback
```

## Target repos

| Repo | Branch | Files |
|---|---|---|
| `variant-inc/iaac-talos` | `feature/op-usxpress-dev` | `iam/*.tf` (appended to modules/irsa/) |
| `variant-inc/iaac-talos-flux-platform` | `op-dev` | `infrastructure/cert-manager/*.yaml` + `infrastructure/cert-manager-issuers/*.yaml` |
| `variant-inc/iaac-talos-flux-cluster` | `master` | append to `clusters/bm-dev/flux-system/infra.yaml` |

## Design choices

| | |
|---|---|
| **Chart** | jetstack/cert-manager (canonical) |
| **Version** | v1.16.1 (pinned, bump deliberately) |
| **DNS provider** | Route53 via cross-account `iaac-route53-zone` assume-role |
| **Source IAM role name** | `cert-manager-op-usxpress-dev` (MUST match wildcard `cert-manager-*` trust on iaac-route53-zone, verified 2026-05-18) |
| **IRSA federation** | On-prem cluster's CloudFront-fronted OIDC issuer |
| **ServiceAccount** | `cert-manager/cert-manager` (chart default) |
| **CRDs** | Flux-managed via `CreateReplace`; chart-side `crds.enabled: false` to avoid double-management |
| **ClusterIssuers** | LE staging + LE PROD; staging first per [RUNBOOK Step 4] |
| **Wildcard cert** | `*.op-dev.usxpress.io` in `istio-ingress` ns; hand-applied to manage LE rate limits |

## Why not AWS PCA?

Tracked as open question in the design doc. LE PROD is the simpler default; switching to PCA is a per-ClusterIssuer change once Steve weighs in.

## Constraints respected

- **Additive** — does not modify any running workload (per [feedback_protect_rw_onprem_workload]).
- **TfApply discipline** in Octopus for the IAM step.
- **No AI attribution** in commits or PRs.
- **Branch correctness** — `iaac-talos` PR base is `feature/op-usxpress-dev`, NOT master (per [feedback_iaac_talos_branch_base]).

## Verification (post-apply)

See [`RUNBOOK.md`](./RUNBOOK.md) for step-by-step smoke tests. Bottom line:

```bash
kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Expect: True

kubectl -n istio-ingress get certificate wildcard-op-dev -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Expect: True (after staging→prod cutover in Step 5)
```
