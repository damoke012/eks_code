# Flux source-bump cascade: dependent Kustomizations show "dependency not ready" right after source update

## Symptom

After a `flux reconcile source git infra` (or after a merged PR triggers source reconcile), several Kustomizations briefly show NotReady with messages like:
- `dependency 'flux-system/istio-ingress' is not ready`
- `dependency 'flux-system/istio-istiod' is not ready`

Even though the dependency targets ARE actually Ready=True at the new revision. The status is STALE — Flux Kustomizations evaluate dependsOn at the moment they're queued; if the dependency hasn't transitioned to Ready in the cluster watcher yet, the check returns false.

Looking at the source-bumped Kustomization status, you'll see things like:
```
flux-system     grafana                  op-dev@sha1:OLDHASH    False   False   dependency 'flux-system/istio-ingress' is not ready
flux-system     istio-cni                op-dev@sha1:OLDHASH    False   False   dependency 'flux-system/istio-istiod' is not ready
```

The hash on the not-ready Kustomization is the OLD revision (pre-bump). Meanwhile the source GitRepository is at the NEW revision, and the dependency Kustomization (e.g., istio-istiod) shows the NEW revision and Ready=True.

## Root cause

Flux's `kustomize-controller` evaluates dependencies via a watcher on the Kustomization CRD. When a source GitRepo bumps, ALL dependent Kustomizations get queued together. There's a race: dependent Kustomization B can evaluate dependsOn on A before A finishes its own reconcile loop. B sees A's pre-bump state (Ready=False or InProgress) and reports "dependency not ready".

This is NOT a real failure — it self-resolves on the NEXT reconcile loop (when A is observed Ready=True). But the next loop only fires on the default interval (10m), so the cluster can sit with NotReady status for 10 minutes after every source bump.

## Resolution

Force-reconcile the dependency chain in dependsOn order, immediately after merging any PR that bumps the infra source:

```bash
flux reconcile source git infra -n flux-system

# Cascade-affected chain: re-reconcile in dependency order
flux reconcile kustomization istio-base -n flux-system
flux reconcile kustomization istio-istiod -n flux-system
flux reconcile kustomization istio-cni -n flux-system
flux reconcile kustomization istio-ztunnel -n flux-system
flux reconcile kustomization istio-ingress -n flux-system
flux reconcile kustomization istiod-health -n flux-system
flux reconcile kustomization grafana -n flux-system
flux reconcile kustomization risingwave-routes -n flux-system

# Verify all Ready=True
flux get kustomizations -A | awk 'NR==1 || $4!="True"'
```

This forces each Kustomization to re-evaluate dependencies AFTER the previous one is observed Ready. Within ~30 seconds the chain clears.

## How we hit this

3x in one session (2026-06-22):
- After PR #47/#19 merge — istio chain went NotReady briefly
- After PR #48/#20 merge — same chain affected
- After PR #50 merge — same chain affected

## Detection

Add this script to post-merge verification:
```bash
sleep 30   # let initial reconcile pass
STUCK=$(flux get kustomizations -A | awk '$4=="False" && $5=="False" {print}')
if [ -n "$STUCK" ]; then
  echo "Cascade detected — force-reconciling:"
  echo "$STUCK" | awk '{print $2}' | while read k; do
    flux reconcile kustomization "$k" -n flux-system
  done
fi
```

## Prevention

- **Default polling interval reduce**: lower the GitRepository `interval` from 1m to 10s for the platform repo so source-bump → dependent watcher catches up faster (~30s instead of ~10m). Costs slight extra git server load. Trade-off acceptable.
- **CronJob "cascade buster"**: scheduled CronJob that runs the above script every 5 min. Catches any cascade left over from forgotten manual merges.
- **Procedural**: every merge of an infra-repo PR should be followed by the force-reconcile sequence (documented in QA-CLUSTER-BOOTSTRAP-CHECKLIST.md as post-merge step).

## Why not just wait?

For Dev, waiting 10 min is fine. For production, "Kustomization NotReady for 10m after every merge" means alerts firing on every deploy. Force-reconcile is the pragmatic answer.

## Refs

- Memory: `[feedback_flux_kstatus_terminal_settled]` — related (different problem: wait: true + terminal-fail)
- Documented in 2026-06-22 session-state body under "Gotchas captured today"
