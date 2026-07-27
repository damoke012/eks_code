# Message to Idris — 2026-07-24

Argo CD is live on **dev and QA** as a platform stack. Summary of where things landed, plus
four things I need from you.

---

## 1. Argo CD — done on both clusters

Installed by Flux from a pinned chart (`argo-cd` 10.2.0 = Argo CD **v3.4.5**, the newest
patch on the 3.4 line you originally targeted). ClusterIP behind Istio, secrets via ESO,
`default` AppProject neutered, `apps` AppProject restricted to `app-*` namespaces.

**The guardrail is proven on both.** A probe Application targeting `risingwave` is refused:

```
application destination server 'https://kubernetes.default.svc' and namespace 'risingwave'
do not match any of the allowed destinations in project 'apps'
```

That's the condition PR #73 was rejected for. It's now structurally impossible rather than a
matter of review discipline — which is the outcome I wanted, and it means app teams get
self-service without anyone having to police what they point it at.

**Dev was not greenfield.** When I connected to review it before rollout, Argo CD had been
running there for 49 days from a raw `kubectl apply -k`, with a live Application syncing
`iaac-risingwave-onprem` → ns `risingwave` on `prune: true, selfHeal: true` — the same
split-brain against Tim's namespace we'd agreed to keep out of QA, already running. I removed
it (finalizer cleared first, so no RisingWave resource was cascade-deleted; Flux stayed
authoritative throughout and RW pods never restarted). Then Helm-adopted the install via a
delete-and-reinstall, preserving `argocd-secret` so `server.secretkey` survived byte-for-byte
and nobody's session or the admin login broke.

Worth knowing for future work: **Helm cannot adopt a non-Helm install** — it has no ownership
metadata to take over, so delete-and-reinstall is the only path, and the secret has to be
excluded from the delete explicitly.

**Where the manifests live now.** Argo CD is installed by Flux from
`iaac-talos-flux-platform`: `infrastructure/argocd/` (chart) and `infrastructure/argocd-config/`
(AppProjects + admin ExternalSecret), wired per-cluster in `iaac-talos-flux-cluster`. On QA
these are two Kustomizations because the AppProjects fail dry-run until the chart has
registered the argoproj CRDs — dev only survived as one because its CRDs had been there since
June. **So `iaac-argocd-onprem` is no longer in the install path.** I'd rather not leave a
repo that looks authoritative but isn't — can we archive it, or is there something in it you
still want kept?

**Your work that carried over:** `argocd-admin-externalsecret.yaml`, `namespace.yaml`, and the
whole `argocd-cm` tuning block — `resource.exclusions` is **merged** (your high-churn kinds
plus the Flux toolkit groups), and all eight `ignoreResourceUpdates` keys are folded into the
HelmRelease values, since under Helm `argocd-cm` is rendered at runtime and a kustomize patch
has no target.

**And you were right where I was wrong.** I'd guessed a `aws-secretsmanager` ClusterSecretStore
and `external-secrets.io/v1beta1`; the cluster has `default` and serves `v1` only. My drafted
ExternalSecret would not have applied. Yours was correct — I deleted mine and kept yours.

---

## 2. Four things I need from you

**a. Which app repo is `argocd-git-externalsecret.yaml` actually for?**
It credentials Argo CD against `iaac-risingwave-onprem`. With the RisingWave Application gone
that's dead weight, and I deleted the orphaned ES on dev. But if it was meant for a *different*
app repo, tell me which and I'll wire it into the `apps` project properly — that's the first
real onboarding and I'd like it to be a genuine app team, not a test.

**b. The `sshPrivateKey` committed in `iaac-talos-flux-platform` PR #73 still needs rotating.**
It's in git history, so closing the PR did nothing. This is independent of everything above and
hasn't moved in two weeks. Can you rotate it and move the replacement to SM/ESO? Happy to do it
if you'd rather hand it over.

**c. `risingwave-user-dashboard.json` pins datasource UID `PBFA97CFB590B2093`** — that's
RisingWave's own Grafana. QA's platform Grafana has a different UID, so every panel reads
"Datasource not found". Needs the platform UID or a template variable. Still on your side.

**d. Write access for `dare-x`** on `iaac-risingwave-onprem` and `iaac-argocd-onprem` (if we're
keeping it). I only have pull, which is why the last round came as patches — every review costs
an extra handoff.

---

## 3. RisingWave QA — where does this stand?

Can you confirm the state of the fix patch (PRs #22/#23)? Once it's merged to `main`:

**The first Octopus deploy applies for real.** `TfApply=true` is QA-scoped and there is no plan
gate, so please don't deploy an unmerged branch — merge #23 → #22 → `main` first. Expected
first apply is **20 creates / 0 destroys** (verified locally against live QA). Watch the task
log to confirm `deploy.ps1` actually runs, the `TF_VAR_*` land, and the worker role
authenticates.

Context on why that path needed fixing: the Octopus project was an unconfigured clone —
lifecycle with no qa phase, zero variables, and a deploy step calling `deploy.ps1` when the repo
only had `deploy.sh`. That's why this Terraform had never applied anywhere; the dev state bucket
was empty. Fixed on the Octopus side and in the repo.

**Still blocking the CR, from Tim not you:** operator chart pin, component sizing, S3 retention.
Sizing is the one I'd push on — `replicas: 1` on meta and frontend means no HA, and under "QA
mirrors prod" that shape propagates straight to prod.

---

## 4. Rollout note

Prod is next for Argo CD and will use the QA manifests unchanged. The only per-env difference is
`global.nodeSelector: {pool: platform}` — QA and prod have node pools, dev has flat workers where
that setting would leave every pod Pending.
