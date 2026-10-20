# Pricing app on-prem — state as of 2026-10-20

**Engagement:** `pricing-rfp-handler` to on-prem. **Jira:** INFRA-1715 (Idris's Stage 1).
**Owner:** Idris, end to end, no approval gate. **Second app onboarded; first with an intake.**

## Where it stands in one table

| | Status |
|---|---|
| The app is identified | ✅ `knx-synergy/pricing-rfp-handler`, prod image `:0.1.39`, digest `sha256:6732ffb9…` |
| Its configuration is inventoried | ✅ 70 keys — 58 settings, 12 credentials, each with an on-prem destination |
| Its dependencies are mapped | ✅ 9 from the cluster + `geoservices` from Idris = 10 |
| The database path | ⚠️ **one firewall rule**, owner identified, not yet requested |
| Kafka ACLs | ❌ not started; longest pole, another team's approval |
| Namespace / chart / Argo app | ❌ Idris, Stage 1 steps 1-6 |
| App team agreement | ❌ nobody has signed anything |
| KNX reachable from on-prem | ✅ **PROVEN 2026-10-20** — 405 + TLS trusted from a pod on op-qa |

## The documents

| File | What it is | For |
|---|---|---|
| `MEETING-2026-10-20-pricing-app-onboarding.md` | the onboarding call, decisions and traps | us |
| `MEETING-2026-10-20-platform-review.md` | the standup: EKS 1.36, Crossplane, the Lambda pin | us |
| `ANALYSIS-octopus-dx-variable-map-2026-10-20.md` | what Octopus does, where DX fits, the runtime map | us |
| `DEPENDENCY-MATRIX-pricing-rfp-handler-2026-10-20.md` | the 10 dependencies, measured | app team + Idris |
| `RESEARCH-atlas-from-onprem-2026-10-20.md` | the Atlas path, with sources | us |
| `EXPLAINER-mongo-onprem-blocker-2026-10-20.md` | plain language + diagrams | app + network teams |
| `REVIEW-idris-stage1-plan-2026-10-20.md` | cross-check of INFRA-1715 against prod | Idris |
| `MESSAGE-idris-stage1-feedback-2026-10-20.md` | the short version to send | Idris |
| `ONBOARDING-pricing-app-onprem-2026-10-20.md` | the repo map and how onboarding works | Idris |

**Published pages** (private until shared from each page's Share menu):

* **Overview, with diagrams** — https://claude.ai/artifact/1R9Qbe1K5ex9jnZg7u3Hxc
  ("Pricing App On-Prem Move" — opens with the plain-terms summary)
* **Variable inventory, 70 rows** — https://claude.ai/artifact/AzVn5mJEnzaQspnKuE3UPV
* **How on-prem delivery is set up** — https://claude.ai/artifact/KFcUymxTX3W7gw1MYfXoCt
* **How the on-prem platform itself is built** — https://claude.ai/artifact/CduE9WmBzQvsXXRxyjd9rv
  ("On-Prem Platform Reference" — clusters, bootstrap, Flux, DNS, the VPN to AWS, secrets,
  identity and the traps; repo copy at `wip/onprem-platform/PLATFORM-ONPREM-REFERENCE-2026-10-20.md`)
  ("On-Prem Delivery Setup" — the four repositories, what a new app needs, and the open
  decision on whether each application gets its own repository)

## The open repository decision

Idris's Stage 1 plan names two repositories we have **not verified exist**:
`iaac-onprem-applications` (for charts) and `iaac-argocd-onprem` (for Argo CD Applications).

RisingWave grew **four** repositories of its own because there was no intake. The pricing plan
creates **none** — a chart directory in a shared applications repository, an Application beside
it, the namespace in the platform repo.

**Recommendation: one shared applications repository, one directory per application.** The
second and third apps are then a directory rather than a project, which is the point of having
an intake. The blast-radius objection is answered with code owners per directory, not by
splitting the repository.

⚠️ Settle it before the first chart is written — it decides the shape every later application
inherits.


## Who owns the next move

| # | Item | Owner |
|---|---|---|
| 1 | Send the Stage 1 feedback | Doke → Idris |
| 2 | Security-group rule on `sg-0c8f8db29b16a1477` | the Octopus `mongodb` project owner |
| 3 | Kafka topic + consumer-group ACL | `ix-kafka-topics-users`, another team's approval |
| 4 | Does `pricing-rfp-api` move too | the app team |
| 5 | Consumer group: shared or new | the app team — it changes behaviour, not just config |
| 6 | Approve the settings/credentials split | Matt |
| 7 | Whose Entra tenant is `0f298105-…` | one command: `az account show --query tenantId` |
| 8 | ~~Ping KNX from an on-prem pod~~ | ✅ done 2026-10-20 |

## Proven today

* The config inventory has **two halves** and each side could only see one: Octopus holds ~53,
  the DX chart injects ~25 more, and the app team can see only the first.
* The container receives **rendered** names, not Octopus names — the single most likely cause
  of a silent failure in Stage 1.
* Mongo is **PrivateLink, ports 1024-1026**, and the datacenter-to-VPC network already exists
  and is routed. One security-group rule.
* **ECR already grants org-wide pull** and the ServiceAccount has **no IRSA** — two work items
  deleted by measurement.
* Production runs **0.1.39**, contradicting the Stage 1 plan's table.
* **Both Knight-Swift endpoints answer from inside an on-prem pod** (405, TLS trusted),
  so the premise of the whole engagement holds — measured from a pod, not a laptop.

## Still not measured

* Dev's own rendered ConfigMap — everything above is production.
* Whether the datacenter routes 10.16.0.0/20 back; deliberately deferred until the
  security-group rule lands, because a timeout before then proves nothing.
* The Octopus side from our own tooling — the push that would enable it is blocked; Idris has
  the export (58 variables, 10 library sets).
