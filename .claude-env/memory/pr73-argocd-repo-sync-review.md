---
name: pr73-argocd-repo-sync-review
description: "ArgoCD on-prem (INFRA-1622) — PR #73 rejected, then adopted as a Flux-installed platform stack; COMPLETE on dev + QA with app-* guardrail proven"
metadata: 
  node_type: memory
  type: project
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
  modified: 2026-07-24T00:17:12.477Z
---

variant-inc/iaac-talos-flux-platform **PR #73** "Chore/flux argocd repo sync" by ifagbemi-usxpress (Idris) → op-dev. +67,612/−1, 17 files, 5 commits, 6/6 checks pass. Reviewer dare-x.

**Verdict (Round 1 VERIFIED on WSL 2026-07-10): DO NOT MERGE — recommend CLOSE.** Adds Argo CD (2nd GitOps controller) pointed at a repo+ns Flux ALREADY reconciles.

**Blockers (ALL VERIFIED on WSL):**
1. ✅ Direct collision — Argo CD app repoURL=`iaac-risingwave-onprem`, dest ns=`risingwave`; Flux already reconciles this via Kustomization `risingwave-onprem` (Ready=True) + `risingwave` + `risingwave-routes`. Same source+ns = split-brain in Tim's prod ns. (iaac-risingwave-onprem is now Flux-managed — INFRA-1487 A2 landed since the 5/28 snapshot.)
2. ✅ `argocd_git_secret.yaml` commits a real `sshPrivateKey` → key compromised, ROTATE now + move to ESO/SM.
3. ✅ dest ns=`risingwave` = Tim's → Tim coord mandatory.

**Solution given to Idris:** RW repo-sync already exists in Flux (`risingwave-onprem` Kustomization). Close #73; if more sync needed, add Flux GitRepository+Kustomization in iaac-talos-flux-cluster (SSH via ESO). Split the Grafana No-Data fix (9953ad1) + dashboards (76c50b5) into their own small PR. Full proposal: `wip/argocd-repo-sync/recommended-solution.md`; finalized comment: `wip/argocd-repo-sync/round1-comment.md`.

**Advisory:** Argo CD NodePort 31311/32119 (vs live Istio ingress); ServerSideApply field-ownership; scope creep (Grafana No-Data fix + RW streaming dashboards + Prometheus refactor bundled — split for clean rollback).

Full audit + WSL verification battery + draft Round-1 comment: `wip/argocd-repo-sync/` (STATE.md, pr-73-review-2026-07-10.md). Codespace can't reach variant-inc or the cluster — run verification on WSL. Related: [[risingwave-onprem]], [[onprem-networking-ingress]].

---

## 2026-07-22 — SUPERSEDED by `variant-inc/iaac-argocd-onprem` (INFRA-1622). RESOLVED.

Doke decided to adopt Argo CD. Idris created a new repo and seeded it — **it was PR #73's
content at a new address**, not a fresh design. `manifests/op-usxpress-{dev,qa}/` contained
`application-risingwave.yaml`: an Argo CD Application with `project: default`,
`repoURL: iaac-risingwave-onprem`, `path: manifests/op-usxpress-qa` (**the exact path Doke's
Flux wiring reconciles**), `destination.namespace: risingwave`, and
`syncPolicy.automated{prune: true, selfHeal: true}` + `ServerSideApply=true`.
**Strictly worse than #73** — two controllers self-healing identical objects fight
indefinitely, `prune` can delete in Tim's namespace, and `project: default` bypasses every
guardrail. Also present: `service-nodeport.yaml` (mapped :443 → plain-HTTP targetPort 8080)
and a `resources:` entry fetching `raw.githubusercontent.com/.../v3.4.3/install.yaml` live
inside the reconcile path.

**Resolution — Argo CD ships as an APP-LAYER controller only.** Design + manifests in
`iaac-drafts/argocd-onprem-jul22/` (commit 09735b5); apply with `merge-into-repo.sh`
(NOT the deleted `seed-argocd-repo.sh`, which wrongly assumed an empty repo and clobbered
two of Idris's files). Guardrails, all asserted by the script's verify pass:
- `AppProject/apps` destinations limited to **`app-*`** — cannot match risingwave,
  flux-system, velero, rook-ceph, istio-system, etc.
- **The built-in `default` AppProject is overwritten with empty allow-lists.** It ships
  permissive (`'*'`); without this override every other guardrail is decorative.
- `resource.exclusions` **merged**: Flux toolkit CRDs (Argo CD must never act on the
  controller that installed it) **plus** Idris's high-churn kinds. 8 groups, 8
  `ignoreResourceUpdates` keys, folded from the now-deleted `argocd-cm-patch.yaml`
  (under Helm, `argocd-cm` is rendered at runtime so a kustomize patch has no target).
- Installed BY Flux from a pinned chart; ClusterIP + Istio; ESO for secrets.
- kustomize **base + overlays**, deliberately NOT branch-per-env.

⚠️ **My base manifests were WRONG and Idris's were RIGHT** — verified against the live
cluster: ClusterSecretStore is **`default`** (there is no `aws-secretsmanager`) and only
**`external-secrets.io/v1`** is served (v1beta1 would not apply). Check the cluster before
writing ExternalSecrets.

**OPEN:** (a) chart `7.7.11` vs Idris's Argo CD `v3.4.3` — different lines, Doke must pin
deliberately; (b) `argocd-git-externalsecret.yaml` still credentials Argo CD for
`iaac-risingwave-onprem` — unnecessary once the Application is gone, ask Idris which app
repo it is actually for; (c) **PR #73's committed sshPrivateKey still needs rotating**
regardless; (d) Istio VirtualService (Gateway + hostname) not yet written — port-forward
until then, do not re-add a NodePort; (e) dev rollout first, then QA.

---

## 2026-07-23 — DEV IS NOT GREENFIELD. Live ArgoCD found + split-brain. (INFRA-1622)

Reviewing dev before the "platform stack" rollout, connected to op-usxpress-dev (.50):
- **ArgoCD live 49 days, hand-installed** (raw `kubectl apply -k`, NO helm ownership on argocd-server). Full stack incl. dex/applicationset/notifications.
- **LIVE SPLIT-BRAIN**: RW managed by BOTH Flux `risingwave-onprem` Kustomization (READY True, 55d, authoritative) AND ArgoCD `risingwave` Application (`git@…/iaac-risingwave-onprem → risingwave`, **prune:true, selfHeal:true, SSA**, OutOfSync). Same repo+ns, both prune-capable = exactly the `application-risingwave.yaml` removed from QA, running on dev.
- **Fold-in half-wired + silently failing**: Flux Kustomization `argocd` (from `infra`, path `infrastructure/argocd`) FAILING "path not found" 17 days — dir never created in iaac-talos-flux-platform. Fold-in target confirmed = `infrastructure/argocd/`.
- **SM secrets exist** under OLD path `op-usxpress-dev/risingwave/argocd` (+ `_git_private_key`). My earlier "missing" was wrong path (`/argocd/` vs `/risingwave/argocd`). `risingwave/` prefix = old RW-scoped framing → migrate to `platform/`.
- **`argocd-secret` has `server.secretkey`** (session key) — MUST preserve across migration.

**Doke's direction**: ArgoCD = platform stack for ALL new apps; DX/MageRunner = ONLY cloud→onprem lift-and-shift. Fold in agreed. Recommended sequence (in `wip/argocd-dev-adoption/DEV-REVIEW.md`): (1) defuse split-brain — remove ArgoCD `risingwave` Application after clearing its finalizer so RW resources aren't cascade-pruned; Flux keeps serving RW. (2) fold into `infrastructure/argocd/` — but Helm CANNOT adopt a raw install, so either take-ownership or delete-and-reinstall preserving argocd-secret+CRDs (brief ArgoCD-only downtime). (3) migrate SM path. (4) QA/prod clean greenfield.
**PENDING Doke decisions**: do Step 1 now? adoption method (take-ownership vs delete-reinstall)? Chart already pinned 10.2.0/v3.4.5 in iaac-argocd-onprem PR #2 (merged, not yet cluster-wired).

**IN-FLIGHT 2026-07-23 EOD — dev ArgoCD adoption cutover PAUSED mid-runbook.** Step 1 (split-brain) DONE: ArgoCD `risingwave` Application deleted (finalizer cleared first, RW pods unchanged, Flux `risingwave-onprem` still authoritative). Steps 2-3 runbook: `wip/argocd-dev-adoption/RUNBOOK.md`; manifests `wip/argocd-dev-adoption/infrastructure-argocd/`.
Progress: ✅ Phase A backup taken (`/tmp/argocd-dev-backup/` on WSL — argocd-secret.yaml 22 lines, server.secretkey.b64 60 bytes). ✅ Phase B verified (helm template: NodePort 0, kind:Secret 0 [createSecret:false works], server.insecure 2) + committed → **PR variant-inc/iaac-talos-flux-platform#81** (feat/argocd-platform-stack → op-dev).
**RESUME AT: merge #81 → `flux suspend kustomization argocd` (avoid 10m auto-reconcile race) → check existing ExternalSecrets in argocd ns → Phase C cutover (delete `-l app.kubernetes.io/part-of=argocd` deploy/sts/svc/cm/sa/role/rb/netpol + argocd-server-nodeport + argocd-dex-server; secrets+CRDs NOT in delete list so PRESERVED) → GATE: confirm argocd-secret server.secretkey survives → flux resume+reconcile → Phase D verify.** Rollback: `kubectl apply -f /tmp/argocd-dev-backup/argocd-secret.yaml` (or argocd-ns-full.yaml). Method = delete-and-reinstall (Helm can't adopt the raw install). Then Step 3 SM migration risingwave/argocd → platform/argocd.

**✅ COMPLETE 2026-07-23 — dev ArgoCD adopted as platform stack (INFRA-1622).** PR variant-inc/iaac-talos-flux-platform#81 merged; cutover executed via `wip/argocd-dev-adoption/RUNBOOK.md`. HelmRelease argocd (chart 10.2.0/v3.4.5) READY, `Helm install succeeded`. VERIFIED: server/controller/applicationset/repo/redis Running (no dex, no notifications); ClusterIP only (no NodePort); `default` AppProject destinations `[]`; `apps` project `app-*` only; **server.secretkey UNCHANGED vs backup** (createSecret:false held — no session/admin breakage); admin ExternalSecret now `secret synced` (my manifest fixed the pre-existing SecretSyncedError). **GUARDRAIL PROVEN**: a probe Application → ns `risingwave` was REJECTED ("do not match any of the allowed destinations in project 'apps'"). Split-brain now structurally impossible. Backup at `/tmp/argocd-dev-backup/`. ✅ **Step 3 DONE (PR #82)**: admin SM migrated to `op-usxpress-dev/platform/argocd` (SecretSynced True); orphaned `argocd-git-private-key` ES deleted; both old `risingwave/argocd*` SM secrets scheduled for deletion 2026-07-30 (7-day window).

---

## 2026-07-24 — ✅ QA ROLLOUT COMPLETE (greenfield). INFRA-1622 done on dev + QA.

QA confirmed greenfield first (no argocd ns / no argoproj CRDs / no Kustomization / no SM
secret). Manifests in `wip/argocd-qa-rollout/` (commit 6668641). Landed via
**iaac-talos-flux-platform PR #83** (op-qa) then **iaac-talos-flux-cluster PR #27** (master)
— **that order is mandatory**; reversed gives the "path not found" Kustomization that sat
broken on dev for 17 days.

**Two deliberate differences from dev, both proved out on the live cluster:**
1. **Install split from config** — `infrastructure/argocd/` (chart only) +
   `infrastructure/argocd-config/` (AppProjects + admin ExternalSecret), the latter
   `dependsOn: [argocd, external-secrets]` with `wait: true`. Dev worked as ONE Kustomization
   only because its 49-day hand-install had already created the argoproj CRDs. On greenfield
   the AppProjects fail dry-run before the chart installs the CRDs — same shape as the
   RisingWave CR ordering failure. Both Kustomizations came up Ready in order.
2. **`global.nodeSelector: {pool: platform}`** — QA/prod have pools, dev has flat workers
   where this would leave every pod Pending. All 5 pods landed on
   `talos-wk-op-qa-platform-1/2/3`.

**Verified live on 10.10.82.51:** HelmRelease `argo-cd@10.2.0` (v3.4.5) install succeeded;
4 services all ClusterIP (no NodePort); `default` AppProject destinations `[]`; `apps` =
`[{"namespace":"app-*","server":"https://kubernetes.default.svc"}]`;
`argocd-admin-credentials` SecretSynced True from `op-usxpress-qa/platform/argocd` (acct
527101283767); **guardrail probe → ns `risingwave` REJECTED** with the same message as dev.

**REMAINING (follow-ups, not blocking):** Istio VirtualService for the UI on **both** dev and
QA (port-forward until then — do NOT re-add a NodePort); backfill the split install/config
pattern to dev; prod rollout uses the QA manifests as-is.

**Backfill CONFIRMED NECESSARY (verified on op-dev .50, 2026-07-24):**
`applications.argoproj.io` + `appprojects.argoproj.io` CRDs created **2026-06-04** (the
hand-install); `argocd-server` Deployment created **2026-07-23** (the cutover). Phase C
worked exactly as designed — all workloads replaced, CRDs and secrets deliberately excluded
from the delete list — which means dev's argoproj CRDs have existed continuously since June.
Dev's single Kustomization (chart + AppProjects together) therefore succeeds on **pre-existing
cluster state, not on anything the manifest expresses**. Rebuild dev from
`infrastructure/argocd/` onto a bare cluster and the AppProjects fail dry-run before the chart
registers the CRDs. Fix = port QA's split (`argocd` + `argocd-config` with
`dependsOn` + `wait: true`, from `wip/argocd-qa-rollout/`) back to op-dev. Dev keeps flat
workers, so do **NOT** carry QA's `global.nodeSelector: {pool: platform}` across — every pod
would go Pending.
