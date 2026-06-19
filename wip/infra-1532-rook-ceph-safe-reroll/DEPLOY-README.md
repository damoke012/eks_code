# INFRA-1532 — Rook-Ceph Re-Roll (post-incident, safe placement)

After the 2026-06-17 OOM cascade incident, this re-roll has STRICT worker-only CSI placement.

## What's different from the previous attempt

| Setting | Previous (broke cluster) | This version (safe) |
|---|---|---|
| `csi.pluginTolerations` | `[{operator: Exists}]` ← landed on CPs | `[]` ← won't tolerate CP taint |
| `csi.provisionerTolerations` | `[{operator: Exists, key: ...control-plane}]` | `[]` |
| `csi.pluginNodeAffinity` | not set | `node-role.kubernetes.io/control-plane=DoesNotExist` |
| `csi.provisionerNodeAffinity` | not set | `node-role.kubernetes.io/control-plane=DoesNotExist` |
| `csi.provisionerReplicas` | 2 (default) | 1 |
| mon/mgr resources | 250m/512Mi req | 100m/256Mi req |
| osd resources | 500m/2Gi req | 250m/1Gi req |
| CP RAM | 4 GB | 8 GB (bumped by iaac-talos PR #36) |

## Pre-merge checklist

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# 1. Cluster healthy, all 10 nodes Ready
kubectl $KCONFIG get nodes
# Expect: 3 CPs Ready + 7 workers Ready

# 2. Workers have free memory (Rook will request ~3GB across them)
kubectl $KCONFIG top nodes 2>/dev/null
# OR check each via talosctl memory

# 3. Confirm CP nodes won't tolerate plugin DS
kubectl $KCONFIG describe node talos-cp-op-dev-1 | grep -A2 Taints
# Expect: NoSchedule taint on control-plane

# 4. Confirm Tim's RW pods are stable
kubectl $KCONFIG -n risingwave get pods | grep -vE "Completed|Running"
# Expect: empty (just header)

# 5. local-path SC available
kubectl $KCONFIG get sc local-path

# 6. Flux infra GitRepository reachable
flux get source git infra -n flux-system
```

## Apply sequence

### Phase 1 — Platform repo PR

```bash
cd ~/work/iaac-talos-flux-platform
git checkout op-dev && git pull
git checkout -b feature/INFRA-1532-rook-ceph-safe-reroll
mkdir -p infrastructure/rook-ceph-operator infrastructure/rook-ceph-cluster

# Copy files from this WIP into the repo
# (use codespace-wsl-transfer skill OR cat-heredoc pattern)

git add infrastructure/rook-ceph-operator infrastructure/rook-ceph-cluster
git commit -m "INFRA-1532: Rook-Ceph re-roll with strict worker-only CSI placement"
git push -u origin feature/INFRA-1532-rook-ceph-safe-reroll
gh pr create --base op-dev --title "INFRA-1532: Rook-Ceph re-roll (post-incident, safe placement)"
```

### Phase 2 — Cluster repo PR

```bash
cd ~/work/iaac-talos-flux-cluster
git checkout master && git pull
git checkout -b feature/INFRA-1532-rook-ceph-safe-reroll

# Append rook-ceph-flux-kustomizations.yaml content to:
# clusters/bm-dev/flux-system/infra.yaml

git add clusters/bm-dev/flux-system/infra.yaml
git commit -m "INFRA-1532: re-add rook-ceph-operator + rook-ceph-cluster Flux Kustomizations"
git push -u origin feature/INFRA-1532-rook-ceph-safe-reroll
gh pr create --base master --title "INFRA-1532: Rook-Ceph Flux Kustomizations (safe re-roll)"
```

### Phase 3 — Merge order

1. Merge platform PR first (manifests must exist in git)
2. Wait ~30s for `infra` GitRepository to fetch
3. Merge cluster PR (adds Kustomizations that reference the new path)

### Phase 4 — Watch bring-up

```bash
# WHILE operator installs, verify CSI plugin DS does NOT spawn on CPs
watch -n 5 'kubectl --server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true \
  -n rook-ceph get ds -o wide 2>/dev/null; \
  echo; \
  kubectl --server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true \
  -n rook-ceph get pods -o wide 2>/dev/null | head -20'

# Expected DaemonSet ROW: DESIRED=7 CURRENT=7 (not 10!)
# That confirms only workers get CSI plugins.

# Cluster bring-up watch
kubectl --server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true \
  -n rook-ceph get cephcluster -w
```

## Stop conditions (back out if any of these happen)

| Stop sign | What to do |
|---|---|
| CSI plugin DS shows DESIRED=10 (one per CP) | Suspend Flux, revert PR. Placement values didn't take. |
| Any CP node memory drops below 1GB available | Suspend Flux, manually delete rook DS, investigate. |
| etcd health check fails on any CP | Same as above — protect quorum first. |
| Tim's RW any pod goes CrashLoopBackOff during install | Investigate before continuing. |

## Validation after HEALTH_OK

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# 1. CephCluster Ready
kubectl $KCONFIG -n rook-ceph get cephcluster
# Expect: PHASE=Ready, HEALTH=HEALTH_OK

# 2. CSI ONLY on workers
kubectl $KCONFIG -n rook-ceph get pods -o wide | grep -E "csi-|provisioner" | awk '{print $7}' | sort -u
# Expect: ONLY talos-wk-op-dev-* lines, NO talos-cp-op-dev-*

# 3. StorageClasses present
kubectl $KCONFIG get sc | grep ceph

# 4. Smoke test PVC binds
cat <<'EOF' | kubectl $KCONFIG apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-smoke
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-block
  resources:
    requests:
      storage: 1Gi
EOF
kubectl $KCONFIG get pvc ceph-smoke
kubectl $KCONFIG delete pvc ceph-smoke
```

## RW protection

Same as before. Touches only:
- new files in `infrastructure/rook-ceph-operator/` and `infrastructure/rook-ceph-cluster/`
- new lines in `clusters/bm-dev/flux-system/infra.yaml`
- the rook-ceph namespace (newly created)

Tim's RW namespace untouched.

## Background context

See `docs/incidents/2026-06-17_cp-oom-cascade.md` for the full story of the previous attempt that crashed the cluster.
