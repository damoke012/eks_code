# INFRA-XXXX — Reconcile CP kubelet hostname ↔ etcd member identity + IaC-pin hostnames per VM-index

**Type:** Task
**Priority:** Medium
**Assignee:** (TBD)
**Component:** On-prem / Talos / Cilium
**Affected env:** op-usxpress-dev

## Background

After 2026-06-17 hostname patch + 2026-06-18 PM `talos_machine_configuration_apply` (Octopus release 1.163), kubelet identity on CPs drifted from etcd member identity. The cluster is still functional (etcd quorum healthy, API responds) but the divergence will compound over the next few apply cycles.

### Current state (2026-06-18 PM)

| IP | kubelet Node hostname | etcd member hostname |
|---|---|---|
| 10.10.82.29 | talos-cp-op-dev-1 | talos-cp-op-dev-1 ✓ |
| 10.10.82.179 | talos-cp-op-dev-2 | talos-cp-op-dev-3 ✗ |
| 10.10.82.181 | (no kubelet Node!) | talos-cp-op-dev-2 ✗ |

The CP at .181 has no kubectl Node registration. Cilium DS pod runs there but the CiliumNode CRD gets created from kubelet's identity, which is broken on .181. End result: only 2 of 3 CPs visible to k8s; the third runs etcd but is invisible to scheduling.

## Why now

- Cluster is dev — low blast radius for surgical work
- The deeper this gets buried under more applies, the harder to unwind
- QA + PROD must not inherit this. We have a known-bad state to clean before cluster pattern rolls forward.

## Scope

### In-scope
1. Identify whether .181 has a stuck kubelet config (`talosctl service kubelet status`)
2. Reconcile CP hostnames in Talos machineconfig so .179 ↔ cp-3 and .181 ↔ cp-2 OR re-bind etcd member identities to match kubelet
3. Get all 3 CPs registered as kubectl Nodes
4. Get all 3 CiliumNodes populated with correct IPs
5. Codify the final state so terraform `talos_machine_configuration_apply` doesn't flip it back

### Out-of-scope
- Etcd data migration (everything stays in place)
- Workload restart (must not disrupt RW; coordinate with Tim if needed)

## Definition of done

- `kubectl get nodes` shows 3 CPs at .29 / .179 / .181 with matching hostnames in etcd
- `kubectl get ciliumnodes` shows 3 CP entries with matching INTERNAL-IPs
- `talosctl etcd members` from any CP matches the kubectl Node list 1:1
- Repeat `terraform plan` shows ZERO changes on CP resources (state in sync)
- Pattern documented for QA + PROD rollout (commit to `iaac-talos` docs)

## Suggested approach

Recommend reading the current Talos machineconfig per CP first (`talosctl get machineconfig -o yaml` against each .29/.179/.181), comparing to TF's rendered config, picking the cleanest reconciliation direction.

Two paths:
- **A — Realign Talos machineconfig hostname to match etcd** (`talosctl patch machineconfig` setting `machine.network.hostname` on each CP)
- **B — Realign etcd member metadata to match kubelet hostname** (`etcdctl member update <id> --name=<new>`)

Path A is safer (declarative + can be codified into Terraform). Path B requires direct etcd API access on a CP that runs `etcdctl`.

After repair, gate against recurrence:
- Ensure tfvars / Talos machineconfig pin `machine.network.hostname` explicitly per CP IP (not auto-derived)
- The new `cilium-node-reconciler` CronJob (this session, includes CASE 4 stale-Node GC) will catch IP/hostname drift within 15 min going forward

## IaC refactor proposal — pin hostname by VM-index, not list-index

Currently in `iaac-talos/deploy/terraform/modules/talos/main.tf`:

```hcl
resource "talos_machine_configuration_apply" "init" {
  node = var.control_plane_ips[0]
  config_patches = [
    yamlencode({ machine = { network = { hostname = "${var.control_plane_name_prefix}-1" } } })
  ]
}

resource "talos_machine_configuration_apply" "join_cp" {
  count = max(var.control_plane_count - 1, 0)
  node  = var.control_plane_ips[count.index + 1]
  config_patches = [
    yamlencode({ machine = { network = { hostname = "${var.control_plane_name_prefix}-${count.index + 2}" } } })
  ]
}
```

This binds hostname to **list index of IP**. If `control_plane_ips` ever comes back in a different order (DHCP refresh, CP reboot order), TF would push "talos-cp-op-dev-1" hostname to a DIFFERENT physical machine. That's how 2026-06-18 PM started: an out-of-band hostname patch broke the binding, today's apply re-applied TF's view to whatever IPs answered first.

**Proposed fix** — derive hostname from the vsphere_virtual_machine resource name (which is stable per VM-identity):

1. `modules/vsphere_vm/outputs.tf` — add a `vm_names` output:
   ```hcl
   output "vm_names" {
     value = vsphere_virtual_machine.vm[*].name
   }
   ```
   This output preserves count.index ordering — `vm_names[N]` always corresponds to `ip_addresses[N]`.

2. `modules/talos/variables.tf` — accept `control_plane_vm_names` + `worker_vm_names`.

3. `modules/talos/main.tf` — derive hostname from VM name:
   ```hcl
   resource "talos_machine_configuration_apply" "init" {
     node = var.control_plane_ips[0]
     config_patches = [
       yamlencode({ machine = { network = { hostname = var.control_plane_vm_names[0] } } })
     ]
   }

   resource "talos_machine_configuration_apply" "join_cp" {
     count = max(var.control_plane_count - 1, 0)
     node  = var.control_plane_ips[count.index + 1]
     config_patches = [
       yamlencode({ machine = { network = { hostname = var.control_plane_vm_names[count.index + 1] } } })
     ]
   }
   ```

4. `deploy/terraform/main.tf` — wire the new outputs:
   ```hcl
   module "talos" {
     ...
     control_plane_vm_names = module.vsphere_cp.vm_names
     worker_vm_names        = module.vsphere_worker.vm_names
   }
   ```

After this PR + apply, each Talos machine's hostname is bound to its vSphere VM identity (NAME, set at create time, never changes). Reboots, DHCP refreshes, out-of-band patches — none of them shift hostname assignments.

**Migration risk** — when first applied, this WILL push new machine configs to all 3 CPs simultaneously, restarting Talos services. Same risk profile as today's apply (which we just survived). Should be a planned-window apply.

**QA + PROD carry-over** — same module change; QA + PROD will inherit the stable-hostname pattern at first apply.

## Related

- Memory: `incident_2026_06_17_cp_oom_cascade` (where the hostname patch originated)
- Memory: `incident_2026_06_18_cilium_orphan_cert_cascade` (yesterday's cascade)
- Memory: `session_state_jun18_pm` (today's apply)
- This session's IaC fix: `wip/iac-sweep-jun18/track1.5-cilium-hygiene/` (catches divergence but doesn't fix this root cause)
- PR #37 on iaac-talos (Phase 1 disk add — applied successfully despite this divergence)
