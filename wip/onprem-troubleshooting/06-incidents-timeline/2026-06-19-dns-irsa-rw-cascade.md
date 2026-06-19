# Incident — DNS + IRSA + RW Cascade (2026-06-18 PM → 2026-06-19 AM)

**Date:** 2026-06-18 evening through 2026-06-19 ~02:30 AM
**Cluster:** op-usxpress-dev
**Severity:** Critical — cluster DNS broken cluster-wide for ~80 min; RW degraded ~6h before recovery
**Root cause domain:** Stack of cascading failures starting from CiliumNode drift on CPs

## Summary

A planned worker memory bump (PR #40 via Octopus 1.171) succeeded cleanly — but the test surface uncovered three deeper failures that were silently degrading the cluster:

1. **CiliumNode drift on CP-1 + CP-2** (residue from prior reset/reshuffle) — the cilium-node-reconciler CronJob deployed previously was supposed to auto-heal this, but its image had an entrypoint bug → safety net was no-op for ~24h
2. **Cluster DNS dead** — broken because CoreDNS pods on CP-1/CP-2 became unreachable via Cilium's eBPF datapath
3. **RW namespace 80% degraded** — pods that booted during the DNS-broken window stuck in CrashLoopBackOff because IRSA fell through to non-existent IMDS

## Timeline (approximate, EDT)

| Time | Event |
|---|---|
| ~21:00 (Jun-18) | Worker memory bump PR #40 prepared (12 GB target + drop `compact()` race) |
| ~22:00 | PR #40 merged + Octopus 1.171 deploy started (TfApply=true) |
| ~22:05 | vSphere hot-add of memory on 7 workers; 3m14s per VM in parallel |
| ~22:10 | **PR #40 precondition CAUGHT the data-source race CLEANLY** — IP refresh saw empty IPs mid-add. Apply errored with our designed message. |
| ~22:13 | Re-ran 1.171; precondition passed second time; apply finished with 2 join_workers updates |
| ~22:14 | Octopus post-deploy [HEALTH] check passed; deploy success |
| ~22:30 | RW namespace checked — many pods stuck ContainerCreating/Init:0/1 |
| ~22:35 | Suspected istio-cni/ztunnel staleness on patched workers; bounced DS pods |
| ~22:50 | Partial RW recovery (wk-5 unblocked); wk-2 still stuck |
| ~23:00 | Found `no ztunnel connection` errors; ztunnel logs show `dial istiod.istio-system.svc: i/o timeout` |
| ~23:15 | DNS test from fresh pod: `connection timed out; no servers could be reached` → **cluster DNS is broken** |
| ~23:30 | CiliumNode investigation: cp-1 missing entirely, cp-2 wrong IP (.179 vs correct .181) |
| ~23:45 | Manual reconciler-equivalent: deleted stale CN, bounced cilium agents on cp-1 + cp-2 |
| ~23:55 | DNS test succeeds: `istiod.istio-system.svc.cluster.local → 10.101.33.234` |
| ~00:00 | ExternalSecrets stuck SecretSyncedError for 81m (refresh interval = 1h) |
| ~00:05 | Force-sync annotation → all 7 RW ExternalSecrets back to SecretSynced/Ready |
| ~00:10 | RW meta still CrashLoopBackOff — booted during DNS outage, has stale state |
| ~00:15 | Bounce ztunnel on wk-5 again (second time, now that DNS healthy) |
| ~00:20 | Deleted RW meta + compute + frontend + compactor + console pods to force fresh boot |
| ~00:25 | Fresh meta pod boots, completes IRSA chain successfully, hummock S3 access works ✓ |
| ~00:30 | All 14 RW pods Running; IRSA verified end-to-end (projected SA token → STS → S3) |
| ~01:00 | Two comprehensive coverage docs written: INCIDENT-COVERAGE-MATRIX + ROOK-CEPH-IMPLEMENTATION |
| ~02:30 | Session wrap; troubleshooting catalog drafted |

## Root cause(s)

**Layer 1 (the primary problem):**
CiliumNodes for cp-1 (`.29`) and cp-2 (`.181`) were drifted/missing from prior IP reshuffles after the [[2026-06-17-cp-oom-cascade]] and various resets. Cilium's eBPF datapath couldn't route traffic to pods on those CPs.

**Layer 2 (DNS death):**
CoreDNS pods happen to run on CP-1 and CP-2 (scheduling defaults). With Cilium routing broken to those CPs, kube-dns Service endpoints were unreachable from every pod in the cluster.

**Layer 3 (IRSA cascade):**
External-secrets operator's ClusterSecretStore "default" uses IRSA via projected SA tokens → STS. STS DNS resolution failed → ClusterSecretStore went NotReady → all dependent ExternalSecrets stuck SecretSyncedError. RW pods booted during this window with empty/stale credential env vars → AWS SDK fell through credential chain → hit IMDS at 169.254.169.254 → timeout (no IMDS on Talos on-prem).

**Layer 4 (the silent enabler):**
The `cilium-node-reconciler` CronJob deployed 2026-06-18 PM (PR #43) was SUPPOSED to auto-heal Layer 1 within 15 min. But its image `bitnamilegacy/kubectl:1.32` has an entrypoint bug — `ENTRYPOINT=kubectl` overrides our `command: ["/bin/sh", "-c", ...]`, so each cron run errored with "You must provide one or more resources by argument or filename" and exited. The safety net was DEPLOYED but NO-OP for ~24h.

## What we did (manual recovery)

The recovery sequence — order matters:

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# 1. Verify worker memory hot-add finished cleanly
for ip in 10.10.82.21 10.10.82.22 10.10.82.26 10.10.82.27 10.10.82.28 10.10.82.178 10.10.82.180; do
  talosctl --nodes $ip --endpoints $ip memory | tail -1
done
# Confirmed: all 7 at 11941 MB ✓

# 2. Fix CiliumNode CP drift (manual reconciler-equivalent)
kubectl $KCONFIG delete ciliumnode talos-cp-op-dev-2
kubectl $KCONFIG -n kube-system delete pod \
  -l k8s-app=cilium \
  --field-selector spec.nodeName=talos-cp-op-dev-1
kubectl $KCONFIG -n kube-system delete pod \
  -l k8s-app=cilium \
  --field-selector spec.nodeName=talos-cp-op-dev-2

# 3. Verify CiliumNodes correct + DNS recovers
sleep 30
kubectl $KCONFIG get ciliumnodes
kubectl $KCONFIG run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup istiod.istio-system.svc.cluster.local

# 4. Force-sync ExternalSecrets (stuck on 1h refresh)
for es in $(kubectl $KCONFIG -n risingwave get externalsecret -o name); do
  kubectl $KCONFIG -n risingwave annotate $es force-sync=$(date +%s) --overwrite
done

# 5. Bounce istio-cni + ztunnel on workers that had kubelet bounces (wk-2/3/5/7)
for node in talos-wk-op-dev-2 talos-wk-op-dev-3 talos-wk-op-dev-5 talos-wk-op-dev-7; do
  kubectl $KCONFIG -n istio-system delete pod \
    -l app=ztunnel --field-selector spec.nodeName=$node
  kubectl $KCONFIG -n istio-system delete pod \
    -l k8s-app=istio-cni-node --field-selector spec.nodeName=$node
done

# 6. Delete dead RW pods so they boot with fresh creds
kubectl $KCONFIG -n risingwave delete pod \
  risingwave-meta-default-0 risingwave-compute-default-0 \
  --ignore-not-found
kubectl $KCONFIG -n risingwave delete pod -l app=risingwave-frontend --ignore-not-found
kubectl $KCONFIG -n risingwave delete pod -l app=risingwave-compactor --ignore-not-found

# 7. Watch full recovery
sleep 60
kubectl $KCONFIG -n risingwave get pods -o wide
```

## IaC changes that came out of this

| # | What | Track | Status |
|---|---|---|---|
| 1 | URGENT — cilium-node-reconciler image fix | 1.5 | Pending PR next session |
| 2 | Runbook Case B-2 (hostname patch-back, no reset) | 1.5 | Pending PR (drafted in WIP) |
| 3 | PromRule `ClusterDNSUnreachable` | 4 NEW | Pending PR |
| 4 | PromRule `IRSAFailureCascade` | 4 NEW | Pending PR |
| 5 | Deploy stakater/Reloader (auto-restart on Secret change) | 5 NEW | Pending PR |
| 6 | ExternalSecret refresh 1h → 5m on critical paths | 5 NEW | Pending PR |
| 7 | `istio-ambient-recovery` CronJob | 1.5 | Pending PR |
| 8 | DS config-hash auto-restart | 4 NEW | Pending PR |
| 9 | Kyverno pod-GC for stuck CrashLoopBackOff | 3 | Pending PR |
| 10 | pod-identity-webhook priority barrier | 5 NEW | Pending PR |

Plus:
- **INCIDENT-COVERAGE-MATRIX-2026-06-19.md** — full 17-mode IaC gap matrix
- **ROOK-CEPH-IMPLEMENTATION-2026-06-19.md** — Rook architecture + phases + recovery

## Lessons learned

1. **One bug in a safety net = no safety net.** The reconciler image entrypoint bug invalidated 24h of "auto-heal". Validate end-to-end behavior, not just deployment success.
2. **DNS death is a stealth killer.** Many systems (ExternalSecrets, IRSA, ztunnel, Flux) silently degrade when DNS breaks. A single PromRule for cluster DNS reachability catches all of them.
3. **Order of operations matters for recovery.** Bouncing ztunnel before DNS is restored is pointless — fresh ztunnel hits the same DNS error. Always fix the root layer first, then unblock downstream.
4. **The compact() precondition was a WIN.** PR #40's precondition fired cleanly during the hot-add race with our designed "wait and re-run" message. Proved the value of "fail loud, not silent."
5. **Manual recovery procedure is a runbook artifact.** Tonight's sequence is now codified across the 6-folder troubleshooting catalog.

## Related entries

- [[../01-cluster-control-plane/ciliumnode-drift]] — primary root-cause class
- [[../01-cluster-control-plane/kubelet-cn-mismatch]] — case B-2 NEW proven twice tonight
- [[../03-networking/cluster-dns-failure]] — Layer 2 symptom
- [[../03-networking/istio-cni-ztunnel-stale]] — sister symptom
- [[../04-secrets-credentials/clustersecretstore-dns-dependency]] — Layer 3 entry
- [[../04-secrets-credentials/irsa-imds-fallback]] — Layer 3 entry
- [[../04-secrets-credentials/externalsecret-stale-sync]] — downstream cleanup
- [[../04-secrets-credentials/rw-recovery-after-secret-sync]] — RW-specific recovery
- [[../05-terraform-octopus/compact-data-source-race]] — PR #40 precondition origin
- [[2026-06-17-cp-oom-cascade]] — original cause of CP IP shuffle
- [[2026-06-18-cilium-orphan-cert-cascade]] — same root cause, prior day

## Memory pointers

- `[Session state Jun 19]` — full session resume narrative
- `[INCIDENT-COVERAGE-MATRIX-2026-06-19]` — 17-row IaC gap matrix
- `[ROOK-CEPH-IMPLEMENTATION-2026-06-19]` — Rook arch + phases
