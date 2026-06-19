# Control Plane Capacity Exhaustion (OOM Cascade)

**Symptom:**
- One or more CPs go NotReady; kube-apiserver becomes intermittently unreachable
- `kubectl get nodes` slow / times out
- Pods scheduled on CPs evicted with `MemoryPressure` reason
- DaemonSets that landed on CPs (CSI plugin pods, etc.) crash-loop with OOM
- VIP (`10.10.82.50:6443`) becomes unstable as kube-apiserver flaps

**Root cause:**
The cluster's CP VMs were originally 4 GB each. Adding any cluster-wide DaemonSet or operator (especially CSI plugins with `tolerations: - operator: Exists`) caused workload pods to schedule on CPs and exhaust memory. Once CPs hit ~95% memory, kubelet OOMKills the largest pod, often itself or critical control-plane components.

The 2026-06-17 incident: CSI plugin DaemonSet for Rook scheduled on CPs (default tolerations), pushed CPs from ~1 GB free → 0 free, kube-apiserver OOMKilled, cascade.

**IaC coverage:** ✓ (CP RAM bumped to 8 GB) + ✓ (placement rules enforced in DaemonSets)

**IaC location:**
- `iaac-talos/deploy/terraform/variables.tf` — CP `cp_memory_mb` (Octopus `TF_VAR_cp_memory_mb=8192`)
- `iaac-talos-flux-platform/infrastructure/rook-ceph-cluster/cephcluster.yaml` — `placement.all` excludes CPs via `node-role.kubernetes.io/control-plane DoesNotExist`
- All operator HelmReleases — `tolerations: []` (no `Exists`) + explicit `nodeAffinity`

### Resolution via IaC

For fresh clusters: 8 GB CP RAM + strict DaemonSet placement rules mean this class of failure can't happen. Every DaemonSet/operator/CSI driver PR must pass the `/onprem-safety` checklist:

```
[ ] DaemonSet spec has explicit nodeSelector OR affinity excluding CP nodes
[ ] Tolerations are [] OR scoped to specific keys (NOT operator: Exists)
[ ] Container memory requests sum to < 500 MB per worker
[ ] CP memory check passed (> 1 GB available on each)
```

### Manual resolution (if cascade in progress)

**Step 1 — Stop the bleeding (suspend the offending Flux Kustomization):**

```bash
KCONFIG="--server=https://<healthy-cp-ip>:6443 --insecure-skip-tls-verify=true"

# Find the Kustomization that owns the rogue DS
kubectl $KCONFIG -n flux-system get kustomizations | grep -i <name>

# Suspend it
kubectl $KCONFIG -n flux-system patch kustomization <name> \
  --type=merge -p '{"spec":{"suspend":true}}'
```

**Step 2 — Free CP memory:**

```bash
# Delete the rogue DS (Flux is suspended so it won't recreate)
kubectl $KCONFIG -n <ns> delete daemonset <ds-name>

# OR delete just the pods on CPs (DS will replace per its affinity — if affinity fixed)
for cp in talos-cp-op-dev-1 talos-cp-op-dev-2 talos-cp-op-dev-3; do
  kubectl $KCONFIG -n <ns> delete pod \
    -l <ds-label> \
    --field-selector spec.nodeName=$cp
done
```

**Step 3 — Verify CP recovery:**

```bash
export TALOSCONFIG=/tmp/talosconfig-op-usxpress-dev
for ip in 10.10.82.29 10.10.82.179 10.10.82.181; do
  echo "=== $ip ==="
  talosctl --nodes $ip --endpoints $ip memory 2>&1 | tail -1
done
# Expect: each CP > 2 GB free
```

**Step 4 — Apply IaC fix in PR + redeploy:**

Fix the DaemonSet spec to exclude CPs (see Prevention), PR, merge, unsuspend Kustomization.

```bash
kubectl $KCONFIG -n flux-system patch kustomization <name> \
  --type=merge -p '{"spec":{"suspend":false}}'
kubectl $KCONFIG -n flux-system annotate kustomization <name> \
  reconcile.fluxcd.io/requestedAt="$(date -u +%s)" --overwrite
```

### Verification

```bash
# 1. CP memory free per node > 1 GB
for ip in 10.10.82.29 10.10.82.179 10.10.82.181; do
  free_mb=$(talosctl --nodes $ip --endpoints $ip memory 2>&1 | tail -1 | awk '{print $4}')
  if [ "$free_mb" -lt 1024 ]; then
    echo "FAIL: $ip has $free_mb MB free (< 1024)"
  else
    echo "OK: $ip has $free_mb MB free"
  fi
done

# 2. No workload pods on CPs (only kube-system + cilium DS expected)
kubectl $KCONFIG get pods -A --field-selector spec.nodeName=talos-cp-op-dev-1 -o wide
```

### Prevention

- CP RAM at 8 GB (codified — Octopus var `TF_VAR_cp_memory_mb=8192`)
- All operator/DS PRs MUST pass `/onprem-safety` Rule 1 (explicit placement) + Rule 2 (CP memory check)
- PromRule `KubeletNodeMemoryPressure` (Track 3) — fires when CP free memory < 1 GB for 5 min
- Code review: refuse any spec with `tolerations: - operator: Exists`

### Related

- [[../06-incidents-timeline/2026-06-17-cp-oom-cascade]] — the founding incident
- [[../../../iac-sweep-jun18/track3-incident-hardening/]] — Track 3 drafts
- `/onprem-safety` skill — pre-deploy gate
- [[etcd-quorum-loss]] — downstream of CP OOM

### Memory pointers

- `[onprem_topology_corrected_jun17]` — CPs originally 4 GB → bumped to 8 GB after 2026-06-17
- `[Confirm before executing]` — slow down before any CP-affecting deploy
