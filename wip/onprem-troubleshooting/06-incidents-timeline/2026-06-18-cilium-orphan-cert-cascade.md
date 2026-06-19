# Incident — Cilium-Orphan Cert Cascade (2026-06-18)

**Date:** 2026-06-18
**Cluster:** op-usxpress-dev
**Severity:** Critical — Octopus apply soft-failed; manual recovery required
**Root cause domain:** CiliumNode drift after CP IP change

## Summary

During an iaac-talos Octopus apply (release 1.163, Rook Phase 1 disk add), CP-1's kubelet re-registered at `.29` but the CiliumNode CRD stayed at `.181`. Cilium's WireGuard mesh became inconsistent → istio-csr lost peer connectivity → istio cert chain stale → istiod health check timed out (Octopus 1200s post-deploy wait), apply marked soft-failed even though TF state saved cleanly.

## Timeline (approximate, EDT)

| Time | Event |
|---|---|
| 10:30 | iaac-talos release 1.163 (Rook Phase 1) deployed to dev |
| 10:35 | vSphere hot-add of `/dev/sdb` (50 GB) to all 7 workers completes |
| 10:38 | Talos config push to all CPs; cp-1 re-registers at .29 (was registered at .181) |
| 10:40 | Cilium agent on cp-1 starts → registers new CiliumNode at .29; OLD CN at .181 remains |
| 10:42 | WireGuard mesh inconsistent — peer URLs in old CN pointing at non-existent .181 |
| 10:50 | istio-csr can't reach CA via mesh; cert renewal stalls |
| 10:55 | istiod's xDS clients begin failing TLS verification |
| 11:00 | Octopus post-deploy health check (1200s istiod readiness wait) starts |
| 11:20 | Health check times out; Octopus marks 1.163 "Failed" |
| 11:25 | Manual investigation begins — TF state is fine, cluster is degraded |
| 11:40 | Manual delete of ghost `talos-cp-op-dev-3` Node + stale `talos-cp-op-dev-1` CiliumNode + bounce cilium agent on .29 |
| 11:45 | istiod rolls out successfully after CN cleanup |
| 11:50 | Cluster healthy; incident resolved |
| 13:00 | Designed `cilium-node-reconciler` CronJob for auto-healing |

## Root cause

CP-1's IP shifted from `.181` → `.29` due to the previous incident (2026-06-17) recovery sequence. Kubelet correctly re-registered at the new IP. But Cilium DOES NOT automatically clean up old CiliumNode entries — they persist as zombie state.

The zombie CN had:
- Hostname `talos-cp-op-dev-1`
- Stale `INTERNALIP: 10.10.82.181`

This confused Cilium's L2 announcement + WireGuard mesh:
- istio-csr's mesh sidecar couldn't reach the CA via the stale peer URL
- Cert renewal silently stalled
- istiod's xDS verification began failing

## What we did (manual recovery)

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# 1. Identified zombie/orphan CN entries
kubectl $KCONFIG get ciliumnodes
# Found: old `talos-cp-op-dev-1` at .181 + ghost `talos-cp-op-dev-3` node

# 2. Deleted ghost Node + stale CN
kubectl $KCONFIG delete node talos-cp-op-dev-3   # ghost Node
kubectl $KCONFIG delete ciliumnode talos-cp-op-dev-1   # stale CN

# 3. Bounced cilium agent on cp-1 (10.10.82.29) — recreates CN with current IP
kubectl $KCONFIG -n kube-system delete pod \
  -l k8s-app=cilium \
  --field-selector spec.nodeName=talos-cp-op-dev-1

# 4. Waited + verified
sleep 30
kubectl $KCONFIG get ciliumnodes  # New CN at .29 ✓
kubectl $KCONFIG -n istio-system get pods   # istiod rolling out ✓
```

## IaC changes that came out of this

- **iaac-talos-flux-platform PR #43** — `cilium-node-reconciler` CronJob (4 failure modes auto-healed)
- **iaac-talos-flux-cluster PR #17** — Flux wire-up for cilium-hygiene
- **PromRule `CiliumNodeDrift`** (Track 1.5) — detection within 10 min of any drift
- **`/onprem-safety` skill** — Rule 4 (etcd quorum) + post-apply CN check

**Caveat:** the reconciler image `bitnamilegacy/kubectl:1.32` had an entrypoint bug — the reconciler ran but produced "no resources" error and didn't actually execute the scripts. This made it a no-op safety net. URGENT fix carried into next session (see [[2026-06-19-dns-irsa-rw-cascade]] — same drift cascaded again).

## Lessons learned

1. **Cilium doesn't auto-clean stale CiliumNodes** — must be done manually or via reconciler
2. **WG mesh + cert chain cascade is silent** — istio-csr failure modes are deep; users see "istiod doesn't roll out" but the root cause is 3 layers down
3. **Reconciler image must be validated** — entrypoint behavior, not just image existence
4. **Octopus post-deploy health check** is a useful canary — but it doesn't fix the underlying problem, just signals it

## Related entries

- [[../01-cluster-control-plane/ciliumnode-drift]] — generalized failure mode
- [[../01-cluster-control-plane/cp-ip-shuffle]] — primary trigger
- [[../03-networking/cluster-dns-failure]] — sister symptom in next-day cascade
- [[2026-06-17-cp-oom-cascade]] — previous-day setup that caused the IP shuffle
- [[2026-06-19-dns-irsa-rw-cascade]] — same root cause, different surface

## Memory pointers

- `[Cilium node-reconciler LIVE]` — reconciler design + image bug pending fix
- `[onprem_topology_corrected_jun17]` — IP map
