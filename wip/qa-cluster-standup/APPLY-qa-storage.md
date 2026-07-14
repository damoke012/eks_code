# Finish QA storage — apply guide (2026-07-14)

Deploys the local-path StorageClass + wires Rook-Ceph on op-usxpress-qa, so the
`ceph-block` SC appears and grafana's PVC binds. Two repos, both **GitOps (Flux)
— push to the branch and Flux reconciles**. (The Octopus-only rule is for
iaac-talos terraform; the Flux repos deploy by git push, unchanged here.)

Set your eks_code clone location:
```bash
EKS=~/work/eks_code   # adjust if different
```

## 1. flux-platform (branch op-qa): add the local-path-storage component
```bash
cd ~/work/iaac-talos-flux-platform
git checkout op-qa && git pull

mkdir -p infrastructure/local-path-storage
cp "$EKS"/wip/qa-cluster-standup/local-path-storage/*.yaml infrastructure/local-path-storage/

git add infrastructure/local-path-storage
git commit -m "INFRA-1589: codify local-path-storage (Talos /var path, privileged ns) for QA Rook mons"
git push origin op-qa
```

## 2. cluster repo (master): wire the 3 storage Kustomizations into QA
Open `clusters/op-usxpress-qa/flux-system/infra.yaml` and paste the three
Kustomizations from `qa-infra-storage-kustomizations.yaml` at the end (they slot
in after velero/etcd-backup — order in-file doesn't matter, dependsOn governs).
```bash
cd ~/work/iaac-talos-flux-cluster
git checkout master && git pull

# append (skip the comment header's duplicate '---' if your editor prefers):
cat "$EKS"/wip/qa-cluster-standup/qa-infra-storage-kustomizations.yaml \
  >> clusters/op-usxpress-qa/flux-system/infra.yaml

git add clusters/op-usxpress-qa/flux-system/infra.yaml
git commit -m "INFRA-1585: wire QA storage tier (local-path -> rook-ceph-operator -> rook-ceph-cluster)"
git push origin master
```

## 3. Reconcile + watch (QA context)
```bash
flux reconcile source git flux-system                 # pull cluster-repo change
flux reconcile source git infra                        # pull flux-platform op-qa change
flux get kustomizations -A | grep -iE 'local-path|rook|NAME'

# progression (a few min each):
kubectl -n local-path-storage get pods            # provisioner Running
kubectl get sc                                     # local-path appears, then ceph-block
kubectl -n rook-ceph get pods                      # operator -> mons (3) -> osds -> mgr
kubectl get cephcluster -n rook-ceph               # HEALTH_OK (allow a few min)
```

## 4. Confirm the fix
```bash
kubectl get sc ceph-block                                    # exists
kubectl -n monitoring get pvc                                # grafana PVC -> Bound
kubectl -n monitoring get pods -l app.kubernetes.io/name=grafana   # Running (was Pending)
```

## If mons hang Pending (the documented helper-pod trap)
Means the privileged ns label didn't take. It's in namespace.yaml, but to verify:
```bash
kubectl get ns local-path-storage -o jsonpath='{.metadata.labels}' ; echo
kubectl -n local-path-storage logs -l app=local-path-provisioner --tail=30
```
Ref: iaac-talos/deploy/docs/troubleshooting/02-storage/local-path-helper-pod-namespace.md

## Rollback
```bash
# cluster repo: git revert the infra.yaml commit, push (Flux prunes the 3 Kustomizations)
# flux-platform: rook/local-path namespaces are pruned when their Kustomizations go.
```

## Follow-ups
- **INFRA-1589**: backfill the same `infrastructure/local-path-storage/` to op-dev
  (replace Dev's manual local-path with this codified one) so Dev==QA==Prod.
- Verify `clusters/op-usxpress-qa/flux-system/infra-source.yaml` points the `infra`
  GitRepository at branch `op-qa` (it should — same pattern as Dev's op-dev).
