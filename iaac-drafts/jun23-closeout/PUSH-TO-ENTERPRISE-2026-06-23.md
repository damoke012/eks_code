# Push jun23-closeout to enterprise — 2026-06-23

WSL paste-blocks to ship tonight's drafts to 6 enterprise repos. Mirrors the jun22 pattern.

## Inventory

| Artifact | Tarball | sha256 |
|---|---|---|
| 6 enterprise READMEs | `archive/transfer-tarballs/jun23-enterprise-readmes.tar.gz` | `145ef33e5a557daf2adca85ddc7ba9d393ea3a681ccbfadf719b0e817f3e69cd` |
| Troubleshooting catalog (37 entries) | `archive/transfer-tarballs/onprem-troubleshooting-jun23-full.tar.gz` | `14eeb265d297506aa2446d20dcf5a41c9f42b19c0c7737b8172e504868091476` |

Raw URLs (transfer branch is public):
- https://raw.githubusercontent.com/damoke012/eks_code/transfer/rook-ceph-safe-reroll-jun17/archive/transfer-tarballs/jun23-enterprise-readmes.tar.gz
- https://raw.githubusercontent.com/damoke012/eks_code/transfer/rook-ceph-safe-reroll-jun17/archive/transfer-tarballs/onprem-troubleshooting-jun23-full.tar.gz

## Jira state (already filed via Atlassian API tonight)

- **INFRA-1544** (Epic): On-prem op-usxpress-dev: restore-readiness + IaC closeout (jun23 marathon)
- **INFRA-1545 (Done)**: Velero: PVC backup + RESTORE proven end-to-end
- **INFRA-1546 (Done)**: etcd snapshot → S3 operational (multi-container CronJob)
- **INFRA-1547 (Done)**: TF: IRSA + S3 buckets + talosconfig SM wrapper
- **INFRA-1548 (Done)**: Prometheus on ceph-block PVC
- **INFRA-1549 (Done)**: rw-2 prometheus-server on ceph-block PVC
- **INFRA-1550 (Done)**: rw-2 operator supplemental ClusterRole
- **INFRA-1551 (Done)**: Ceph mgr memory bump 512Mi → 2Gi
- **INFRA-1552 (Done)**: External-DNS IRSA re-mutation fix
- **INFRA-1553 (Done)**: Default branch flip iaac-talos-flux-platform
- **INFRA-1554 (Done)**: Catalog ship: 6 entries + Flux bootstrap runbook (PR #45)
- **INFRA-1555 (To Do)**: Postgres rw-2 local-path → ceph-block migration (NEEDS TIM WINDOW)
- **INFRA-1556 (To Do)**: READMEs across 6 on-prem repos (THIS DOCUMENT — close after PRs land)
- **INFRA-1557 (To Do)**: TF state cross-region replication advisory (cloud-ops handoff)

Existing tickets commented (status updates posted):
- **INFRA-1535** (OnPremise Octopus space) — external blocker remains
- **INFRA-1542** (Flux bootstrap automation) — runbook shipped, full TF automation deferred
- **INFRA-1543** (OnPremise Octopus worker pool IaC) — tied to 1535, blocked external

## Step 1 — Pull tarballs from codespace transfer branch (WSL)

```bash
BRANCH=transfer/rook-ceph-safe-reroll-jun17
BASE_URL=https://raw.githubusercontent.com/damoke012/eks_code/$BRANCH/archive/transfer-tarballs

mkdir -p /tmp/jun23-closeout && cd /tmp/jun23-closeout

curl -sSfL -o jun23-enterprise-readmes.tar.gz \
  "$BASE_URL/jun23-enterprise-readmes.tar.gz"
curl -sSfL -o onprem-troubleshooting-jun23-full.tar.gz \
  "$BASE_URL/onprem-troubleshooting-jun23-full.tar.gz"

# Verify sha256
echo "145ef33e5a557daf2adca85ddc7ba9d393ea3a681ccbfadf719b0e817f3e69cd  jun23-enterprise-readmes.tar.gz" | sha256sum -c
echo "14eeb265d297506aa2446d20dcf5a41c9f42b19c0c7737b8172e504868091476  onprem-troubleshooting-jun23-full.tar.gz" | sha256sum -c

# Extract
tar -xzf jun23-enterprise-readmes.tar.gz
tar -xzf onprem-troubleshooting-jun23-full.tar.gz

ls -la
# Expected: readmes/  onprem-troubleshooting/
ls readmes/
# Expected: iaac-octopus-onprem  iaac-risingwave-2  iaac-risingwave-onprem  iaac-talos  iaac-talos-flux-cluster  iaac-talos-flux-platform
```

## Step 2 — PR #1: iaac-talos (README + remaining catalog entries)

```bash
cd ~/work/iaac-talos
git fetch origin
git checkout feature/op-usxpress-dev
git pull origin feature/op-usxpress-dev

git checkout -b docs/jun23-readme-and-catalog

# Drop in the README at repo root (review the diff before committing — Doke may want to merge with existing content rather than replace wholesale)
cp /tmp/jun23-closeout/readmes/iaac-talos/README.md ./README.md.draft
diff README.md README.md.draft | head -50
# If wholesale-replace OK:
mv README.md.draft README.md
# If you want to keep current README + append the new sections, hand-merge:
#   - keep old content above
#   - paste sections from README.md.draft starting at "## Recent additions — jun23 marathon"

# Drop in catalog entries — overwrite mode (wip entries are the authoritative source)
mkdir -p deploy/docs/troubleshooting
cp -r /tmp/jun23-closeout/onprem-troubleshooting/* deploy/docs/troubleshooting/

# PR #45 shipped 7 entries into a slightly different section layout
# (03-network-irsa vs the wip layout's 03-networking + 03-network-irsa split).
# Reconcile by inspection:
git status
git diff --stat | head -40
ls deploy/docs/troubleshooting/03-networking 2>/dev/null
ls deploy/docs/troubleshooting/03-network-irsa 2>/dev/null

# Stage + commit
git add README.md deploy/docs/troubleshooting/
git commit -m "docs: jun23 marathon README + troubleshooting catalog sweep (INFRA-1556)

- README.md restructured to cover new platform stack (IRSA module for Velero
  + etcd-backup, talosconfig SM wrapper with declarative ARN import, Octopus
  TfApply ceremony, per-cluster bring-up notes)
- deploy/docs/troubleshooting/ catalog expanded from 6 (PR #45) to 37 entries
  covering CP control plane, storage, networking, secrets, TF/Octopus, and
  incident timelines
- QA-CLUSTER-BOOTSTRAP-CHECKLIST.md added at catalog root

Tickets: INFRA-1556 (this work), INFRA-1554 (PR #45 — catalog initial 6 entries),
INFRA-1544 (marathon umbrella)"

git push -u origin docs/jun23-readme-and-catalog

gh pr create --base feature/op-usxpress-dev \
  --title "docs: jun23 marathon README + troubleshooting catalog sweep" \
  --body "$(cat <<'EOF'
## Summary
- README.md restructured to cover new platform stack added in the 2026-06-23 marathon:
  - IRSA module: Velero role + S3 bucket, etcd-backup role + S3 bucket
  - Talosconfig AWS Secrets Manager wrapper (declarative ARN-based import)
  - Octopus TfApply ceremony documented in full
  - Per-cluster bring-up notes (QA path)
  - SM secret seed + recovery procedure
- deploy/docs/troubleshooting/ catalog sweep: 7 entries (PR #45) → 37 entries
  - 6 dimensions: control-plane / storage / networking / secrets / TF-Octopus / incidents
  - QA-CLUSTER-BOOTSTRAP-CHECKLIST.md added at catalog root

## Marathon context
INFRA-1544 (umbrella). 16 PRs shipped across 4 repos. Restore-readiness end-to-end:
- Velero PVC backup + restore PROVEN (test-restore-jun24, 20Gi PVC restored)
- etcd snapshot → S3 OPERATIONAL (287MB validated, hourly schedule)
- Talosconfig SM secret TF-managed (PR #48 + #49 — adopted into TF via declarative ARN-based import)
- Prometheus + rw-2 prometheus-server migrated to ceph-block
- rw-2 operator + supplemental ClusterRole (9 resources)
- External-DNS pod-identity-webhook re-mutation fix

## Related tickets
- INFRA-1556 (READMEs across 6 on-prem repos — this PR closes the iaac-talos portion)
- INFRA-1554 (Catalog initial 6 entries via PR #45 — Done)
- INFRA-1544 (Epic — marathon umbrella)

## Test plan
- [ ] Render README on GitHub for legibility
- [ ] Spot-check catalog entries render correctly (the symptoms index in deploy/docs/troubleshooting/README.md)
- [ ] Confirm onprem-troubleshooting skill (Cloud Platform agent harness) surfaces all 37 entries after merge
EOF
)"
```

## Step 3 — PR #2: iaac-talos-flux-cluster (README)

```bash
cd ~/work/iaac-talos-flux-cluster
git fetch origin
git checkout master
git pull origin master

git checkout -b docs/jun23-readme

cp /tmp/jun23-closeout/readmes/iaac-talos-flux-cluster/README.md ./README.md.draft
diff README.md README.md.draft 2>/dev/null | head -50 || cat README.md.draft | head -50
# Choose: replace or merge
mv README.md.draft README.md

git add README.md
git commit -m "docs: README for Flux Kustomization layer (INFRA-1556)

Covers:
- Repo purpose + relationship to iaac-talos-flux-platform
- Naming conventions (bm-dev legacy + future cluster-named dirs)
- Kustomization patterns: suspend/un-suspend via IaC, wait: false for CSS-only,
  dependsOn ordering, prune semantics
- Flux kstatus terminal-failure gotcha (caused 32-day cascade earlier this year)
- PSA awareness (manifests landing here must respect restricted ns requirements)
- Per-cluster bring-up procedure for QA + future clusters

Tickets: INFRA-1556 (this work), INFRA-1542 (Flux bootstrap automation — runbook
shipped via PR #45)"

git push -u origin docs/jun23-readme
gh pr create --base master --fill
```

## Step 4 — PR #3: iaac-talos-flux-platform (README)

```bash
cd ~/work/iaac-talos-flux-platform
git fetch origin
git checkout op-dev
git pull origin op-dev

git checkout -b docs/jun23-readme

cp /tmp/jun23-closeout/readmes/iaac-talos-flux-platform/README.md ./README.md.draft
diff README.md README.md.draft 2>/dev/null | head -50 || cat README.md.draft | head -50
mv README.md.draft README.md

git add README.md
git commit -m "docs: README for Flux platform manifest layer (INFRA-1556)

Covers all platform components added/modified in the jun23 marathon:
- Velero (IRSA-backed S3, AWS_REGION env, restore proven)
- etcd-backup (multi-container CronJob, talosctl distroless pattern)
- Prometheus (ceph-block PVC, first prod workload on ceph)
- Rook-Ceph (mgr memory 512Mi → 2Gi)
- External-Secrets + cross-cluster-eso (wait: false bootstrap pattern)
- External-DNS (IRSA re-mutation pattern)
- Istio + cert-manager + gateway-passthrough (Phase 0/1/2 complete)
- rook-recovery-jobs (manual-apply templates)

Includes a Velero gotcha catalog (duplicate extraEnvVars trap, AWS_REGION
requirement, Bitnami legacy migration) and the etcd-backup multi-container
pattern in full.

Tickets: INFRA-1556 (this work), INFRA-1544 (marathon umbrella)"

git push -u origin docs/jun23-readme
gh pr create --base op-dev --fill
```

## Step 5 — PR #4: iaac-risingwave-2 (README)

```bash
cd ~/work/iaac-risingwave-2
git fetch origin
git checkout main
git pull origin main

git checkout -b docs/jun23-readme

cp /tmp/jun23-closeout/readmes/iaac-risingwave-2/README.md ./README.md.draft
diff README.md README.md.draft 2>/dev/null | head -50 || cat README.md.draft | head -50
mv README.md.draft README.md

git add README.md
git commit -m "docs: README for team-owned rw-2 RisingWave (INFRA-1556)

Covers:
- Purpose: team-owned RW instance in risingwave-2 ns for validation + pattern proving
- Stack: risingwave-operator + RisingWave CR + bundled Prometheus + Postgres
- Operator chart gap: supplemental ClusterRole (9 cluster-scoped resources)
- ceph-block migration: Prometheus done (PR #17), Postgres deferred (INFRA-1555 — needs Tim window)
- Relationship to Tim's risingwave ns (separate, never touched)
- Per-cluster bring-up (supplemental ClusterRole needed PER cluster + PER non-default install ns)

Tickets: INFRA-1556 (this work), INFRA-1550 (supplemental ClusterRole — Done via
PRs #15/#16), INFRA-1549 (Prometheus ceph-block — Done via PR #17), INFRA-1555
(Postgres ceph-block — To Do)"

git push -u origin docs/jun23-readme
gh pr create --base main --fill
```

## Step 6 — PR #5: iaac-risingwave-onprem (README — read-only ack)

```bash
cd ~/work/iaac-risingwave-onprem
git fetch origin
git checkout main
git pull origin main

git checkout -b docs/cloud-platform-readonly-ack

cp /tmp/jun23-closeout/readmes/iaac-risingwave-onprem/README.md ./README.md.draft
diff README.md README.md.draft 2>/dev/null | head -50 || cat README.md.draft | head -50

# IMPORTANT: this repo is Tim's domain. Coordinate with Tim before merging — he may
# want to author the top section himself; the Cloud Platform sections below can be
# preserved as appendix or moved to a CLOUD-PLATFORM.md sibling file.

# Recommendation: ship as a sibling file CLOUD-PLATFORM-ACK.md to avoid stomping
# on Tim's authoritative README.
mv README.md.draft CLOUD-PLATFORM-ACK.md

git add CLOUD-PLATFORM-ACK.md
git commit -m "docs: Cloud Platform read-only ack + pre/post check pattern (INFRA-1556)

Documents the Cloud Platform team's relationship to this repo:
- Tim Preble owns the manifests + RW operational config
- Cloud Platform supports the cluster underneath
- Pre/post check pattern used by Cloud Platform when making cluster-wide
  changes that could affect Tim's namespace
- Binding rule: protect-rw-onprem-workload (RW pre/post + coordinate with Tim
  before invasive changes)
- 2026-06-23 marathon non-touch confirmation: 16+ PRs across other repos
  with Tim's risingwave ns Running 0 restarts throughout

Filed as CLOUD-PLATFORM-ACK.md (not README.md) so Tim retains authority over
the repo's primary documentation.

Coordinate with Tim before merging.

Tickets: INFRA-1556 (this work)"

git push -u origin docs/cloud-platform-readonly-ack
gh pr create --base main \
  --title "docs: Cloud Platform read-only ack (CLOUD-PLATFORM-ACK.md)" \
  --body "$(cat <<'EOF'
## Summary
- New file CLOUD-PLATFORM-ACK.md (not modifying README.md) documenting:
  - Cloud Platform team's relationship to this repo (Tim owns; Cloud Platform supports cluster underneath)
  - Pre/post check pattern Cloud Platform runs before any cluster-wide change
  - Binding rule (protect-rw-onprem-workload)
  - 2026-06-23 marathon non-touch confirmation

## Why a sibling file vs README.md
Tim authors the primary README. This sibling file documents the platform
team's adjacent perspective without overriding his content.

## Coordination
- Tim should review the pre/post check pattern + the "cluster-wide changes
  that can affect this ns" list. Adjust as needed.

## Related tickets
- INFRA-1556 (READMEs across 6 on-prem repos — this PR closes the iaac-risingwave-onprem portion)
- INFRA-1544 (marathon umbrella)
EOF
)"
```

## Step 7 — PR #6: iaac-octopus-onprem (README — blocked-by-admin)

```bash
cd ~/work/iaac-octopus-onprem
git fetch origin
git checkout master 2>/dev/null || git checkout main  # confirm default branch
git pull origin "$(git branch --show-current)"

git checkout -b docs/jun23-readme

cp /tmp/jun23-closeout/readmes/iaac-octopus-onprem/README.md ./README.md.draft
diff README.md README.md.draft 2>/dev/null | head -50 || cat README.md.draft | head -50
mv README.md.draft README.md

git add README.md
git commit -m "docs: README documenting target pattern (blocked on admin token)

Covers:
- Repo purpose: house Octopus OnPremise space + worker pool + project bindings as IaC
- Current state: BLOCKED on Octopus admin token (INFRA-1535/1543)
- Target architecture (when token arrives): space → worker pool → project bindings
- TfApply ceremony pattern (same as iaac-talos: false → plan → true → apply → false)
- Bootstrap runbook (target — runs once per environment)
- Repo layout target structure (terraform/space.tf, worker-pool.tf, projects/)
- Cross-references: iaac-talos + iaac-talos-flux-cluster + iaac-talos-flux-platform

This README is the closeout artifact since no manifests can land here until
the OnPremise space is provisioned (INFRA-1535 admin-token blocker).

Tickets: INFRA-1556 (this work), INFRA-1535 (admin token blocker — In Progress),
INFRA-1543 (worker pool IaC — blocked on 1535), INFRA-1544 (marathon umbrella)"

git push -u origin docs/jun23-readme
gh pr create --base "$(git rev-parse --abbrev-ref origin/HEAD | sed 's@^origin/@@')" --fill
```

## Step 8 — Post-merge: close INFRA-1556

After all 6 PRs merge:

```bash
# From any directory with the jira CLI configured, or via the JIRA UI:
# 1. Add merged-PR links to INFRA-1556 as a comment
# 2. Transition INFRA-1556 → Done

# Or via Atlassian API:
curl -X POST -u "doke@usxpress.com:<token>" \
  -H "Content-Type: application/json" \
  -d '{"transition":{"id":"<done-transition-id>"}}' \
  https://usxpress.atlassian.net/rest/api/3/issue/INFRA-1556/transitions
```

## Step 9 — Send TF state CRR advisory to cloud-ops (INFRA-1557)

```bash
# Read the advisory
cat /tmp/jun23-closeout/onprem-troubleshooting/../tf-state-cross-region-advisory.md 2>/dev/null \
  || curl -sSfL https://raw.githubusercontent.com/damoke012/eks_code/transfer/rook-ceph-safe-reroll-jun17/iaac-drafts/jun23-closeout/tf-state-cross-region-advisory.md

# Send via Slack DM or email to cloud-ops lead. Once acknowledged:
# - Add cloud-ops contact name + ack date as comment on INFRA-1557
# - Leave INFRA-1557 in To Do until cloud-ops confirms replication is enabled
```

## Step 10 — INFRA-1555 Postgres migration (with Tim)

When Tim's window opens:

```bash
# Pull the runbook
curl -sSfL -o /tmp/postgres-migration-runbook.md \
  "https://raw.githubusercontent.com/damoke012/eks_code/transfer/rook-ceph-safe-reroll-jun17/iaac-drafts/jun23-closeout/postgres-migration-runbook.md"

# Execute step-by-step per the runbook
# Velero pre-backup as safety net is the first step
```

## Merge sequencing

PRs are independent and can land in any order. Suggested batch:

1. **iaac-talos-flux-cluster** (smallest, lowest blast radius)
2. **iaac-risingwave-2** (own repo, no cross-repo coupling)
3. **iaac-octopus-onprem** (blocked-state docs, no live impact)
4. **iaac-risingwave-onprem** (coordinate with Tim — could merge later)
5. **iaac-talos-flux-platform** (biggest README, most components)
6. **iaac-talos** (last because catalog sweep is also in this PR — biggest review surface)

## Backout

Each PR is a documentation-only change. Revert is git-revert + push. No cluster impact.
