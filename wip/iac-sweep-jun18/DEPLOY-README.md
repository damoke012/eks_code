# IaC sweep — 2026-06-18

**Origin:** post-incident codification of the 2026-06-17 OOM cascade + 2026-06-18 Cilium-orphan cert cascade. Everything here turns manual learnings + manual fixes into IaC so they ship with QA bring-up and survive cluster restores.

**Status:** DRAFT. NOT yet PRed. Each track has files ready for review.

## Tracks at a glance

| Track | What it adds | Driven by | Folder |
|---|---|---|---|
| 1 | istio xDS + cert TTL PromRules, pinned istiod ClusterIP, weekly gateway DS restart CronJob | 2026-06-18 grafana 503 | [`track1-istio-resilience/`](track1-istio-resilience/) |
| 1.5 | CiliumNode-vs-Node divergence detection (PromRule + reconcile Job) | 2026-06-18 root cause | [`track1.5-cilium-hygiene/`](track1.5-cilium-hygiene/) |
| 2 | Rook-Ceph PromRule, ServiceMonitor, monitoring patch on CR, restore runbook | Rook deploy from this morning | [`track2-rook-ceph-observability/`](track2-rook-ceph-observability/) |
| 3 | CP memory + etcd peer PromRules, talosconfig backup CronJob, worker RAM 4→8 GB TF bump | 2026-06-17 OOM cascade | [`track3-incident-hardening/`](track3-incident-hardening/) |

Each track folder has its own README with file inventory + PR sequence.

## Suggested merge order (overall)

Detection rules first (zero blast radius), then mitigations, then the active CronJobs / capacity bumps.

1. **All PromRules** — Tracks 1, 1.5, 2, 3 — pure detection, no behavior change
2. **Track 2 monitoring patch** — turns on Rook mgr metrics endpoint (needed before its PromRule does anything)
3. **Track 1 pinned ClusterIP** — locks in current istiod IP, minor blast radius
4. **Track 1.5 reconciler CronJob** — DRY_RUN=true mode; just reports
5. **Track 1 weekly gateway restart CronJob** — first run will roll gateways on a Sunday at 04:00 UTC
6. **Track 3 talosconfig backup CronJob** — needs IRSA role first (Track 3 README covers it)
7. **Track 3 worker RAM bump** — coordinate with Tim; triggers VM power cycles

## Repo distribution

| Target repo | Files going there |
|---|---|
| `iaac-talos-flux-platform` (branch `op-dev`) | All PromRules, ServiceMonitor, pinned ClusterIP patch, cephcluster monitoring patch, gateway restart CronJob, ciliumnode reconciler CronJob, talosconfig backup CronJob |
| `iaac-talos` | Worker RAM bump (variables.tf) + IRSA role for talosconfig backup |
| `eks_code` (docs/) | Rook-Ceph restore runbook |

## Pre-PR checklist for EACH track

```
[ ] PromRule rules validate (promtool check rules <file>)
[ ] kube-state-metrics exposes the metrics the rule queries (verify via /metrics scrape)
[ ] CronJob RBAC is namespace-scoped where possible (not cluster-admin)
[ ] CronJob image is bitnamilegacy/* (per Bitnami feedback rule)
[ ] Kustomize patch tested against current op-dev manifests (kustomize build .)
[ ] Track README updated with the actual current ClusterIPs / IPs / values where the file has TODO placeholders
[ ] /onprem-safety pre-flight passes BEFORE any merge that changes cluster behavior (Tracks 1.5 reconciler, 1 weekly restart, 3 worker RAM)
```

## QA cluster carry-over

When the QA cluster gets built:
1. Fork these files into the QA-branch equivalents of the same repos
2. Update IPs / hostnames / cluster-specific values
3. The lessons codified here transfer directly — no rediscovery
4. The pinned ClusterIP patch in Track 1 must use a QA-specific IP from QA's Service CIDR

## Tickets to file (Jira)

Once the trackdrafts are reviewed, file these — one Epic with 4 children:

```
EPIC  INFRA-???? — Post-incident IaC sweep (2026-06-17/18)
  ├─ INFRA-???? — Track 1: istio resilience monitoring + defensive restart
  ├─ INFRA-???? — Track 1.5: Cilium node-divergence detection
  ├─ INFRA-???? — Track 2: Rook-Ceph observability + restore runbook
  └─ INFRA-???? — Track 3: incident hardening (PromRules + worker RAM + tfstate backup)
```

Each child links to the corresponding `wip/iac-sweep-jun18/track*/README.md`.

## Related lessons codified
- [[incident_2026_06_17_cp_oom_cascade]]
- [[incident_2026_06_18_cilium_orphan_cert_cascade]]
- [[skill_onprem_safety]] — Rules 7 + 8 added today
- [[feedback_automate_and_document]] — this sweep IS the codification

## Open questions for the reviewer

1. Should the Track 1.5 reconciler CronJob default to `DRY_RUN=false` after a 1-week soak, or always stay `DRY_RUN=true` and rely on alert-only?
2. Is `lazy-tf-state-65v583i6my68y6x9` the right bucket for talosconfig snapshots, or do we want a separate bucket with stricter lifecycle policy?
3. The pinned ClusterIP in Track 1 is `10.101.33.234` (current op-dev value). Should we instead use a fixed "reserved" IP from a documented range, so all envs share a convention?
