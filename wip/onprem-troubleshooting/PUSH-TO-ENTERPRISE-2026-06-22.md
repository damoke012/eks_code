# Push catalog + IaC drafts to enterprise repos — 2026-06-22

This document captures the EXACT WSL paste-blocks to push today's work to the right enterprise repos.

## Paste-block 1 — Pull tarballs from codespace transfer branch

```bash
# Pull both tarballs via raw URL (transfer branch is public)
BRANCH=transfer/rook-ceph-safe-reroll-jun17
BASE_URL=https://raw.githubusercontent.com/damoke012/eks_code/$BRANCH/archive/transfer-tarballs

mkdir -p /tmp/jun22-recovery
cd /tmp/jun22-recovery

curl -sSfL -o onprem-troubleshooting-2026-06-22.tar.gz \
  "$BASE_URL/onprem-troubleshooting-2026-06-22.tar.gz"
curl -sSfL -o cross-cluster-eso-restructure-jun22.tar.gz \
  "$BASE_URL/cross-cluster-eso-restructure-jun22.tar.gz"

# Verify sha256
echo "f383cb286e13a8657e4538b064f316c7bde15dd6b0bbcfa14ffbe58c384dd132  onprem-troubleshooting-2026-06-22.tar.gz" | sha256sum -c
echo "7b0200b64ef80f52cbcf79409f5da25c896f0d1e46abe15f89ce52c32eda06fc  cross-cluster-eso-restructure-jun22.tar.gz" | sha256sum -c

# Extract
tar -xzf onprem-troubleshooting-2026-06-22.tar.gz
tar -xzf cross-cluster-eso-restructure-jun22.tar.gz

ls -la
# Expected: onprem-troubleshooting/  cross-cluster-eso-restructure-jun22/
```

## Paste-block 2 — PR-D: catalog updates to iaac-talos enterprise repo

```bash
cd ~/work/iaac-talos
git fetch origin
git checkout feature/op-usxpress-dev
git pull origin feature/op-usxpress-dev

# Create branch for catalog updates
git checkout -b docs/troubleshooting-catalog-jun22-rook-eso-recovery

# Copy the catalog from /tmp/jun22-recovery/onprem-troubleshooting/ to deploy/docs/troubleshooting/
# (only the new/updated files; everything else should already be present from PR #42)
mkdir -p deploy/docs/troubleshooting

# Rsync would preserve modes; cp -r works too — but we want to ONLY copy the new/updated entries
cp /tmp/jun22-recovery/onprem-troubleshooting/02-storage/rook-osd-keyring-missing.md \
   deploy/docs/troubleshooting/02-storage/
cp /tmp/jun22-recovery/onprem-troubleshooting/02-storage/rook-osd-pg-peering-crash.md \
   deploy/docs/troubleshooting/02-storage/
cp /tmp/jun22-recovery/onprem-troubleshooting/04-secrets-credentials/external-secrets-config-cascade.md \
   deploy/docs/troubleshooting/04-secrets-credentials/
cp /tmp/jun22-recovery/onprem-troubleshooting/README.md \
   deploy/docs/troubleshooting/
cp /tmp/jun22-recovery/onprem-troubleshooting/QA-CLUSTER-BOOTSTRAP-CHECKLIST.md \
   deploy/docs/troubleshooting/

# Diff to confirm what's actually new vs already-present
git status
git diff --stat

# Stage + commit
git add deploy/docs/troubleshooting/
git commit -m "docs: catalog updates for 2026-06-22 Rook+ESO recovery + QA bootstrap checklist

- 02-storage/rook-osd-keyring-missing.md (REWRITTEN with PROVEN sequence:
  toolbox pre-req, Option A.1 mon-side ceph auth import, Option B per-OSD
  purge + wipe + re-prepare)
- 02-storage/rook-osd-pg-peering-crash.md (NEW: same_interval_since=0
  assertion crash + Option B fix + IaC artifact pointer)
- 04-secrets-credentials/external-secrets-config-cascade.md (NEW: Octopus-
  runbook chicken-and-egg + Flux kstatus terminal-failure gotcha +
  structural IaC fix via cross-cluster-eso split)
- README.md (updated symptom index with 3 new rows)
- QA-CLUSTER-BOOTSTRAP-CHECKLIST.md (NEW: Phase 1..10 bootstrap order +
  restore-from-disaster checklist + open IaC gaps table)

Source authored in wip/onprem-troubleshooting/ + tarball at
archive/transfer-tarballs/onprem-troubleshooting-2026-06-22.tar.gz on
the public eks_code transfer branch.

INFRA-1538 (parent ticket) covers the 4 PRs landing this material:
- PR-A iaac-talos-flux-platform (cross-cluster-eso split)
- PR-B iaac-talos-flux-cluster (new Kustomization)
- PR-C iaac-talos-flux-platform (toolbox always-on)
- PR-D this PR (catalog to iaac-talos)

INFRA-1532 closure comment recorded the recovery details."

git push -u origin docs/troubleshooting-catalog-jun22-rook-eso-recovery

gh pr create --base feature/op-usxpress-dev \
  --title "docs: troubleshooting catalog updates for 2026-06-22 Rook+ESO recovery" \
  --body "$(cat <<'EOF'
## Summary
- 3 new/rewritten troubleshooting entries from the 2026-06-22 op-usxpress-dev recovery
- New QA cluster bootstrap checklist (Phase 1..10 + restore-from-disaster)
- README symptom index updated

## Catalog changes

| File | Change |
|---|---|
| `deploy/docs/troubleshooting/02-storage/rook-osd-keyring-missing.md` | REWRITTEN with PROVEN sequence |
| `deploy/docs/troubleshooting/02-storage/rook-osd-pg-peering-crash.md` | NEW — sis=0 assertion crash |
| `deploy/docs/troubleshooting/04-secrets-credentials/external-secrets-config-cascade.md` | NEW — Octopus-seeded CSS chicken-and-egg |
| `deploy/docs/troubleshooting/README.md` | Index updated |
| `deploy/docs/troubleshooting/QA-CLUSTER-BOOTSTRAP-CHECKLIST.md` | NEW |

## Why
2026-06-22 recovered op-usxpress-dev from a 32-day external-secrets-config
cascade + 3-day Rook OSD downtime. These docs capture the PROVEN procedures
so the same scenarios are recoverable in <30 min next time, and the QA
cluster can be bootstrapped without hitting the same chicken-and-egg.

## Related tickets
- INFRA-1532 (closure comment posted with recovery details)
- INFRA-1535 / 1536 / 1537 / 1538 (follow-up tickets for runbook + PVC + webhook + IaC restructure)

## Test plan
- [ ] Render the markdown locally / on GitHub for legibility
- [ ] Cross-link checks (catalog README ↔ entries ↔ memory pointers)
- [ ] Confirm `/onprem-troubleshooting` skill picks up new entries after merge
EOF
)"
```

## Paste-block 3 — PR-A: split cross-cluster CSS (iaac-talos-flux-platform)

```bash
cd ~/work/iaac-talos-flux-platform
git fetch origin
git checkout op-dev
git pull origin op-dev

git checkout -b refactor/cross-cluster-eso-split-jun22

# Create new directory structure
mkdir -p infrastructure/cross-cluster-eso
mkdir -p infrastructure/rook-recovery-jobs

# Copy new manifests from /tmp/jun22-recovery/cross-cluster-eso-restructure-jun22/
cp /tmp/jun22-recovery/cross-cluster-eso-restructure-jun22/cross-cluster-eso/*.yaml \
   infrastructure/cross-cluster-eso/

# Overwrite external-secrets-config with the trimmed version (default CSS only)
cp /tmp/jun22-recovery/cross-cluster-eso-restructure-jun22/external-secrets-config/*.yaml \
   infrastructure/external-secrets-config/
# Remove the now-orphan file (moved to cross-cluster-eso/)
rm -f infrastructure/external-secrets-config/onprem-platform-rbac.yaml

# Copy recovery job templates
cp /tmp/jun22-recovery/cross-cluster-eso-restructure-jun22/rook-recovery-jobs/*.yaml \
   /tmp/jun22-recovery/cross-cluster-eso-restructure-jun22/rook-recovery-jobs/README.md \
   infrastructure/rook-recovery-jobs/

# Diff to confirm
git status
git diff infrastructure/external-secrets-config/

# Stage + commit
git add infrastructure/cross-cluster-eso/ infrastructure/external-secrets-config/ infrastructure/rook-recovery-jobs/
git commit -m "refactor: split cross-cluster CSS into separate Kustomization + add rook recovery job templates

Breaks the 32-day bootstrap chicken-and-egg between external-secrets-config
Kustomization and the Octopus-seeded cloud-eks-reader-token Secret. Per
PR-A of PR-PLAN in iaac-drafts/cross-cluster-eso-restructure-jun22/.

Changes:
- NEW infrastructure/cross-cluster-eso/ — cloud-eks CSS + onprem-platform-rbac
  (target Kustomization: wait: false, see iaac-talos-flux-cluster PR-B)
- TRIM infrastructure/external-secrets-config/ to just the default (AWS SM) CSS
- REMOVE infrastructure/external-secrets-config/onprem-platform-rbac.yaml
  (moved to cross-cluster-eso/)
- NEW infrastructure/rook-recovery-jobs/ — manual-apply templates:
  - osd-wipe.yaml (privileged Pod, destructive)
  - bluestore-inspect.yaml (read-only diagnostic)
  - toolbox.yaml (always-on rook-ceph-tools Deployment, will be wired into
    rook-ceph-cluster Kustomization in follow-up PR-C)
  - README.md (decision tree + usage)

Catalog: deploy/docs/troubleshooting/04-secrets-credentials/external-secrets-config-cascade.md
(landing via iaac-talos PR-D)

Tickets: INFRA-1538 (parent), INFRA-1532 (closure)"

git push -u origin refactor/cross-cluster-eso-split-jun22
gh pr create --base op-dev --fill
```

## Paste-block 4 — PR-B: add cross-cluster-eso Kustomization (iaac-talos-flux-cluster)

```bash
cd ~/work/iaac-talos-flux-cluster
git fetch origin
git checkout master
git pull origin master

git checkout -b feat/cross-cluster-eso-kustomization-jun22

# Edit clusters/bm-dev/flux-system/infra.yaml — append the new Kustomization block
# (insert AFTER the external-secrets-config Kustomization block, BEFORE app-secrets)
# Use your editor; or apply the diff manually:

# Manifest to insert (read the PR-PLAN.md or PUSH-TO-ENTERPRISE-2026-06-22.md
# for the exact block — append to infra.yaml at the correct position):
cat >> clusters/bm-dev/flux-system/infra.yaml.new-block <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cross-cluster-eso
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/cross-cluster-eso
  prune: true
  wait: false
  timeout: 5m
  dependsOn:
  - name: external-secrets
EOF
# Then manually merge into infra.yaml at correct ordering position
# (use code/vim to insert after `external-secrets-config` block)

git diff clusters/bm-dev/flux-system/infra.yaml

git add clusters/bm-dev/flux-system/infra.yaml
rm -f clusters/bm-dev/flux-system/infra.yaml.new-block
git commit -m "feat(flux): add cross-cluster-eso Kustomization (wait: false)

Pairs with iaac-talos-flux-platform PR-A which splits the cloud-eks CSS
into its own infrastructure/cross-cluster-eso/ directory.

wait: false is intentional — the Kustomization owns only a CSS that depends
on an Octopus-seeded Secret. Without wait: false, this Kustomization would
block forever waiting for the CSS Ready, which can't happen until the
Octopus runbook (INFRA-1535) is set up and run.

INFRA-1538 (parent), INFRA-1532 (closure)"

git push -u origin feat/cross-cluster-eso-kustomization-jun22
gh pr create --base master --fill
```

## Merge sequence + verification

1. **PR-A** (flux-platform) — merge first
2. **PR-B** (flux-cluster) — merge second
3. Wait ~5 min for Flux to reconcile both
4. **Verify on op-usxpress-dev:**
   ```bash
   flux get kustomizations -A | awk 'NR==1 || $4!="True"'  # should be header-only
   kubectl get clustersecretstore                          # default Ready=True, cloud-eks Ready=False (expected)
   kubectl -n flux-system get kustomization cross-cluster-eso  # Ready=True
   ```
5. **PR-C** (toolbox always-on) — separate, low-risk
6. **PR-D** (catalog) — independent, can land any time

## Backout

- Each PR is independent and reversible via revert (PR-A doesn't change live behavior beyond moving manifest files between Kustomization scopes; Flux will see both as known + apply without error)
- If anything goes wrong on PR-A/B, the pre-state (`external-secrets-config` Ready=True with terminal-failed cloud-eks CSS) was already functional for downstream consumers
