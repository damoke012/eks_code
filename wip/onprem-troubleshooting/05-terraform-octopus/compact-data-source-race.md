# vSphere Data Source Race (compact() Silent Index Shift)

**Symptom:**
- Terraform apply errors at `talos_machine_configuration_apply.join_workers[<N>]` with:
  ```
  Error: Invalid index
   on modules/talos/main.tf line 161, in resource ...
   161:   node = var.worker_ips[count.index]
   │ count.index is <N>
   │ var.worker_ips is list of string with 3 elements
  ```
- Or after PR #40: the new precondition fires with a clear "wait and re-run" message:
  ```
  Error: Module output value precondition failed
   on modules/vsphere_vm/outputs.tf line 6, in output "ip_addresses":
  One or more vSphere VMs has no default_ip_address (likely mid hot-add). Wait ~60s and re-run.
  ```
- Symptom triggered during VM hot-add operations (memory bump, disk add) when data sources re-read mid-operation

**Root cause (historical):**
The vsphere_vm module's `ip_addresses` output had:
```hcl
value = compact([for vm in data.vsphere_virtual_machine.vm_info : try(vm.default_ip_address, "")])
```

When vSphere data sources read during a hot-add operation, some VMs returned empty IPs momentarily. `try()` converted those to empty strings, `compact()` silently dropped them, and the output list shrunk from 7 → fewer elements. Downstream consumers using positional index (`var.worker_ips[count.index]`) errored.

**Resolution (PR #40 merged 2026-06-19):**
Drop `compact()` + `try()`. Add output precondition that fails LOUDLY if any IP is empty:
```hcl
value = [for vm in data.vsphere_virtual_machine.vm_info : vm.default_ip_address]
precondition {
  condition = alltrue([
    for vm in data.vsphere_virtual_machine.vm_info :
    vm.default_ip_address != null && vm.default_ip_address != ""
  ])
  error_message = "One or more vSphere VMs has no default_ip_address (likely mid hot-add). Wait ~60s and re-run."
}
```

**IaC coverage:** ✓ (PR #40 ships the precondition; planned follow-up Option B drops data source entirely)

**IaC location:**
- `iaac-talos/deploy/terraform/modules/vsphere_vm/outputs.tf` — current precondition form

### Resolution via IaC (current)

Precondition fires CLEANLY during hot-add race. User sees clear error, waits 60s, re-runs Octopus deploy → succeeds.

**Future improvement (Option B — drop data source):** Use the `vsphere_virtual_machine` resource's `default_ip_address` attribute directly instead of a separate data source. Eliminates the race window entirely. Drafted in `wip/iac-sweep-jun18/INCIDENT-COVERAGE-MATRIX-2026-06-19.md` § F1.

### Manual resolution (if it errors today)

```bash
# 1. Wait 60-90 sec for VM IPs to stabilize after hot-add completion
sleep 90

# 2. Verify all 7 worker IPs are reachable via Talos API
export TALOSCONFIG=/tmp/talosconfig-op-usxpress-dev
for ip in 10.10.82.21 10.10.82.22 10.10.82.26 10.10.82.27 10.10.82.28 10.10.82.178 10.10.82.180; do
  nc -zv -w 2 $ip 50000 2>&1 | head -1
done
# Expect: 7 succeeded

# 3. Re-run the Octopus deploy with TfApply=true
# (via Octopus UI; deploy the same release)
```

The second apply succeeds because data sources read all IPs cleanly.

### Verification

```bash
# Plan output should show all 7 worker_ips populated
# Look in Octopus deploy log for:
#   ~ worker_ips = [
#       "10.10.82.26",
#       "10.10.82.28",
#       "10.10.82.178",
#       "10.10.82.180",
#       "10.10.82.27",
#       "10.10.82.22",
#       "10.10.82.21",
#     ]

# After apply:
kubectl get nodes -o wide
# Expect: all 10 Ready
```

### Prevention

- **PR #40 LIVE** — precondition catches the race cleanly. Next session: ship Option B (drop data source) to eliminate the race entirely.
- During VM operations: WAIT for `Modifications complete` lines on all VMs before assuming apply will succeed. The vSphere provider sometimes returns "complete" before guest tools re-report IP.

### Related

- [[../01-cluster-control-plane/kubelet-cn-mismatch]] — historical: 1.168 with compact() race pushed WRONG hostnames to 2 workers (case B-2)
- [[octopus-tfapply-variable]] — TfApply controls plan-only vs apply
- Memory: `[Octopus TfApply variable controls plan vs apply]`

### Memory pointers

- `[Session state Jun 19]` — PR #40 applied via 1.171; precondition caught race CLEANLY 4 of 7 workers hot-adding; recovery was just re-run
- `[INCIDENT-COVERAGE-MATRIX-2026-06-19]` § F1 — Option B follow-up scoped
