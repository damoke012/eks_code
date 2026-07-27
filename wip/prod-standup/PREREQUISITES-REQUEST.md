# op-usxpress-prod — prerequisite requests (INFRA-1621)

Four teams own the values that block the prod build. Each section below is written to
be pasted straight into a ticket or Teams thread. The prod scaffolding (tfvars, Octopus
var script, runbook, gates) is already built and validated against QA — these values are
the only thing standing between us and a first apply.

**Why this format:** every one of these is a value that, if guessed wrong, deploys clean
and fails invisibly (INFRA-1623 cost us 13 silent days on exactly this class). So I'm not
inferring any of them — I'm asking the owner and gating the apply until they answer.

---

## 1 → Cloud team — AWS account + state bucket + IRSA

**What I need:**
1. **Confirm the prod AWS account is `937464026810`** (ops-controller / usxpress-prod).
   I've inferred this from the established pattern — op-dev uses the dev cloud account
   `700736442855`, op-qa uses the qa account `527101283767`, so op-prod should reuse the
   prod cloud account. **Confirm or correct before we bake it into IAM and the backend.**
2. **A Terraform state bucket in that account** for `iaac/talos/op-usxpress-prod.tfstate`
   (per-account, same shape as QA's `lazy-tf-state-425rbol87rmn6c7m`). Name it and grant
   the Octopus worker role write.
3. **IRSA (phase 2, not blocking first apply):** `ONPREM_BOOTSTRAP_ROLE_ARN_PROD` and the
   OIDC bucket name, same as you dropped for QA. We stand up with IRSA off and flip it on
   once these exist.

**Why it blocks:** without the account + bucket, `terraform init` can't even resolve the
backend. This is the first thing the build touches.

---

## 2 → Networking — prod VIP + node IP plan

**What I need:** the IP allocation for op-usxpress-prod —
- **Control-plane VIP** (single address, the API endpoint)
- **Node IP ranges** for 3 control-plane + ~10 worker VMs

**Why it blocks, specifically:** this is the exact field that carried dev's VIP
`10.10.82.50` into QA's etcd-backup CronJob and produced 13 days of silent backup failure.
The prod manifests are parameterised to take this value — I will not hardcode a guess.
One wrong digit here is a cluster that looks up but can't back up its own control plane.

For reference, QA's VIP is `10.10.82.51` on vLAN 82. Is prod on the same vLAN or dedicated?
(That question also drives §4.)

---

## 3 → Networking / CySec — DNS domain

**What I need:** the DNS domain/zone for prod ingress and service hostnames.

**Why it blocks:** external-dns `txt-owner-id`, all ingress hostnames, and the OIDC
CloudFront issuer for IRSA all derive from this. Related live issue you should know about:
QA's external-dns is currently writing TXT records owned by `op-usxpress-dev` (a
branch-copy bug we're fixing this week) — I want prod's ownership id correct from birth,
not corrected after an incident.

---

## 4 → Infra / vSphere — capacity + placement

**What I need:** vSphere placement for the prod VMs —
- **datacenter / vm_cluster_name**
- **datastore** (QA uses `USXD1NTXPROD-SC1`)
- **network_name** (QA uses `10.10.82 (vLAN 82) Prod` — note: QA already rides a network
  labelled "Prod"; confirm whether prod gets a dedicated vLAN or shares it)
- **content library + Talos image item** (QA uses `talos-v1.11.1`)
- **capacity confirmation** for the sizing below

**Sizing (mirrors QA by design — "QA mirrors prod"):**
| Pool | Count | vCPU | RAM | Disk | Ceph |
|---|---|---|---|---|---|
| control-plane | 3 | 4 | 16 GB | — | — |
| system | 2 | 4 | 8 GB | 100 GB | — |
| platform | 3 | 8 | 16 GB | 200 GB | — |
| application | 5 | 16 | 32 GB | 300 GB | 500 GB |

Total ≈ 13 VMs. Confirm the cluster has headroom, or tell me the ceiling and I'll resize.

**Why it blocks:** no placement = the VMs have nowhere to land. Terraform's vSphere
provider needs every one of these by name.

---

## Turnaround

§1 (account + bucket) and §2 (VIP) are the two on the true critical path — nothing inits
without §1, nothing backs up correctly without §2. §3 and §4 are needed before Flux
bootstrap and VM creation respectively, a step later. If we get §1 and §2 back this week,
the parallel QA-hardening track (E2/E3) finishes in the same window and prod can cut a
clean branch immediately after.
