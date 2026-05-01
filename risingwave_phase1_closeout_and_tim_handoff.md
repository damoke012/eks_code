# RisingWave Phase 1 — Closeout & Tim Handoff Status

**As of 2026-04-30**, prepared for Dare's PTO (May 4-9), authoritative reference for Idris during PTO and Dare on return.

This document synthesizes:
- Multi-session work April 28-30 to bring RisingWave up on `op-usxpress-dev` (cluster setup, IAM/IRSA, operator install, networking, GitOps wiring)
- Three meetings April 30:
  - **Cluster Access & Secrets Management** (Dare ↔ Idris)
  - **RW On-Prem Deployment Progress Update** (James/Dare, Tim, Idris, Buddy, Cloud Engineer) — biweekly cadence kicked off
  - **Setting Up Secure Secret Manager Integration** (Dare ↔ Idris)

---

## Executive summary

Phase 1 platform deployment is **functionally complete**. RisingWave v2.8.2 is up, Postgres metastore running, IRSA→S3 verified, both internal (ClusterIP) and external (NodePort) SQL endpoints work, GitOps wiring proven for the external Service. Tim is the consumer for Phase 2 (Kafka sources, materialized views, SQL pipelines). Tim will be onboarded Friday afternoon (cluster access, config files share, RW Slack POC channel).

**The remaining Phase 1 closeout work** — capture the rest of the deployment as IaC, set up the proper CI/CD pipeline (GHA + Octopus + Flux pattern, mirror of `iaac-talos`), and integrate AWS SM for secrets — happens during PTO (Idris autonomously) and post-PTO (Dare returns May 12).

---

## What's running today on op-usxpress-dev

### Cluster-side state

| Component | State | Owner / source |
|---|---|---|
| Talos cluster `op-usxpress-dev` | Healthy, 3 CP + 5 workers, v1.32.0 | iaac-talos repo |
| Namespace `risingwave` | Created, labeled `purpose=streaming-db`, `istio.io/dataplane-mode=ambient` | Hand-applied (NOT in git) |
| ServiceAccount `risingwave/risingwave` with IRSA annotation | Annotated `eks.amazonaws.com/role-arn=arn:aws:iam::700736442855:role/op-usxpress-dev-risingwave` | Hand-applied (NOT in git) |
| RW operator (`risingwavelabs/risingwave-operator` Helm chart) | Installed in `risingwave-operator-system` namespace, watching cluster-wide | `helm install` (NOT in git) |
| `RisingWave` CR | Running=True, v2.8.2, MetaStore=PostgreSQL, StateStore=S3 | `kubectl apply` (NOT in git) |
| Postgres metastore (StatefulSet `pg-postgresql-0`) | 1/1 Running, hand-rolled | `kubectl apply` (NOT in git) |
| External SQL Service `risingwave-frontend-lb` (NodePort 32567) | Flux-managed | iaac-talos-flux-platform/infrastructure/risingwave/frontend-lb.yaml (op-dev branch, commit 70f3b70) |
| Flux Kustomization `risingwave` | Ready=True, applied revision op-dev@sha1:6b3e9bc9 | iaac-talos-flux-cluster/clusters/bm-dev/flux-system/infra.yaml (master, commit b86a8bc) |
| RW root password | Set via `ALTER USER` once (`WLThdeIQznAJ9RxSdWV3SaCFMY1yFjO1`) | NOT in AWS SM yet — manual one-time |
| Postgres credentials | Hardcoded in StatefulSet (default RW/RW values) | NOT in AWS SM yet |

### AWS-side state

| Resource | ARN / Name |
|---|---|
| S3 state bucket | `risingwave-state-op-usxpress-dev` (us-east-2, encrypted, versioned, public access blocked) |
| IAM role | `arn:aws:iam::700736442855:role/op-usxpress-dev-risingwave` |
| IAM policy | `op-usxpress-dev-risingwave-s3` (S3 R/W on bucket) |
| OIDC issuer trusted | `d3a7wcnazdrd6p.cloudfront.net` |
| IRSA trust scope | `system:serviceaccount:risingwave:risingwave` (strict) |

### What's verified working

- ✅ psql round-trip (DDL + DML + SELECT)
- ✅ IRSA → S3 (`hummock_*/` prefixes written by RW compute)
- ✅ All RW pods 1/1 Running (meta, compute, frontend, compactor)
- ✅ External SQL Service via VPN (`psql -h 10.10.82.26 -p 32567 -d dev -U root`)
- ✅ In-cluster DNS path (`risingwave-frontend.risingwave.svc.cluster.local:4567`)
- ✅ Built-in RW Dashboard via port-forward (`http://localhost:5691` after `kubectl port-forward svc/risingwave-meta 5691:5691`)
- ✅ GitOps loop for the NodePort Service (delete → Flux recreates from git)
- ✅ Flux ownership labels on the Service

---

## Endpoints

| Path | Address | Use case | Source-of-truth in git? |
|---|---|---|---|
| **In-cluster SQL** (operator-managed ClusterIP) | `risingwave-frontend.risingwave.svc.cluster.local:4567` | Tim's Kafka pipelines, MV jobs, in-cluster apps | Operator-managed (no git, that's correct) |
| **External SQL** (Flux-managed NodePort) | `psql -h 10.10.82.26 -p 32567 -d dev -U root` | Humans on USXpress VPN, BI tools, pgAdmin | ✅ Yes |
| **Dashboard (UI)** — currently | `http://localhost:5691` after port-forward | Operational debugging, streaming graph view | Port-forward only (NodePort manifest pending — drafted in this doc) |
| **Future Dashboard NodePort** | `http://10.10.82.26:32569` (proposed) | Same as above, no port-forward | Pending commit |

**Auth**:
- RW user: `root`, password: `WLThdeIQznAJ9RxSdWV3SaCFMY1yFjO1` (rotate before any prod)
- Database: `dev`
- TLS: not configured (dev cluster, plaintext acceptable)

---

## Decisions (from the meetings)

### From "RW On-Prem Deployment Progress Update" (biweekly kickoff)

| Decision | Rationale |
|---|---|
| **Mongo: cloud Atlas, not local** | USXpress already has cloud Atlas dev space. No on-prem Mongo licensing. Buddy/Cloud Engineer + James agreed. Tim accepts. |
| **Bi-weekly check-in cadence** | Standing meeting, can move; James not married to current time |
| **Tim's scope: super-user in `risingwave` namespace only** | Not cluster-wide. Includes Postgres in same namespace. Least privilege. |
| **Phase 3: on-prem SQL Server access for RW native connector** | Deferred. Not this week, not this month. Future capability. |
| **S3 state bucket: read-only for app team** | "Let the need drive the necessity" — only grant write access if Tim hits a specific debug case |
| **Tim ↔ Idris meeting next week (during PTO)** | Recorded so Dare can catch up on return. James to coordinate. |
| **Tim/Idris/Dare added to RW Slack POC channel** | Tim added all three. Run LLM bot is preferred Q&A path. |

### From "Cluster Access & Secrets Management" (Dare ↔ Idris)

| Decision | Detail |
|---|---|
| **AWS SM as source of truth for credentials** | Postgres user/password, RW root password, license key — all in AWS SM with ExternalSecret pulling into k8s |
| **No port-forwarding for Tim** | NodePort is the path. Idris to disable any leftover port-forward demo configs. |
| **License setup (RW premium) deferred** | Tim coordinates with Zach for premium key extension. Not today. Once SM is set up, then revisit. |
| **User creation = SQL via kubectl** | RW users live in Postgres metadata, not k8s. Step-by-step doc for Tim. Eventually: Bootstrap Job pattern (drafted below). |

### From "Setting Up Secure Secret Manager Integration" (Dare ↔ Idris)

| Decision | Detail |
|---|---|
| **Don't tear down current setup** | Just add SM + ExternalSecret on top. Migration in place. |
| **Both root and regular user creds go to SM** | `op-usxpress-dev/risingwave/root` and `op-usxpress-dev/risingwave/postgres` |
| **Secret needs better encryption than k8s base64 long-term** | k8s secrets are encoded, not encrypted. Future: KMS-backed etcd encryption or external secret operators. Document for Tim now. |
| **Document the secret creation process for Tim** | Step-by-step doc — manual SQL via kubectl for now, declarative Bootstrap Job pattern when CI/CD is wired |

---

## Tim's Day-1 priorities (Friday handoff)

From the meeting transcript:

1. **Connection details** — psql endpoint + dashboard
2. **Authentication / Secret management** — how creds are managed, how to add users
3. **Verify Kafka reachability** — can the cluster's RW reach the existing Kafka?
4. **Build a basic pipeline** — employee enrichment as a smoke test
5. **Premium key extension** — coordinate with Zach (RW Director of Product)

### What Tim will do himself once he has access

- Test psql via VPN endpoint
- Browse the Dashboard
- Try creating a Kafka source
- Basic CDC table → enrichment MV

### What Idris should walk him through

- Where credentials live (k8s Secret today, SM-backed later)
- How to connect from his sandbox (Tim has a Red Hat POC server demo to compare)
- Config file shape (operator chart values, RW CR YAML)
- The Slack POC channel + Run LLM bot for RW Labs Q&A

---

## Open questions

| Question | Owner | Status |
|---|---|---|
| When does Tim get RW premium key extended for our cluster? | Tim ↔ Zach | Tim will coordinate. Once we have AWS SM bridge, the license slots in via ExternalSecret. |
| Does the cluster already have Kafka access wired up? | Confirmed yes by James in meeting. Worth Tim verifying with a real source. | ✅ |
| LDAP / SSO integration for RW users? | Phase 3+. Tim mentioned in passing. | Deferred |
| PGvector setup for Tim's RAG work | Tim to specify in pipeline req | Pending |
| MCP server for RW (RW Labs ships one) | Tim — once basic pipelines work | Pending |
| Network team: BGP / static routes for VPN-reachable LB IPs | Dare to engage post-PTO | Drafted ask in this doc |
| Service Desk: corporate root CA fetchable internally | Dare to engage post-PTO | Blocking Idris's terraform install today |
| `iaac-risingwave` repo: unarchive vs new repo (`iaac-risingwave-onprem`) | Vibin (post-PTO) or on-prem team self-decides | Stop-gap: manifests in `iaac-talos-flux-platform` |

---

## Architecture decisions (durable knowledge)

### Why NodePort, not LoadBalancer

Cilium uses **L2/ARP** for LB advertisement (no BGP on-prem). L2/ARP claims the IP only on the cluster's L2 broadcast domain. **VPN clients are routed in from a different segment**, and routers don't relay ARP. Result: LB VIPs are invisible to VPN clients. We tried `10.10.82.221`, worked from inside cluster, timed out from VPN. Pivoted to NodePort because **worker IPs are routable from VPN** (proven via API VIP at `10.10.82.50`).

**Talos blocks NodePort on control plane nodes by default** — must use worker IPs. The 5 workers: `.26 .27 .28 .178 .180`. Pin to `10.10.82.26` as canonical.

When BGP exists at the network layer, we can flip back to LoadBalancer — same Flux machinery, just edit the manifest.

### Secret management: dual approach

| Tier | Secret | Source-of-truth |
|---|---|---|
| Cluster-level credentials | RW root password, Postgres user/password | **AWS SM** → ExternalSecret → k8s Secret → consumed by Bootstrap Job / RW CR |
| SQL pipeline secrets | Kafka URLs, tokens, connection strings (Tim's domain) | Either: AWS SM via ExternalSecret + manually consumed, OR: **RW built-in Secret Manager** (premium feature, requires license extension) |
| RW premium license key | License string from RW Labs | AWS SM → ExternalSecret → mounted into RW operator |

RW's built-in Secret Manager doesn't directly integrate with AWS SM (Tim confirmed via the `Run LLM` query). Two backends: meta (Postgres) or HashiCorp Vault. We'll bridge via ExternalSecret pulling from SM into k8s, then either RW reads the k8s Secret or we further inject into RW's Secret Manager.

### CI/CD pattern: mirror `iaac-talos`

Vibin's "RW lives outside DX/Octopus/mage-runner" directive was about app-deploy pipelines. Platform IaC at USXpress uses Octopus too — see [iaac-talos/.github/workflows/octo.yaml](iaac-talos/.github/workflows/octo.yaml): GHA validates → Octopus deploys via `deploy/` scripts → Terraform apply.

RW gets the same pattern in `iaac-risingwave-onprem` (or wherever it lands):

```
PR opened
  → GHA validates (kubeval + tflint + helm template + kustomize build)
PR merged to op-dev
  → GHA "octo" stage packages + sends release to Octopus "iaac-risingwave" project
  → Octopus runs deploy/deploy.sh: terraform apply + cluster-bootstrap (SM secrets, namespace, etc.)
  → Flux reconciles K8s manifests → cluster
  → GHA Flyway-migrate (Phase 2, Tim) post-merge: SQL migrations
```

### Bootstrap Job pattern for SQL-managed config

RW users live in Postgres metadata, NOT as Kubernetes resources. We can't create a `User` CRD. SQL is the only API for setting passwords / GRANTs. Solution: a Kubernetes Job that runs psql against RW with SM-sourced credentials. Idempotent (re-runs on every Flux reconcile, no-op if already correct).

Same pattern works for any RW user, GRANT, initial DDL, license key application. Once Tim brings Flyway online, this absorbs into Flyway migrations naturally.

### iaac-risingwave repo status

`variant-inc/iaac-risingwave` was archived **Sep 4, 2025** by an earlier abandoned attempt (only template scaffolding, 5 commits). We can't push to it.

Current stop-gap: manifests in `iaac-talos-flux-platform/infrastructure/risingwave/` (works, follows existing platform-component pattern alongside cilium-lb, prometheus, keda).

Long-term home (post-PTO decision): either ask Vibin to unarchive, or create new `variant-inc/iaac-risingwave-onprem` (mirrors `iaac-octopus-onprem` precedent for on-prem-team-owned platform repos). The CI/CD pipeline (GHA + Octopus + TF + Flyway migrations) needs a dedicated repo because it doesn't fit cleanly into flux-platform.

### Corporate CA on WSL: durable bootstrap script needed

USXpress proxy does SSL inspection. WSL doesn't trust corp CA out of the box. Symptoms:
- `helm install` → x509 error
- `terraform init` (downloading from `releases.hashicorp.com`) → x509 error
- Any HTTPS to public host

Today: each engineer hand-installs the cert (Idris stuck on this for terraform). Production-grade fix: a bootstrap script in version control that any new engineer runs once. Drafted below.

---

## Next steps by owner

### Idris (PTO week May 4-9)

**Priority 1 — Friday afternoon (today): Tim handoff**
- [ ] Walk Tim through psql access at `10.10.82.26:32567`
- [ ] Share operator chart values, RW CR YAML, Postgres StatefulSet manifest
- [ ] Demo the Dashboard (port-forward today; commit NodePort manifest in parallel)
- [ ] Confirm Tim added to RW Slack POC channel
- [ ] Hand off this doc as the master reference

**Priority 2 — During PTO**
- [ ] Continue building `iaac-risingwave-onprem` local tree (matches structure in [risingwave_repo_structure_guide.md](risingwave_repo_structure_guide.md))
- [ ] Capture hand-rolled deploy as IaC into `iaac-talos-flux-platform/infrastructure/risingwave/` (interim home):
  - [ ] Operator HelmRelease (translate from `helm install`)
  - [ ] RisingWave CR (`kubectl get rw risingwave -n risingwave -o yaml > ...`)
  - [ ] Postgres StatefulSet (or migrate to Bitnami chart once corp-CA fixed)
  - [ ] ServiceAccount + IRSA annotation
  - [ ] ExternalSecrets for `pg-credentials` and `rw-root-credentials`
  - [ ] Bootstrap Job for RW root password (manifest drafted below)
  - [ ] Dashboard NodePort Service (manifest drafted below)
- [ ] Recorded meeting with Tim — Phase 2 walkthrough, demo of Tim's POC Red Hat server, demo of his RAG pipeline
- [ ] AWS SM seeding: via GHA workflow (drafted below) OR manually:
  - `op-usxpress-dev/risingwave/postgres` (username/password/postgres-password)
  - `op-usxpress-dev/risingwave/root` (password)
- [ ] Get USXpress corp CA installed in WSL (unblock terraform install)
- [ ] Set up Prometheus/Grafana ServiceMonitor for RW metrics (chart already there, Idris just wires it up)

**Priority 3 — Defer to post-PTO pairing**
- iaac-risingwave-onprem repo creation + Octopus project structure (paired with Dare)
- Migration of manifests from flux-platform → iaac-risingwave-onprem
- Cluster-dir rename (`bm-dev/` → `op-usxpress-dev/`)
- Network team engagement
- Service Desk corp-CA distribution

### Dare (post-PTO, May 12+)

- [ ] Pair with Idris on `iaac-risingwave-onprem` repo + Octopus project structure
- [ ] Send network team ask (drafted below)
- [ ] Send Service Desk ask for corp-CA fetchable endpoint
- [ ] Premium RW key extension coordination (Tim leads, Dare supports SM integration)
- [ ] Cluster-dir rename
- [ ] Review what Idris built during PTO; close any GitOps-debt gaps

### Tim

- [ ] Sign in to RW Slack POC channel (done — Idris/Dare added)
- [ ] Build first basic pipeline (employee enrichment) on dev cluster
- [ ] Coordinate Zach for premium key extension
- [ ] PGvector / RAG pipeline setup
- [ ] MCP server installation (when ready)
- [ ] Phase 3 deferred: on-prem SQL Server connector

### Network team (Dare to engage post-PTO)

- [ ] Discuss BGP peering vs static routes for LB pool reachability from VPN
- [ ] Either: BGP between Cilium on workers and corp router, or static routes for `10.10.82.220-240` → worker IPs

### Service Desk (Dare to engage post-PTO)

- [ ] Provide USXpress corporate root CA fetchable from internal endpoint
- [ ] (Probably already exists somewhere — need to find canonical location)

### Vibin (post-PTO)

- [ ] Unarchive `variant-inc/iaac-risingwave` OR confirm OK to use new `iaac-risingwave-onprem`
- [ ] Confirm cluster placement direction (on-prem-first vs EKS-first) — current direction is on-prem-first per Steve

---

## Action items being executed RIGHT NOW (codespace-side)

Items that don't require WSL or external coordination — drafted and committed to `damoke012/eks_code` in this commit:

- [x] This synthesis document
- [x] GHA workflow draft for AWS SM secret seeding (`onprem-cluster-secrets-rw.yaml` mirror of iaac-talos pattern)
- [x] ExternalSecret + Bootstrap Job manifests for RW root and Postgres credentials
- [x] Dashboard NodePort Service manifest
- [x] Network team ask doc
- [x] WSL corp-CA + dev tools bootstrap script
- [x] Memory updated with all meeting decisions

Idris/Dare can copy these artifacts directly when they have WSL access.

---

## Reference: drafted artifacts (this repo)

All in [risingwave_iaac_artifacts/](risingwave_iaac_artifacts/):

- `cluster-secrets-rw.yaml` — GHA workflow to seed AWS SM secrets (`op-usxpress-dev/risingwave/{root,postgres,license}`)
- `manifests-pg-externalsecret.yaml` — ExternalSecret pulling Postgres creds
- `manifests-rw-root-externalsecret.yaml` — ExternalSecret pulling RW root password
- `manifests-rw-bootstrap-job.yaml` — Job that runs `ALTER USER root` from SM-sourced password
- `manifests-dashboard-ext.yaml` — NodePort Service for RW Dashboard
- `network-team-ask.md` — formal ask for BGP / static routes
- `wsl-bootstrap.sh` — WSL setup script (corp-CA install + standard dev tools)

These all need to be committed to `iaac-talos-flux-platform/infrastructure/risingwave/` (or future `iaac-risingwave-onprem`) on `op-dev` branch — Idris pushes from WSL.

---

## Memory references

Persistent context for future sessions:

- [risingwave_onprem_progress.md](memory/risingwave_onprem_progress.md) — current Phase 1 state
- [onprem_external_access_l2_vs_nodeport.md](memory/onprem_external_access_l2_vs_nodeport.md) — L2 LB vs NodePort gotcha
- [onprem_flux_repo_layout.md](memory/onprem_flux_repo_layout.md) — repo branch/dir mapping
- [iaac_risingwave_archived.md](memory/iaac_risingwave_archived.md) — repo archival blocker
- [wsl_corp_ca_helm_cert_gotcha.md](memory/wsl_corp_ca_helm_cert_gotcha.md) — corp-CA root cause
- [feedback_onprem_owns_endtoend.md](memory/feedback_onprem_owns_endtoend.md) — on-prem team ownership rule
- [risingwave_repo_structure_guide.md](risingwave_repo_structure_guide.md) — full repo layout blueprint
- [risingwave_onprem_platform.md](risingwave_onprem_platform.md) — comprehensive platform reference

---

## Bottom line

Phase 1 platform work is done. Tim is unblocked for Friday. The remaining work is **GitOps closeout** (capturing hand-rolled state into git) + **CI/CD pipeline build-out** (mirror iaac-talos). Idris owns this during PTO with the artifacts drafted below. Post-PTO pairing with Dare for the structural decisions (repo home, Octopus project, network engagement).

No external dependencies on the critical path. On-prem team owns end-to-end.
