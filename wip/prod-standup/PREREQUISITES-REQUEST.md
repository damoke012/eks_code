# op-usxpress-prod — prerequisite requests (INFRA-1621)

**Updated 2026-07-24 after self-validation (`validate-register.sh`).** Three of the
original five blockers were confirmed directly from the prod AWS account and are now
CLOSED — no ask needed:

- ✅ **AWS account = `937464026810`** — verified via `sts get-caller-identity`, not inferred.
- ✅ **DNS domain = `usxpress-prod.com`** — public Route53 zone confirmed in the prod account.
- ✅ **State bucket** — `lazy-tf-state-ipp58n854uhpw13x` exists (QA's naming scheme);
  confirming it holds `iaac/talos` state. No cloud request unless the confirm fails.

**Two genuinely external asks remain** — values that must be *allocated*, not looked up.
Both are of the class that, guessed wrong, deploys clean and fails invisibly (INFRA-1623).

---

## 1 → Networking — prod VIP + node IP plan  *(CRITICAL PATH)*

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

## 2 → Infra / vSphere — capacity + placement

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

Only two asks remain, and **§1 (VIP) is the true critical path** — it's the field that
broke QA's etcd backups for 13 silent days, and the whole build is parameterised around it.
§2 (vSphere) is needed a step later, at VM creation. If both come back this week, the
parallel QA-hardening track (E2/E3) finishes in the same window and prod cuts a clean
branch immediately after.

**Not on this list anymore** (self-resolved): AWS account, DNS domain, state bucket, and
IRSA (phase 2). Also outstanding but ours, not a team ask: create the `prod` environment in
Octopus and add it to the `iaac-talos` lifecycle.
