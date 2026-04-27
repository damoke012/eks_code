# Session 7 — RisingWave deep-dive (Idris's project kickoff)

**Duration:** 90 min
**Goal:** Idris owns the RisingWave project. By end of session he has: a 4-week roadmap, a draft design doc outline, an iaac-eks PR skeleton, and a kickoff plan for Tim Preble.
**Format:** Working session (not a lecture). He drives.

---

## Why this session is different

Sessions 0-6 are about onboarding. Session 7 hands him the keys to his project. We pivot from "let me explain" to "what's your plan?"

---

## Prerequisites

- Sessions 0-6 complete.
- He's read RisingWave docs (https://docs.risingwave.com).
- He's read `kt5_vibin_cloud.md` and any RisingWave-specific memory files.
- Tim Preble intro meeting **scheduled** (this is a hard gate — don't run Session 7 without it on the calendar).

---

## Agenda (90 min)

| Time | Topic |
|------|-------|
| 0–5 | Recap |
| 5–20 | What is RisingWave (deep, not surface) |
| 20–35 | Why Knight-Swift wants it — use cases |
| 35–55 | Architectural shape on iaac-eks |
| 55–70 | 4-week roadmap |
| 70–80 | Design doc outline |
| 80–90 | Kickoff plan for Tim Preble + Q&A |

---

## Section 1 — What is RisingWave (15 min)

### One-liner

**Streaming database** — Kafka in, materialized views computed continuously, Postgres-protocol query interface out.

### Architectural layers

```
                     ┌─────────────────┐
                     │   Frontend       │  Postgres protocol; SQL parsing
                     └────────┬────────┘
                              │
                     ┌────────┴────────┐
                     │   Meta service  │  cluster metadata in Postgres
                     └────────┬────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
       ┌──────────┐   ┌──────────┐    ┌──────────┐
       │ Compute  │   │ Compute  │    │ Compute  │   stateful, stream processing
       └────┬─────┘   └────┬─────┘    └────┬─────┘
            │              │               │
            └──────────────┼───────────────┘
                           ▼
                    ┌──────────────┐
                    │  Compactor   │   merges sst files
                    └──────┬───────┘
                           ▼
                    ┌──────────────┐
                    │   S3 (state) │   durable storage
                    └──────────────┘
```

**Components:**
- **Frontend** — accepts SQL, parses, plans. Stateless. Speaks Postgres wire protocol.
- **Meta** — cluster coordinator. Stores DDL state in Postgres (RDS).
- **Compute** — runs stream queries. Stateful (LSM tree, S3-backed). Scales horizontally.
- **Compactor** — background process merging SST files in S3.

### What it isn't

- Not a regular DB. You don't INSERT rows. You CREATE SOURCE FROM kafka, then CREATE MATERIALIZED VIEW.
- Not a data warehouse. Latency-optimized (sub-second), not throughput-optimized.
- Not a replacement for Postgres. Use it for derived/aggregated streaming views; not OLTP.

### Mental model

Think "Kafka Streams or Flink, but you write SQL instead of Java DSL, and queries are continuously kept fresh in the background, exposed via PG protocol."

---

## Section 2 — Why Knight-Swift wants it (15 min)

### Existing pain

Knight-Swift produces a lot of streaming events:
- Truck telemetry (GPS, speed, fuel, hours-of-service)
- Freight events (load tendered, picked up, in-transit, delivered)
- Customer interactions
- Driver compliance events

Right now this all goes into Kafka, then various downstream consumers (analytics, batch jobs, reporting) re-derive metrics from raw streams. Each consumer does its own aggregation. Inconsistencies arise. Latency varies.

### What RisingWave changes

Put a single materialized view layer in front of Kafka:
- `MV_active_loads` — every load currently in transit, refreshed continuously.
- `MV_driver_hours` — running totals of HOS per driver, current 7-day window.
- `MV_freight_kpis` — daily aggregates by lane, by customer.

Apps query MVs via Postgres protocol. Single source of truth. Sub-second freshness.

### Specific use cases (from Vibin / Tim discussions)

1. **Real-time dispatch dashboard** — operators need current truck/load state without waiting for batch ETL.
2. **Compliance monitoring** — HOS violations need to be flagged within minutes, not hours.
3. **Customer-facing freight tracking** — sub-second updates to "where is my freight" queries.
4. **Anomaly detection** — pattern queries over windowed events.

### Why now

Tim Preble (RisingWave SME) joined recently. Vibin signed off March 31. Q4 2026 brings AHV (on-prem hyperconverged storage), so the on-prem story for RW becomes viable. Now is the on-ramp.

### Idris's scope

Phase 1 (Idris's project): get RW deployed on **usx-dev EKS** with one toy materialized view consuming an existing kafka topic. Prove the deployment + ops loop works.

Phase 2 (later): production on usxpress-prod, real MVs, app team integration.

Phase 3 (Q4+): port to on-prem (op-usxpress-dev or its successor) once AHV is up.

---

## Section 3 — Architectural shape on iaac-eks (20 min)

### Deployment model

**Option A: RisingWave Operator + CR (recommended)**
- Install RisingWave Operator via Helm (CRD-based).
- Create a `RisingWave` CR that defines compute/meta/compactor/frontend nodes.
- Operator reconciles, creates StatefulSets, Services, etc.

**Option B: Plain Helm chart**
- Install RisingWave via the upstream Helm chart.
- Values define replicas/resources directly.

We'll go with **A** — operator is the upstream-recommended path, easier upgrade story.

### Required AWS resources

1. **S3 bucket for state store** — `risingwave-state-{env}-{account_id}`. Lifecycle policy: keep all (RW manages compaction). Encryption: SSE-S3 or KMS.

2. **IAM role for compute pods** — IRSA-trusted, policy includes:
   - `s3:GetObject`, `PutObject`, `DeleteObject` on the state bucket.
   - `s3:ListBucket` on the bucket.
   - Optional: KMS access if KMS-encrypted.

3. **RDS Postgres for metadata** — small instance (db.t3.micro for dev). RW meta service stores cluster state here.

4. **ECR access** — pull RisingWave images. They're publicly available, but mirroring to our ECR is recommended for prod.

5. **Networking** — RW frontend exposes port 4566 (PG protocol). For dev: ClusterIP. For prod: NLB or PrivateLink endpoint for app teams.

### Required K8s resources

- Namespace: `risingwave` (or `streaming`).
- ServiceAccount with IRSA annotation.
- Karpenter NodePool for RW (memory-optimized; tainted to dedicate).
- ServiceMonitor for Prometheus.
- (Optional) NetworkPolicy.

### TF module skeleton

```
iaac-eks/modules/addons/risingwave/
├── main.tf              # composition
├── variables.tf
├── outputs.tf
├── operator.tf          # helm_release for risingwave-operator
├── cluster.tf           # kubernetes_manifest for the RisingWave CR
├── s3.tf                # state-store bucket
├── iam.tf               # compute role + IRSA
├── postgres.tf          # RDS metadata DB
├── networking.tf        # Service definition (start with ClusterIP)
└── monitoring.tf        # ServiceMonitor + dashboards
```

`main.tf` for usx-dev:

```hcl
module "risingwave" {
  source = "./modules/addons/risingwave"
  count  = var.enable_risingwave ? 1 : 0

  cluster_name      = var.cluster_name
  env               = var.env
  account_id        = data.aws_caller_identity.current.account_id
  oidc_provider_arn = module.cluster.oidc_provider_arn
  oidc_issuer_url   = module.cluster.cluster_oidc_issuer_url

  state_store = {
    bucket_name = "risingwave-state-${var.env}"
    kms_key_arn = null  # no KMS for dev
  }

  metadata_db = {
    instance_class      = "db.t3.micro"
    allocated_storage   = 20
    backup_retention    = 7
  }

  compute = {
    replicas = 2
    cpu      = "2000m"
    memory   = "8Gi"
  }

  meta = {
    replicas = 1
    cpu      = "500m"
    memory   = "2Gi"
  }

  compactor = {
    replicas = 1
  }

  tags = local.tags
}
```

### Postgres metadata DB sizing decision

**For dev**: db.t3.micro is fine.
**For prod**: aurora-postgres-serverless v2 with 0.5–4 ACU. Don't undersize the meta DB; metadata ops can be heavy under churn.

### Karpenter NodePool

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: risingwave
spec:
  template:
    metadata:
      labels:
        workload: risingwave
    spec:
      taints:
      - key: dedicated
        value: risingwave
        effect: NoSchedule
      requirements:
      - key: karpenter.k8s.aws/instance-family
        operator: In
        values: [r6i, r6g]   # memory-optimized
      - key: karpenter.k8s.aws/instance-size
        operator: In
        values: [xlarge, 2xlarge]
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 5m
```

RW pods need toleration:
```yaml
tolerations:
- key: dedicated
  operator: Equal
  value: risingwave
  effect: NoSchedule
```

### Monitoring

RisingWave exposes metrics on port 1250 (configurable). ServiceMonitor:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: risingwave
  namespace: risingwave
spec:
  selector:
    matchLabels:
      risingwave-component: compute
  endpoints:
  - port: metrics
    interval: 30s
```

Dashboard: RisingWave provides reference Grafana dashboards. Mirror into iaac-monitoring.

---

## Section 4 — 4-week roadmap (15 min)

### Week 1 — Setup + design doc

- [ ] Day 1-2: read RisingWave docs cover-to-cover. Set up local docker-compose RW for hands-on.
- [ ] Day 3-4: write design doc (see Section 5).
- [ ] Day 5: Tim Preble intro meeting. Bring design doc as discussion starter.

### Week 2 — TF skeleton + dev deploy

- [ ] Day 6-7: build the iaac-eks/modules/addons/risingwave/ TF module skeleton. Reference an existing addon (cert-manager or external-secrets) for patterns.
- [ ] Day 8-9: PR review with Vibin + Dare. Iterate on naming, sizing, conventions.
- [ ] Day 10: deploy to usx-dev EKS via standard iaac-eks deploy flow (Octopus DevOps space → push release).

### Week 3 — Functional validation

- [ ] Day 11-12: connect to existing kafka topic (pick a low-traffic one — `truck-telemetry-test`?). Define a SOURCE.
- [ ] Day 13: create MV. Verify data flows.
- [ ] Day 14: query via psql client from a bastion pod. Verify Postgres protocol works.
- [ ] Day 15: hammer-test — increase compute replicas, generate load on Kafka, observe MV freshness.

### Week 4 — Observability + handoff

- [ ] Day 16-17: ServiceMonitor + Grafana dashboard. Validate alerts fire on simulated failures (kill compute pod).
- [ ] Day 18: write runbook for ops (deploy, scale, restart, troubleshoot).
- [ ] Day 19: demo to Vibin + Tim + Steve.
- [ ] Day 20: post-mortem; document open issues; plan Phase 2.

### Done criteria for Phase 1

- RW deployed on usx-dev EKS via TF.
- One MV consuming real Kafka data.
- Postgres-protocol query works from inside cluster.
- Prometheus metrics flowing; one Grafana dashboard.
- Runbook in Confluence.
- Design doc reviewed + approved.

---

## Section 5 — Design doc outline (10 min)

Idris owns this. Vibin reviews. Should land in Confluence at the end of week 1.

### Outline

```
RisingWave on USXpress — Design Doc
====================================

Author: Idris Fagbemi
Reviewers: Vibin Joseph, Tim Preble, Dare Oke
Status: Draft / Under Review / Approved
Date: TBD

1. Background
   - What is RisingWave (one paragraph)
   - Why Knight-Swift cares (use cases)

2. Goals & non-goals
   Goals: prove deployment, exercise iaac-eks pattern, deliver runbook
   Non-goals: production-ready, multi-tenant, on-prem

3. Architecture
   - Diagram: RW components + AWS resources
   - Data flow: kafka → SOURCE → MV → query
   - Networking model

4. Operational model
   - Sizing per env (dev/qa/prod)
   - Scaling: compute replicas, autoscaling considerations
   - Backup/restore
   - Upgrade strategy

5. Security
   - IRSA scope
   - S3 encryption
   - PG protocol auth (initially: ClusterIP only, no external auth)
   - Future: SCRAM/TLS

6. Cost
   - Estimate per env
   - Compute, RDS, S3 storage + transfer

7. Observability
   - Metrics: list of key metrics
   - Dashboards
   - Alerts: list of alert rules

8. Rollout plan
   - Week-by-week (the 4-week plan above)

9. Open questions
   - Network exposure (NLB? PrivateLink?)
   - On-prem migration plan (depends on AHV timeline)
   - Multi-region: needed? when?

10. Appendix: spec/MV examples
```

---

## Section 6 — Tim Preble kickoff plan (10 min)

Tim has RW expertise. Idris doesn't. Use Tim well.

### Before the meeting

- Idris reads docs.
- Idris drafts design doc to ~50%.
- Send draft + this onboarding plan to Tim 24h ahead.

### Meeting agenda (60 min)

1. Idris introduces himself + project (5 min).
2. Tim explains RW context — what he's seen work, what hasn't (15 min).
3. Walk through draft design doc together — Tim flags concerns (20 min).
4. Sizing + use-case discussion: which Kafka topics first? Which apps benefit? (15 min).
5. Open questions + next-meeting plan (5 min).

### After the meeting

- Update design doc.
- Set recurring weekly with Tim during Phase 1.

---

## Section 7 — Q&A + closing (5 min)

By now Idris has the platform context, his project context, and a plan. The next 4 weeks are execution.

### Things Dare commits to

- Daily 30-min office hours.
- Code review for every PR.
- Pair on the first Octopus deploy of RisingWave.
- Be a sounding board for design decisions.

### Things Idris commits to

- Send draft design doc by end of week 1.
- Weekly status update (5 bullets, send Friday).
- Flag blockers within 24h, not at end of week.
- Ask "dumb questions" liberally.

---

## Reference cheat sheet

| Thing | Value |
|---|---|
| Project | RisingWave on USXpress |
| Repo | `variant-inc/iaac-eks` (modules/addons/risingwave) |
| Cluster | `usxpress-dev` EKS first |
| AWS account | 700736442855 (USX-Dev) |
| Region | us-east-2 |
| RW version | latest stable (verify at https://github.com/risingwavelabs/risingwave/releases) |
| Operator chart | risingwavelabs/risingwave-operator |
| State bucket pattern | `risingwave-state-{env}-{account_id}` |
| Metadata DB | RDS Postgres (db.t3.micro for dev) |
| PG-protocol port | 4566 |
| Metrics port | 1250 |
| Karpenter NodePool | `risingwave` (memory-optimized r6i/r6g, tainted) |

---

## After Session 7

This is the last KT session. From here, Idris is a contributor, not an onboardee. Subsequent meetings are project work, not training.

Schedule:
- Weekly 1-on-1 with Dare (status, blockers, technical discussion).
- Weekly with Tim Preble during Phase 1.
- Bi-weekly with Vibin during PR review periods.
- Standup attendance per team norm.
