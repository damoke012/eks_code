# Runbook: Flux bootstrap from scratch (cluster rebuild path)

**For**: INFRA-1542 (Flux bootstrap automation)
**Last validated**: 2026-06-23 op-usxpress-dev (steady state)
**Target audience**: anyone bringing up a NEW Talos cluster that should run our on-prem Flux topology

## When to use this

- Bringing up a new cluster (e.g., QA, prod)
- Recovering after a "lost cluster" scenario (etcd corrupted, all 3 CPs destroyed)
- Migrating Flux ownership from one repo to another (rare)

This runbook is **documentation, not automation**. Full Terraform automation is INFRA-1542's longer-term scope — pinned for future work.

## Prerequisites

| Prerequisite | How to verify |
|---|---|
| Talos cluster up + kubeconfig works | `kubectl get nodes` — all Ready |
| Cluster's IRSA OIDC provider in AWS | `aws iam get-open-id-connect-provider --open-id-connect-provider-arn ...` |
| iaac-talos terraform applied for the cluster | check `outputs.tf` outputs (oidc_provider_arn, octopus_worker_role_arn, etc.) |
| GitHub deploy key / PAT for the Flux repo | tested via `git clone` |
| Network: cluster can reach github.com over 443 | from any worker: `kubectl run test --rm -it --image=alpine -- wget -qO- https://github.com` |
| Network: cluster can reach S3 (if Flux source uses git + helm in S3) | similar |

## Step 1 — Install Flux CLI on the bootstrapper machine

```bash
curl -s https://fluxcd.io/install.sh | sudo bash
flux version --client
# Verify the version matches what's pinned in the Flux source-controller image you'll install
```

## Step 2 — Pre-flight the cluster

Run the `/onprem-safety` skill checklist first. Confirm CP memory headroom, etcd quorum, no existing Flux installation.

```bash
# Should return no resources — confirms no existing Flux
kubectl get crd | grep fluxcd
kubectl get ns flux-system 2>/dev/null && echo "WARN: flux-system exists" || echo "clean"
```

## Step 3 — Bootstrap Flux pointing at the cluster repo

For op-usxpress-dev (template — replace cluster path for QA):

```bash
export GITHUB_TOKEN=<your_pat_with_repo_scope>

flux bootstrap github \
  --owner=variant-inc \
  --repository=iaac-talos-flux-cluster \
  --branch=master \
  --path=clusters/bm-dev \
  --personal=false \
  --read-write-key
```

For QA cluster (example):

```bash
flux bootstrap github \
  --owner=variant-inc \
  --repository=iaac-talos-flux-cluster \
  --branch=master \
  --path=clusters/op-usxpress-qa \    # NEW path under clusters/
  --personal=false \
  --read-write-key
```

Before the QA bootstrap can succeed, the new `clusters/op-usxpress-qa/` subdir + Kustomization CRs must exist in iaac-talos-flux-cluster.

The bootstrap will:
1. Create `flux-system` namespace
2. Install controllers (source, kustomize, helm, notification)
3. Add a deploy key to the GitHub repo
4. Push a `flux-system` Kustomization to the cluster pointing at the path you specified
5. Reconcile in a loop

## Step 4 — Wait for the cluster Kustomizations to apply

```bash
# Watch them come up
watch -n 5 'flux get kustomizations -A'
```

Expected ordering on op-usxpress-dev:
1. `flux-system` (the bootstrap one) → Ready=True
2. `infra` (which holds GitRepository pointer to iaac-talos-flux-platform) → Ready=True
3. Each child Kustomization (cilium-config, rook-ceph-operator, rook-ceph-cluster, istio-*, prometheus, velero, etcd-backup, etc.) → cascade Ready=True

Expect failures during first roll for ANY Kustomization whose AWS prerequisites haven't been applied yet (e.g., Velero needs IAM role + S3 bucket). For those, the Kustomization will sit at NotReady — that's fine.

## Step 5 — Run iaac-talos Octopus apply (AWS prerequisites)

In Octopus UI:
1. Project `iaac-talos` → Variables → set `TfApply = true`
2. Releases → latest `feature/<cluster>-dev.x.y.z` → Deploy → Development
3. Verify the plan output shows ONLY expected new resources (no drift)
4. Approve apply if plan is clean
5. After apply: flip `TfApply = false` (binding rule — leave OFF after use)

## Step 6 — Seed the AWS Secrets Manager secrets the cluster expects

```bash
# Talosconfig for etcd-backup
aws secretsmanager create-secret \
  --name <cluster>/talosconfig \
  --secret-string file://<path-to-talosconfig> \
  --tags '[{"Key":"Cluster","Value":"<cluster>"},{"Key":"Purpose","Value":"etcd-backup"}]' \
  --profile usx-dev --region us-east-2

# Other cluster-specific secrets (rw operator, postgres creds, etc.) — refer to ExternalSecret YAMLs in
# iaac-talos-flux-platform to know which keys to seed
```

## Step 7 — Verify cluster is steady-state

```bash
flux get kustomizations -A | awk 'NR==1 || $4!="True"'
# Should print only the header — all Kustomizations Ready=True

kubectl get pods -A | grep -vE "Running|Completed"
# Should be near-empty (only transient ContainerCreating)

kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s | head
# HEALTH_OK
```

## Step 8 — Validate backups end-to-end

```bash
# Velero — should already have run the daily-full schedule by tomorrow 02:00 UTC
velero backup get | tail -5

# Trigger a one-off small test
velero backup create test-bootstrap --include-namespaces prometheus --wait
velero backup describe test-bootstrap | grep Phase
# Expected: Completed

# etcd-backup — once INFRA-1547 lands
kubectl -n etcd-backup get cronjob
kubectl -n etcd-backup create job --from=cronjob/etcd-snapshot-to-s3 test-bootstrap
kubectl -n etcd-backup logs job/test-bootstrap --tail=30
aws s3 ls s3://etcd-snapshots-<cluster>/ --recursive
```

## Rollback

If bootstrap goes sideways:

```bash
# Tear down Flux without touching workloads
flux uninstall --silent
kubectl delete ns flux-system

# Cluster is now Flux-free; re-bootstrap with corrected args
```

This does NOT delete workloads created by Flux Kustomizations (they have owner refs to Flux Kustomizations, which would normally cascade — but `flux uninstall` removes the CRDs first, breaking the cascade).

Be careful: if you re-bootstrap with a different `--path`, the new Flux installation may try to remove resources that the old one had created if it doesn't see them in the new path. Use `--path` consistently.

## Known gotchas

- **Network**: if the cluster cant reach github.com on 443, Flux source-controller goes NotReady forever
- **GitHub deploy key conflict**: if you bootstrap twice without cleaning up, deploy keys accumulate. Trim manually via the GitHub repo settings UI.
- **Branch protection**: if `master` requires PR review, the bootstrap command's auto-PR won't merge automatically. Bootstrap with a PAT that has admin permissions, OR have a maintainer merge the bootstrap PR.
- **Existing PSA-restricted namespaces**: Flux controllers themselves need to satisfy restricted PSA if you've labeled `flux-system` that way. The chart `flux-system` namespace doesn't currently have a PSA label — leave it alone.

## Related

- [`session-state-jun23`](../../../memory/session_state_jun23.md) — closed-state reference (what op-usxpress-dev looks like steady state)
- [`onprem-flux-repo-layout`](../../../memory/onprem_flux_repo_layout.md)
- [`onprem-cluster-tf-state-location`](../../../memory/onprem_cluster_tf_state_location.md)
- [`onprem-safety` skill](../../../.claude/skills/onprem-safety/SKILL.md)
- INFRA-1542 ticket — pending full automation
