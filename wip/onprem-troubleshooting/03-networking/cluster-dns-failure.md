# Cluster DNS Failure (CoreDNS Unreachable)

**Symptom:**
- New pods fail to start with errors mentioning `dial tcp: lookup ... i/o timeout`
- Fresh test pod: `kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- nslookup kubernetes.default` returns `connection timed out; no servers could be reached`
- ExternalSecrets show `SecretSyncedError` with `failed to retrieve credentials ... lookup sts.us-east-2.amazonaws.com: i/o timeout`
- ztunnel logs: `XDS client connection error ... lookup istiod.istio-system.svc: i/o timeout`
- Flux HelmRepository: `failed to fetch Helm repository index: ... dial tcp: lookup <repo-host>: i/o timeout`
- RisingWave/RW meta logs: hummock S3 access falls through to IMDS (which doesn't exist on Talos), times out

**Root cause:**
Cluster DNS works as a chain:
1. Pod → kube-dns Service IP (10.96.0.10) → CoreDNS Pod
2. CoreDNS Pod → upstream resolver (for external names)

If pod-to-CoreDNS-pod routing is broken, EVERYTHING that needs DNS dies. The most common cause on op-usxpress-dev:

**CiliumNode drift on the nodes where CoreDNS Pods live.** CoreDNS runs on CPs (`coredns-* on talos-cp-op-dev-1` and `-2` per scheduling defaults). If those CPs have stale or missing CiliumNode entries, Cilium's eBPF datapath can't program routes to their pods. The Service endpoints exist but are unreachable.

Other causes:
- CoreDNS pods themselves crashed/evicted (memory pressure on CPs)
- kube-proxy or Cilium kube-proxy-replacement not initialized on a node
- NetworkPolicy denying egress to kube-dns

**IaC coverage:** ⚠ (root-cause fix via reconciler is deployed but image broken; no DNS-health detection PromRule yet)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/cilium-hygiene/cronjob.yaml` — `cilium-node-reconciler` handles CN drift (image bug; URGENT fix pending)
- Planned: PromRule `ClusterDNSUnreachable` in Track 4 (NEW — drafted in `wip/iac-sweep-jun18/INCIDENT-COVERAGE-MATRIX-2026-06-19.md`)

### Resolution via IaC (when reconciler image fixed)

The reconciler CronJob would auto-detect [[ciliumnode-drift]] every 15 min and self-heal. With the image fix, today's DNS death would have resolved within 15 min of CP IP shuffle.

### Manual resolution

**Step 1 — Confirm cluster DNS is actually broken:**

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# Fresh pod DNS test
kubectl $KCONFIG run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup kubernetes.default 2>&1 | tail -10
# OK: returns 10.96.0.1 (kubernetes service)
# BROKEN: connection timed out

# CoreDNS pods alive?
kubectl $KCONFIG -n kube-system get pods -l k8s-app=kube-dns -o wide
# Expect: 2 pods Running

# Service endpoints populated?
kubectl $KCONFIG -n kube-system get endpoints kube-dns
# Expect: 6 endpoints (2 pods × 3 ports)
```

**Step 2 — Check CiliumNode alignment (most common root cause):**

```bash
# Compare CiliumNode IPs vs Node IPs
kubectl $KCONFIG get nodes -o wide
kubectl $KCONFIG get ciliumnodes -o wide

# Look for: missing CN entries, mismatched InternalIPs
```

**Step 3 — Apply reconciler-equivalent fix:**

If CoreDNS-hosting nodes have CN drift, follow [[ciliumnode-drift]] § Manual resolution:

```bash
# For each drifted node
kubectl $KCONFIG delete ciliumnode <stale-cn-name>

kubectl $KCONFIG -n kube-system delete pod \
  -l k8s-app=cilium \
  --field-selector spec.nodeName=<node-name>

sleep 30

# Verify CN recreated with correct IP
kubectl $KCONFIG get ciliumnodes
```

**Step 4 — Verify DNS recovered:**

```bash
kubectl $KCONFIG run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup istiod.istio-system.svc.cluster.local 2>&1 | tail -10
# Expect: Name: istiod.istio-system.svc.cluster.local / Address: <ClusterIP>
```

### Cascade implications (in-flight workloads when DNS dies)

When DNS goes down, these things ALSO break (and may need explicit recovery):

| Workload | Failure mode | Recovery after DNS restored |
|---|---|---|
| ExternalSecret operator | Can't reach AWS STS to assume IRSA role | Force-sync ExternalSecrets — [[../04-secrets-credentials/externalsecret-stale-sync]] |
| ztunnel (Istio ambient) | Can't reach istiod for xDS | Bounce ztunnel + istio-cni pods on affected nodes — [[istio-cni-ztunnel-stale]] |
| Flux | Can't fetch HelmRepository indexes | Flux retries on its own ~5 min cadence; no action |
| RW meta | Can't reach S3 hummock store (IRSA fails) | Delete RW pods so they boot fresh with working IRSA — [[../04-secrets-credentials/rw-recovery-after-secret-sync]] |
| Reloader / Argo / any operator with external dependencies | Stuck reconcile loops | Self-heal on retry |

### Verification

```bash
# 1. Cluster DNS works
kubectl $KCONFIG run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup kubernetes.default 2>&1 | tail -5

# 2. CoreDNS pods reachable
kubectl $KCONFIG -n kube-system exec deploy/coredns -- nslookup kubernetes.default 2>&1 | tail -5

# 3. New workload pods can start
kubectl $KCONFIG -n <some-ns> get pods --field-selector=status.phase=Pending
# Expect: empty or pods just being scheduled
```

### Prevention

- **URGENT** — fix the `cilium-node-reconciler` image (PR scoped in matrix). Auto-heals CN drift within 15 min.
- **PromRule `ClusterDNSUnreachable`** (Track 4 — drafted): probe pod runs every 5 min, alerts if `nslookup kubernetes.default` fails for 3+ min
- **Scheduling diversity**: ensure CoreDNS runs across multiple CPs (current: 2 replicas with anti-affinity)
- **PromRule `CoreDNSDown`**: fires if either CoreDNS pod NotReady > 2 min

### Related

- [[../01-cluster-control-plane/ciliumnode-drift]] — primary cause of DNS death
- [[../01-cluster-control-plane/cp-ip-shuffle]] — what triggers CN drift on CPs
- [[istio-cni-ztunnel-stale]] — common companion symptom
- [[../04-secrets-credentials/externalsecret-stale-sync]] — downstream of DNS death
- [[../04-secrets-credentials/irsa-imds-fallback]] — downstream of DNS death
- [[../06-incidents-timeline/2026-06-19-dns-irsa-rw-cascade]] — last night's cascade

### Memory pointers

- `[Session state Jun 19]` — DNS broken cluster-wide for ~80 min; CN drift on CPs the root cause
- `[Cilium node-reconciler LIVE]` — reconciler design (image bug)
