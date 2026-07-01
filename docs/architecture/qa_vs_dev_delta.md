# op-usxpress-qa vs op-usxpress-dev — delta reference

**Status:** ACTIVE — living document tracking every deliberate difference between the QA on-prem cluster and the Dev cluster it mirrors.

**Related tickets:** INFRA-1585 (QA cluster stand-up coordination), INFRA-1560 (umbrella epic, 22 sub-tickets).

**Related design page:** Confluence 4589191169 (QA cluster stand-up + production readiness).

**Related memory:** [[qa-standup-design-jun25]], [[onprem-aad-identity-strategy-jun25]], [[secure-token-ingress-pattern]].

---

## Why this document exists

Dev was stood up incrementally, learning as we went. QA is the first cluster built deliberately to the standard Prod will be held to. Every difference from Dev is a *deliberate choice* — not a mistake, not a shortcut, and not something to retrofit later. This document is the point-in-time record of *what* is different and *why*.

If a decision is deferred back to "the Dev way" for QA, it must be recorded here with rationale.

---

## Cluster identity

| Property | Dev (op-usxpress-dev) | QA (op-usxpress-qa) | Why different |
|---|---|---|---|
| Cluster name | `op-usxpress-dev` | `op-usxpress-qa` | Environment naming convention |
| AWS account | USX-Dev (700736442855) | USX-QA (527101283767) | Per-env account boundary is Prod standard; INFRA-1561 |
| SM secret path prefix | `op-usxpress-dev/*` | `op-usxpress-qa/*` | IRSA policy scoped to prefix; blast radius isolation |
| DNS subdomain | `op-dev.usxpress.io` | `op-qa.usxpress.io` | Per-env subdomain; Let's Encrypt wildcard cert |
| Route 53 hosted zone location | USX-Dev account | USX-QA account | Cross-account NS delegation from `usxpress.io` at parent |
| Talos version | v1.32.0 | v1.32.x (latest patch at build time) | Match Dev unless upstream security fix warrants bump |
| API VIP | 10.10.82.50 | TBD (allocate in QA VLAN) | Physically distinct subnet |
| Cluster network CIDR | Dev subnet | QA subnet (allocate) | Physical isolation |

---

## Node topology

### Control plane

| Property | Dev | QA | Why |
|---|---|---|---|
| CP count | 3 | 3 | HA quorum |
| CP RAM | 8 GB (bumped from 4 after 2026-06-17 OOM incident) | **16 GB** | Prod-standard headroom; safely hosts CP-covering security agents (Wiz, etc.) with 256Mi hard cap without repeating the 2026-06-17 OOM cascade |
| CP vCPU | 4 | 4 | Adequate for control plane; kube-apiserver + etcd + scheduler + kcm not CPU-bound |
| CP disk | 100 GB | 100 GB | Room for etcd growth |
| CP IPs | .29, .179, .181 | Allocate 3 in QA VLAN | Physical distinct |
| Security agent placement | **CP-excluded** in Dev | **CP-included with 256Mi mem cap** | 16 GB CPs can safely host runtime security DaemonSets; keeps CP coverage (visibility on kube-apiserver, etcd, controller-manager) instead of dropping it |

### Worker pools

**Dev has a flat pool of 7 x 4GB workers.** QA has three pools with dedicated roles:

| Property | Dev (flat) | QA — System pool | QA — Platform pool | QA — Application pool |
|---|---|---|---|---|
| Node count | 7 | 2 | 3 | 5 |
| RAM per node | 4 GB | 8 GB | 16 GB | 32 GB |
| vCPU per node | 4 | 4 | 8 | 16 |
| Disk per node | ~50 GB | 100 GB | 200 GB | 300 GB |
| Taint | none | none | `pool=platform:NoSchedule` | `pool=application:NoSchedule` |
| Node label | none | `pool=system` | `pool=platform` | `pool=application` |
| What runs here | Everything (CNI, kube-proxy, ESO, cert-manager, monitoring, apps, RW) | CNI, kube-proxy, node-local-DNS, other essential DaemonSets | cert-manager, ESO, Velero, kube-prometheus-stack, Grafana, Loki, Kyverno | RisingWave, application namespaces, Rook-Ceph OSDs |
| Total (pool) | 28 GB / 28 vCPU | 16 GB / 8 vCPU | 48 GB / 24 vCPU | 160 GB / 80 vCPU |

**Why pool separation:** Dev had cases where an application pod OOMed a node hosting a critical DaemonSet, cascading. Isolation prevents this class of incident.

### Aggregate capacity

| Metric | Dev | QA | Delta |
|---|---|---|---|
| vCPU (workers + CPs) | 28 + 12 = 40 | 8 + 24 + 80 + 12 = 124 | **+84 vCPU** |
| RAM (workers + CPs) | 28 + 24 = 52 GB | 16 + 48 + 160 + 48 = **272 GB** | **+220 GB** |
| Disk (workers + CPs) | ~350 + 300 = 650 GB | 200 + 600 + 1500 + 300 = **2.6 TB** | **+~2 TB** |

Sanity: 3.1× the compute of Dev. QA hosts more platform workloads at production sizing (Loki, Grafana at prod-sized retention, Kyverno, etc.) so this is right.

---

## Fault-domain / DRS

| Property | Dev (verified 2026-07-01) | QA target | Why |
|---|---|---|---|
| CP zone labels | **None** — CPs have only `node-role.kubernetes.io/control-plane` | `topology.kubernetes.io/zone: op-usxpress-qa-{a,b,c}` set on CPs too | Fault-domain awareness at the control-plane level |
| Worker zone labels | ✅ Distributed across `op-usxpress-dev-{a,b,c}` in 2-2-3 pattern | `topology.kubernetes.io/zone: op-usxpress-qa-{a,b,c}` in even 3-3-x pattern per pool | topologySpreadConstraints already meaningful on workers |
| ESXi host label | **Not set on any node** | Set — either `topology.kubernetes.io/host` via vSphere CPI, or a Talos machine-config label | Visibility of physical placement; feeds Prometheus + Grafana |
| DRS anti-affinity rules | None | **Per-pool DRS rules** — no two nodes of same pool on same ESXi host | Single host failure doesn't take a pool |

**Dev's actual state (audit 2026-07-01):**
- Workers: real fault-domain distribution across 3 zones (a/b/c) — usable for topologySpreadConstraints today.
- CPs: no zone label — control plane not fault-domain aware.
- No host-level label on any node — can't visualize which ESXi host runs which pod.

**QA improvements:**
- CPs also get zone labels (Dev gap closed for QA from day one)
- Even 3-3-x distribution per pool (rather than 2-2-3 skew)
- Host-level label populated (vSphere CPI or Talos machine-config)

**Open question:** Whether the Talos vSphere provider surfaces ESXi host through the Node object automatically, or whether we need to set the label from Talos machine-config. Needs research before Phase 2.

---

## Identity

| Property | Dev | QA | Why |
|---|---|---|---|
| Human admin auth | Talos X.509 client certs (individual) | Same | Consistent |
| Workload auth to AWS | IRSA + OIDC to USX-Dev IAM | IRSA + OIDC to USX-QA IAM | Per-env account boundary |
| Grafana / observability SSO | (not enabled in Dev — deferred) | **AAD OIDC via shared Dev+QA App Registration** | INFRA-1559 hybrid AAD identity strategy — Dev + QA share the App Reg, Prod gets its own |
| Security partner (Wiz etc.) token ingress | 1Password → shared vault → Doke → AWS SM | **Scoped IAM role** `op-usxpress-qa-security-partner`; partner STS-assumes and writes directly to AWS SM | Prod-ready pattern per [[secure-token-ingress-pattern]] — plaintext never on Doke's machine; CloudTrail captures under partner identity |

---

## Log management

| Property | Dev | QA | Why |
|---|---|---|---|
| Log aggregation | None (kubectl logs only) | **Loki on platform pool** + fluent-bit DaemonSet | Prod-standard observability |
| Audit log verbosity | Default (Metadata) | **RequestResponse for high-value events, Metadata for routine, None for noise** | Prod-appropriate audit; policy captured in kube-apiserver audit-policy.yaml |
| Retention (hot) | N/A | 30 days | Reasonable working-window for operational debugging |
| Retention (cold) | N/A | 1 year for audit logs (S3 with lifecycle) | Compliance-adjacent baseline |
| Log storage backend | N/A | S3 (via Loki chunks store) | Cheap durable |

---

## Storage

| Property | Dev | QA | Why |
|---|---|---|---|
| Storage system | Rook-Ceph | Rook-Ceph | Same; proven pattern |
| OSD placement | Any worker | **Application pool only** | Isolates disk IO from control-path pods |
| Replication factor (block pool) | 3 | 3 | Same |
| Backup | Velero PVC backup to S3 (USX-Dev bucket) | Velero PVC backup to S3 (USX-QA bucket) | Per-env account boundary |
| etcd snapshot to S3 | Yes (USX-Dev) | Yes (USX-QA) | Per-env account boundary |
| Full-cluster restore drill | Done 2026-06-23 | **Required within 30 days of stand-up; is the gate for "production-ready" declaration** | This is INFRA-1582 |

---

## DR posture

| Scenario | Dev RTO (aspirational) | QA RTO (target) | Notes |
|---|---|---|---|
| Single worker loss | 15 min | 15 min | Karpenter-equivalent doesn't exist on-prem; manual VM re-provision via Terraform |
| Single CP loss | 30 min | 30 min | 2/3 quorum survives; replace via Talos machine-config |
| Two CP loss | Not tested | 2 hr | Restore from etcd snapshot + rebuild |
| Full cluster loss | Not tested | 4 hr | Restore from etcd + Velero + Flux reconciliation |
| Datacenter loss | Undefined | Days (documented) | Requires manual re-provision at alt DC; scope of Phase 5 |

---

## Policy baseline

| Property | Dev | QA | Why |
|---|---|---|---|
| Pod Security Admission | privileged (unrestricted) | **restricted on application namespaces; baseline on platform namespaces** | Prod standard |
| Kyverno | Not installed | **Installed with verifyImages (cosign) + approved-registry list + NetworkPolicy-required** | Prod baseline |
| NetworkPolicy | Not enforced | Enforced per-namespace | Zero-trust default |
| Image signature verification | No | **cosign signature required for all images from approved registries** | Supply-chain integrity |

---

## Image promotion

| Property | Dev | QA | Why |
|---|---|---|---|
| Image source | ECR (064859874041 devops/ECR) or upstream | Same ECR, **same SHA re-tagged from Dev** | No rebuild between environments; Prod-standard promotion |
| Promotion gate | Manual push to Dev branch | **cosign signature applied at each promotion; branch-protected per-env Flux branches** | Prod-standard promotion pattern |

---

## Route 53 self-serve

We provision the `op-qa.usxpress.io` hosted zone **ourselves** via Terraform.

**Parent zone location (verified 2026-07-01 by grepping iaac-talos):** The `usxpress.io` Route 53 hosted zones live in AWS account **`155768531003`** (shared DNS account, not previously in memory). The `iaac-route53-zone` IAM role in that account holds Route 53 write and is assumed cross-account via IRSA.

**Wildcard trust is already in place.** The trust policy on `iaac-route53-zone` accepts role name patterns from any AWS account:
- `extd-usxpress-io-*` — external-dns roles per cluster
- `cert-manager-*` — cert-manager DNS-01 solver roles

**Implication:** for the standard cluster-level DNS pattern (external-dns + cert-manager), we do NOT need to modify anything in `155768531003`. Our QA cluster's `extd-usxpress-io-op-usxpress-qa` and `cert-manager-op-usxpress-qa` roles will match the wildcard automatically.

**Architectural fact (verified 2026-07-01 via `dig NS op-dev.usxpress.io`):**

`op-dev.usxpress.io` is **NOT a delegated hosted zone**. All Dev DNS records (e.g., `grafana.op-dev.usxpress.io`, `rw-2.op-dev.usxpress.io`) live inline in the parent `usxpress.io` zone in account `155768531003`. Confirmed by the parent's NS servers: `ns-709.awsdns-24.net`, `ns-1577.awsdns-05.co.uk`, `ns-251.awsdns-31.com`, `ns-1172.awsdns-18.org` — all AWS Route 53.

**QA follows the same pattern:** no hosted zone creation, no NS delegation. Records for `*.op-qa.usxpress.io` live inline in the parent `usxpress.io` zone.

**What we actually need to do:**

1. On the cluster side (self-serve in USX-QA):
   - external-dns IRSA role `extd-usxpress-io-op-usxpress-qa` — matches the wildcard trust automatically
   - cert-manager IRSA role `cert-manager-op-usxpress-qa` — matches the wildcard trust automatically
   - Both roles assume `arn:aws:iam::155768531003:role/iaac-route53-zone`
   - external-dns writes records to `usxpress.io` with FQDNs like `grafana.op-qa.usxpress.io` — allowed by the wildcard trust
   - cert-manager writes DNS-01 challenge TXT records for `*.op-qa.usxpress.io` — allowed by the wildcard trust

2. No Terraform changes in 155768531003 required for the standard case.

3. Manual record additions (rare, e.g., static apex records or non-external-dns-managed entries) would require someone with write access to the parent zone. Track case-by-case.

**Access to `155768531003`:** confirm Doke's write access if we ever need direct TF against the parent zone. For the standard external-dns + cert-manager flow, **no direct write access to `155768531003` is required** — the cross-account assume-role path handles everything.

**Big simplification** vs the original plan: no DNS-account Terraform work needed for the standard QA cluster stand-up.

References:
- Memory: [[aws-account-155768531003-iaac-route53-zone]]
- Memory: [[onprem-route53-wildcard-trust-discovery]]

---

## What we are NOT changing from Dev

Listed explicitly so future readers know these were deliberate defaults, not oversights:

- Talos as the OS
- Cilium as the CNI (with node-reconciler LIVE — auto-remediates 4 divergence modes per [[cilium-node-reconciler-live-jun18]])
- Flux GitOps
- kube-prometheus-stack for metrics scrape
- Grafana for dashboards
- cert-manager + LE wildcard cert
- External-Secrets Operator + AWS SM as the source of truth
- Istio for gateway + mesh
- Bitnami legacy image migration (already resolved)

---

## Sub-ticket coverage matrix

| Delta above | Covered by INFRA sub-ticket |
|---|---|
| Per-env AWS account boundary + SM path + Route 53 zone | INFRA-1561 |
| TF state bucket + CRR + DynamoDB lock | INFRA-1562 |
| ECR access pattern + image promotion gate | INFRA-1563 |
| Talos cluster provisioning (VMs, networking, machine config) | INFRA-1564 |
| Three node pool architecture with labels + taints | INFRA-1565 |
| vSphere fault-domain audit + DRS anti-affinity | INFRA-1566 |
| Flux bootstrap + Kustomizations | INFRA-1567 |
| Identity management (admin certs + IRSA + AAD SSO + scoped security-partner IAM role) | INFRA-1568 |
| Log management end-to-end (Loki + fluent-bit + audit policy + S3 cold) | INFRA-1569 |
| cert-manager + wildcard cert for `*.op-qa.usxpress.io` | INFRA-1570 |
| External-Secrets Operator + ClusterSecretStore | INFRA-1571 |
| Velero + DR pre/post checks + first PVC restore drill | INFRA-1572 |
| etcd-backup CronJob to S3 | INFRA-1573 |
| Rook-Ceph with OSD placement on application pool | INFRA-1574 |
| Prometheus + Grafana + AAD SSO + baseline dashboard | INFRA-1575 |
| Istio Gateway + DNS record for op-qa.usxpress.io | INFRA-1576 |
| PSA tier policy enforcement | INFRA-1577 |
| Kyverno policy baseline + image signing with cosign | INFRA-1578 |
| Generalize platform-app-expose chart for multi-env | INFRA-1579 |
| Onboard first application to QA via generalised chart | INFRA-1580 |
| Path-to-Production gates (branch protection + Octopus approvals) | INFRA-1581 |
| Full cluster loss restore drill (declares production-ready) | INFRA-1582 |

---

## Changelog

- **2026-07-01:** Initial version; captures all deltas from the QA design page 4589191169 + INFRA-1585 kickoff.
