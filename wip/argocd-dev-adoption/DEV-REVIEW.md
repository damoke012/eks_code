# ArgoCD on dev — adoption review (INFRA-1622)

**Reviewed 2026-07-23 against live op-usxpress-dev (10.10.82.50).**
Goal set by Doke: ArgoCD is a **platform stack for ALL apps** (new apps deploy via
ArgoCD; cloud→onprem lift-and-shift uses DX/MageRunner). Fold it into the platform
repo, dev first.

## What's actually on dev (not greenfield — this is an adoption)

1. **ArgoCD is live, 49 days, hand-installed** (`kubectl apply -k`, raw — the
   deployment carries only `last-applied-configuration`, NO `helm.sh/*` ownership).
   Full stack: server, application-controller, applicationset, dex, notifications,
   redis, repo-server.

2. **LIVE SPLIT-BRAIN on the `risingwave` namespace.** RW is managed by BOTH:
   - Flux `risingwave-onprem` Kustomization — READY True, 55d, `main@dafc9f48`.
     **Authoritative and healthy.** (Same pattern just wired to QA.)
   - ArgoCD `risingwave` Application — `git@…/iaac-risingwave-onprem → risingwave`,
     **automated{prune:true, selfHeal:true}, ServerSideApply=true**. OutOfSync.
   Two controllers, same repo, same namespace, both prune-capable. "Healthy" only
   because manifests match; a divergence means a fight and ArgoCD can prune RW.
   **This is the exact thing `application-risingwave.yaml` (removed from QA) does.**

3. **Fold-in is half-wired and silently failing.** A Flux Kustomization `argocd`
   (sourced from `infra`, path `infrastructure/argocd`) exists — 17 days FAILING
   "path not found" because the directory was never created in
   iaac-talos-flux-platform. So the platform-stack intent predates us; the target
   dir is `infrastructure/argocd/`, we just complete it.

4. **SM secrets exist under the OLD RW-scoped path** (my earlier "missing" was a
   wrong path — I checked `op-usxpress-dev/argocd/*`, reality is):
   - `op-usxpress-dev/risingwave/argocd` → admin.password + admin.passwordMtime
   - `op-usxpress-dev/risingwave/argocd_git_private_key` → ARGOCD_GIT_PRIVATE_KEY
   The `risingwave/` prefix is the old "ArgoCD is for RW" framing → migrate to a
   platform path.

5. **`argocd-secret` holds `server.secretkey`** (session-signing key) plus the
   admin bcrypt and TLS. **Must be preserved** across any migration or all sessions
   break and admin resets.

## Recommended sequence — deliberate, not a charge-ahead

### Step 1 (do first, standalone, high value): DEFUSE THE SPLIT-BRAIN
Remove the ArgoCD `risingwave` Application WITHOUT deleting RW's resources. Flux
`risingwave-onprem` is authoritative and will keep serving RW.
- Confirm/remove the Application's deletion finalizer first so deleting the
  Application CR does NOT cascade-prune the namespace:
    kubectl -n argocd patch application risingwave --type merge \
      -p '{"metadata":{"finalizers":[]}}'
    kubectl -n argocd delete application risingwave
- Verify RW unaffected: `kubectl -n risingwave get pods` unchanged; Flux
  `risingwave-onprem` still READY True.
This removes the live prune risk regardless of what we decide about the fold-in.

### Step 2: FOLD IN as a platform stack
Create `iaac-talos-flux-platform/infrastructure/argocd/` with the HelmRelease IaC
(chart 10.2.0 = v3.4.5, app-* AppProject, default project neutered, ClusterIP+Istio,
no NodePort). The failing `argocd` Kustomization then goes green.
⚠️ **Helm cannot adopt a raw install** (ownership metadata). Two sub-options:
  a. `helm ... --take-ownership` / annotate existing resources for Helm, OR
  b. delete the raw install objects (PRESERVE `argocd-secret`, the CRDs, and any
     Applications), let the HelmRelease reinstall and re-attach to the preserved
     secret so `server.secretkey` survives.
Option (b) is cleaner but has brief ArgoCD downtime (no workload impact — Flux
serves RW throughout). Needs a short window.

### Step 3: MIGRATE THE SM PATH
`op-usxpress-dev/risingwave/argocd*` → `op-usxpress-dev/platform/argocd*`
(create new, repoint ExternalSecrets, delete old). Reflects platform ownership.

### Step 4: QA + PROD are clean greenfield
No existing install → the fold-in applies directly, no adoption dance.

## The decision needed from Doke
- **Aggressiveness on dev:** Step 1 now (safe, defuses live risk) — yes/no?
- **Adoption method (Step 2):** take-ownership (no downtime, fiddly) vs.
  delete-and-reinstall (clean, brief ArgoCD-only downtime in a window)?
- **DX boundary:** confirm DX/MageRunner stays the path ONLY for cloud→onprem
  lift-and-shift; all net-new apps use ArgoCD. (Stated by Doke 2026-07-23.)
