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
