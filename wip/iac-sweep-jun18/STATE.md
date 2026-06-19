# iac-sweep-jun18 — STATE

**STATUS:** ACTIVE (Track 1.5 LIVE, Track 2 + 3 partial)
**Last updated:** 2026-06-19 ~12:50 AM (end of marathon session)
**Owner:** Doke

## Session 2026-06-18 PM → 2026-06-19 ~01:00 final additions

- **PR #38 iaac-talos hostname-pin** — MERGED + APPLIED via Octopus 1.166. Talos hostname now bound to vSphere VM identity + kubelet hostname-override. CP-2 fixed; CP-3 needed manual reset.
- **Codified runbook for kubelet CN-mismatch recovery** — `wip/iac-sweep-jun18/track1.5-cilium-hygiene/runbook-kubelet-cn-mismatch-recovery.md` + matching PromRule. Used successfully to fix CP-3 (.179). Ready to PR.
- **PR #44 iaac-talos-flux-platform Phase 2** — MERGED + Flux APPLIED. Live CephCluster CR now has `deviceFilter: ^sdb$`. OSDs not yet spawning — blocked on pre-existing mon crash loop.
- **PR #39 iaac-talos worker RAM bump 4→8 GB** — MERGED + APPLIED via Octopus 1.168. vSphere hot-add SUCCESS on all 7 workers (verified 7921 MB each post-apply). TF post-step errored on `compact()` race — needs re-run next session.

## Status as of session end

- **Cluster control plane**: 3/3 CPs Ready, etcd aligned (first time today)
- **Workers**: 7/7 Ready, ALL at 8 GB RAM
- **istiod**: 1/1, 33h, 0 restarts
- **Rook**: still degraded — mons crash-looping 10h (pre-existing), operator Pending until memory eased, mon-endpoints ConfigMap stuck with finalizer
- **RW**: degraded (postgres-postgresql-0 was Pending due to memory; should now schedule)
- **Reconciler CronJob**: deployed but image entrypoint bug means it's not actually executing the script

## First-thing-next-session work

1. Re-run iaac-talos 1.168 apply (TfApply=true) to finish the talos_machine_configuration_apply step that erred on compact()
2. Watch postgres + RW pods schedule and recover (worker memory now 8 GB)
3. Rook mon recovery: diagnose why mons crash, force-remove finalizer on stuck mon-endpoints CM, kick operator
4. Fix compact() race in vsphere_vm/outputs.tf (small TF PR)
5. Fix reconciler image (small flux-platform PR)
6. Ship the PromRule + Runbook (small PR pair)

## What this is

Post-incident codification of the 2026-06-17 CP OOM cascade + 2026-06-18 Cilium-orphan cert cascade incidents. Turns manual learnings + manual fixes into IaC that ships with QA bring-up and survives cluster restores.

## Track status

| Track | Theme | Detection | Auto-heal | Status |
|---|---|---|---|---|
| 1 | istio cert chain + xDS resilience | ✓ (PR #40 merged) | partial | PromRule LIVE; pinned ClusterIP + weekly gateway restart DRAFTED |
| 1.5 | Cilium ↔ kubectl Node hygiene | ✓ (PR #41 merged) | ✓ (PR #43 + PR #17 merged 2026-06-18 PM) | **FULLY LIVE** |
| 2 | Rook-Ceph observability | drafted | n/a | gated on Phase 2 (deviceFilter) cephcluster CR landing |
| 3 | CP memory + etcd peer hardening | ✓ (PR #42 merged) | partial | PromRule LIVE; talosconfig backup CronJob + worker RAM bump DRAFTED |

## What landed 2026-06-18 PM (this session)

### Phase 1 Rook (worker disk add) — DONE

- iaac-talos PR [#37](https://github.com/variant-inc/iaac-talos/pull/37) — MERGED
- Octopus release `0.1.0-feature-op-usxpress-dev.1.163` applied to DEV with `TfApply=true`
- `/dev/sdb` (50 GB) confirmed on all 7 workers via `talosctl get disks`
- See `wip/iac-sweep-jun18/rook-ceph-phase1-vsphere-disk-add.md` for the change details
- **Unblocks Phase 2** (cephcluster.yaml `deviceFilter: ^sdb$` switch)

### Track 1.5 Cilium hygiene — FULLY LIVE

- iaac-talos-flux-platform PR [#43](https://github.com/variant-inc/iaac-talos-flux-platform/pull/43) — MERGED
  - CronJob `kube-system/cilium-node-reconciler` runs every 15 min
  - 4 failure modes auto-remediated:
    1. ORPHAN CiliumNode (no matching Node)
    2. STALE CiliumNode IP (CN INTERNALIP ≠ Node INTERNALIP) — deletes CN + bounces agent
    3. GHOST kubectl Node (NotReady + duplicate IP of Ready peer)
    4. STALE kubectl Node (NotReady > 30 min, sits alone) — catches the today's pattern
- iaac-talos-flux-cluster PR [#17](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/17) — MERGED
  - Wires `cilium-hygiene` Kustomization into bm-dev Flux chain
- Flux will reconcile within ~10 min; first CronJob run at next :15 boundary
- **Permanent IaC fix**: reboots, IP changes, kubelet renames now auto-heal within 15-30 min

### Today's incident — RESOLVED

- During the 1.163 apply, Cilium IP divergence cascade triggered AGAIN (CP-1 kubelet re-registered at .29 but CN stayed at .181)
- Manual cleanup: deleted ghost cp-3 Node + stale CP-1 CiliumNode + bounced cilium agent
- istiod 1/1 Ready, cluster healthy
- Track 1.5 PRs above ensure this is the LAST time this needs manual intervention

## Known remaining issues

### Deep iaac-talos hostname pinning refactor — PENDING

Today's session-handoff surfaced that:
- 2 CP machines (at .29 and .181) had both registered as `talos-cp-op-dev-1` over time
- 2 CP machines (at .179 and the etcd cp-3) disagree on hostname between kubelet vs etcd
- Today's apply pushed new machine configs that SHOULD have fixed this but kubelet at .181 stopped registering as a Node entirely

Full refactor proposal: `jira/drafts/INFRA-XXXX-cp-hostname-etcd-divergence.md`
- Pin Talos hostname by `vsphere_virtual_machine.vm[count.index].name` (VM identity) instead of `var.control_plane_name_prefix` (list-index)
- Outputs `vm_names` from vsphere_vm module, threads through talos module
- Eliminates the class of bug entirely

Out-of-scope today; surgical work needs its own session. The cilium-node-reconciler CronJob (case 4) is the safety net underneath.

## Open per-track items

### Track 1 — istio resilience (still partial)
- `cronjob-weekly-gateway-restart.yaml` — DRAFTED, not PRed (small, low blast radius)
- `istiod-service-pinned-clusterip-patch.yaml` — DRAFTED, not PRed

### Track 2 — Rook observability (gated)
- Everything DRAFTED
- Gated on Phase 2 cephcluster.yaml deviceFilter PR

### Track 3 — incident hardening (still partial)
- `cronjob-talosconfig-backup.yaml` — DRAFTED, needs IRSA role first
- `worker-ram-bump.tf.patch` — DRAFTED, coordinate with Tim before applying

## Next session

1. **Verify track 1.5 CronJob ran cleanly** at next :15 / :30 boundary
2. **Phase 2 PR** — cephcluster.yaml deviceFilter switch (file already drafted in `wip/iac-sweep-jun18/rook-ceph-phase2-deviceFilter.md`)
3. Track 1 + Track 3 remaining items (low priority — detection already live)
4. Schedule the iaac-talos hostname-pin refactor as a planned-window surgical change

## Files

- `STATE.md` — this file
- `DEPLOY-README.md` — original sweep plan
- `rook-ceph-phase1-vsphere-disk-add.md` — Phase 1 draft (APPLIED)
- `rook-ceph-phase2-deviceFilter.md` — Phase 2 draft (NEXT)
- `track1-istio-resilience/` — istio resilience drafts
- `track1.5-cilium-hygiene/` — Cilium hygiene drafts (PRs MERGED)
- `track2-rook-ceph-observability/` — Rook observability drafts
- `track3-incident-hardening/` — incident hardening drafts
