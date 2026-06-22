# iac-sweep-jun18 — STATE

**STATUS:** Rook restore-readiness COMPLETE (2026-06-22 LATE PM). All 7 PRs landed; cluster green on op-dev@35416383. Only INFRA-1535 Octopus runbook remains as documented manual step.
**Last updated:** 2026-06-22 LATE PM — 7 PRs merged, cluster verified green, restore-readiness GREEN.
**Owner:** Doke

## Today's landings (2026-06-22)

7 PRs merged:
- **iaac-talos #43** — Troubleshooting catalog (Rook + ESO + QA bootstrap checklist)
- **iaac-talos-flux-platform #47** — cross-cluster-eso CSS split
- **iaac-talos-flux-cluster #19** — cross-cluster-eso Kustomization wait:false
- **iaac-talos-flux-platform #48** — Rook restore-readiness (toolbox + ServiceMonitor + PromRule + mon PVC 10→20Gi + geoenrichment ES split)
- **iaac-talos-flux-cluster #20** — cross-cluster-app-secrets Kustomization + restored wait:true
- **iaac-talos-flux-platform #49** — Fix PromRule/ServiceMonitor labels (release=prometheus-stack)
- **iaac-talos-flux-cluster #21** — Fix dependsOn (app-namespaces → app-secrets)

Cluster end-state: all 36 Flux Kustomizations Ready=True; only HEALTH_WARN is mon-disk-low (INFRA-1536 mon PVC expand pending).

## Next session priorities (2026-06-23+)

1. **INFRA-1535** — OnPremise Octopus space + onprem-platform-bootstrap project + Seed Cross-Cluster ESO Token runbook. ONLY remaining manual step for full restore-readiness.
2. **INFRA-1536** — Expand existing mon PVCs from 10Gi → 20Gi (IaC value already bumped; needs mon-by-mon recreate or external resize)
3. **INFRA-1537** — pod-identity-webhook caBundle auto-refresh after CP rebuild
4. **Tracks 4+5** — DNS PromRule, IRSA PromRule, Reloader, ES 5m refresh
5. **Octopus TfApply=false** housekeeping flip (if still true)
6. **argocd/argocd-admin-credentials ES SecretSyncedError** — Idris's track, investigate AWS SM path

See `~/.claude/projects/-workspaces-eks-code/memory/session_state_jun22.md` for full context.

## Session 2026-06-19 AM additions (THIS SESSION)

### IaC + cluster work landed

- **PR #40 (iaac-talos)** — worker RAM 8→12 GB + drop `compact()` race in vsphere_vm/outputs.tf — MERGED + APPLIED via Octopus 1.171 (which retried after precondition caught the hot-add race cleanly — exact behavior we designed)
- **All 7 workers now at 11941 MB (12 GB)** — verified post-apply via `talosctl memory`
- **Compact race FIX LIVE in state** — `worker_ips` output now 7 stable elements (was 3-element residue from 1.168 race)
- **State drift reconciled** — `talos_machine_configuration_apply.join_workers[1]/[2]` updated to correct target IPs

### Manual cluster recoveries during session (now codified for next session)

- **.27 (wk-5) + .21 (wk-7) CN-mismatch recovery** — hostname patch back to original CN identity (no etcd remove, no reset needed — case B-2 of the runbook). PROVEN twice tonight.
- **CiliumNode drift on CPs** — manual reconciler-equivalent (delete stale CN talos-cp-op-dev-2 at wrong IP + bounce cilium agents on cp-1 and cp-2). This is EXACTLY what the (broken-image) cilium-node-reconciler CronJob would have done — but the image entrypoint bug made it no-op.
- **DNS broken cluster-wide** — caused by CN drift on CoreDNS-hosting CPs. Restored after Cilium fix.
- **istio-cni + ztunnel stale on 4 workers** (wk-2/wk-3/wk-5/wk-7) — bounced DS pods on touched nodes; needed second bounce on wk-5 after DNS fix because original bounce happened before DNS was healthy.
- **ExternalSecrets force-sync** — all 7 RW ExternalSecrets stuck in SecretSyncedError after the DNS-broken hour; manual force-sync annotation brought them back. Critical secrets like `rw-service-account-credentials` re-synced.
- **RW full recovery** — all 14 RW namespace pods now Running. IRSA chain verified end-to-end (projected SA token → STS AssumeRoleWithWebIdentity → S3 hummock state store).
- **Dead ghostunnel pods cleaned** — 8d/35h CrashLoopBackOff stragglers manually deleted.

### IaC coverage docs WRITTEN (THIS SESSION)

- **`INCIDENT-COVERAGE-MATRIX-2026-06-19.md`** — 17 failure-mode matrix with IaC artifact assigned to each gap. Categorized by track 1.5 / 4 (NEW) / 5 (NEW) / 3.
- **`ROOK-CEPH-IMPLEMENTATION-2026-06-19.md`** — full Rook-Ceph architecture doc: phases 1+2 deployed, phase 3 monitoring drafted, phase 4 production-readiness mapped. Includes recovery commands for mon finalizer stuck pending-deletion.

## Status as of session end

### Cluster — fully healthy

- 3 CPs Ready @ aligned hostnames + etcd
- 7 workers Ready @ 12 GB RAM
- istiod 1/1 Ready (35h uptime, 0 restarts through everything)
- DNS resolves both in-cluster and external (cluster-wide CNs aligned)
- RW namespace: 14 pods all Running, IRSA proven working
- Prometheus + Grafana + Postgres + ghostunnel: all Running

### Pending blockers (next session)

#### 1. Rook OSDs not spawning

- Phase 2 CephCluster CR applied with `deviceFilter: ^sdb$` ✓
- BUT mons crash-looping 10h+ pre-existing
- ConfigMap `rook-ceph-mon-endpoints` stuck `deletionTimestamp:2026-06-17T16:22:04Z` + finalizer `ceph.rook.io/disaster-protection`
- Operator was Pending earlier; may now schedule with 12 GB workers freed
- **Recovery path:** see `ROOK-CEPH-IMPLEMENTATION-2026-06-19.md` § "Known blockers"

#### 2. cilium-node-reconciler image entrypoint bug — URGENT

- CronJob deployed (PR #43 merged + Flux applied)
- Image `bitnamilegacy/kubectl:1.32` has `ENTRYPOINT=kubectl`
- Our `command: ["/bin/sh", "-c", ...]` not overriding; args passed as kubectl args → instant error
- **THIS IS WHY** today's CN drift on CPs cascaded into DNS death — the safety net was deployed but no-op
- **Fix:** swap to `alpine/k8s:1.32.6` or `rancher/kubectl:v1.32.0`, or add explicit `command: []` + proper args separation
- **URGENT** — every cluster reboot/IP-change will hit the same cascade without this fix

### IaC gaps captured (next session work)

See `INCIDENT-COVERAGE-MATRIX-2026-06-19.md` for the 17-row matrix. High-priority IaC PRs:

| Priority | Track | PR |
|---|---|---|
| URGENT | 1.5 | cilium-node-reconciler image fix |
| HIGH | 1.5 | Runbook Case B-2 (hostname patch-back) |
| HIGH | 4 (NEW) | PromRule `ClusterDNSUnreachable` |
| HIGH | 5 (NEW) | Deploy stakater/Reloader for Secret-change pod restart |
| MEDIUM | 4 (NEW) | PromRule `IRSAFailureCascade` |
| MEDIUM | 5 (NEW) | ExternalSecret refresh interval 1h→5m on critical paths |
| MEDIUM | 1.5 | New `istio-ambient-recovery` CronJob OR CASE 5 in reconciler |
| MEDIUM | 4 (NEW) | DS config-hash auto-restart pattern |
| LOW | 3 | Kyverno pod-GC for chronic CrashLoopBackOff |
| LOW | 5 (NEW) | pod-identity-webhook priority barrier |

## Track status

| Track | Theme | Detection | Auto-heal | Status |
|---|---|---|---|---|
| 1 | istio cert chain + xDS resilience | ✓ (PR #40 merged previously) | partial | PromRule LIVE; weekly gateway restart + pinned ClusterIP DRAFTED |
| 1.5 | Cilium ↔ kubectl Node hygiene | ✓ (PR #41 merged) | ⚠ (PR #43 merged but image broken) | LIVE but image bug = no-op |
| 2 | Rook-Ceph observability | drafted | n/a | Gated on mon recovery |
| 3 | CP memory + etcd peer hardening | ✓ (PR #42 merged) | partial | PromRule LIVE; talosconfig backup CronJob DRAFTED; **Phase 1 + worker RAM 12 GB APPLIED** |
| 4 (NEW) | DNS + ambient hygiene | needs PRs | needs PRs | NEW track, fully scoped tonight |
| 5 (NEW) | RW resilience (secret-change reload, refresh tightening) | needs PRs | needs PRs | NEW track, fully scoped tonight |

## First-thing-next-session work

1. **Diagnose + recover Rook mons** — see ROOK-CEPH-IMPLEMENTATION-2026-06-19.md
2. **URGENT PR — cilium-node-reconciler image fix** (one YAML edit in flux-platform op-dev)
3. **Ship runbook Case B-2** (hostname patch-back, no reset) — proven twice tonight
4. **Flip TfApply back to false** in Octopus (currently `true`)
5. **Ship Tracks 4 + 5 PRs** (DNS health + RW resilience)

## What this is

Post-incident codification of the 2026-06-17 CP OOM cascade + 2026-06-18 Cilium-orphan cert cascade + 2026-06-18→19 DNS+IRSA+RW cascade. Turns manual learnings + manual fixes into IaC that ships with QA bring-up and survives cluster restores.

## Files

- `STATE.md` — this file
- `CHANGELOG.md` — chronological session-by-session record
- `DEPLOY-README.md` — original sweep plan
- `INCIDENT-COVERAGE-MATRIX-2026-06-19.md` — **THIS SESSION** — 17 failure-mode IaC gap matrix
- `ROOK-CEPH-IMPLEMENTATION-2026-06-19.md` — **THIS SESSION** — full Rook-Ceph architecture + phases doc
- `rook-ceph-phase1-vsphere-disk-add.md` — Phase 1 details (APPLIED)
- `rook-ceph-phase2-deviceFilter.md` — Phase 2 details (APPLIED)
- `track1-istio-resilience/` — istio resilience drafts
- `track1.5-cilium-hygiene/` — Cilium hygiene drafts (LIVE but image bug)
- `track2-rook-ceph-observability/` — Rook observability drafts (gated)
- `track3-incident-hardening/` — incident hardening drafts
