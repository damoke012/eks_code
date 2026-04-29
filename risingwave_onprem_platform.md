# RisingWave on op-usxpress-dev — Platform & Infra Reference

**Status:** POC setup in progress (platform side ready, deployment pending)
**Cluster:** op-usxpress-dev (on-prem Talos, https://10.10.82.50:6443)
**Owners:**
- **Dare Oke** — platform setup, AWS/IAM/cluster, on-call for blockers
- **Idris Fagbemi** — active build, Helm/values, day-to-day platform work
- **Tim Preble** — RW SME, SQL pipelines + MV design (Phase 2)

**Last updated:** 2026-04-29

---

## Project context

Knight-Swift / USXpress is adopting **RisingWave** for streaming SQL over our existing Kafka data — real-time analytics on truck telemetry, freight events, driver compliance, etc. Replaces ad-hoc batch aggregations with continuously-fresh materialized views queryable over Postgres protocol.

Strategic driver: single source of truth for derived/aggregated streaming data, sub-second freshness, app teams query MVs instead of building their own consumers.

### Scope split — who does what

| Phase | Scope | Owner |
|---|---|---|
| **Phase 1 — Platform & Infrastructure** | Cluster setup, S3 state store, Postgres metadata, IAM/IRSA, RW deployment via Helm, networking, observability | Idris (with Dare on-call) |
| **Phase 2 — SQL Pipelines** | Kafka sources, materialized views, sinks, perf tuning | Tim (Idris supports) |

The deliverable for Phase 1: working RW cluster on op-usxpress-dev, healthy pods, S3-backed state, metrics flowing, ready for Tim to point Kafka topics at it.

### Vibin's architectural decisions (March 31)

- **RisingWave is an iaac-eks-style pattern**, not a per-app deploy. Owned outside the DX/mage/Octopus pipeline.
- **New repo: `iaac-risingwave`** (analog of `iaac-eks`). Owns the chart reference + supporting TF (S3, IRSA roles).
- **Own CI/CD** — not through Octopus or mage-runner. Keeps RW out of the DX pipeline.
- **Cluster placement** — original direction was usx-dev EKS first; current direction (per Steve/Idris kickoff) is op-usxpress-dev first to leverage on-prem skills, then EKS later. Worth confirming with Vibin when he's back from PTO.

---

## What we have today (platform side)

### Cluster access (Idris)
- **Identity**: `idris-fagbemi` (cert-based, expires 2027-04-28)
- **Cluster-wide**: `onprem-platform-operator` role — read+write on most resources, no secrets
- **Namespace-scoped**: `edit` ClusterRole bound at `risingwave` namespace — full edit incl. secrets
- See [onprem_cluster_access_runbook.md](onprem_cluster_access_runbook.md) for the per-user access pattern

### Namespace
- `risingwave` — created, labeled `purpose=streaming-db`, `istio.io/dataplane-mode=ambient`

### S3 state store
- **Bucket**: `risingwave-state-op-usxpress-dev`
- **Region**: us-east-2
- **Account**: 700736442855 (USX-Dev)
- **Encryption**: SSE-S3 (AES256)
- **Versioning**: enabled
- **Public access**: blocked (all 4 controls)
- **Tags**: `purpose=risingwave-state-store`, `cluster=op-usxpress-dev`, `managed-by=onprem-platform-team`

### IAM role for IRSA
- **Role**: `op-usxpress-dev-risingwave`
- **ARN**: `arn:aws:iam::700736442855:role/op-usxpress-dev-risingwave`
- **OIDC issuer trusted**: `d3a7wcnazdrd6p.cloudfront.net` (the on-prem cluster's IRSA issuer)
- **Trust scope**: `system:serviceaccount:risingwave:risingwave` only — strict
- **Attached policy**: `op-usxpress-dev-risingwave-s3` — S3 R/W on the bucket above
- **No IAM access keys** — pods authenticate via projected SA tokens through IRSA

### What Idris has been told to do
- Create the SA `risingwave/risingwave` with the `eks.amazonaws.com/role-arn` annotation
- Deploy Bitnami Postgres for RW metadata DB (`pg-postgresql.risingwave.svc.cluster.local`)
- Read RW chart values for the version, draft his own `values.yaml`, dry-run, then install
- Verify IRSA works (exec into compute pod, `aws s3 ls` against the bucket)
- Connect via psql port-forward, run `SELECT version();`

---

## What's pending

| Item | Owner | Status |
|---|---|---|
| variant-inc GitHub org invite for `ifagbemi-usxpress` | Vibin | ⏳ blocking repo work; not blocking Helm CLI install |
| `iaac-risingwave` repo creation in variant-inc | Vibin/Dare | ⏳ after Vibin's PTO ends |
| RW pods running on cluster | Idris | ⏳ in progress |
| IRSA verification (S3 list from compute pod) | Idris | ⏳ |
| psql connection test | Idris | ⏳ |
| Tim Preble intro / kickoff meeting | Idris + Tim | Friday meeting scheduled |
| Grafana dashboard for RW metrics | Idris | Phase 2 of POC |
| MV design / first Kafka source | Tim | Phase 2 |
| S3 lifecycle policy (retention strategy) | TBD with Tim | Open — needs storage growth estimate |
| Move from POC to operator-based deploy | Idris + Dare | Phase 2 (operator install needs cluster-admin) |
| Production sizing review | Idris + Tim + Vibin | Pre-prod gate |

---

## Two deployment paths

The RW Helm-charts repo offers **two charts**. Pick deliberately.

### Path A — Standalone chart (recommended for POC)

- **Chart**: `risingwavelabs/risingwave`
- **Reference**: https://docs.risingwave.com/deploy/risingwave-k8s-helm
- Deploys raw K8s primitives (Deployments / StatefulSets / Services) — no CRDs.
- **No cluster-admin needed** for any step. Idris can do this 100% himself.
- Lifecycle: kubectl/helm-driven. No operator-managed reconciliation.

**Why this is right for POC**: it works. CRDs aren't needed. Idris stays unblocked even when cluster-admin (Dare) is on PTO.

### Path B — Operator-based deploy

- **Operator chart**: `risingwavelabs/risingwave-operator`
- **Reference**: https://github.com/risingwavelabs/helm-charts/tree/main/charts/risingwave-operator
- Operator install creates ~5-10 cluster-scoped CRDs (`RisingWave`, `RisingWaveScaleView`, etc.).
- User then creates `RisingWave` CR instances in their namespace; operator reconciles.
- **Requires cluster-admin** for operator install (CRDs).
- **Production-grade** — better lifecycle, rolling upgrades, scale operations declarative.

**When to use**: production. After POC stability is proven. Plan a joint session with Dare/cluster-admin to install the operator + extend Idris's RBAC to cover the `risingwave.risingwavelabs.com` API group.

---

## The CRD blocker (and why it doesn't block POC)

If anyone tries to install the **operator chart** while logged in as a non-admin (Idris, with `onprem-platform-operator` role), it fails:

1. `helm install risingwave-operator` → **403 Forbidden** on creating CustomResourceDefinitions.
2. Even if CRDs existed, `kubectl apply -f rw-cluster.yaml` (a `RisingWave` CR) → **403** because the API group `risingwave.risingwavelabs.com` isn't in his role.

**Avoidance for POC**: use the **standalone chart** (Path A). No CRDs. He's never blocked.

**If we move to operator path**: the steps below need to happen **once**, by a cluster-admin. Document them here so any cluster-admin (not just Dare) can run them.

```bash
# 1. Install the operator chart (creates CRDs + operator Deployment)
helm repo add risingwavelabs https://risingwavelabs.github.io/helm-charts
helm repo update
helm install rw-operator risingwavelabs/risingwave-operator \
  --namespace risingwave-operator-system \
  --create-namespace

# 2. Verify CRDs are present
kubectl get crd | grep risingwave

# 3. Extend the onprem-platform-operator ClusterRole to allow Idris (and future operators)
#    to create/manage RisingWave CRs. Patch into the existing CRD-rule (rules[3]):
kubectl patch clusterrole onprem-platform-operator --type=json -p='[
  {"op":"add","path":"/rules/3/apiGroups/-","value":"risingwave.risingwavelabs.com"}
]'

# 4. Verify Idris can now manage RW CRs
kubectl auth can-i create risingwaves.risingwave.risingwavelabs.com -n risingwave --as=idris-fagbemi
# → should be: yes
```

---

## Working with Tim

Tim is the RW SME. He owns Phase 2 (SQL pipelines / MV design). Idris's job in Phase 1 is to make Tim's Phase 2 easy.

### What Idris gives Tim (when platform is healthy)
- The PG-protocol endpoint (port-forward at first; later in-cluster Service or NLB)
- 1-2 candidate Kafka topics for the first MV (low-traffic, non-prod — Dare/team picks)
- Postgres metadata DB connection details
- Grafana dashboards for: compute throughput, MV freshness, S3 IOPS
- A summary: PG metadata DB size, S3 state-store size, current resource limits

### What Idris asks Tim
- Sizing guidance for compute replicas (Tim has real-workload data)
- Which Kafka topic for the first demo
- Schema/MV design (Idris doesn't design these but should understand them for debugging)
- Operational lessons from prior RW deployments
- Storage growth expectations (drives S3 lifecycle + PG sizing)
- Migration tooling preference: Tim mentioned **Flyway** as a candidate (https://documentation.red-gate.com/fd/flyway-open-source-277579296.html) — for managing schema/MV evolution. dbt was ruled out (doesn't work well with RW scripts per Tim).

### First meeting agenda
1. Idris walks Tim through what's running on op-usxpress-dev.
2. Tim sketches the first MV he wants — grounds the conversation.
3. Pick the first Kafka topic together.
4. Agree on demo timeline.
5. Decide migration tooling (Flyway / Liquibase / go-migrate).

---

## References (curated from Tim)

### RW deployment docs
- **Helm overview**: https://docs.risingwave.com/deploy/risingwave-k8s-helm
- **Kubernetes general guide**: https://docs.risingwave.com/deploy/risingwave-kubernetes
- **Hardware requirements**: https://docs.risingwave.com/deploy/hardware-requirements

### Charts & values
- **Standalone chart values.yaml**: https://github.com/risingwavelabs/helm-charts/blob/main/charts/risingwave/values.yaml
- **Operator chart**: https://github.com/risingwavelabs/helm-charts/tree/main/charts/risingwave-operator
- **Examples**: https://github.com/risingwavelabs/helm-charts/tree/main/examples
- **Terraform provider** (RW Cloud only — not for self-hosted): https://github.com/risingwavelabs/terraform-provider-risingwavecloud

### Existing internal POC
- `usxpressinc/risingwave-poc` — earlier POC repo (Tim mentioned). Worth reading for prior lessons. Idris needs variant-inc + usxpressinc GitHub access to view; will resolve when Vibin returns.

### Migration tooling under evaluation
- **Flyway**: https://documentation.red-gate.com/fd/flyway-open-source-277579296.html — Tim's primary candidate
- **Liquibase**, **go-migrate** — alternatives if Flyway has issues

---

## Idris's first-week task list (POC build)

Calendared for the week Dare is on PTO (May 4–8 2026):

- [ ] Day 1: Create SA with IRSA annotation. Deploy Bitnami Postgres. Pods up.
- [ ] Day 2: Read `risingwavelabs/risingwave` chart values. Draft custom `values.yaml` with bucket, PG, SA references.
- [ ] Day 3: Dry-run, then install. Verify all RW pods Running.
- [ ] Day 4: Verify IRSA (S3 list from compute pod). Verify psql connection. Capture sample query output.
- [ ] Day 5: Wire ServiceMonitor for Prometheus. Mirror RW reference Grafana dashboards into iaac-monitoring.
- [ ] Friday meeting with Tim: walk-through, pick first Kafka topic.

---

## Day-to-day commands reference

```bash
# Activate context
export KUBECONFIG=~/.kube/configs/op-usxpress-dev
kubectl config use-context op-usxpress-dev

# Check his identity (sanity)
kubectl auth whoami

# Deploy / inspect
kubectl -n risingwave get pods -w
kubectl -n risingwave logs deploy/rw-compute --tail=100
kubectl -n risingwave describe pod <pod-name>

# Get PG password
kubectl -n risingwave get secret pg-postgresql -o jsonpath='{.data.password}' | base64 -d ; echo

# Verify IRSA from a compute pod
POD=$(kubectl -n risingwave get pod -l risingwave-component=compute -o name | head -1)
kubectl -n risingwave exec -it $POD -- aws s3 ls s3://risingwave-state-op-usxpress-dev/

# psql access via port-forward
kubectl -n risingwave port-forward svc/rw-frontend 4566:4566 &
psql -h localhost -p 4566 -d dev -U root
```

---

## Decisions log

| Date | Decision | Rationale | Decided by |
|---|---|---|---|
| 2026-03-31 | RW lives in iaac-eks-style separate repo, NOT in DX pipeline | Decouple from app-deploy machinery, separate ownership/release cadence | Vibin |
| 2026-04-28 | Cluster target = op-usxpress-dev (on-prem) for first POC | Leverage on-prem skills, AWS-outage-independence story | Steve / Dare |
| 2026-04-29 | Use standalone chart for POC (not operator) | Avoid CRD blocker; Idris fully unblocked | Dare (this doc) |
| 2026-04-29 | IRSA for S3 (no IAM access keys) | Standard prod pattern, leverages existing Talos OIDC infra | Dare |
| 2026-04-29 | Bitnami Postgres for metadata (POC) | Simple, no extra operator. Migrate to CNPG/RDS for prod. | Dare |
| TBD | Flyway vs Liquibase vs go-migrate for migrations | Pending Tim's recommendation + Idris's eval | Tim + Idris |

---

## Open questions

1. **Cluster placement final decision** — confirm op-usxpress-dev first vs Vibin's original "iaac-eks first" call. Sync with Vibin when he's back.
2. **Storage growth estimates** — drives S3 lifecycle policy and Postgres metadata DB sizing. Tim has data from prior deployments.
3. **PG-for-metadata at prod scale** — Bitnami chart for POC; migrate to CNPG operator or RDS for prod?
4. **Networking exposure** — keep frontend internal (ClusterIP) or expose via Istio Gateway / NLB for app teams to query?
5. **Backup/restore strategy** — RW uses S3 versioning. PG metadata DB needs separate backup plan (CNPG built-in, RDS automated, or pgdump cron for Bitnami).
6. **Observability integration** — how does RW dashboards fit into iaac-monitoring? Standard ConfigMap-with-grafana-dashboard-label pattern.
7. **Multi-tenancy / namespace isolation** — single shared RW cluster, or one per business unit? Affects RBAC and IRSA design.

---

## Pre-PTO checklist (for Dare before May 4)

- [x] Cluster access for Idris provisioned (cert + RBAC + namespace-scoped edit)
- [x] S3 bucket created
- [x] IAM role for IRSA created
- [x] Idris briefed via Slack with full step-by-step
- [ ] Confirm with Idris that he can deploy via standalone chart with no admin help
- [ ] Walk Idris through `kubectl auth can-i` on the namespace so he understands his ceiling
- [ ] Document this doc's location in #cloud-platform Slack channel for visibility
- [ ] Alert Steve to be backup contact for any cluster-admin-needs (CRDs, cluster-scoped resources) during PTO
- [ ] Tim Preble intro meeting Friday — Idris + Tim aligned on Phase 1 vs Phase 2 scope

---

## Post-PTO follow-ups (when Dare returns May 11)

- Review what Idris built; pair on any blockers he hit
- Sync with Vibin on `iaac-risingwave` repo creation
- If POC is healthy, plan Phase 2 kickoff with Tim
- Decide: stay on standalone chart, or migrate to operator (with proper RBAC + CRD install)
- Add RisingWave reference to the master KT plan (`idris_kt_master_plan.md`)
- Update `idris_kt_session7_risingwave.md` to reflect on-prem-first decision (currently written for EKS-first)

---

## Backup contacts during Dare's PTO (May 4–8)

For Idris if he hits a wall:

| Need | Contact |
|---|---|
| Cluster-admin task (CRD install, cluster-scoped resources) | Steve Duck (or wait until Dare is back) |
| RisingWave technical question | Tim Preble |
| AWS account / IAM emergency | Vibin (back later in week) |
| GitHub variant-inc invite issue | Vibin |
| General platform outage | Cloud-platform on-call rotation |

**Default for non-urgent**: queue questions in Slack with full context; Dare picks them up May 11.

**Default for urgent cluster-admin**: Steve has admin kubeconfig access (break-glass cert from offline backup if needed). Direct him to this doc for context.
