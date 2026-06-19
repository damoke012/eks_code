# CP IP Reshuffling (kubelet vs etcd peer disagreement)

**Symptom:**
- `kubectl get nodes -o wide` shows CP node InternalIP that disagrees with `talosctl etcd members` PEER URL
- Same node has two identities: e.g., `talos-cp-op-dev-3` per kubectl @ `.179`, but etcd member ID was created when it was at `.181`
- VIP `10.10.82.50` floats unpredictably to whichever CP happens to be elected
- Cosmetic only at first; becomes real when reconciler-equivalent runs and tries to align CN to "current" IP

**Root cause:**
The original cluster was bootstrapped with 3 CPs at `10.10.82.20/21/22`. After incidents and resets:
- CP-1 ended up at `.29`
- CP-2 ended up at `.181`
- CP-3 ended up at `.179`

But etcd members were registered with their ORIGINAL PEER URLs (pointing at the old IPs). The kubelet view (kubectl) tracks the CURRENT IP, the etcd view tracks the BOOTSTRAP IP. They diverge after any reset.

**IaC coverage:** ⚠ (PR #38 hostname-pin prevents the kubelet side from drifting on future resets)

**IaC location:**
- `iaac-talos/deploy/terraform/modules/talos/main.tf` — hostname pinned to VM identity (PR #38)
- No IaC yet for etcd peer URL alignment on fresh resets

### Resolution via IaC

For FRESH clusters: PR #38 ensures kubelet hostname is stable across resets. New etcd member is created with correct PEER URL because the bootstrap IP matches the current IP at first-deploy time.

For LEGACY clusters (today's op-usxpress-dev): the etcd peer URL → current IP divergence is BAKED IN until the next time a CP is fully reset + rejoined with new peer URL.

### Manual resolution

**Only needed when divergence becomes a real problem** (etcd quorum unstable, peer URL unreachable).

```bash
export TALOSCONFIG=/tmp/talosconfig-op-usxpress-dev

# 1. Snapshot etcd before touching it
talosctl --nodes <healthy-cp> --endpoints <healthy-cp> etcd snapshot \
  /tmp/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db

# 2. Identify the diverged member
talosctl --nodes <healthy-cp> --endpoints <healthy-cp> etcd members
# Note the member with PEER URL pointing at a stale IP

# 3. Remove the diverged member
STALE_ID=<id-from-step-2>
talosctl --nodes <healthy-cp> --endpoints <healthy-cp> etcd remove-member "$STALE_ID"

# 4. On the CP whose member was removed: reset to rejoin fresh
talosctl --nodes <stuck-cp-ip> --endpoints <stuck-cp-ip> reset \
  --system-labels-to-wipe=EPHEMERAL \
  --reboot \
  --graceful=false

# 5. Wait + verify rejoin
sleep 90
talosctl --nodes <healthy-cp> --endpoints <healthy-cp> etcd members
```

**Risk:** during step 4, etcd quorum drops to 2/3. If ANOTHER CP fails during this window, quorum is lost. Only do this during a maintenance window with all other CPs verified healthy.

### Verification

```bash
# 1. etcd quorum is 3/3 again
talosctl --nodes <any-cp> --endpoints <any-cp> etcd members
# Expect: 3 members listed, PEER URLs all reachable

# 2. kubectl + etcd see same hostnames
kubectl get nodes -o wide
talosctl --nodes <any-cp> --endpoints <any-cp> etcd members
# Cross-reference: kubectl Name col should appear in etcd PEER URL (or be close)
```

### Prevention

- PR #38 hostname-pin reduces the surface area for new divergence
- ANY full CP reset (not just kubelet bounce) should re-add the member with corrected PEER URL — Talos handles this automatically as part of bootstrap
- PromRule `EtcdPeerUnreachable` — fires when any peer URL fails connectivity probe
- Track 3 `talosconfig-backup` CronJob — periodic etcd snapshot to S3 for DR

### Related

- [[kubelet-cn-mismatch]] — the kubelet half of the divergence story
- [[ciliumnode-drift]] — Cilium's view of the same IP shuffle
- [[etcd-quorum-loss]] — what happens if you do step 4 wrong
- [[../06-incidents-timeline/2026-06-17-cp-oom-cascade]] — when the IPs first reshuffled

### Memory pointers

- `[onprem_topology_corrected_jun17]` — the current vs original IP map
- `[Session state Jun 19]` — etcd hostnames aligned for first time after .179 reset
