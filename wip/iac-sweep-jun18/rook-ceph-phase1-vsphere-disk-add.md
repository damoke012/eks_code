# Rook-Ceph Phase 1 — Add 2nd virtual disk per worker (PR OPEN)

**Target repo:** variant-inc/iaac-talos
**Base branch:** `feature/op-usxpress-dev` (NOT master — master is stale per [[feedback_iaac_talos_branch_base]])
**Branch:** `feature/INFRA-XXXX-worker-ceph-disk`
**PR:** https://github.com/variant-inc/iaac-talos/pull/37
**Status:** PR open 2026-06-18 PM. Awaiting review, pre-flight, plan-only diff review, then apply.

## Why

Verified via deep-research (Sidero docs): single-disk Talos VMs are NOT a supported topology for Rook. Phase 2 (deviceFilter) is impossible without a dedicated raw block device on each worker. This PR adds that disk.

## File-by-file diff

### 1. `deploy/terraform/modules/vsphere_vm/variables.tf` — add one variable

Append at the end:

```hcl
variable "extra_disk_size_gb" {
  description = "Optional size (GB) of a 2nd raw disk per VM. 0 = no extra disk."
  type        = number
  default     = 0
}
```

### 2. `deploy/terraform/modules/vsphere_vm/main.tf` — dynamic 2nd disk block

Inside `resource "vsphere_virtual_machine" "vm"`, immediately AFTER the existing `disk { label = "disk0" ... }` block, add:

```hcl
  dynamic "disk" {
    for_each = var.extra_disk_size_gb > 0 ? [1] : []
    content {
      label            = "disk1"
      size             = var.extra_disk_size_gb
      unit_number      = 1
      thin_provisioned = true
    }
  }
```

`unit_number = 1` ensures SCSI bus position 1, which Talos surfaces as `/dev/sdb` (matches the `^sdb$` deviceFilter in Phase 2).

### 3. `deploy/terraform/variables.tf` — add the worker-only variable

Append at the end:

```hcl
variable "worker_ceph_disk_gb" {
  description = "Size (GB) of dedicated Ceph OSD disk per worker (0 = none). Workers only — CPs do not get this disk."
  type        = number
  default     = 50
}
```

### 4. `deploy/terraform/main.tf` — pass the new var to the worker module ONLY

In `module "vsphere_worker"`, add ONE line — keep all existing lines unchanged:

```hcl
module "vsphere_worker" {
  source                    = "./modules/vsphere_vm"
  vm_count                  = var.worker_count
  # ... all existing lines unchanged ...
  disk_size_gb              = var.disk_size_gb
  extra_disk_size_gb        = var.worker_ceph_disk_gb  # NEW
  name_prefix               = var.worker_name_prefix
  sleep_seconds             = var.sleep_seconds
}
```

`module "vsphere_cp"` is **NOT changed** — it omits `extra_disk_size_gb`, so the variable defaults to 0 and the dynamic block produces zero disk blocks on CPs. CPs stay single-disk (correct — they don't host OSDs).

### 5. `deploy/terraform/<env>.tfvars` (or similar) — declare the value

Wherever per-cluster tfvars live for op-usxpress-dev, add (if needed — default of 50 GB already covers it):

```hcl
worker_ceph_disk_gb = 50
```

For QA + PROD: pin the same default, override later if capacity needs to grow.

## How to apply

1. **Pre-flight via `/onprem-safety`** — confirm CPs healthy + RW baseline + Octopus drift = 0 commits
2. **Verify vSphere hot-add status** on the worker VMs:
   - Open vSphere → VM → Edit Settings → VM Options → Advanced → CPU/Memory Hotplug + Hot-plug Devices
   - If ENABLED: disk adds with no reboot
   - If DISABLED: rolling worker reboots ~5 min each × 7 = ~35 min total
3. **Flip Octopus TfApply=true** on iaac-talos project (PR off `feature/op-usxpress-dev`)
4. **Plan-only first** — diff should show:
   - `module.vsphere_worker.module.vsphere_vm.vsphere_virtual_machine.vm[0..6]` → 1 new disk each
   - **NO** changes on `module.vsphere_cp.*`
   - 0 adds, 7 changes, 0 destroys (or thereabouts)
5. **Apply** if plan matches
6. **Verify each worker:**
   ```bash
   export TALOSCONFIG=/tmp/talosconfig-op-usxpress-dev
   for ip in 10.10.82.21 10.10.82.22 10.10.82.26 10.10.82.27 10.10.82.28 10.10.82.178 10.10.82.180; do
     echo "=== $ip ==="
     talosctl --nodes $ip --endpoints $ip get disks 2>&1 | grep -E '(sd|nvme)'
   done
   # Expect each worker to show sda (OS, ~existing GB) + sdb (50 GB, no FS)
   ```
7. **Flip Octopus TfApply=false** (safety default per [[reference_octopus_tfapply_variable]])

## RW awareness

- Hot-add ON: Tim sees nothing
- Hot-add OFF: rolling reboots — RW pods migrate between healthy workers. **Coordinate with Tim on Teams first.**
- Pre/post: capture `kubectl -n risingwave get pods,svc,pvc` per /onprem-safety Rule 5

## After this lands

→ Phase 2: `wip/iac-sweep-jun18/rook-ceph-phase2-deviceFilter.md` (CephCluster CR switch)

## Risks

- **vSphere datastore capacity** — 7 × 50 GB thin-provisioned = up to 350 GB additional. Verify datastore free space > 500 GB before apply.
- **Talos device-naming variation** — if vSphere VM uses NVMe controller, disks show as `/dev/nvme1n1` instead of `/dev/sdb`. The Worker Talos OVA used here is the standard pvscsi/LSI Logic — should show `/dev/sdb`. Verify with the step-6 check.
- **vSphere hot-add OFF** — rolling reboots required; coordinate with Tim.

## What this does NOT change

- CPs (`module.vsphere_cp`) — unchanged
- Existing OS disk (`disk0`) on workers — same size, same datastore
- Networking, taints, labels — unchanged
- Cilium / Talos config — unchanged
- Per [[feedback_zero_cloud_impact]]: no AWS-side changes

## Related
- [[rook_ceph_production_plan_jun18]] — full plan
- [[skill_onprem_safety]] — Rules 2 (capacity), 5 (RW awareness)
- [[reference_octopus_tfapply_variable]] — TfApply safety default
- [[feedback_iaac_talos_branch_base]] — base off `feature/op-usxpress-dev`, NOT master
