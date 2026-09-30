# On-prem app onboarding — the working reference

**For the room.** Open this during an intake conversation. It is ordered the way the
conversation goes, not the way the work goes.

Last measured 2026-09-30. Numbers carry a date because they rot.

---

## The 60-second version

**Classify → size → identity → secrets → workload → network → alerting → promote.**

Every stage is load-bearing for the next. Three of them do not properly exist yet
(see [What is not ready](#what-is-not-ready)), which is why the first app we onboard
should be one **we** chose rather than one that arrived.

And one rule underneath all of it:

> **Whoever owns the repo owns the pager.** If nobody will say who that is, the app is
> not ready to onboard.

---

## 1. Classify first — four intake classes

| Class | What it is | Deployed by | Repo | State |
|---|---|---|---|---|
| **A. Platform service** | RisingWave, Istio, cert-manager | Flux | its own `iaac-<app>-onprem` | ✅ proven |
| **B. App-team workload** | anything in an `app-*` namespace | ArgoCD | `deploy/` in the app's own repo | ⚠️ **unproven** |
| **C. Existing cloud app via DX** | the common case now | undecided | see [§5](#5-the-dx-case) | ⚠️ no path yet |
| **D. Stateful cloud app** | anything on RDS / EFS | either | either | ⚠️ untested |

**The test for A vs B:** *does the platform team get paged when it breaks?*
Yes → platform service, own repo, Flux. No → app workload, app's repo, ArgoCD.

⚠️ **Flux and ArgoCD must never both own an object.** Two controllers doing server-side
apply on the same resource fight forever. The `apps` AppProject restricts ArgoCD to the
`app-*` namespace glob; keep it that way.

---

## 2. The intake questions

Twelve questions, four groups. For each: why it is asked, what you will actually hear,
and what it means.

### Q1 — Is it moving on-prem, or running in both places?

*The first question, because everything downstream changes with the answer.*

| They say | It means | Watch for |
|---|---|---|
| "Moving, cloud gets decommissioned" | cleanest case. One identity, one pipeline, a cutover date | ask when cloud is switched **off** — "eventually" means both, forever |
| "Both — on-prem is DR / latency / data residency" | two of everything, and drift is now a permanent programme | who reconciles them? If the answer is "we'll keep them in sync", that is nobody |
| "On-prem first, cloud later" | you are the pilot. Fine, if scoped as one | the word "just" — "we'll just run it on-prem first" |

### Q2 — Does it need AWS? Which services, and with what permissions?

| They say | It means | Watch for |
|---|---|---|
| "S3 and Secrets Manager" | standard. IRSA role + ExternalSecret, done | which **account**? On-prem clusters use the account for *their* environment, not the app's cloud account |
| "RDS" | ⚠️ there is no RDS reachable from on-prem by default. This is an application change | "it's just a connection string" — it is a VPN path, a security review and a latency budget |
| "Nothing, it's self-contained" | good — but confirm images, logs and metrics too | almost nothing is self-contained |
| "It uses an access key" | stop. IRSA exists on-prem; a long-lived key in a Secret is a finding | "we'll rotate it manually" |

### Q3 — Does it log users in? Whose Entra app registration?

| They say | It means | Watch for |
|---|---|---|
| "It has its own" | fine. On-prem is a **redirect URI addition**, not a new identity | who can edit it — app-registration *update* is proven for us, *create* is not |
| "It shares the cloud one" | ⚠️ **every DX deploy destroys and recreates that registration.** New client ID, and on-prem breaks on a *cloud* release | this is the single most common silent breakage for a DX app |
| "SSO is handled by the platform" | it is not, for apps. Argo CD and Grafana have SSO; your app does not inherit it | assumption that Istio does authn |

### Q4 — Stateful or stateless? How much, which storage class?

| They say | It means | Watch for |
|---|---|---|
| "Stateless" | easiest path. Confirm no local cache that matters | "stateless except for…" |
| "EBS volume" | → `ceph-block` (RWO). Sizing and IOPS are not the same | a single-node Ceph is degraded by design; replication wants three |
| "EFS / shared filesystem" | → `ceph-fs` (RWX) | RWX assumptions that were never true on EBS either |
| "S3" | → the app's own bucket, IRSA-scoped | bucket in the wrong account |

### Q5 — What is the restore requirement if the cluster is lost?

| They say | It means | Watch for |
|---|---|---|
| "It's backed up" | by what? Velero is installed; a backup existing is not a restore having been tested | "Velero covers it" — has a restore ever run? |
| "Data lives in S3, pods are disposable" | best answer. Rebuild is a deploy | the metastore nobody mentioned |
| "We'd rebuild from cloud" | then cloud is a dependency and Q1's answer was "both" | |

### Q6 — Who calls it, and over what protocol?

| They say | It means | Watch for |
|---|---|---|
| "HTTPS, internal users" | `shared-http` gateway (80/443), VirtualService, cert via DNS01 | hostname must be in our zone |
| "Postgres wire / gRPC / raw TCP" | ⚠️ `tcp-passthrough` gateway (4567/5432) **and** a TLS sidecar. RisingWave needed ghostunnel for exactly this | "it's just a port" |
| "Public internet" | different conversation — CySec, WAF, egress | assume no until someone owns it |
| "Only other pods" | ClusterIP, no ingress, no cert. Cheapest case | east-west policy still applies in ambient mode |

### Q7 — What hostname, in which zone?

DNS is ours and automatic: external-dns reads VirtualService annotations and writes into
the zone in network account `155768531003`. The record targets **this cluster's own worker
IPs**, and the owner-id is per cluster.

⚠️ **A VirtualService copied from another cluster fails silently** — it publishes, and it
points at the other cluster's workers.

### Q8 — Where is the image built, and how is it referenced?

| They say | It means | Watch for |
|---|---|---|
| "ECR, tagged `latest` or a branch" | ⚠️ must be a **digest** on-prem. 515 of 517 ECR repos accept org-wide push and there is no registry policy | "we always tag releases" — tags are mutable |
| "Built by DX" | then the build stays; only the deploy moves | see [§5](#5-the-dx-case) |
| "Docker Hub / public registry" | egress path and pull-through caching to confirm | rate limits at 3am |

### Q9 — Who deploys it, and on what trigger?

| They say | It means | Watch for |
|---|---|---|
| "On merge to main" | ⚠️ that is deploying to production. Needs a **tag** per cluster | this is the default in most templates, including ours until 17 Sep |
| "Octopus" | fine, but a release **freezes** its variable snapshot | a changed variable that never reached the release |
| "ArgoCD" | class B — and that path is not yet proven with a real payload | |

### Q10 — Who gets paged?

| They say | It means | Watch for |
|---|---|---|
| a named team | good. They also need `kubectl` and a dashboard | |
| "Platform" | then it is class A and it needs a platform-owned repo | quiet reassignment of the pager during onboarding |
| "We'll watch the dashboard" | ⚠️ **nothing delivers alerts on-prem today.** There is no Alertmanager on any cluster | agreement to onboard before INFRA-1698 lands |

### Q11 — What does it cost — CPU, memory, storage, per environment?

Default namespace quota is **4 CPU / 8 Gi / 20 pods**, LimitRange 500m/512Mi default and
100m/128Mi request. Anything larger is a conversation, not a form field.

⚠️ **The unit of growth here is a cluster, not a VM.** A new *environment* reserves a full
set whether or not it runs anything. Current Nutanix position (2 Sep): **10.79 TB reserved
against 2.7 TB used** — re-measure before quoting.

### Q12 — Who needs `kubectl`, and in which environments?

Access is an AWS SSO permission set mapped through the self-hosted `aws-iam-authenticator`.

⚠️ **It works on QA only.** Dev and prod have the authenticator but not the apiserver
webhook flag (INFRA-1661). Promising dev access today is promising something that does not
exist.

---

## 3. What we anticipate

The predictable friction, so it is not a surprise in the room.

| We expect | Why |
|---|---|
| "Can't we just point DX at the on-prem cluster?" | DX provisions identity, ECR, Octopus project and deploy as one unit. On-prem has none of that shape. The honest answer is the deploy moves and the build stays |
| "It works in cloud, so it will work here" | different storage, different ingress, different identity plumbing, no RDS, VPN latency to AWS |
| "We need it in production by <date>" | production has no proven app-team delivery path yet, and no alert delivery. A date set before those is a date against a hole |
| Sizing given as "same as cloud" | cloud instances are elastic; ours are reserved from a fixed pool that is already 4× over-reserved |
| "The team will own it" | true until the first 3am page. Confirm the pager, in writing, in the same conversation as the repo |
| Nobody knows who owns the Entra registration | the most common unknown, and the one that breaks quietly later |

---

## 4. The red-flag glossary

Phrases to stop on, and what they usually mean.

| Phrase | Usually means |
|---|---|
| "The secret is synced" | a green `ExternalSecret` proves the sync ran, not that the value works. ESO writes **partial** secrets on failure and the pod dies at container creation with **0 restarts** |
| "It's green in Argo / Flux" | four layers each report Ready while the next is stale. Finish at the **pod start time** |
| "We'll copy it from dev" | copied manifests carry dev role ARNs and dev worker IPs, and fail silently |
| "It deploys on merge" | merging is deploying, to every cluster tracking that branch |
| "We'll create the OIDC provider" | that object is **per AWS account**. The second app gets a 409, and a destroy takes out the first |
| "Just a small cluster for testing" | `dpl` and `jbtest` started that way and are now a decommissioning ticket |
| "Same Entra app as cloud" | a cloud deploy will rotate the client ID out from under you |
| "We'll keep the two in sync" | nobody is "we" |

---

## 5. The DX case

**The situation.** A DX-provisioned app today owns, as one bundle: the Entra app
registration, the ECR repository, the Octopus project and the deployment. On-prem has
Octopus but a different project shape, and none of the rest.

**So the question is not "which repo". It is:**

> Does the app get a **second deployment target**, or a **second definition**?

| | Second target | Second definition |
|---|---|---|
| Source of truth | one | two |
| Identity | DX keeps owning it | on-prem gets its own |
| Cost | DX must learn Flux/ArgoCD | two manifests to keep in step |
| Risk | app-registration churn hits on-prem | drift |

**Recommendation: second definition, shared image.** Build once, publish to ECR by digest,
let each platform deploy it its own way. Forking the *image* is what makes environments
drift; forking the *deployment manifest* is normal and reviewable.

**What that means concretely for a DX app:**

1. The build pipeline stays where it is. Nothing about DX changes.
2. On-prem gets a `deploy/onprem/` folder — in the app's repo for class B, or a new
   `iaac-<app>-onprem` for class A.
3. The image is referenced **by digest**, the same digest cloud runs.
4. Identity is decided explicitly: either the app gets its own registration for on-prem, or
   it accepts that a cloud deploy can break it. There is no third option while DX recreates
   the registration on every deploy.
5. Secrets are re-created under `op-usxpress-<env>/<app>/<connector>` — they are **not**
   shared with the cloud copy.

---

## 6. Where things live

| Repo | Layer | What you change |
|---|---|---|
| `iaac-talos` | infrastructure — Terraform, Talos, Flux bootstrap | nothing, for an app |
| `iaac-talos-flux-cluster` | per-cluster Flux DAG | `clusters/<cluster>/flux-system/infra.yaml` — GitRepository + Kustomization |
| `iaac-talos-flux-platform` | platform services, **per-environment branches** | `infrastructure/app-namespaces/`, `app-secrets/`, `<app>-routes/`, `prometheus/`, `rbac/` |
| `iaac-<app>-onprem` | class A app | Terraform + `manifests/op-usxpress-<env>/` |
| the app's own repo | class B app | `deploy/` |

### Environments

| Environment | Cluster | API | Platform branch | AWS account |
|---|---|---|---|---|
| dev | `op-usxpress-dev` | 10.10.82.50 | `op-dev` | 700736442855 |
| QA | `op-usxpress-qa` | 10.10.82.51 | `op-qa` | 527101283767 |
| prod | `op-usxpress-prod` | 10.10.82.52 | `op-prod` | 937464026810 |

⚠️ `dpl`, `dpl2` and `jbtest` appear in older guides. **They are the abandoned clusters**
being decommissioned under INFRA-1686 — do not wire anything into them. Account
`786352483360` is `dpl`, not production.

---

## 7. What is not ready

Say this out loud rather than discovering it during an onboarding.

| Gap | Effect on an app onboarded today | Ticket |
|---|---|---|
| **No alert delivery on any cluster** | its alerts fire and reach nobody. Measured on QA 2026-09-18: `.spec.alerting` null, zero Alertmanager pods, 21 alerts firing | INFRA-1698 |
| **The ArgoCD path is unproven** | op-dev has zero Argo Applications; QA's only success carried a *smoke* payload | INFRA-1697 |
| **`kubectl` via SSO works on QA only** | dev and prod have the authenticator, not the apiserver flag | INFRA-1661 |
| **No prod RisingWave manifests** | the reference app is not itself in production yet | INFRA-1674 |
| **Nutanix over-reservation** | a new environment reserves a cluster's worth against an already-strained pool | INFRA-1686 |

---

## 8. The per-app sequence

Only when the above is understood. Each stage works only if the one above it does.

| # | Stage | Done when |
|---|---|---|
| 1 | **Classify + size** | class agreed, capacity signed off, **pager named** |
| 2 | **Identity** | a pod can call AWS — IAM role, OIDC trust, SA annotation |
| 3 | **Secrets** | you have **read the value**, not the green tick |
| 4 | **Workload** | pods running on **dev only**, image pinned by digest |
| 5 | **Network** | the hostname resolves to *this* cluster's workers |
| 6 | **Observability** | a test alert arrives somewhere a human looks |
| 7 | **Promote** | dev → QA → prod, **by tag**, each step deliberate |

---

## What this document does not claim

It does not claim the platform is ready for arbitrary apps. It claims we know the order,
we know the traps, and we know which three gaps have to close first. A date for the first
production app should be quoted **after** INFRA-1697 and INFRA-1698, not before.
