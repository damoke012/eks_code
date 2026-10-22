---
name: prod-standup
description: "op-usxpress-prod stand-up (INFRA-1589/1621) — cluster UP + full platform reconciled 2026-07-29; 4 source-level gaps still open before destroy→rebuild acceptance"
metadata: 
  node_type: memory
  type: project
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
  modified: 2026-07-29T01:52:31.647Z
---

**op-usxpress-prod stand-up — kicked off 2026-07-24 (INFRA-1589 automation, INFRA-1621 gaps).**
Deploy is Octopus ONLY (never local terraform apply). This is the FIRST real execution of the
teardown→rebuild path — QA was built forward, never from scratch, so nothing is proven E2E.

**Doke's key input:** on-prem reuses the cloud per-env AWS account. op-dev→700736442855,
op-qa→527101283767, so **op-prod→937464026810** (ops-controller / usxpress-prod). INFERRED from
the pattern — flagged CONFIRM everywhere, not silently baked in.

**Artifacts (all in `wip/prod-standup/`, codespace drafts — apply on WSL, token isolation):**
- `prod.tfvars` (E5) — modelled on verified QA tfvars. Three value classes: RESOLVED / MIRRORED-from-QA / `TBD-PROD-*` sentinel.
- `add-prod-vars.py` (E4) — prod Octopus vars, modelled on `add-qa-vars.py`. Dry-run default; `--apply` REFUSES while any `TBD-PROD` remains (INFRA-1623 defence in code); `--diff-qa` shows prod-vs-QA drift.
- `RUNBOOK.md` — placeholder register (§1, the load-bearing list), build order, gates B1–B7 as acceptance.
- `E3-substitutefrom.md` — postBuild.substituteFrom design; cluster-vars ConfigMap; ⚠️ grafana `${datasource}` blanking landmine; QA-first rollout.
- `E2-op-qa-commands.md` — WSL grep+fix for op-qa foreign-env literals; external-dns txtOwnerId FIRST (live blast radius).

**REGISTER — 3 of 5 self-resolved 2026-07-24 via `validate-register.sh` (read-only AWS across profiles):**
- ✅ **Account 937464026810 VERIFIED** (was inferred) — `sts get-caller-identity` on ops-controller profile. Pattern confirmed: dev=usx-dev/700736442855, qa=usx-qa/527101283767, prod=ops-controller/937464026810.
- ✅ **DNS = `usxpress-prod.com`** — public Route53 zone in prod acct. → external-dns `--domain-filter=usxpress-prod.com`, `--txt-owner-id=op-usxpress-prod`.
- ✅ **State bucket = `lazy-tf-state-ipp58n854uhpw13x`** (matches QA's `lazy-tf-state-*` scheme; QA was `lazy-tf-state-425rbol87rmn6c7m`). Other candidate `usxpress-tf-state-25cypfeqq8xpf582` is older/unrelated. Confirm holds `iaac/talos` before final.
- IRSA OIDC = greenfield, phase 2, not blocking.

**VIP RESOLVED 2026-07-24 — `10.10.82.52`.** Doke's call: dev/qa VIPs were self-assigned on vLAN 82 (dev .50, qa .51), NOT allocated by networking — so prod .52, verified free (silent ping, no kubeconfig ref). Networking gets NOTIFIED, not asked. **Node IPs are DHCP** on the vLAN (QA CPs scattered .25/.24/.177) — there is NO per-node static IP list; only the VIP is static. This corrected my over-specified "node IP plan" ask.

**vSphere RESOLVED 2026-07-24 (lead call, "whatever's prod-ready"):** prod uses the
prod-DESIGNATED infra — datastore `USXD1NTXPROD-SC1`, network `10.10.82 (vLAN 82) Prod`,
content-lib `dev-cluster`/`talos-v1.11.1`, dedicated vm_folder `/KubernetesD1/TalosD1/op-usxpress-prod`.
Key reframe: the names say PROD — these are prod's own storage/network and QA is CO-TENANTING
on them (a QA-hygiene note, not a prod problem). datacenter/vm_cluster_name are unscoped global
Octopus vars (QA didn't env-scope them). **PRE-APPLY GATE:** verify `USXD1NTXPROD-SC1` has
headroom for prod's ~5 TB (13 VMs, app pool 5×(300+500)=4 TB dominates) ON TOP of QA's usage —
`govc datastore.info` or vSphere UI. Co-tenancy makes capacity the one thing NOT automatically true.

**SECRET-SEEDING MODEL CONFIRMED FROM MODULE 2026-07-24 (iaac-talos deploy/terraform):** ALL
secret ops gated on `enable_irsa`. `secrets-values.tf`: `seed_secret_values = enable_irsa &&
manage_platform_secret_values`. `talosconfig-secret-import.tf`: `import{ for_each = enable_irsa ?
{...} : {} }` (comment: "IRSA disabled = no-op"). grafana secret resources live in `modules/irsa`
(count=0 when off). **So PHASE 1 (enable_irsa=false) seeds NOTHING — no talosconfig, no grafana, no
import; cluster bootstraps from TF-generated talos_machine_secrets internally.** Phase-1 Octopus vars:
talosconfig/grafana/azure-ad ARNs = "" (empty, NOT placeholder), manage_platform_secret_values=false,
enable_irsa=false, irsa_oidc_bucket_name="". ZERO TBD-PROD left → guard passes, no cloud dep, no secrets.
Phase 2: seed placeholder SM secrets at op-usxpress-prod/{talosconfig, platform/grafana,
platform/grafana/azure-ad}, set ARNs, flip enable_irsa+manage_platform_secret_values=true → TF imports
wrappers + writes real values (grafana admin = random_password 28ch; azure-ad = PLACEHOLDER + ignore_changes).

**op-qa literals (grep 2026-07-24) — 13 files, ONLY 1 in phase-1 scope:**
`infrastructure/cert-manager/release.yaml` (phase-1 core). All others phase-2: cert-manager-issuers,
app-secrets/brands-api, arc-runner-rw-pipeline, ecr-credentials, etcd-backup(×3), grafana(dashboard),
octopus-worker, prometheus-rules, rook-ceph-operator, velero. So cutting a clean phase-1 op-prod needs
only cert-manager/release.yaml's dev ref checked/fixed; the rest fixed at phase-2 prep. NOTE op-qa STILL
has op-usxpress-dev refs (E2 not yet done on op-qa).

**Config COMPLETE + VAR PARITY PROVEN 2026-07-24** via `--diff-qa` (empty "only in QA" section).
`--diff-qa` caught a real gap: QA scoped 3 platform-secret vars prod's set lacked —
`grafana_admin_secret_arn` (QA path `op-usxpress-qa/platform/grafana`),
`grafana_azure_ad_secret_arn` (`.../platform/grafana/azure-ad`, Entra SSO = A1),
`manage_platform_secret_values=true`. Without grafana_admin, prod Grafana boots with NO admin
credential — deployed-but-unusable, passes every health check. Added all 3 at op-usxpress-prod
paths; both grafana ARNs are build-time seeds (like talosconfig). **Guard now blocks only on 3
build-time secret ARNs** (talosconfig + 2 grafana), all seeded together in RUNBOOK step 5.
⚠️ CONFIRM against the actual iaac-talos TF module whether these ARNs are TF-created (computed
output) or seed-first (input) — QA passes them as inputs → seed-first assumed.

**QA cluster wiring layout** (`iaac-talos-flux-cluster/clusters/op-usxpress-qa/flux-system/`):
`gotk-components.yaml` (identical boilerplate), `gotk-sync.yaml`, `infra-source.yaml` (GitRepository
→ platform repo branch op-qa), `infra.yaml` (~35 Kustomizations), `kustomization.yaml`. Prod = new dir
`clusters/op-usxpress-prod/` on master (dir-per-env, NOT branch), infra-source → platform branch
op-prod. Platform repo IS branch-per-env (op-dev/op-qa/op-prod); cutting op-prod from op-qa after E2 fixes.

**PROD CLUSTER DIR DRAFTED 2026-07-24** — `wip/prod-standup/clusters-op-usxpress-prod/` (4 files +
README; gotk-components copied verbatim). Env edits: infra-source branch→op-prod, gotk-sync path→
clusters/op-usxpress-prod.

**⚠️ CORRECTION — IRSA bootstrap is NOT "phase 2, not blocking". It blocks a FUNCTIONAL platform.**
Reading QA's infra.yaml: external-secrets/ESO, external-dns, velero, etcd-backup ALL auth to AWS via
the CloudFront OIDC (IRSA). Prod has NO OIDC provider yet. So without the prod IRSA bootstrap
(`ONPREM_BOOTSTRAP_ROLE_ARN_PROD` + OIDC bucket, from cloud) ESO can't read SM → no ExternalSecret
syncs → grafana/argocd admin creds never populate. TWO MILESTONES: (1) **cluster exists** = Talos+Flux+
AWS-free core (cert-manager, trust-manager, gateway-api, keda, kyverno(+policies), reloader, cilium-lb,
cilium-hygiene, pod-identity-webhook) — needs nothing external, do now; (2) **platform functional** =
everything AWS-dependent + argocd — needs the prod IRSA bootstrap. **This is the ONE genuine remaining
cloud ask** (same OIDC/role cloud already did for QA). prod infra.yaml is PHASED: phase-1 core active,
phase-2 a commented appendix to uncomment after IRSA lands. **RisingWave OMITTED** from prod (its
`./manifests/op-usxpress-prod` path doesn't exist → would be the 17-day "path not found" failure).

**PROGRESS 2026-07-27 — cluster wiring + vars DONE, PARKED at the deploy gate:**
- ✅ Octopus prod env exists = **`production`** (`Environments-41`), NOT `prod`. add-prod-vars.py default set to it.
- ✅ `op-prod` platform branch CUT from op-qa (exact copy) + pushed. cert-manager/release.yaml fixed on op-prod
  (the ONE live phase-1 literal: role-arn `527101283767:cert-manager-op-usxpress-qa` → `937464026810:...-prod`).
- ✅ `clusters/op-usxpress-prod/` MERGED to master via **PR #28** (iaac-talos-flux-cluster). Phased infra.yaml (core active, phase-2 commented), infra-source→op-prod.
- ✅ **29 prod-scoped Octopus vars APPLIED** (`add-prod-vars.py --apply`, scoped Environments-41). Backup `/tmp/octopus-varset-prod-backup-*.json`. Phase-1 model: all secret ARNs empty, enable_irsa=false, manage_platform_secret_values=false, VIP 10.10.82.52, bucket lazy-tf-state-ipp58n854uhpw13x. ZERO TBD.

═══ 🎉 **op-usxpress-prod IS UP — 13 nodes Ready, Flux reconciling. 2026-07-28/29** ═══
`Apply complete!` on release **`.1.223`**. **13/13 nodes Ready v1.32.0** (talos-cp-op-prod-1..3, wk-application-1..5,
wk-platform-1..3, wk-system-1..2). 4 Flux controllers Running. All 3 GitRepositories Ready — **`infra` = `op-prod@82838ec6`**
(gate B7 at source level). **Gate B1 PASSED** — SM talosconfig starts `context: op-usxpress`, not PLACEHOLDER.
IRSA live: prod's OWN CloudFront OIDC = **`https://d3rxit8f4yvshu.cloudfront.net`**; all 3 SSM params validated.
**FIVE bugs found+fixed during the apply (all greenfield-only paths, all in deploy.ps1 on feat/aws-iam-authenticator):**
1. `AccessDenied` iam:CreateOpenIDConnectProvider + cloudfront:CreateOriginAccessControl → ran
   `octopus/apply-bootstrap-perms.sh` locally w/ ops-controller (Doke's SSO HAS iam:PutRolePolicy — **never a cloud ask**);
   also widened the policy to 3 role-name shapes (`b1ca617`).
2. k8s provider hit apiserver mid-restart (`connection refused`) — `wait_for_cluster` only TCP-probes, doesn't check
   `/healthz`. Fixed by retry. **STILL A REAL GAP — should poll /healthz; will bite every rebuild.**
3. `ce bash -c "..."` splats args → bash got only `rm` (`9fc325b`).
4. kubeconfig written via `Out-File -NoNewline` on a string ARRAY → whole YAML on one line (`76091b8`).
   ⚠️ SAME LATENT BUG still in the stuck-namespace block.
5. `kubectl apply -k` sends CRDs + CRs in one stream → "ensure CRDs are installed first". Two-pass + wait
   for Established (`bae3c41`).
6. **`flux bootstrap` creates the `flux-system` git-credentials Secret; `kubectl apply -k` does NOT** → both
   GitRepositories stuck "secrets flux-system not found", every Kustomization "Source artifact not found" — cluster
   healthy, reconciling NOTHING. Seeded manually w/ `gh auth token`; permanent fix `ca5479f` seeds it between pass 1
   and pass 2. **NOT YET VERIFIED BY A DEPLOY — next redeploy proves it (and replaces Doke's PAT with Octopus's token).**
**STATE at hand-off:** ~14 Kustomizations Ready (cert-manager, cert-manager-issuers, trust-manager(+bundle), cilium-lb,
cilium-hygiene, gateway-api, istio-namespace, local-path-storage, prometheus, prometheus-rules, reloader,
pod-identity-webhook, flux-system). external-secrets/keda/kyverno/istio-csr showed `health check failed ... HelmRelease
InProgress` = charts slower than the 5m timeout, **pods ARE Running** — Flux retries automatically, not a real failure.
ClusterSecretStore not created yet (gated on external-secrets). Everything else parked on dependsOn.
**NEXT:** wait/`flux reconcile kustomization external-secrets --with-source` → confirm ClusterSecretStore Ready (first
real IRSA test) → then B2–B6 gates. Then REDEPLOY to verify the git-secret automation. Then destroy→rebuild = the
actual INFRA-1589 acceptance test.

═══ ✅ **FULL PLATFORM RECONCILED 2026-07-29** — ESO/IRSA/Istio/ArgoCD all green ═══
**Gate: ClusterSecretStore `default` = Valid/ReadWrite/Ready** → ESO authenticates to Secrets Manager through prod's
OWN CloudFront OIDC (`d3rxit8f4yvshu.cloudfront.net`), no static creds. First genuine end-to-end IRSA proof on-prem.
ArgoCD admin credential verified CONTENT-level: `argocd-secret.admin.password` starts `$2b$` (real bcrypt, not a
placeholder) — the [[eso-secretsynced-not-content-check]] trap, checked properly. **Password ROTATED 2026-07-29 and
captured** (previous one was shredded unread); it also went into terminal scrollback + a Claude transcript → rotate
again post-go-live.

**THREE NEW GREENFIELD-ONLY BUGS — all root-caused and fixed:**
1. ⛔ **istio-cni installed BEFORE ztunnel → 22-MINUTE CLUSTER-WIDE SANDBOX BLACKOUT.** With `wait: true`, Flux made
   `istio-cni` fully Ready (CNI chained into every node) before `istio-ztunnel` was even applied. Every pod sandbox
   created in that window died: `istio-cni cmdAdd failed to contact node Istio CNI agent ... no ztunnel connection`
   (~84 retries). kyverno/keda/argocd/istio-ingress blew their Helm timeouts as collateral; **kyverno's release wedged
   in `uninstalling`, which Flux CANNOT exit** — needed `helm uninstall --no-hooks` by hand. Self-heals once ztunnel
   lands, so it LOOKS transient — the lasting damage is wedged Helm releases. **FIX = swap the dependsOn: ztunnel
   dependsOn istiod, cni dependsOn ztunnel.** Safe both ways (ztunnel's own pods get normal Cilium networking when no
   istio-cni exists yet). **PR #30 MERGED** (iaac-talos-flux-cluster/master) covering **prod + qa + bm-dev** — all three
   carried it. `dpl` too (not ours, flagged only); `dpl2` unaffected (no ztunnel = not ambient).
   ⚠️ **NOTE: dev in the CLUSTER repo is `clusters/bm-dev/`, NOT `op-usxpress-dev`.** Cluster repo = dir-per-env on
   `master`; platform repo = branch-per-env. Don't confuse them.
2. ⛔ **`configmapNamespaceSelector: "name=istio-system"` starved every other namespace of `istio-ca-root-cert`** →
   all 10 `istio-ingressgateway` pods stuck ContainerCreating on `MountVolume.SetUp failed ... configmap not found`.
   NOT RBAC — istio-csr was explicitly told to write only into istio-system. **Ambient namespaces don't need the
   ConfigMap; SIDECAR ones do** — `istio-ingress` carries `istio.io/rev=default`, so it's the first namespace ever to
   expose this. Selector is identical on EVERY branch incl. dpl/dpl2 → likely wrong fleet-wide, unverified on QA
   (QA context was missing from kubeconfig, see [[wsl-kubeconfig-churn]]). **FIX = `configmapNamespaceSelector: ""`
   (chart default = all namespaces). PR #85 MERGED** → ConfigMap appeared in all 21 namespaces within seconds.
   ⚠️ **`valuesFrom` ConfigMap edits do NOT trigger a Helm upgrade** — reconciling the Kustomization updates the
   ConfigMap but the release keeps old values until the HR's next interval. Must
   `flux reconcile hr <name> -n <ns> --force`. Reloader is in-stack and could close this.
3. ⛔ **`pool=` node labels applied to the SYSTEM pool ONLY** → `argocd-redis-secret-init` (nodeSelector
   `pool=platform`) unschedulable: `0/13 nodes available: 10 didn't match selector, 3 control-plane taint`. Blocked
   ArgoCD's pre-install hook → Helm install `Failed`. **The Terraform is FINE** — `local.worker_pool_metadata`
   (deploy/terraform/main.tf:53) flattens `sort(keys(pools))` × count, correctly one entry per worker, index-aligned
   with worker_vm_names. **The gap is the INPUT: prod's `TF_VAR_worker_pools` JSON only carries `labels` on the
   `system` entry.** Same failure shape as the empty `irsa_oidc_bucket_name`. **`nodeTaints` comes from the same
   struct → prod's pool taints are missing too; nothing keeps workloads off platform/application pools.**
   🔧 **UNFIXED AT SOURCE — labels applied BY HAND (`kubectl label node ... pool=platform|application`); a rebuild
   loses them.**

**⚠️ FLEET-WIDE FINDING — op-dev, op-qa AND op-prod ALL RUN `dpl2`'s MESH IDENTITY.** 6 literals on op-prod:
`istio/istiod/values.yaml` meshID + `cluster:` + trustDomain, `istio-csr/values.yaml` trustDomain,
`cert-manager-issuers/issuer.yaml:29`, `cilium-lb/resources.yaml` `dpl2-lb-pool`. The `dpl` branch uses
`dpl.mesh.usxpress` throughout → **convention IS per-cluster; op-* were forked from dpl2 and never renamed.**
`fix-op-prod-literals.sh` missed these (it hunted account IDs / cluster names, not mesh domains).
**NOT an active security hole** — each cluster has its OWN root CA (`create-istio-root-ca` job), so no cross-cluster
trust. Breaks: multi-cluster federation, mesh telemetry, AuthorizationPolicies matching on principal.
**TEAM DECISION, not a solo fix** (rotates every workload identity). **Prod is the CHEAP WINDOW — no traffic yet.**

**4 OPEN ITEMS BEFORE destroy→rebuild ACCEPTANCE:**
- 🔧 node labels + taints at source (prod `TF_VAR_worker_pools` JSON) — currently hand-applied
- 🔧 `install.remediation.retries: 3` on heavy HelmReleases — THREE releases wedged today because a blown timeout has
  no retry path and escalates into an unrecoverable state. Platform repo, op-prod.
- 🔧 `wait_for_cluster` polls TCP, not `/healthz` (carried from the .223 apply)
- 🔧 git-secret automation `ca5479f` STILL UNVERIFIED — next redeploy proves it + swaps Doke's PAT for Octopus's token
- 📋 **Diff prod's ENTIRE Octopus var set against QA's field-by-field** — 3 prod-vs-QA drifts surfaced today, all in
  the hand-built variable set, all invisible until build time. Worth more than any further individual fix.

═══ **(earlier) FIRST APPLY RAN. PARTIAL.** ═══
🟡 **FIRST REAL APPLY 2026-07-28 — got a long way, then failed on IAM/CloudFront perms. NOT a code bug.**
Deployed release **`0.1.0-feat-aws-iam-authenticator.1.219`** (that branch = refactor/multi-env-parameterization + 2
commits adding an OPTIONAL aws-iam-authenticator webhook; both `enable_aws_iam_authenticator` vars default **false**
and the apiserver-patch refactor is output-identical when off → `.219` ≡ `.215` for prod. Verified safe.)
**WORKED:** `[SM-SEED]` created then idempotently re-described all 3 SM wrappers · `[WHOAMI]` = 937464026810 ·
**13 VMs CREATED** (all CP + 3 worker pools) · `aws_secretsmanager_secret_version.talosconfig` written (proves
manage_platform_secret_values=true seeds real values) · 3 imports adopted the wrappers cleanly.
**FAILED:** `AccessDenied` on `iam:CreateOpenIDConnectProvider` and `cloudfront:CreateOriginAccessControl` —
`octopus-usxpress` in the prod account had no IAM/CloudFront rights.
✅ **FIXED: ran `octopus/apply-bootstrap-perms.sh` locally** (`AWS_PROFILE=ops-controller CLUSTER_NAME=op-usxpress-prod`)
— Doke's ops-controller SSO role HAS `iam:PutRolePolicy`, so **there was never a cloud ask.** Inline policy
`iaac-talos-bootstrap` now on `octopus-usxpress` in 937464026810. **This is a ONE-TIME-PER-ACCOUNT prerequisite — a
rebuilt account needs it again; belongs in the runbook.**
⚠️ **Also patched the policy's role-name scoping (`b1ca617`)** — modules/irsa creates 10 roles in THREE shapes:
`<cluster>-*` (etcd-backup, ecr-credentials-sync, external-secrets, risingwave-2, velero), `*-<cluster>`
(cert-manager, extd-usxpress-io, iaac-octopus-worker) and `gha-<cluster>-*` (2 risingwave GHA roles). Original policy
matched only the first two shapes. Now three patterns, all still cluster-scoped.
**STATE = PARTIAL APPLY. 13 VMs exist, talosconfig in SM, IRSA half-built. DO NOT DESTROY — terraform resumes.**
**NEXT: re-arm production-scoped `TfApply=true` (⋮ → Add another value, NOT "Copy" — that makes `TfApply - Copy`
which deploy.ps1 never reads), redeploy `.1.219`, then DELETE the scoped row.** Watch for: OIDC provider + CloudFront
distribution create (slow, 3-5 min, not a hang) · 10 IAM roles · `Apply complete!` · `[SSM-VALIDATE] OK` ×3 ·
**`[STEP] Post-apply: Bootstrapping Flux` ← STILL never executed.**
Note: the two `gha-*-risingwave-*` roles get created on prod even though RW is excluded — harmless IAM clutter;
gating them would be a modules/irsa change touching dev+QA too. Leave for now.

═══ **(earlier) flip production `TF_VAR_enable_irsa` false→true, then PLAN-ONLY deploy** ═══
**DAY-2 (2026-07-28 pm) — ZERO-TOUCH WORK, nearly all closed.** Doke's requirement: no manual intervention, full
platform (ESO/Grafana/Velero/etcd-snapshot/ArgoCD/Istio/Rook). Audit = `ZERO-TOUCH-AUDIT.md`, gaps = `AUTOMATION-GAPS.md`.
- ✅ **33 Kustomizations AUTHORED** into `clusters/op-usxpress-prod/flux-system/infra.yaml` (was a COMMENT listing 21
  names — nothing to "uncomment"). NOT phased: all active, Flux dependsOn handles order, AWS components retry till IRSA
  is up. Validated 33 docs / no dupes / no dangling deps / no cycles. **PR #29 MERGED.**
- ✅ **All 32 infra paths verified to EXIST on op-prod** (no "path not found" traps).
- ✅ **cross-cluster-eso is RETIRED** (`qa-tier2-additions.yaml:6`) → QA-checklist Phase 7 (manual Octopus "Seed
  Cross-Cluster ESO Token" runbook) and Phase 8 (uncomment ExternalSecrets) DO NOT APPLY to prod. Both manual steps gone.
- ✅ **op-prod literals fixed + RW manifests removed + op-dev/ deleted. PR #84 MERGED.** (Had to also drop the deleted
  RW schedule from `velero/kustomization.yaml` — it broke the build.)
- ✅ **deploy.ps1 automation (`ac9eccc`, `496bb3c`):** (1) Flux bootstrap post-apply — `kubectl apply --server-side -k`
  on the committed gotk manifests (NOT `flux bootstrap`, which rewrites kustomization.yaml = the cascade cause);
  (2) SM wrapper ensure-and-export incl. `restore-secret`; (3) `[WHOAMI]` sts echo.
- ✅ **`[WHOAMI]` PROVED prod worker = `arn:aws:sts::937464026810:assumed-role/octopus-usxpress` on
  `octopusworker-1.prod.usxpress.io`** → prod IS self-contained; enable_irsa builds the OIDC stack in the PROD account.
  **NO cloud ask at all — delete CLOUD-IRSA-ASK.md.**
- ✅ Octopus vars: `irsa_oidc_bucket_name` = `op-usxpress-prod-irsa-oidc-v2`; worker_pools system RAM 8192→**12288**
  (QA-checklist 12 GB post-OOM floor). `fix-prod-vars.py`.
- ✅ **ArgoCD admin secret SEEDED** (`seed-argocd-admin.py`) — bcrypt `admin.password` + `admin.passwordMtime` JSON at
  `op-usxpress-prod/platform/argocd`. NOT a TF resource → `terraform destroy` never deletes it → ONE-TIME per cluster,
  survives rebuilds. ⚠️ Last rotation was shredded UNREAD — password unknown; re-rotate when ArgoCD is live.
- ✅ **ecr-credentials + octopus-worker: NOT in QA's infra.yaml either** → omitting from prod is PARITY, not a gap.
- ⚠️ **OPEN: `etcd_quota_backend_bytes` NOT IMPLEMENTABLE** — no such TF variable; `git grep etcd` under
  `modules/talos/` returns NOTHING. QA checklist wants ≥8 GB (default 2 GB). Needs a Talos machine-config patch in the
  module. dev+QA also run at the default → prod at 2 GB is parity. Follow-up, not a bring-up blocker.
- ⏳ **NEVER-EXECUTED code paths (expect discovery):** the Flux bootstrap block, the SM-seed block, Rook OSD formation.

═══ **(day-1) PLAN IS GREEN, NOT YET APPLIED** ═══
✅ **Prod plan-only deploy of `0.1.0-refactor-multi-env-parameterization.1.211` to `production` SUCCEEDED
2026-07-28: `Plan: 45 to add, 0 to change, 0 to destroy`.** 3 CP + 10 pool workers (system 2 + platform 3 +
application 5) = 13 VMs. Backend init OK against `lazy-tf-state-ipp58n854uhpw13x` / `iaac/talos/op-usxpress-prod.tfstate`
/ us-east-2. `flux_manifests_path = clusters/op-usxpress-prod`. Network → `dvportgroup-700707`. Terraform PGP
signature warning is benign (fell back to builtin key). **NOT applied — TfApply still false everywhere.**
STILL UNVERIFIED from that log: grep Raw Log for `aws_ssm_parameter` and `module.irsa.` — both must be 0 hits.

🎯 **DOKE'S NEW REQUIREMENT (2026-07-28): ZERO MANUAL INTERVENTION.** Full platform must come up automatically —
Flux reconciling, ESO, Grafana, Velero, etcd snapshots, external-DNS, Argo CD. That is the actual INFRA-1589 goal.
**See `AUTOMATION-GAPS.md` (G1–G7).** Only TWO need code: **G1** flux bootstrap (`terraform_data` + local-exec
`kubectl apply -k clusters/<cluster>/flux-system/` — NEVER re-add `flux_bootstrap_git`) and **G4** an
ensure-and-export loop in deploy.ps1 for the 3 SM secrets. Rest is config: G2 GH secret, G3 two Octopus vars,
G5 `fix-op-prod-literals.sh`, G6 uncomment infra.yaml phase-2 appendix.
⚠️ **G4 teardown trap:** `terraform destroy` schedules the SM secrets for deletion (7–30 day window); a rebuild
inside it fails `create-secret` with "scheduled for deletion" → the ensure step MUST `restore-secret` first.
⚠️ **CLOUD-IRSA-ASK.md OVERSTATES THE ASK — do not send as written.** `modules/irsa/main.tf` creates
`aws_s3_bucket.oidc` + CloudFront + `aws_iam_openid_connect_provider` itself, so ask items 1–3 are NOT a cloud
dependency. Only the bootstrap role may be, and `.github/workflows/onprem-account-bootstrap.yaml` already
references `secrets.ONPREM_BOOTSTRAP_ROLE_ARN_PROD`.

**FIRST TWO COMMANDS TOMORROW** (both were blocked by an expired SSO token):
```
aws sso login --profile ops-controller
aws secretsmanager list-secrets --profile ops-controller --region us-east-2 \
  --query "SecretList[?starts_with(Name,'op-usxpress-prod')].Name"
gh secret list --repo variant-inc/iaac-talos | grep -i onprem
```
If `ONPREM_BOOTSTRAP_ROLE_ARN_PROD` is populated → **G2 done, ZERO external asks remain, delete CLOUD-IRSA-ASK.md.**

**Open decision:** apply phase 1 now as a cheap checkpoint (bare cluster, proves 45 resources build on real vSphere)
vs hold until G1–G6 land and do one full run. My rec: apply now, then close gaps, then prove with destroy→rebuild.
**INFRA-1589 is DONE only when a destroy → rebuild completes untouched** — both 2026-07-28 blockers came from code
paths that only run on a from-scratch build, so expect more.

**(historical) deploy gate:** deploy.ps1:113 `if ($TfApply -eq "true")` gates apply — anything else = plan only.
Binding rule (runbook): leave TfApply OFF, flip true only to apply, flip back.
**`preflight-deploy.py` (2026-07-27, RUNBOOK §3.5) scripts the gate — read-only, re-runnable, exit≠0 on blocker.
RUN IT ON WSL (codespace has NO Octopus key; auth path verified, 401s on a dummy key).** Checks: P1 TfApply not
already true for prod, P2 lifecycle reaches `production` + no REQUIRED earlier phase blocking promotion, P3 no
step env-scoped to exclude prod (skipped step = SUCCESS = the INFRA-1623 shape), P4 29 vars present/no TBD/
enable_irsa=false/only the 4 secret ARNs blank, P5 no dev-qa literal in a prod value (B5 applied to Octopus).
⚠️ **TfApply is UNSCOPED (all envs)** — flipping it true to apply prod ARMS dev+qa for that window. Safer: add a
`production`-scoped TfApply=true (most specific scope wins), apply, DELETE it; global stays false throughout.
Re-deploys read vars fresh at deploy time (not snapshotted at release creation) → flip-then-redeploy works, no new release.
✅ **DATASTORE GATE CLEARED 2026-07-28** — Doke confirmed `USXD1NTXPROD-SC1` has well over the ~5 TB prod needs on
top of QA's usage (vSphere UI; govc not installed). **ALL PRE-DEPLOY GATES NOW PASS — cleared to deploy .208.**
THEN: create release off op-prod → deploy to production with TfApply NOT true → read plan (all creates, **0 destroys —
any destroy = STOP**) → arm TfApply → redeploy → cluster up → disarm. Phase-1 needs NO secrets, NO IRSA bootstrap.

**⛔ PHASE-1 BLOCKER FOUND 2026-07-28 (`PHASE1-SSM-VALIDATE-BLOCKER.md`):** deploy.ps1's post-apply block
asserts 3 SSM params exist and `exit 1`s if any is missing. ALL FOUR `aws_ssm_parameter` in main.tf are
`count = var.enable_irsa ? 1 : 0` (lines 263 endpoint / 278 cert-authority / 293 oidc_issuer / 356 token).
Phase 1 = enable_irsa=false → none created → fails on the FIRST (`endpoint`). **TF applies, cluster builds
FINE, Octopus marks deploy FAILED.** Inverse of INFRA-1623: red deploy that did everything. INVISIBLE in the
plan-only run (block is inside `TfApply=="true"`) → bites mid-provision on a fresh cluster. Never hit because
dev.tfvars+qa.tfvars both set enable_irsa=true.
✅ **FIXED + PUSHED 2026-07-28 = `c9a6ae2`** on refactor/multi-env-parameterization — block wrapped in
`if ($env:TF_VAR_enable_irsa -eq "true")` + else-branch log. 7 insertions, deliberately NOT re-indented so the
diff stays reviewable. No `pwsh` on WSL so no parse check ran; braces verified by eye in the diff.

**⛔ PHASE-1 GAP #2 FOUND 2026-07-28 — NOTHING BOOTSTRAPS FLUX ON GREENFIELD (`PHASE1-FLUX-BOOTSTRAP-GAP.md`).**
`modules/flux/main.tf` (BOTH master and the refactor branch) = `terraform_data.wait_for_cluster` (TCP wait loop)
+ `removed{flux_bootstrap_git.this}` + `removed{terraform_data.restore_infra_refs}`. **That's the whole module.**
It still declares the flux provider and still takes target_path/github_* (main.tf:198-210) and USES NONE OF THEM.
PR #27 `2f2ad95` (Option B) deleted `flux_bootstrap_git` to stop a drift cascade that broke dev 3× in 24h — correct
for clusters that ALREADY have Flux (dev+QA); `removed` is a NO-OP on greenfield. **→ prod applies GREEN and comes up
a bare Talos cluster: no flux-system, no GitRepository, no Kustomizations, no platform stack.** FAILS SILENTLY (worse
than the SSM blocker, which exit 1s). #27's own message names the trade-off: *"future Flux upgrades become manual"*.
**FIX = NOT a count-gated flux_bootstrap_git** (can't coexist with the `removed` block for the same address; would
reintroduce the cascade for prod). **Instead `kubectl apply -k clusters/op-usxpress-prod/flux-system/`** — manifests
already committed via PR #28; git stays source of truth, nothing in TF state, and it avoids `flux bootstrap` rewriting
kustomization.yaml (the original cascade cause). Now RUNBOOK step 7.

**⚠️ MASTER IS STALE — prod must deploy from `refactor/multi-env-parameterization` (dare-x = Doke's own branch,
119 commits / +2089 lines in deploy/terraform NOT on master; master is at PR #27, branch has #52/#53/#54/#57).**
Confirm which ref Octopus builds releases from (Octopus → iaac-talos → Releases, last QA deploy) — STILL OPEN.
Phase-1 seeds-nothing model RE-VERIFIED on that branch: `seed_secret_values = enable_irsa && manage_platform_secret_values`,
grafana resources carry a 2nd guard (`&& arn != ""`), talosconfig import `for_each = enable_irsa ? {...} : {}`. Holds.

**RELEASE↔BRANCH MODEL SOLVED 2026-07-28 (`octopus-releases.py`, pasted heredoc — beats the download loop):**
project is NOT git-backed; **the PACKAGE VERSION ENCODES THE BRANCH** — e.g. `0.1.0-refactor-multi-env-parameterization.1.207`.
Latest QA deploy = `...refactor-multi-env-parameterization.1.207` → **QA ALREADY DEPLOYS FROM THAT BRANCH; master is
irrelevant to this pipeline.** Prod cuts from the same branch.
✅ **`0.1.0-refactor-multi-env-parameterization.1.208` BUILT 2026-07-28 00:47, contains c9a6ae2 (SSM fix) + #57. Never
deployed. THIS IS PROD'S RELEASE.** CI = GHA "Validate & Push to Octopus" (auto-creates the Octopus release; does NOT
auto-deploy). First run failed on a **transient Octopus 503** in the Octo Deploy step — NOT a code problem;
`gh run rerun <id> --failed` fixed it. Note Octopus API flakiness before leaning on it mid-deploy.

**Octopus lifecycle = `iaac-release` (Lifecycles-42): phase1 development, phase2 qa, phase3 staging, phase4 production.**
✅ **RESOLVED 2026-07-28 THE WAY DEV WAS — add the env to the FEATURE channel's lifecycle. No master merge needed.**
`docs/runbooks/op-usxpress-dev-build-runbook.md` **Issue 1** records the identical problem for dev: feature-channel
lifecycle only had `dpl`; fix was `PUT /api/Spaces-2/lifecycles/Lifecycles-1502` adding `development`. QA same way.
**I reasoned forward from the release channel instead of reading the dev runbook and burned an hour on a master merge
+ ggshield/bento detour. CHECK THE DEV RUNBOOK FIRST for any prod stand-up question.**
Steps actually taken: (1) appended `production` (Environments-41) phase to Lifecycles-1502 — optional+manual;
(2) production still greyed because `qa` was the lone REQUIRED phase and now sat BEFORE it; (3) flipping qa→optional
alone **fails 400: "Lifecycle must have at least one phase that is not optional"**; (4) **SWAP** — qa→optional AND
production→REQUIRED in ONE PUT. Production is the LAST phase so REQUIRED gates nothing (the role qa played before).
Backups: `/tmp/octopus-lifecycle-1502-*.json`. Final: development[opt] → dpl[opt] → qa[opt] → production[REQUIRED].
**Deploy target = release `0.1.0-refactor-multi-env-parameterization.1.211`** (feature channel; supersedes .208, still
contains the SSM fix c9a6ae2). PR #58 (branch→master) DID merge — harmless, good hygiene, but was NOT needed. The
bento/GitGuardian work sits unmerged on the branch and is off the critical path (Doke: not rotating that password).

🔑 **(superseded, kept for context) THE CHANNEL vs PROJECT LIFECYCLE (via `octopus-channels.py`).**
iaac-talos has TWO channels:
- **`feature` (Channels-9403)** → lifecycle **`iaac-feature-manual` (Lifecycles-1502)**: development / dpl / qa.
  **NO production, NO staging.** ← **CI puts EVERY branch build here**, incl. .208. This is why production was
  absent from the deploy dropdown (staging's absence was the tell — an optional phase that should've shown).
- **`release` (Channels-9404, DEFAULT)** → lifecycle **`iaac-release` (Lifecycles-42)**: development [REQUIRED] /
  qa [opt] / staging [opt] / production [REQUIRED]. ← the only path to prod.

**FIX — ❗ Doke's correction 2026-07-28: releases are NEVER created by hand here; CI auto-generates them on push.**
**CHANNEL ROUTING CONFIRMED from `variant-inc/actions-octopus@archive/master/v1` `release.ps1`:**
```
if (GitVersion_BranchName -eq DEFAULT_BRANCH) { channel = "release" }
elseif (GitVersion_BranchName -match FEATURE_CHANNEL_BRANCHES) { channel = "feature" }
else { exit 0 }
```
action.yml defaults: `default_branch: master`, `feature_channel_branches: .*`. **Master is checked FIRST**, so a push
to master → `release` channel despite the catch-all feature regex. Channels have NO Octopus-side version rules
(`Rules: []` on both) — the action alone decides. octo.yaml passes neither input → defaults apply.
→ **THE ROUTE TO PROD IS MERGING `refactor/multi-env-parameterization` → `master`** (~119 commits / +2089 lines in
deploy/terraform). That is now the critical path. **PR OPENED 2026-07-28 = variant-inc/iaac-talos#58 — awaiting merge.** (My "manually create release 0.1.2" advice was wrong for this pipeline.)
❌ **DON'T** narrow `feature_channel_branches` in octo.yaml to shortcut the merge: it would route `feature/op-usxpress-dev`
into the `release` channel too, whose phase-1 development is AUTO → every dev-branch push would auto-deploy to dev.
⚠️ **`octopus release create --ignore-existing` + `package upload --overwrite-mode=overwrite`:** if the master build
computes a version that ALREADY exists as a release (e.g. `0.1.1`, which exists pointing at feature package .202),
release creation is silently SKIPPED. After merging, VERIFY the new release's version + channel + that its package came
from the merge commit — a stale reused release is the "deploys clean, wrong content" shape.
✅ **Lifecycles-42 targets confirmed: phase1 development = AUTO; qa / staging / production = MANUAL.** So creating the
release AUTO-DEPLOYS to development (plan-only while TfApply=false) and that **satisfies required phase 1 for free** —
production then becomes manually selectable with no extra step. Master is effectively DORMANT in this pipeline today
(every recent dev+QA deploy came from `feature`-channel packages), so the merge is the intended end state, not a detour.
Then phase 1 development IS genuinely required on Lifecycles-42 → deploy to **development** first
(TfApply=false = plan vs DEV state, changes nothing) → production then appears → plan-only → arm → apply → disarm.
❌ NEVER add production to the `feature` channel lifecycle (would let any branch build reach prod). Never pick `dpl`.
Preflight **P2b** now enumerates channels + their effective lifecycles and BLOCKS if the newest release is in a
channel that can't reach prod. My earlier P2 flip-flop (demote→restore) came from reading only the PROJECT lifecycle.

**deploy.ps1 uses `$env:TF_VAR_*` ONLY — no `-var-file`/tfvars.** Octopus vars ARE the config; `envs/*.tfvars` are for
local/manual runs. So NO `envs/prod.tfvars` needed; our prod.tfvars stays a reference doc. Also `$env:TF_VAR_irsa_role_arn`
is read by deploy.ps1 but is in NO env's var set (qa.tfvars:85 = ""), so SSM reads run as the Octopus worker identity —
confirm the worker can read SSM in 937464026810 before phase 2 or the same exit 1 returns.

**ECR IS CENTRAL — do NOT rewrite.** `ecr-credentials/cronjob.yaml:40,150` hardcode `AWS_ACCOUNT="064859874041"`, a
FOURTH account (not dev/qa/prod). Registry stays; only `rbac.yaml:7` role-arn becomes prod's. Not in the literal list, so
the fixer never touches it.

✅ **IRSA ACCOUNT MODEL PROVEN 2026-07-29 — EACH ENV OWNS ITS IRSA STACK IN ITS OWN ACCOUNT.** Verified by direct AWS
calls: bucket `op-usxpress-qa-irsa-oidc-v2` exists in **527101283767** (403 from usx-dev); role `op-usxpress-qa-velero`
= `arn:aws:iam::527101283767:...` (NoSuchEntity in dev). Each account has its OWN CloudFront OIDC provider — dev
`d3a7wcnazdrd6p`, qa `d2t7d36wmf0hbm`. **ops-controller (prod) has NO CloudFront OIDC provider yet** (only EKS
BF7BD089) → `modules/irsa` creates prod's from scratch. **So `700736442855` in `velero/serviceaccount.yaml:9` is a
STALE DEV COMMENT, not the live model — PR #84's rewrite to 937464026810 is CORRECT.** NO cloud ask for the OIDC stack.
⚠️ **STILL UNPROVEN: which AWS identity the Octopus worker uses.** `providers.tf` adds `assume_role` ONLY when
`var.irsa_role_arn != ""`, and `TF_VAR_irsa_role_arn` is defined ONLY for `development` (empty) — qa and production
don't define it at all. So the AWS provider uses the **worker's AMBIENT credentials**, and whatever account that
resolves to is where IRSA lands. The prod plan ran on **`octopusworker-1.prod.usxpress.io`** (NOT the
`octopusworker-2.dev` in the dev runbook) and reached the prod state bucket → per-env workers with per-env identities
is the likely explanation. **`[WHOAMI]` sts echo added to deploy.ps1 (`496bb3c`): re-run a PLAN-ONLY prod deploy and
read the account. 937464026810 → safe to flip enable_irsa=true. 700736442855 → prod needs its own
TF_VAR_irsa_role_arn FIRST.** Also: production's `TF_VAR_irsa_oidc_bucket_name` is EMPTY → set
`op-usxpress-prod-irsa-oidc-v2` before enabling IRSA.

**⚠️ (superseded) CLOUD IRSA ASK MAY BE MUCH SMALLER THAN ASSUMED.** `modules/irsa/main.tf` CREATES its own
`aws_s3_bucket.oidc` + CloudFront + `aws_iam_openid_connect_provider`; the bucket is NOT a pre-existing input. So the real
external dep may be only "can the Octopus worker authenticate into 937464026810", not a cloud-built OIDC provider.
**SEND cloud IRSA ask** ([CLOUD-IRSA-ASK.md]) — phase-2 long pole, parallel; not yet confirmed sent.

**Sizing = MIRRORED from QA** (3 CPs 4c/16G; pools system 2, platform 3, application 5). "QA mirrors prod" by design so this is the intended shape — but CONFIRM, may go up not down. See [[qa-cluster-standup]], [[qa-vs-dev-delta]].

**Sequencing insight:** do E3's conversion AS the E2 fix — replace each `op-usxpress-dev` literal with `${cluster_name}` (not the hardcoded QA value). One pass → drift-PROOF instead of drift-corrected. Prod then inherits a parameterised branch, not a fresh copy of literals to chase. This is the E3=highest-value-item point from [[eks-k8s-upgrade]]'s sibling PROD-AUTOMATION.md.

**IRSA landmine:** never commit `enable_irsa=false` once IRSA resources exist in state — false flips them to DESTROY. Greenfield prod starts false (nothing exists yet), flip true phase 2, then NEVER back.

**Octopus prod environment is MISSING (verified 2026-07-24):** `add-prod-vars.py` authenticated to Octopus (`iaac-talos` = `Projects-8283`, Spaces-2) but aborted — no `prod` environment exists. Added `--list-envs` (read-only lister) + `--env-name` override to confirm it's not just differently-named before creating. If truly absent, an Octopus admin creates a `prod` env + adds it to the `iaac-talos` lifecycle. This is a FIFTH blocker but the only one we own directly (Octopus config, not another team's data). QA used lifecycle `Lifecycles-42` (iaac-release) for the RW project; the iaac-talos project is `Projects-8283`.

**First Octopus run: keep `TfApply=FALSE`** to get a real plan gate on prod even though QA applies ungated. Read plan, then flip. Related: [[onprem-deploy-via-octopus]], [[pr73-argocd-repo-sync-review]] (ArgoCD platform stack ships to prod via QA manifests, only diff = keep `global.nodeSelector: {pool: platform}`).
