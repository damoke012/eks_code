# QA Cluster Bootstrap Checklist + Lessons-Learned (Carries to PROD)

**Target audience:** Whoever stands up the next on-prem Talos cluster (QA, then PROD). This document captures the bootstrap ORDER + IaC settings that prevent the issues encountered on op-usxpress-dev between 2026-05 and 2026-06-22.

**Mission:** Cluster comes up automatically from IaC + a single planned Octopus runbook sequence. No manual recovery should be required for a fresh bootstrap.

## Pre-bootstrap: IaC repos must be in correct state

### A. `iaac-talos` (Talos machine config + cluster definition)

- Branch base: `feature/op-usxpress-dev` (NOT master — see memory `[iaac-talos PR base = feature/op-usxpress-dev]`)
- For QA: fork to `feature/op-usxpress-qa` with QA-specific values
- Worker count: ≥ 7 (3 CP + 7 worker minimum for proper failure-domain spread)
- Worker RAM: 12 GB minimum (post 2026-06-17 incident, see `[Worker RAM 4→12 GB]`)
- CP RAM: 8 GB minimum (post 2026-06-17, was 4 GB → OOM cascade)
- `etcd_quota_backend_bytes`: ≥ 8 GB (raise from default 2 GB to prevent mon/etcd disk pressure issues)

### B. `iaac-talos-flux-cluster` (Flux Kustomization manifests)

For the QA cluster, the `clusters/<qa-cluster>/flux-system/infra.yaml` should have:

- **Kustomization ordering via `dependsOn`** — match op-dev ordering, but with the **cross-cluster-eso split** (see [[external-secrets-config-cascade]]):
  ```
  external-secrets ──┬─→ external-secrets-config (default CSS only, wait: true)
                     └─→ cross-cluster-eso (cloud-eks CSS, wait: false)  ← NEW separate Kustomization
  ```
- **`wait: false` on `cross-cluster-eso` Kustomization** — prevents bootstrap chicken-and-egg
- **All other Kustomizations: `wait: true`** (cluster convention)

### C. `iaac-talos-flux-platform` (resource manifests)

- **Split `infrastructure/external-secrets-config/`** into TWO directories:
  - `infrastructure/external-secrets-config/` — keep `default` CSS only (AWS SM, works without external bootstrap)
  - `infrastructure/cross-cluster-eso/` — NEW: `cloud-eks` CSS + onprem-platform-rbac (requires Octopus runbook seed)
- **`infrastructure/app-secrets/`** — only ExternalSecrets that use the `default` CSS at first deploy
- ExternalSecrets that depend on `cloud-eks` CSS: keep in source as comment-blocked manifests; uncomment + apply AFTER Octopus runbook seeds the secret (see Phase 6)

### D. Octopus on-prem stack

- OnPremise Octopus space MUST exist BEFORE Phase 6 (see `[Octopus worker progress]`)
- `onprem-platform-bootstrap` project MUST be deployed in the OnPremise space
- `Seed Cross-Cluster ESO Token` runbook MUST be configured + tested against a known-good cloud EKS cluster

## Bootstrap phases (in strict order)

### Phase 1 — Cluster up (Talos)

```
1. Terraform plan + apply iaac-talos (CP + workers)
2. talosctl bootstrap on CP1
3. Verify 3 CPs + N workers Ready
4. Confirm etcd quorum
5. Capture talosconfig + kubeconfig to tfstate (S3)
```

**Verification:**
- `kubectl get nodes` → all Ready
- `talosctl etcd members` → all 3 healthy
- `kubectl get componentstatuses` (or equivalent) → all OK

### Phase 2 — Flux up (cluster-level)

```
1. Apply flux-system Kustomization (bootstrap Flux against iaac-talos-flux-cluster master)
2. Wait for flux-system Kustomization Ready=True
3. GitRepository "infra" pulls iaac-talos-flux-platform op-dev (or qa-dev for QA)
```

**Verification:**
- `flux get sources git -A` → all Ready
- `kubectl -n flux-system get kustomization flux-system` → Ready=True

### Phase 3 — Platform foundation (cert-manager, trust-manager, gateway-api)

These have no external dependencies and should reconcile cleanly.

**Verification:**
- All Phase-3 Kustomizations Ready=True within ~5 min

### Phase 4 — Service mesh + ingress (Istio, gateway)

**Verification:**
- istio-cni, istio-ztunnel, istio-istiod, istio-ingress all Ready=True

### Phase 5 — External secrets foundation (split)

- `external-secrets` Kustomization (operator) → reconciles first
- `external-secrets-config` Kustomization (default CSS only, `wait: true`) → goes Ready when default CSS applies (immediate)
- `cross-cluster-eso` Kustomization (cloud-eks CSS, `wait: false`) → goes Ready immediately (does NOT wait on the CSS being ready; the CSS will reconcile separately later)

**Verification:**
- All 3 Ready=True
- `kubectl get clustersecretstore` → `default` Ready=True, `cloud-eks` Ready=False (expected, will be fixed in Phase 7)

### Phase 6 — Octopus worker + app-secrets + downstream

- `app-secrets` Kustomization (only ExternalSecrets that use `default` CSS) → Ready=True
- `octopus-worker` Kustomization → Ready=True; Octopus worker pod registers with the OnPremise Octopus space

**Verification:**
- All ExternalSecrets in `app-secrets/` sync successfully
- Octopus UI shows the new on-prem worker registered

### Phase 7 — Seed cloud-eks CSS via Octopus runbook

From Octopus UI:
1. Navigate to OnPremise space → onprem-platform-bootstrap project
2. Run the **Seed Cross-Cluster ESO Token** runbook against the new cluster as target
3. Wait for completion

**Verification:**
- `kubectl -n external-secrets get secret cloud-eks-reader-token` → exists with `token` + `ca` keys
- `kubectl get clustersecretstore cloud-eks` → Ready=True

### Phase 8 — Restore cross-cluster ExternalSecrets

Per the comment-blocked manifests in `infrastructure/app-secrets/`:
1. Uncomment the ExternalSecret manifests that depend on `cloud-eks` CSS
2. Commit + merge to op-dev (or qa-dev) branch
3. Flux applies them
4. Verify they sync from cloud EKS to on-prem namespaces

### Phase 9 — Storage (Rook-Ceph)

```
1. Rook operator (rook-ceph-operator Kustomization)
2. CephCluster (rook-ceph-cluster Kustomization)
3. Operator runs osd-prepare jobs on each worker (uses deviceFilter `^sdb$`)
4. OSDs come up + join CRUSH automatically
```

**Verification:**
- `kubectl -n rook-ceph get cephcluster` → PHASE=Ready, HEALTH=HEALTH_OK
- `ceph -s` (via toolbox): mon quorum, all OSDs up/in, all PGs active+clean
- PVC smoke test:
  ```bash
  cat <<EOF | kubectl apply -f -
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata: { name: ceph-smoke-test, namespace: default }
  spec:
    storageClassName: ceph-block
    accessModes: [ReadWriteOnce]
    resources: { requests: { storage: 1Gi } }
  EOF
  ```
  Should bind in < 30 sec.

### Phase 10 — Observability + apps

- Prometheus, Grafana, ARC runner, RisingWave (if applicable), other apps
- Each Kustomization should go Ready=True without intervention

## What to do if something fails

For each failure mode, see the corresponding catalog entry:

| Failure | Entry |
|---|---|
| Worker OOM during bootstrap | [01-cluster-control-plane/cp-capacity-exhaustion.md](01-cluster-control-plane/cp-capacity-exhaustion.md) |
| Cilium DNS issues | [03-networking/cluster-dns-failure.md](03-networking/cluster-dns-failure.md) |
| Rook OSD CrashLoop on auth | [02-storage/rook-osd-keyring-missing.md](02-storage/rook-osd-keyring-missing.md) |
| Rook OSD CrashLoop on PG peering | [02-storage/rook-osd-pg-peering-crash.md](02-storage/rook-osd-pg-peering-crash.md) |
| `external-secrets-config` cascade | [04-secrets-credentials/external-secrets-config-cascade.md](04-secrets-credentials/external-secrets-config-cascade.md) |
| ClusterSecretStore DNS dependency | [04-secrets-credentials/clustersecretstore-dns-dependency.md](04-secrets-credentials/clustersecretstore-dns-dependency.md) |
| IRSA → IMDS fallback | [04-secrets-credentials/irsa-imds-fallback.md](04-secrets-credentials/irsa-imds-fallback.md) |
| Rook mon CrashLoop | [02-storage/rook-mon-crashloop.md](02-storage/rook-mon-crashloop.md) |
| Rook operator restart breaks state | [02-storage/rook-operator-restart-state-loss.md](02-storage/rook-operator-restart-state-loss.md) |
| Stuck finalizer | [02-storage/stuck-finalizer-removal.md](02-storage/stuck-finalizer-removal.md) |

## Restore-from-disaster checklist

If the cluster needs to be fully recreated (e.g., disaster scenario):

```
1. Terraform destroy + recreate (Phase 1 above) — restores Talos cluster
2. talosconfig + kubeconfig restored from tfstate (S3)
3. Flux bootstrap re-applied → reconciles all Kustomizations
4. Octopus runbooks re-run (Phase 7) — re-seeds cross-cluster CSS
5. App data restored from S3/Mongo Atlas backups (per app's DR runbook)
```

**Key DR principle**: NEVER manually create a Secret on the cluster that isn't IaC'd. Every Secret must be either:
- Generated by ESO from AWS Secrets Manager (most apps)
- Seeded by an Octopus runbook that's idempotent + IaC-recorded (cross-cluster bridge, license keys)
- Persisted in tfstate (talosconfig, kubeconfig — Terraform manages these)

This way, a cluster-destroy + recreate always produces a working cluster.

## Open IaC gaps (must close before QA cluster goes prod-equivalent)

| Gap | Track | Ticket |
|---|---|---|
| Cross-cluster CSS split into separate Kustomization with `wait: false` | On-prem | INFRA-* (TBD this session) |
| OnPremise Octopus space + `Seed Cross-Cluster ESO Token` runbook IaC'd | On-prem | INFRA-* (TBD this session) |
| `pod-identity-webhook` caBundle auto-refresh on CP rebuild | On-prem | INFRA-* (TBD this session) |
| Mon PVC size increase (avoid the 21-27% available warning) | On-prem | INFRA-* (TBD this session) |
| OSD recovery Job templates as IaC artifacts (in `rook-recovery-jobs/`) | On-prem | INFRA-* (TBD this session) |
| `rook-ceph-tools` toolbox always-present as IaC (not ad-hoc) | On-prem | INFRA-* (TBD this session) |

## Related

- [[../wip/iac-sweep-jun18/INCIDENT-COVERAGE-MATRIX-2026-06-19.md]] — 17-row failure matrix
- [[../wip/iac-sweep-jun18/ROOK-CEPH-IMPLEMENTATION-2026-06-19.md]] — Rook architecture phases
- Memory: `[Confirm before executing]`, `[Zero cloud impact]`, `[Protect RW on op-usxpress-dev]`, `[Issue codify + push immediately]`
