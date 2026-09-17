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
| 03 | [`iaac-talos-flux-platform`](03-iaac-talos-flux-platform.md) | the platform stack, branch per cluster | drafted |
| 04 | [`iaac-octopus-config`](04-iaac-octopus-config.md) | spaces, environments, worker pools, lifecycles — **not** project variables | drafted |
| 05 | [`iaac-octopus-server` + `iaac-octopus` + `iaac-octopus-onprem`](05-octopus-platform.md) | Octopus itself: the server StatefulSet, the three worker tentacle pods, the release mirror | drafted |
| 06 | `iaac-networking` | | not started |
| 07 | [`iaac-risingwave-onprem`](07-iaac-risingwave-onprem.md) | RisingWave operator, CR, console — **the repo with no gate before prod** | drafted |
| 08 | `risingwave-pipeline` | the ETL, branch per environment | not started |
| 09 | `iaac-argocd-onprem` | app delivery | not started |
| 10 | `ix-kafka-topics-users`, `iaac-confluent-cloud`, `ix-schema-registry` | app onboarding | not started |
| 11 | observability — `iaac-grafana-config`, `ix-blackbox-monitoring`, `iaac-monitoring` | | not started |
| 12 | `actions-octopus`, `actions-setup`, `actions-collection` | the shared GHA actions everything above calls | not started |

All repos are at `https://github.com/variant-inc/<name>` on corporate GitHub — reachable from
the WSL box, never from a codespace ([[usx-github-enterprise-not-personal]]).

**Where the build actually runs.** Nothing on-prem builds itself. The Talos clusters are created by
three Octopus worker pods running in **AWS EKS in the `dpl` account** (`786352483360`), which reach
out to on-prem vSphere. The Octopus server those workers talk to is itself delivered by Flux from
`iaac-flux-manifests`. Section 05 has the chain.

## How to read a section

Each one answers the same questions in the same order: what triggers it, what is in it, what
the important code actually does, **what we changed from the default and why**, and **what is
not automated**. The last of those is the one to read before building anything.

## The standing claim this book is testing

"Everything is automated." Section 01 already lists nine things that are not, and section 04 adds
the largest one: **no repo manages the Octopus project variables that build a cluster.** Every
`TF_VAR_*` is typed into a web form, which is where `TBD-qa-vip`, the wrong Flux repository name
and dev's 2 vCPU all came from. `octopus/new-environment.sh` and `TF_USE_VARFILE=true` are the
route out — they move those decisions into `envs/<env>.tfvars`, under review, in git.

The way to settle the claim is to build a throwaway cluster from these documents alone and record
every step that was not in them.
