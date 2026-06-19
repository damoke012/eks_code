# Incident — CP OOM Cascade (2026-06-17)

**Date:** 2026-06-17
**Cluster:** op-usxpress-dev
**Severity:** Critical — kube-apiserver intermittently unreachable for ~3h
**Root cause domain:** Control plane capacity exhaustion

## Summary

Adding a CSI plugin DaemonSet (Rook-Ceph CSI driver) caused workload pods to schedule on CP nodes. Combined with default 4 GB RAM on CPs, this exhausted memory, kube-apiserver was OOMKilled across 2 of 3 CPs, etcd quorum briefly destabilized.

## Timeline (approximate, EDT)

| Time | Event |
|---|---|
| 14:30 | Rook-Ceph CSI driver Flux Kustomization applied |
| 14:35 | CSI plugin DaemonSet schedules on all nodes including CPs (default `tolerations: - operator: Exists`) |
| 14:42 | CP free memory drops from ~1.1 GB → <100 MB on all 3 CPs |
| 14:45 | First kube-apiserver OOMKilled on cp-1 |
| 14:50 | kube-apiserver flapping; etcd peer URL probing intermittent |
| 14:55 | Two CPs intermittently unreachable; cluster wedged |
| 15:10 | Manual diagnosis: identified CSI DaemonSet as memory hog |
| 15:15 | Suspended Rook-Ceph Flux Kustomization |
| 15:18 | Manually deleted CSI plugin DS — freed ~800 MB per CP |
| 15:25 | kube-apiserver stabilized, etcd quorum back to 3/3 |
| 15:30 | Incident declared resolved |
| 17:00 | Initial root-cause docs drafted |

## Symptoms during the incident

- `kubectl get nodes` times out
- 2 of 3 CPs showing NotReady (`MemoryPressure`)
- Workload pods being evicted
- Cilium control-plane stutters (couldn't reach api server)
- Talos console alarms on memory

## Root cause

**Two compounding factors:**

1. **CSI plugin DaemonSet default tolerations** — `tolerations: - operator: Exists` matched the CP NoSchedule taint, allowing the plugin pods to schedule on CPs.
2. **CP RAM at 4 GB default** — insufficient headroom for any additional workload pods beyond core control-plane components.

When the CSI DS landed on each CP, it took ~100-200 MB of memory. CPs already running ~85% used (kube-apiserver, etcd, cilium, kubelet) flipped over the OOM threshold.

## What we did (manual recovery)

```bash
# 1. Suspended the Flux Kustomization
kubectl -n flux-system patch kustomization rook-ceph-cluster \
  --type=merge -p '{"spec":{"suspend":true}}'

# 2. Deleted the CSI plugin DaemonSet
kubectl -n rook-ceph delete daemonset csi-rbdplugin csi-cephfsplugin

# 3. Waited for kubelet to free memory, kube-apiserver to stabilize
sleep 120

# 4. Verified CP recovery
for ip in 10.10.82.29 10.10.82.179 10.10.82.181; do
  talosctl --nodes $ip --endpoints $ip memory
done

# 5. PR'd corrected CSI DS spec (explicit nodeAffinity + tolerations:[])
# 6. Bumped CP RAM 4 → 8 GB via iaac-talos TF apply
```

## IaC changes that came out of this

- **iaac-talos: CP RAM 4 → 8 GB** (Octopus `TF_VAR_cp_memory_mb=8192`) — applied within 24h of incident
- **`/onprem-safety` skill** — codified Rule 1 (explicit CP exclusion in DaemonSets) + Rule 2 (CP capacity check before deploy)
- **CephCluster CR `placement.all`** — explicit CP exclusion via `node-role.kubernetes.io/control-plane DoesNotExist`
- **Track 3 PromRule** — `KubeletNodeMemoryPressure` for CP memory < 1 GB

## Lessons learned

1. **Default DaemonSet tolerations are dangerous** — `operator: Exists` matches every taint including CP NoSchedule. Use `tolerations: []` or scoped tolerations.
2. **4 GB on a CP is too tight** — even without extra workloads, adding any operator can OOM-cascade.
3. **Pre-deploy capacity check** is essential. The `/onprem-safety` Rule 2 codifies this.
4. **Suspend Flux Kustomization** is the right first-aid move — stops the cascade without destroying state.

## Related entries

- [[../01-cluster-control-plane/cp-capacity-exhaustion]] — generalized failure mode
- [[../01-cluster-control-plane/etcd-quorum-loss]] — downstream risk
- [[../01-cluster-control-plane/cp-ip-shuffle]] — CP IPs reshuffled as resets happened
- [[2026-06-18-cilium-orphan-cert-cascade]] — followup cascade the next day

## Memory pointers

- `[onprem_topology_corrected_jun17]` — CP IP map (post-incident)
- `[Cilium node-reconciler LIVE]` — reconciler designed in response to subsequent drift
