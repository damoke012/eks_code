# QA cluster stand-up — sprint execution workspace

**Ticket:** [INFRA-1585](https://usxpress.atlassian.net/browse/INFRA-1585) (In Progress)<br>
**Epic:** [INFRA-1560](https://usxpress.atlassian.net/browse/INFRA-1560) (22 sub-tickets, 136 pts)<br>
**Confluence design:** [4589191169](https://usxpress.atlassian.net/wiki/spaces/UI/pages/4589191169)<br>
**Delta doc:** [docs/architecture/qa_vs_dev_delta.md](../../docs/architecture/qa_vs_dev_delta.md)

## What this workspace holds

- Terraform drafts for the QA cluster (mirrors iaac-talos Dev pattern with QA-specific values)
- Flux Kustomization structure for op-qa branch of iaac-talos-flux-platform
- Sprint execution notes + checklist
- Any commands / apply outputs we want to preserve for the runbook

## Direction (locked 2026-07-01)

**Move fast. Iterate later.** Anything that can be a follow-up ticket IS a follow-up ticket. Concrete deferrals already agreed:

- Fault-domain: CP zone labels + host-level labels — deferred to [INFRA-1587](https://usxpress.atlassian.net/browse/INFRA-1587) (retrofits Dev + QA together)
- Design review with Idris: skipped ("we own this")
- Route 53 delegation: not needed (records inline in parent zone `usxpress.io` account 155768531003)

## Pre-flight results captured

| Check | Result | Reference |
|---|---|---|
| USX-QA account access | ✅ AdministratorAccess via SSO | Verified 2026-07-01 |
| Parent zone location | `155768531003`, no delegation for op-qa needed | `dig NS op-dev.usxpress.io` returned nothing |
| Cross-account IRSA trust | Wildcard `extd-usxpress-io-*` + `cert-manager-*` accepts QA-named roles | iaac-talos grep 2026-07-01 |
| Dev fault-domain audit | Workers a/b/c 2-2-3; CPs zone-less; no host labels | Deferred to INFRA-1587 |
| Direct write to 155768531003 | Not required for standard case | Cross-account assume-role flow |

## Execution phases (compressed)

### Phase 1 — Foundation (INFRA-1561..1563)

- [ ] AWS account boundary + SM path prefix + Route 53 cross-account IRSA (INFRA-1561)
- [ ] TF state bucket + DynamoDB lock + S3 CRR in USX-QA (INFRA-1562)
- [ ] ECR access + image promotion pattern from Dev-ECR to QA (INFRA-1563)

### Phase 2 — Cluster (INFRA-1564..1566)

- [ ] Talos VMs provisioned via vSphere provider (INFRA-1564)
- [ ] Three node pool architecture with labels/taints (INFRA-1565)
- [ ] vSphere fault-domain audit + DRS anti-affinity (INFRA-1566) — note: label populate deferred to 1587

### Phase 3 — Platform (INFRA-1567..1576)

- [ ] Flux bootstrap + Kustomizations (INFRA-1567)
- [ ] Identity management (INFRA-1568) — includes secure token ingress pattern for security partners
- [ ] Log management end-to-end (INFRA-1569)
- [ ] cert-manager + wildcard LE cert (INFRA-1570)
- [ ] External-Secrets + ClusterSecretStore (INFRA-1571)
- [ ] Velero + first PVC restore drill (INFRA-1572)
- [ ] etcd-backup CronJob (INFRA-1573)
- [ ] Rook-Ceph with OSD on application pool (INFRA-1574)
- [ ] Prometheus + Grafana + AAD SSO (INFRA-1575)
- [ ] Istio Gateway + DNS record (INFRA-1576)

### Phase 4 — Application + governance (INFRA-1577..1582)

- [ ] PSA tier policy (INFRA-1577)
- [ ] Kyverno + cosign (INFRA-1578)
- [ ] platform-app-expose chart multi-env (INFRA-1579)
- [ ] First app onboarded (INFRA-1580)
- [ ] Path-to-Prod gates (INFRA-1581)
- [ ] Full cluster restore drill → **declares production-ready** (INFRA-1582)

## Non-Terraform work to do in parallel

- iaac-talos: new branch `feature/op-usxpress-qa` from `feature/op-usxpress-dev`
- iaac-talos-flux-platform: new branch `op-qa` from `op-dev`
- Both PRs go to Doke for review + apply

## Follow-up tickets already filed

- [INFRA-1587](https://usxpress.atlassian.net/browse/INFRA-1587) — fault-domain retrofit (Dev + QA)
