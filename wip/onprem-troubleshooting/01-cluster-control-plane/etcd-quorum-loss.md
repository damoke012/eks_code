# Etcd Quorum Loss

**Symptom:**
- `kubectl` commands hang or return `etcdserver: request timed out`
- `talosctl etcd members` shows < 2 members with healthy PEER URL
- New pods cannot schedule (scheduler can't read state)
- API server logs show `error retrieving resource lock kube-system/...: rpc error: code = Unavailable`

**Root cause:**
On op-usxpress-dev, etcd is co-located with the CPs (no external etcd cluster). Quorum requires 2 of 3 CPs healthy. Common causes:
- 2 CPs rebooted simultaneously (e.g., Talos config apply to all CPs at once)
- 2 CPs OOMKilled in OOM cascade ([[cp-capacity-exhaustion]])
- 1 CP genuinely dead + 1 CP with corrupt etcd data
- Network partition isolating 2 of 3 CPs

**IaC coverage:** ⚠ (only prevention via placement rules; recovery is manual)

**IaC location:**
- `iaac-talos/deploy/terraform/modules/talos/main.tf` — Talos config push happens to ONE CP at a time (TF resource ordering), but Octopus apply can be parallel; check resource `parallelism`
- No IaC for etcd snapshot-to-S3 yet (drafted in `wip/iac-sweep-jun18/track3-incident-hardening/cronjob-talosconfig-backup.yaml`)

### Resolution via IaC

For fresh clusters: 8 GB CP RAM + strict DaemonSet placement (Rule 1) means OOM cascade can't happen. Talos config apply via Terraform serializes per CP — only ONE CP rebooted at a time.

For DR after total quorum loss: the planned `talosconfig-backup` CronJob would auto-snapshot etcd every 6h to S3. Restore from snapshot is documented in the Talos upstream `etcd-recovery` runbook.

### Manual resolution

**Case A — 1 of 3 healthy, 2 are unreachable/corrupt:**

```bash
# 1. Identify the healthy CP
for ip in 10.10.82.29 10.10.82.179 10.10.82.181; do
  echo "=== $ip ==="
  talosctl --nodes $ip --endpoints $ip etcd status 2>&1 | tail -5
done
# The healthy CP will show "Leader" or "Member"; others time out

# 2. Force single-member etcd (DESTRUCTIVE — only when other CPs are confirmed dead)
HEALTHY=10.10.82.<healthy-ip>
talosctl --nodes $HEALTHY --endpoints $HEALTHY etcd forfeit-leadership   # if it was leader
# Then manually edit /etc/kubernetes/manifests/etcd.yaml inside Talos to set
# --force-new-cluster=true and restart kubelet — see Talos docs
```

**Case B — etcd corruption on a single CP (other 2 healthy):**

```bash
# 1. Confirm the corrupt CP
talosctl --nodes <other-healthy-cp> --endpoints <other-healthy-cp> etcd members
# Note the BAD member's ID

# 2. Remove the bad member
talosctl --nodes <healthy-cp> --endpoints <healthy-cp> etcd remove-member <bad-id>

# 3. Reset the bad CP — wipes EPHEMERAL, drops etcd data, rejoins clean
talosctl --nodes <bad-cp-ip> --endpoints <bad-cp-ip> reset \
  --system-labels-to-wipe=EPHEMERAL \
  --reboot \
  --graceful=false

# 4. Wait for rejoin — quorum returns to 3/3 within 90 sec
sleep 90
talosctl --nodes <any-cp> --endpoints <any-cp> etcd members
```

**Case C — Restore from snapshot (last resort, when 0/3 healthy):**

See Talos docs: https://www.talos.dev/v1.11/advanced/etcd-maintenance/

```bash
# 1. Stop kubelet on all 3 CPs
for ip in 10.10.82.29 10.10.82.179 10.10.82.181; do
  talosctl --nodes $ip --endpoints $ip service kubelet stop
done

# 2. Restore from snapshot on ONE CP (the new leader)
talosctl --nodes <new-leader-ip> --endpoints <new-leader-ip> etcd snapshot restore \
  /tmp/etcd-snapshot.db --skip-hash-check

# 3. Start kubelet on the restored CP
talosctl --nodes <new-leader-ip> --endpoints <new-leader-ip> service kubelet start

# 4. Reset the other 2 CPs so they rejoin fresh
for ip in <other-cp-1> <other-cp-2>; do
  talosctl --nodes $ip --endpoints $ip reset --system-labels-to-wipe=EPHEMERAL --reboot --graceful=false
done
```

### Verification

```bash
# 1. All 3 members healthy
talosctl --nodes <any-cp> --endpoints <any-cp> etcd members
# Expect: 3 members, all with reachable PEER URLs

# 2. kube-apiserver responds normally
kubectl get nodes
kubectl get componentstatuses

# 3. New resources can be created
kubectl create configmap quorum-test --from-literal=ts=$(date +%s) -n default
kubectl get configmap quorum-test -o yaml | head -5
kubectl delete configmap quorum-test -n default
```

### Prevention

- **Rule 4 (`/onprem-safety`)** — never reboot 2 CPs simultaneously. Always one at a time, 3 min apart.
- **PromRule `EtcdQuorumWarn`** (Track 3 — drafted) — fires when only 2 members reachable for > 5 min
- **Etcd snapshot to S3 every 6h** (drafted CronJob in `wip/iac-sweep-jun18/track3-incident-hardening/`)
- **Off-cluster etcd?** — fundamental design choice; current cluster is co-located. Externalizing etcd is a Phase 4 consideration.

### Related

- [[cp-capacity-exhaustion]] — common cause of multi-CP failure
- [[cp-ip-shuffle]] — etcd PEER URL drift downstream of resets
- [[../06-incidents-timeline/2026-06-17-cp-oom-cascade]] — historical reference

### Memory pointers

- `/onprem-safety` skill Rule 4
- `[onprem_topology_corrected_jun17]` — CP IPs (29/179/181)
- `[Session state Jun 19]` — etcd 3/3 aligned for first time after PR #38 + .179 reset
