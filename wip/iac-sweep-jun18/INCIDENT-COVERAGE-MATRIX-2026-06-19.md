# Full IaC Coverage Matrix — Tonight's Incident (2026-06-18 PM → 2026-06-19 AM)

**Context:** Marathon session covered worker memory bump, CN-mismatch recovery, CiliumNode drift, DNS cluster outage, RW recovery. Cluster + RW fully Running at session end.

**Goal:** Every failure mode encountered must have IaC coverage so a fresh deploy or full cluster restore handles it without manual intervention.

## Failure mode → IaC coverage matrix

| # | Failure mode | Manual fix used tonight | Existing IaC | Gap | Fix |
|---|---|---|---|---|---|
| 1 | vSphere data-source race after hot-add silently drops IPs (compact race) | PR #40 dropped compact() + added precondition | **PARTIAL** — precondition fails loudly | No retry — pipeline still fails | **F1**: Time_sleep OR drop data source / use resource attr (Option B preferred) |
| 2 | Kubelet TLS cert CN-mismatch lockup after hostname change (machine config push to wrong target) | PR #38 hostname-pin refactor (compact race won't recur) + `etcd remove-member + reset --EPHEMERAL --reboot` (codified runbook) | **YES** — PR #38 + runbook Case A | Runbook Case B-2 missing (patch hostname back when cert CN is ORIGINAL) | **F2**: Runbook update — add Case B-2 |
| 3 | Stale CiliumNode (orphan / wrong IP / missing) → broken pod-to-pod routing → DNS death | Deleted CN + bounced cilium agent | **YES** (designed) — cilium-node-reconciler CronJob handles all 4 CASES | **IMAGE BUG** — `bitnamilegacy/kubectl:1.32` entrypoint runs `kubectl` directly, our command args are passed AS args, errors immediately | **F3 URGENT**: Image fix — `alpine/k8s:1.32.6` or `rancher/kubectl:v1.32.0` + explicit command/args separation |
| 4 | istio-cni + ztunnel stale after talos config push (idempotent kubelet bounce nudges CNI socket) → new pods fail sandbox setup with "no ztunnel connection" | Deleted istio-cni + ztunnel pods on affected nodes (DS respawn) | **NONE** | Pattern not auto-healed; not in runbook | **F4**: New CronJob `istio-ambient-recovery` OR add CASE 5 to cilium-node-reconciler; runbook update |
| 5 | Cluster DNS broken (timeout) when CN drift hits CP nodes where CoreDNS runs | Manual reconciler-equivalent on CPs | **NONE** for detection | No PromRule fires when in-cluster DNS times out | **F5**: PromRule `ClusterDNSUnreachable` (CoreDNS reachability from probe pod) + auto-heal via fix F3 |
| 6 | ExternalSecret refresh interval is 1h — stays stuck in SecretSyncedError after DNS recovers until next scheduled refresh | Manual `force-sync` annotation | **NONE** | No auto-recovery on transient ClusterSecretStore failure | **F6**: Shorten refresh interval to 5m on critical ESes (RW, ghostunnel TLS, RW operator) OR add liveness-based force-sync controller |
| 7 | RW pods don't restart when their backing Secret content changes — boot with stale empty creds, CrashLoop indefinitely | Manual `kubectl delete pod` | **NONE** | No reload mechanism | **F7**: Deploy `stakater/Reloader` — auto-restart Deployments/StatefulSets when their referenced Secret/CM mutates |
| 8 | Stale CiliumNode after CP IP shuffle (cp-1 missing entirely, cp-2 at wrong IP, cp-3 correct) | Manual CN delete + cilium agent restart | **PARTIAL** — F3 reconciler design handles it, image bug blocks | Same as F3 | **F3** (above) covers this |
| 9 | OIDC issuer / IRSA chain doesn't fail loudly when STS is unreachable — falls through to IMDS which doesn't exist on Talos → cryptic timeout | (waited for DNS recovery) | **NONE** for detection | No alert on IRSA failure cascade | **F8**: PromRule `IRSAFailureCascade` (detect AssumeRoleWithWebIdentity failures via pod-identity-webhook or external-secrets metrics); runbook entry "if seeing IMDS timeout on non-EKS, IRSA chain is broken" |
| 10 | Multiple stuck CrashLoopBackOff pods (ghostunnel 8d/35h) compete with healthy replacements indefinitely | Manual `kubectl delete pod` | **NONE** | k8s doesn't auto-delete stuck CrashLoopBackOff replicas | **F9**: PodGarbageCollector or Kyverno policy: pods in CrashLoopBackOff > 6h get deleted (paired with restartPolicy:Always = new healthy replacement) |
| 11 | Worker memory pressure (.26 at 174 MB free after 8 GB bump) pushes pods into eviction → cascade scheduling failures | PR #39 + #40 bumped to 12 GB | **YES** — Track 3 PromRule alerts memory <1 GB | Sufficient at 12 GB now; PromRule alerts before hitting limit | None needed (already in track 3) |
| 12 | Old ghostunnel pods with stale CrashLoopBackOff state from 8d+ ago survived all this time | Manual delete | **NONE** | Same as F9 | F9 covers |
| 13 | Long network outage causes RW operator state divergence — expired workers stuck in cluster table | RW meta auto-cleaned on restart (no manual fix needed) | **YES** — RW operator built-in | No gap | None |
| 14 | Bitnami chart NP blocks Istio ambient HBONE (port 15008) | Already in memory `[feedback_bitnami_chart_np_ambient_hbone]` | **YES** — feedback memory | Documented as feedback | None |
| 15 | DaemonSet (cilium, istio-cni, ztunnel) doesn't rotate when underlying node config changes | Manual delete pods | **NONE** for general case; per-DS specific | No declarative DS-touch-on-config-change | **F10**: Tag DSes with config-hash annotation via Kustomize/Flux; auto-restart on hash change |
| 16 | CP IP "promotion" reshuffling (cp-1 originally at .181, now at .29) — cilium had hardcoded inventory | Reconciler-equivalent | **YES** (designed) — F3 handles | Image bug | F3 covers |
| 17 | Pod-identity-webhook didn't mutate pods that scheduled before webhook was ready (race) | (not seen tonight, but fundamental risk) | **NONE** | No retry on missed mutation | **F11**: webhook readiness check before app pods schedule (use `priorityClassName` ordering or init container barrier) |

## Track summary — what NEEDS NEW PRs to fully cover

### Track 1.5 — Cilium hygiene (UPDATES)
- **F3 URGENT** — cilium-node-reconciler image fix (small flux-platform PR, 3-line change)
- **F2** — Runbook Case B-2 update (hostname patch-back, no reset)
- **F4** — istio-cni/ztunnel staleness detection + auto-heal (new CronJob OR new CASE in reconciler)

### Track 4 (NEW) — DNS + ambient hygiene
- **F5** — `ClusterDNSUnreachable` PromRule (CoreDNS probe pod)
- **F8** — `IRSAFailureCascade` PromRule
- **F10** — DS config-hash auto-restart pattern

### Track 5 (NEW) — RW resilience
- **F6** — Shorten ExternalSecret refresh interval to 5m on critical paths (RW + ghostunnel)
- **F7** — Deploy stakater/Reloader (auto-restart on Secret/CM change)
- **F11** — pod-identity-webhook readiness barrier (or priorityClassName ordering)

### Track 3 — Incident hardening (UPDATE)
- **F9** — Pod GC for chronic CrashLoopBackOff (Kyverno cluster policy)

## What we can ship tonight (low-risk, high-value)

1. **F3 URGENT** — cilium-node-reconciler image fix (one-line YAML edit, restores the safety net we already deployed)

## What needs design + review next session

- F4 (istio-ambient-recovery CronJob) — new pattern, needs Tim/Steve review on impact to RW
- F7 (Reloader) — new operator, deployment scope check
- F11 (webhook readiness barrier) — design choice

## Carry-over for QA + PROD bring-up

Every failure mode above carries forward. The QA/PROD bring-up checklist needs:

- [ ] Reconciler image fixed before cluster bring-up
- [ ] Reloader deployed in flux-platform infrastructure layer
- [ ] DNS health PromRule in prometheus stack
- [ ] IRSA failure PromRule in prometheus stack
- [ ] Pod GC Kyverno policy in flux-platform infrastructure layer
- [ ] ExternalSecret refresh intervals tuned (5m for critical)
- [ ] Webhook readiness barrier validated in pod-identity-webhook deploy

## Related files

- `track1.5-cilium-hygiene/cronjob.yaml` — reconciler (needs image fix)
- `track1.5-cilium-hygiene/runbook-kubelet-cn-mismatch-recovery.md` — needs Case B-2 append
- `track1.5-cilium-hygiene/prometheusrule-kubelet-not-registering.yaml` — existing PromRule
- `STATE.md` — this session's state
