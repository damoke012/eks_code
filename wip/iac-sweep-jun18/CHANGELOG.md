# iac-sweep-jun18 — CHANGELOG

## 2026-06-18 PM

### Phase 1 Rook (worker disk add) — APPLIED to op-usxpress-dev

- iaac-talos PR #37 merged + applied via Octopus release 1.163
- All 7 workers now have `/dev/sdb` (50 GB) — verified via `talosctl get disks`
- vSphere hot-add worked (HW version 20) — zero RW disruption
- TF state now codifies CP IP ordering (was drift since yesterday's hostname patch)
- Pre-flight all 4 gates green; 6 baseline captures saved to `~/dr-snapshot-2026-06-18/`
- Unblocks Phase 2 (cephcluster.yaml deviceFilter switch)

### Today's incident — Cilium IP divergence cascade (resolved)

- During the 1.163 apply, CP-1 kubelet re-registered at 10.10.82.29; CiliumNode CRD stayed at 10.10.82.181
- Cascade: WG mesh inconsistent → istio-csr → cert chain → Octopus istiod health check timed out (1200s)
- Apply itself completed cleanly (state saved, post-check soft-failed)
- Manual cleanup: deleted ghost `talos-cp-op-dev-3` Node + stale `talos-cp-op-dev-1` CiliumNode + bounced cilium agent on .29
- istiod rolled out successfully after cleanup

### Track 1.5 Cilium hygiene — FULLY LIVE (IaC permanent fix)

- iaac-talos-flux-platform PR #43 merged — CronJob `cilium-node-reconciler` in kube-system
  - Runs every 15 min on workers (CP nodeAffinity DoesNotExist)
  - 4 failure modes auto-remediated:
    1. ORPHAN CiliumNode
    2. STALE CiliumNode IP (delete CN + bounce agent)
    3. GHOST kubectl Node (NotReady + duplicate IP)
    4. STALE kubectl Node (NotReady > 30 min, sits alone) — NEW today
  - `AUTO_REMEDIATE=true`, `MIN_AGE_SECONDS=300`, `NOTREADY_GRACE_SECONDS=1800`
- iaac-talos-flux-cluster PR #17 merged — Flux Kustomization wire-up
- Result: reboots, IP changes, kubelet renames now auto-heal within 15-30 min without manual kubectl-delete

### Deeper ticket drafted — iaac-talos hostname-pin refactor

- `jira/drafts/INFRA-XXXX-cp-hostname-etcd-divergence.md`
- Concrete TF diff sketches: output `vm_names` from vsphere_vm module, derive Talos hostname from VM name instead of list index
- Eliminates the class of bug that caused today's cascade
- Surgical work — needs own session

## 2026-06-19 AM — extended marathon (worker mem bump → DNS recovery → full RW + IaC coverage doc)

### IaC landed

- **iaac-talos PR #40** — worker_memory_mb default 8192→12288 + drop compact() race in vsphere_vm/outputs.tf (precondition replaces silent index shift) — MERGED + APPLIED via Octopus 1.171
- All 7 workers verified at 11941 MB (12 GB) total via talosctl memory
- TF state `worker_ips` now stable 7-element list (was 3-element compact-race residue from 1.168)
- Precondition fired CLEANLY during apply with our designed message — proved its value vs cryptic index error

### Cluster recoveries during session (each captured for IaC codification next session)

- **CN-mismatch recovery** on .27 (wk-5) + .21 (wk-7) via `talosctl patch machineconfig` — hostname back to original cert CN identity. NEW pattern vs existing runbook Case A — no etcd remove, no reset. PROVEN twice tonight.
- **CiliumNode CP drift** — manually deleted stale CN talos-cp-op-dev-2 (at wrong IP .179) + bounced cilium agents on cp-1 + cp-2. Reconciler-equivalent; image bug in PR #43 deployment meant safety net was no-op.
- **DNS restoration** — broken cluster-wide for ~80 min due to CN drift on CoreDNS-hosting CPs. Fix: above CiliumNode cleanup. Verified via fresh probe pod (`nslookup istiod.istio-system.svc.cluster.local → 10.101.33.234`).
- **istio-cni + ztunnel staleness** — bounced DS pods on wk-2/wk-3/wk-5/wk-7 after talos config push + DNS recovery. wk-5 needed second bounce because original came before DNS healed.
- **ExternalSecrets force-sync** — all 7 RW ESes stuck SecretSyncedError; manual `force-sync` annotation re-synced against now-healthy AWS SM.
- **Dead ghostunnel pods** — manually deleted 8d/35h CrashLoopBackOff replicas.
- **RW full recovery** — all 14 RW namespace pods Running after fresh respawn picked up synced credentials. IRSA chain verified working end-to-end.

### Coverage docs WRITTEN (THIS SESSION)

- `INCIDENT-COVERAGE-MATRIX-2026-06-19.md` — 17 failure modes from this session + IaC artifact assigned to each gap. Categorized by track 1.5 / 4 (NEW) / 5 (NEW) / 3. Includes QA + PROD bring-up checklist.
- `ROOK-CEPH-IMPLEMENTATION-2026-06-19.md` — full architecture + phases + repo file inventory + recovery commands + Rook upstream links. Documents what's IaC'd vs manual today.

### Known blockers carried into next session

- **Rook mons crash-looping 10h+** (pre-existing). Operator was Pending; should now schedule with 12 GB workers. ConfigMap `rook-ceph-mon-endpoints` stuck with finalizer (one-liner removal in implementation doc).
- **cilium-node-reconciler image broken** — URGENT next-session PR. Image entrypoint bug means the safety net we deployed yesterday is no-op. Without it, every reboot/IP-change cascades into DNS death again.

### Carried-forward IaC PRs (10 slated for next session, covered in matrix)

1. URGENT — reconciler image fix (1.5)
2. Runbook Case B-2 (1.5)
3. PromRule ClusterDNSUnreachable (4-NEW)
4. PromRule IRSAFailureCascade (4-NEW)
5. Deploy Reloader operator (5-NEW)
6. ES refresh interval 5m on critical (5-NEW)
7. istio-ambient-recovery CronJob (1.5)
8. DS config-hash auto-restart (4-NEW)
9. Kyverno pod-GC (3)
10. webhook priority barrier (5-NEW)

## 2026-06-19 PM (post-yesterday-marathon)

### IaC landed today

- **iaac-talos PR #41** (initial troubleshooting catalog, 30 entries) — MERGED
- **flux-platform PR #45** (cilium-node-reconciler image: bitnamilegacy → alpine/k8s:1.32.6) — MERGED + LIVE + VERIFIED (clean exec at 14:17 UTC, 0 divergence)
- **iaac-talos PR #42** (2 new Rook catalog entries: rook-osd-keyring-missing.md + rook-operator-restart-state-loss.md) — MERGED

### Reconciler verified working

- Forced job run via `kubectl create job --from=cronjob/cilium-node-reconciler manual-test-XXXX`
- Output started with `=== Cilium node reconciler 2026-06-19T14:17:51Z ===`
- Scanned all 10 nodes for 4 CASES of drift
- Reported `divergence=0 actions=0` — safety net is officially LIVE

### Rook attempted recovery — partial fail, codified

- Mons self-healed overnight (12 GB memory bump unblocked operator scheduling)
- 7 OSDs created via Phase 2 deviceFilter but stuck in CrashLoopBackOff
- Root cause: missing `rook-ceph-osd-X-keyring` k8s Secrets
- Made mistake: cleared stuck mon-endpoints CM finalizer + restarted operator → bootstrap-from-scratch loop with canary mon deployments
- Recovered via mon scale-down/up (Scenario A)
- OSDs remain CrashLoop pending planned-window DR
- Both learnings codified in PR #42 catalog entries (codify-immediately rule)

### New process rule saved

- `feedback_issue_codify_push_immediately.md` — codify catalog entry + push IaC + push catalog same session; don't backlog learnings

### Tomorrow / post-compact

1. Execute Rook OSD fix Option A (extract keys from mons → create secrets → restart OSDs)
2. Fall back to Option B (nuclear purge + wipe /dev/sdb + re-prepare) if A fails
3. Verify HEALTH_OK + PVC smoke test
4. Codify which option worked as catalog update PR
5. Move to Octopus TfApply=false flip
6. Tracks 4+5 NEW PRs (DNS PromRule, IRSA PromRule, Reloader, ES 5m refresh)

## 2026-06-22 — Rook + ESO recovery WRAPPED

### Outcome (all green)

- 7/7 Rook OSDs UP (since 3 days down)
- 169 PGs active+clean
- PVC smoke test against ceph-block: BOUND in 15s
- All Flux Kustomizations Ready=True (`external-secrets-config`, `app-secrets`, `octopus-worker` were stuck for 32 days)
- Tim's RisingWave unaffected throughout

### Recovery sequence (now PROVEN + codified)

1. **WSL kubeconfig fix** — stale .21 worker IP → VIP .50 via sed
2. **external-secrets-config cascade** — removed orphan `geoenrichment-sync-handler-m-u` ExternalSecret (sole consumer of broken `cloud-eks` CSS). Kept Namespace + ConfigMap as pre-staging. PR merged on `iaac-talos-flux-platform op-dev`.
3. **Rook OSD Option A.1** — `ceph auth import` aligning mon-recorded keys to bluestore label keys (all 7 OSDs).
4. **Rook OSD Option B (for 6 of 7)** — `ceph osd out + purge` → delete Rook deploy + prepare job → wipe `/dev/sdb` via privileged pod → operator restart + Flux reconcile → fresh osd-prepare jobs ran in parallel → 6 new OSDs joined cluster. osd.4 kept as anchor.
5. **Validation** — `ceph -s` shows 7 osds up, 7 in, 169 PGs active+clean.

### Catalog updates (wip/onprem-troubleshooting/)

- **REWRITTEN** `02-storage/rook-osd-keyring-missing.md` — PROVEN sequence (toolbox pre-req → Option A.1 → Option B)
- **NEW** `02-storage/rook-osd-pg-peering-crash.md` — sis=0 assertion entry + Option B reference
- **NEW** `04-secrets-credentials/external-secrets-config-cascade.md` — chicken-and-egg + Flux kstatus terminal-failure gotcha + structural IaC fix
- **NEW** `QA-CLUSTER-BOOTSTRAP-CHECKLIST.md` — Phase 1..10 bootstrap order for QA + PROD; restore-from-disaster checklist
- **UPDATED** README symptom index (3 new rows)

### IaC restructure drafts (iaac-drafts/cross-cluster-eso-restructure-jun22/)

- `cross-cluster-eso/` — new Kustomization payload (CSS + RBAC, wait: false target)
- `external-secrets-config/` — trimmed to default CSS only
- `rook-recovery-jobs/` — osd-wipe.yaml, bluestore-inspect.yaml, toolbox.yaml (steady-state) + README
- `PR-PLAN.md` — 4-PR merge sequence: A (flux-platform split), B (flux-cluster add new Kustomization), C (toolbox always-on), D (catalog to iaac-talos)

### INFRA tickets filed

- INFRA-1532 (existing) — closure comment posted with recovery details
- INFRA-1535 — OnPremise Octopus space + bootstrap runbook for cloud-eks token seed
- INFRA-1536 — Mon PVC size increase + MonDiskLow PromRule (mons a,b at 21-27% available)
- INFRA-1537 — pod-identity-webhook caBundle auto-refresh after CP rebuild
- INFRA-1538 — IaC restructure parent ticket (4 PRs above)

### Memory written

- `session_state_jun22.md` (full day state)
- `feedback_flux_kstatus_terminal_settled.md`
- `feedback_rook_toolbox_for_ad_hoc_ceph_cli.md`
- `feedback_bluestore_label_is_source_of_truth.md`
- `feedback_sed_range_anchor_indent.md`
- MEMORY.md index updated

### Tarballs staged

- `archive/transfer-tarballs/onprem-troubleshooting-2026-06-22.tar.gz` (61 KB) — catalog for iaac-talos
- `archive/transfer-tarballs/cross-cluster-eso-restructure-jun22.tar.gz` (6 KB) — IaC drafts for flux-platform + flux-cluster

### Pending (next session)

- WSL pull tarballs + open 4 PRs per PR-PLAN.md
- After PR-A/B merge: verify cross-cluster-eso Ready, all Kustomizations Ready
- Once INFRA-1535's runbook is set up: restore geoenrichment ExternalSecret manifests
- Mon disk monitoring + INFRA-1536 plan
- pod-identity-webhook caBundle review (INFRA-1537)
