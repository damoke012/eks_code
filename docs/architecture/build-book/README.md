# On-prem build book

How the US Xpress on-prem Talos environments are created, repo by repo, in the order the
work happens. Written so someone who has not built one could.

Three environments, each its own AWS account and vSphere footprint:

| Env | Cluster | API endpoint | AWS account |
|---|---|---|---|
| dev | `op-usxpress-dev` | `10.10.82.50` | `700736442855` |
| QA | `op-usxpress-qa` | `10.10.82.51` | `527101283767` |
| prod | `op-usxpress-prod` | `10.10.82.52` | `937464026810` |

## Sections

| # | Repo | Owns | Status |
|---|---|---|---|
| 01 | [`iaac-talos`](01-iaac-talos.md) | vSphere VMs, Talos bootstrap, Cilium, Flux bootstrap, IRSA | drafted, `deploy.ps1` pending |
| 02 | [`iaac-talos-flux-cluster`](02-iaac-talos-flux-cluster.md) | the Flux `GitRepository` + `Kustomization` wiring | drafted |
| 03 | `iaac-talos-flux-platform` | the platform stack, branch per cluster | not started |
| 04 | `iaac-octopus-config` | Octopus variables — supplies every `TF_VAR_*` | not started |
| 05 | `iaac-octopus-onprem` | release mirror, enrollment, fork-side dispatchers | not started |
| 06 | `iaac-networking` | | not started |
| 07 | `iaac-risingwave-onprem` | RisingWave operator, CR and console | not started |
| 08 | `risingwave-pipeline` | the ETL, branch per environment | not started |
| 09 | `iaac-argocd-onprem` | app delivery | not started |
| 10 | `ix-kafka-topics-users`, `iaac-confluent-cloud`, `ix-schema-registry` | app onboarding | not started |
| 11 | observability — `iaac-grafana-config`, `ix-blackbox-monitoring`, `iaac-monitoring` | | not started |
| 12 | `actions-octopus`, `actions-setup`, `actions-collection` | the shared GHA actions everything above calls | not started |

All repos are at `https://github.com/variant-inc/<name>` on corporate GitHub — reachable from
the WSL box, never from a codespace ([[usx-github-enterprise-not-personal]]).

## How to read a section

Each one answers the same questions in the same order: what triggers it, what is in it, what
the important code actually does, **what we changed from the default and why**, and **what is
not automated**. The last of those is the one to read before building anything.

## The standing claim this book is testing

"Everything is automated." Section 01 already lists nine things that are not. The way to settle
it is to build a throwaway cluster from these documents alone and record every step that was
not in them.
