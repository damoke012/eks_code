# main.tf — replace the `module "vsphere_worker"` block

## Find this exact block in `deploy/terraform/main.tf`:

```hcl
module "vsphere_worker" {
  source                    = "./modules/vsphere_vm"
  vm_count                  = var.worker_count
  vm_folder                 = vsphere_folder.cluster_folder.path
  datacenter                = var.datacenter
  datastore                 = var.datastore
  vm_cluster_name           = var.vm_cluster_name
  content_library_name      = var.content_library_name
  content_library_item_name = var.content_library_item_name
  network_name              = var.network_name
  cpus                      = var.worker_cpus
  memory_mb                 = var.worker_memory_mb
  disk_size_gb              = var.disk_size_gb
  extra_disk_size_gb        = var.worker_ceph_disk_gb
  name_prefix               = var.worker_name_prefix
  sleep_seconds             = var.sleep_seconds
}
```

## Replace with:

```hcl
# Worker pools: if worker_pools is set, iterate per pool (labels/taints/sizing
# per-pool). If empty, fall back to a single implicit "default" pool built
# from the legacy scalar variables so Dev keeps working unchanged.
locals {
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
}

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

## Also update the `module "talos"` block

The Talos module currently receives flat lists `worker_ips` + `worker_vm_names` from the single vsphere_worker module. Now they come from multiple pool instances.

### Find:

```hcl
  control_plane_ips         = module.vsphere_cp.ip_addresses
  worker_ips                = module.vsphere_worker.ip_addresses
  control_plane_vm_names    = module.vsphere_cp.vm_names
  worker_vm_names           = module.vsphere_worker.vm_names
```

### Replace with:

```hcl
  control_plane_ips         = module.vsphere_cp.ip_addresses
  worker_ips                = flatten([for k, v in module.vsphere_worker : v.ip_addresses])
  control_plane_vm_names    = module.vsphere_cp.vm_names
  worker_vm_names           = flatten([for k, v in module.vsphere_worker : v.vm_names])
```

### Also add — pool metadata (for later per-pool label/taint application in talos module):

Right after the existing `worker_count` and `worker_name_prefix` lines inside the `module "talos"` block, add:

```hcl
  worker_pools = local.effective_worker_pools
```

**Note:** The `modules/talos` code needs to accept this new `worker_pools` input and apply labels/taints per-worker in the machine config. That module change is drafted separately (see `patches/04-modules-talos-*.md`) — after you paste the module's `main.tf` and `variables.tf` I'll finalize those changes.
