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
- **Cluster-admin** — bound directly. He can install operators, manage CRDs, modify cluster-wide RBAC. This is the right tier for a platform engineer; we treat the cluster as prod and audit-log every action against his identity.
- Also has (redundant but harmless): `onprem-platform-operator` cluster-wide and `edit` on `risingwave` namespace from earlier provisioning.
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

## Deployment path — operator-based (production-grade, no POC detour)

We use the **operator chart**. No standalone-chart detour. POC ≠ prod-ready, and switching paths later is wasted work. Path is:

- **Operator chart**: `risingwavelabs/risingwave-operator`
- **Reference**: https://github.com/risingwavelabs/helm-charts/tree/main/charts/risingwave-operator
- Installs ~5-10 cluster-scoped CRDs (`RisingWave`, `RisingWaveScaleView`, etc.).
- Operator runs as a Deployment, watches CRs cluster-wide.
- Idris creates `RisingWave` CR instances in `risingwave` namespace; operator reconciles them into Deployments/StatefulSets.

Idris has **cluster-admin** so he installs the operator + creates CRs himself. No admin gating on the deployment path during PTO.

### Operator install (Idris runs this himself)

```bash
# Verify cert-manager is healthy (operator's webhook needs it)
kubectl get pods -n cert-manager
# All Running

# Install the operator
helm repo add risingwavelabs https://risingwavelabs.github.io/helm-charts
helm repo update

helm install rw-operator risingwavelabs/risingwave-operator \
  --namespace risingwave-operator-system \
  --create-namespace

# Verify operator + CRDs landed
kubectl get pods -n risingwave-operator-system
kubectl get crd | grep risingwave
# Expected: risingwaves.risingwave.risingwavelabs.com,
#           risingwavescaleviews.risingwave.risingwavelabs.com,
#           risingwavepodtemplates.risingwave.risingwavelabs.com (and a few more)

# Read CR examples to model from
helm show values risingwavelabs/risingwave-operator > /tmp/rw-operator-values.yaml
# Browse: https://github.com/risingwavelabs/helm-charts/tree/main/examples
```

### RisingWave CR (Idris writes this)

```yaml
# rw-cluster.yaml — namespace: risingwave
apiVersion: risingwave.risingwavelabs.com/v1alpha1
kind: RisingWave
metadata:
  name: rw
  namespace: risingwave
spec:
  # Image / version — pin explicitly, don't track latest
  image: risingwavelabs/risingwave:v2.x.x

  # ServiceAccount — must be 'risingwave' (matches IRSA trust)
  global:
    serviceAccountName: risingwave

  # State store — S3 via IRSA (no access keys)
  stateStore:
    s3:
      bucket: risingwave-state-op-usxpress-dev
      region: us-east-2
      # No accessKey/secretAccessKey — IRSA handles auth via the SA annotation

  # Metadata store — PostgreSQL
  metaStore:
    postgresql:
      host: pg-postgresql.risingwave.svc.cluster.local
      port: 5432
      database: risingwave
      username: risingwave
      passwordSecret:
        name: pg-postgresql
        key: password

  # Component sizing — tune with Tim's input post-deploy
  components:
    meta:
      replicas: 1
      resources:
        requests: { cpu: 200m, memory: 1Gi }
    frontend:
      replicas: 1
      resources:
        requests: { cpu: 200m, memory: 1Gi }
    compute:
      replicas: 2
      resources:
        requests: { cpu: 1, memory: 4Gi }
        limits:   { cpu: 2, memory: 8Gi }
    compactor:
      replicas: 1
      resources:
        requests: { cpu: 500m, memory: 2Gi }
```

```bash
kubectl apply -f rw-cluster.yaml
kubectl -n risingwave get risingwave rw -w
# Wait for Status.Phase = Ready
kubectl -n risingwave get pods
```

CR field names vary between operator versions — verify against the values file from `helm show values` for the version you install. Example CRs at https://github.com/risingwavelabs/helm-charts/tree/main/examples are the source of truth.

### Why this approach

- **Production-grade lifecycle**: operator handles rolling updates, scale ops, and component coordination declaratively. Standalone chart can't.
- **No re-platforming work later**: same path POC → prod, just sizing/replicas change.
- **Standard RW pattern**: matches what Tim's deployments use; matches RW Cloud's model; matches the upstream docs.
- **Cluster-admin is fine for Idris** — he's a platform engineer onboarded to the on-prem core team.

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

## Idris's first-week task list (operator-first build)

Calendared for the week Dare is on PTO (May 4–8 2026):

- [ ] Day 1: Create SA `risingwave/risingwave` with IRSA annotation. Deploy Bitnami Postgres in `risingwave` ns. PG pods up.
- [ ] Day 2: Install `risingwave-operator` chart (`helm install` — he has cluster-admin). Verify CRDs landed. Read example CRs in upstream `helm-charts/examples/`.
- [ ] Day 3: Write `RisingWave` CR YAML referencing his SA + bucket + PG metadata DB. `kubectl apply` it. Watch reconciliation.
- [ ] Day 4: Verify IRSA (S3 list from compute pod). Verify psql via port-forward. Capture sample query output.
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
| 2026-04-29 | Use **operator** chart (production-grade); skip standalone POC | POC ≠ prod-ready; switching paths later is wasted work | Dare (revised same day) |
| 2026-04-29 | Bind Idris to **cluster-admin** | Required for operator install (CRDs, webhook configs); appropriate for platform engineer; audit-logged per his identity | Dare |
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
- [ ] **Bind Idris to cluster-admin** (`kubectl create clusterrolebinding cluster-admin-idris-fagbemi --clusterrole=cluster-admin --user=idris-fagbemi`)
- [ ] Verify cert-manager is healthy (operator dependency)
- [ ] Send Idris updated message: operator-first path, you have cluster-admin, install away
- [ ] Document this doc's location in #cloud-platform Slack channel for visibility
- [ ] Alert Steve as backup contact for emergencies during PTO (Idris is now self-sufficient for normal work)
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
| Cluster-admin task | **Idris does this himself** — he has cluster-admin |
| RisingWave technical question | Tim Preble |
| AWS account / IAM emergency | Vibin (back later in week) |
| GitHub variant-inc invite issue | Vibin |
| General platform outage / break-glass | Steve Duck (offline cert kubeconfig backup) |

**Default for non-urgent**: queue questions in Slack with full context; Dare picks them up May 11.

**Default for urgent cluster-admin work**: Idris is the cluster-admin during PTO — he handles his own operator/CRD/RBAC needs. Steve is break-glass only.
