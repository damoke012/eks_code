# main.tf — worker pools + talos pool metadata wiring

**Corrected 2026-07-13** after seeing the real `modules/talos` interface:
the module ALREADY supports pools via `var.worker_pool_metadata` (a flat
`list(object({pool_name, labels, taints}))`, taints as `map(string)` in
Talos `key => "value:Effect"` form, empty list = Dev backward-compat).
So there is **NO module patch needed** (old "patch 05" is obsolete). The work
is purely in root `main.tf`: provision per-pool VMs and build the aligned
`worker_pool_metadata` list.

---

## 1. Add locals (top of `main.tf`, or your locals block)

```hcl
locals {
  # Pool source: real pools if set, else a single implicit "default" pool from
  # the legacy scalars so Dev keeps working unchanged.
  effective_worker_pools = length(var.worker_pools) > 0 ? var.worker_pools : {
    default = {
      count        = var.worker_count
      cpus         = var.worker_cpus
      memory_mb    = var.worker_memory_mb
      disk_size_gb = var.disk_size_gb
      ceph_disk_gb = var.worker_ceph_disk_gb
      labels       = {}
      taints       = []
    }
  }

  # Per-worker metadata for modules/talos, index-aligned with worker_ips.
  # MUST iterate pools in the SAME order Terraform flattens module.vsphere_worker
  # (map keys are sorted), so we sort() the keys here too. Each pool contributes
  # `count` entries. Taints convert "key=value:Effect" -> { key = "value:Effect" }.
  # Dev (empty worker_pools) -> [] so the module applies exactly today's behavior.
  worker_pool_metadata = length(var.worker_pools) > 0 ? flatten([
    for pool in sort(keys(var.worker_pools)) : [
      for _ in range(var.worker_pools[pool].count) : {
        pool_name = pool
        labels    = var.worker_pools[pool].labels
        taints    = { for t in var.worker_pools[pool].taints : split("=", t)[0] => split("=", t)[1] }
      }
    ]
  ]) : []
}
```

## 2. Replace `module "vsphere_worker"` with a per-pool `for_each`

```hcl
module "vsphere_worker" {
  for_each = local.effective_worker_pools

  source                    = "./modules/vsphere_vm"
  vm_count                  = each.value.count
  vm_folder                 = vsphere_folder.cluster_folder.path
  datacenter                = var.datacenter
  datastore                 = var.datastore
  vm_cluster_name           = var.vm_cluster_name
  content_library_name      = var.content_library_name
  content_library_item_name = var.content_library_item_name
  network_name              = var.network_name
  cpus                      = each.value.cpus
  memory_mb                 = each.value.memory_mb
  disk_size_gb              = each.value.disk_size_gb
  extra_disk_size_gb        = each.value.ceph_disk_gb
  name_prefix               = each.key == "default" ? var.worker_name_prefix : "${var.worker_name_prefix}-${each.key}"
  sleep_seconds             = var.sleep_seconds
}
```

## 3. REQUIRED: `moved` block so Dev doesn't destroy/recreate

Singleton → `for_each` changes the address `module.vsphere_worker` ->
`module.vsphere_worker["default"]`. Without this, `plan` shows Dev workers
being replaced (breaks the empty-diff retest).

```hcl
moved {
  from = module.vsphere_worker
  to   = module.vsphere_worker["default"]
}
```

## 4. Rewire the `module "talos"` inputs

Worker IP/name lists now come from multiple pool instances (sorted key order),
and pass the new pool metadata list. In the `module "talos"` block:

```hcl
  # was: worker_ips = module.vsphere_worker.ip_addresses
  worker_ips             = flatten([for k, v in module.vsphere_worker : v.ip_addresses])
  # was: worker_vm_names = module.vsphere_worker.vm_names
  worker_vm_names        = flatten([for k, v in module.vsphere_worker : v.vm_names])

  # NEW — drives per-pool labels+taints in modules/talos (empty [] on Dev):
  worker_pool_metadata   = local.worker_pool_metadata
```

`for k, v in module.vsphere_worker` and `sort(keys(var.worker_pools))` both
iterate sorted pool keys (application, platform, system), so `worker_ips[i]`
lines up with `worker_pool_metadata[i]`.

## Verify
- `terraform plan -var-file=envs/dev.tfvars` → **No changes** (the `moved` block
  absorbs the address change; `worker_pool_metadata=[]` keeps module output identical).
- `terraform plan -var-file=envs/qa.tfvars` → all-adds; spot-check the machine
  config for pool nodes shows `nodeLabels.pool` + `nodeTaints` (platform/application).
