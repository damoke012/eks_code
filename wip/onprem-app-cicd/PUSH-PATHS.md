# Push paths — exact commands, in order

Run these **on WSL**, where the corp GHE remotes live. Nothing here runs from the codespace: the
`damoke012` codespace token must never reach `variant-inc` repos.

Set the source once:

```bash
SRC=/home/doke/work/eks_code/wip/onprem-app-cicd
ls "$SRC"          # sanity: IMPLEMENTATION.md, ONBOARDING.md, platform/, app-template/, terraform/
```

⚠️ **Your WSL `eks_code` is ~20 commits behind and its pull is blocked** by uncommitted changes in
`wip/onprem-qa-access/aws-sso-webhook/`. Resolve that first, or `git archive` just this directory
out of `origin/main` without touching your working tree:

```bash
cd /home/doke/work/eks_code
git fetch origin
mkdir -p ~/onprem-app-cicd && git archive origin/main wip/onprem-app-cicd \
  | tar -x --strip-components=2 -C ~/onprem-app-cicd
SRC=~/onprem-app-cicd
```

**Before every platform PR**, on the branch you are about to merge into:

```bash
bash scripts/check-foreign-cluster-ids.sh ~/iaac-talos-flux-platform op-qa --diff origin/op-qa
```

It scans the changed files for another cluster's account ID, OIDC issuer, API node or DNS
suffix, and exits non-zero on a hit. Six defects of that class by 2026-08-20, every one of
them silent — the Kustomization reports Ready and the workload cannot authenticate or route.

The platform repo carries **one branch per cluster** (`op-dev`, `op-qa`, `op-prod`). Files land on
the branch for the cluster they're for. That's why the same directory is pushed more than once.

---

## PR 1 — ECR repository + push role

**Repo:** the one that manages account `064859874041` (infra-common / devops).
**⚠️ Not `iaac-talos`** — that manages `700736442855`. Confirm the repo before raising this.

```
terraform/ecr-app-repos.tf   →   <that repo>/<module path>/ecr-app-repos.tf
```

Verify after apply:

```bash
aws ecr describe-repositories --repository-names risingwave/etl-pipeline \
  --region us-east-2 --profile <devops profile> \
  --query 'repositories[0].[repositoryUri,imageTagMutability]' --output text
```

Want `…/risingwave/etl-pipeline  IMMUTABLE`.

## PR 2 — app namespaces (three branches)

```
platform/app-namespaces/   →   iaac-talos-flux-platform:<branch>/infrastructure/app-namespaces/
```

```bash
for BR in op-dev op-qa op-prod; do
  git -C ~/iaac-talos-flux-platform checkout "$BR" && git pull
  mkdir -p ~/iaac-talos-flux-platform/infrastructure/app-namespaces
  cp "$SRC"/platform/app-namespaces/* ~/iaac-talos-flux-platform/infrastructure/app-namespaces/
  # commit + push + PR against "$BR"
done
```

## PR 3 — the app repo

```
app-template/build/                    →  risingwave-pipeline/build/
app-template/deploy/                   →  risingwave-pipeline/deploy/
app-template/.github/workflows/…yml    →  risingwave-pipeline/.github/workflows/build-and-push.yml
```

Do **not** merge this before PR 1 — the workflow assumes the role and the repository exist.

## PR 4 — wire the Kustomizations

```
platform/cluster-wiring-block.yaml  →  append into iaac-talos-flux-cluster (master)
                                       clusters/bm-dev/flux-system/infra.yaml
                                       clusters/op-usxpress-qa/flux-system/infra.yaml
                                       clusters/op-usxpress-prod/flux-system/infra.yaml
```

Append the whole block; it defines both `app-namespaces` and `argocd-apps`.

Verify per cluster:

```bash
kubectl get kustomization -n flux-system app-namespaces argocd-apps
kubectl get ns app-risingwave -o jsonpath='{.metadata.labels}' ; echo
```

## PR 5 — the QA ApplicationSet

⚠️ An ApplicationSet alone does not produce a working deploy. Argo CD holds no Git
credential on either cluster, so an Application pointing at an internal repository fails
with `ComparisonError: authentication required`. **PR 8 is a prerequisite for this one
being useful**, not a follow-up.


```
platform/argocd-apps/applicationset-qa.yaml  →  iaac-talos-flux-platform:op-qa/infrastructure/argocd-apps/
platform/argocd-apps/kustomization.yaml      →  same directory
```

One ApplicationSet per cluster generates an Application per app. Onboarding an app later is four
lines in `elements` — no new file. **Do not put the prod ApplicationSet on this branch.**

## PR 6 — Kyverno policies (any time)

```
platform/kyverno-policies/*.yaml  →  iaac-talos-flux-platform:<branch>/infrastructure/kyverno-policies/
```

Add both filenames to that directory's existing `kustomization.yaml`. They ship in `Audit`, so they
report without blocking. After the first app deploys:

```bash
kubectl get policyreport -n app-risingwave
```

Clean report → flip `validationFailureAction: Audit` to `Enforce` in a follow-up PR.

## PR 7 — the prod Application (after QA is proven)

```
platform/argocd-apps/applicationset-prod.yaml  →  iaac-talos-flux-platform:op-prod/infrastructure/argocd-apps/
```

plus a `kustomization.yaml` on that branch listing `applicationset-prod.yaml` only. It has no
`automated:` block — prod syncs when a human presses Sync.

---

## Before PR 2 — checked, nothing to do

`ecr-credentials-sync` enumerates namespaces dynamically (excluding `kube-system`, `kube-public`,
`kube-node-lease`, `flux-system`) and also patches every ServiceAccount with `imagePullSecrets`.
`app-risingwave` is covered within 5 minutes of creation. Verified on op-dev 2026-08-18.

After PR 2 lands, confirm it actually happened before wondering why a pull fails:

```bash
kubectl -n app-risingwave get secret ecr-pull-secret
kubectl -n app-risingwave get sa default -o jsonpath='{.imagePullSecrets}' ; echo
```

## Order summary

```
1 ECR + role                 (blocks 3)
2 namespaces × 3 branches    (blocks 4, 5)
4 Flux wiring × 3 clusters
3 app repo                   (blocks 5)
5 QA Application             → first real deploy
6 Kyverno (any time)
7 prod Application           (after QA is proven twice)
```

Sync QA **twice** before raising PR 7. First run applies, second must report `0 applied, N
unchanged`. If it re-applies, stop — Argo CD re-syncs on its own and a pipeline that re-runs DDL
will eventually recreate a streaming job and re-read the topic from `earliest`.

---

## PR 8 — the Argo CD Git credential (INFRA-1647) — required before ANY deploy works

Full procedure, including the Secrets Manager merge and the verification that is not
`SecretSynced`: [`ARGOCD-GIT-CREDENTIAL.md`](ARGOCD-GIT-CREDENTIAL.md). Or run
[`wizard-argocd-git-credential-qa.sh`](wizard-argocd-git-credential-qa.sh), which does the
whole of it including these checks — on WSL, not from this repo.

```
platform/argocd-config/op-qa/repo-creds-externalsecret.yaml
  → iaac-talos-flux-platform:op-qa/infrastructure/argocd-config/
platform/argocd-config/op-prod/repo-creds-externalsecret.yaml
  → iaac-talos-flux-platform:op-prod/infrastructure/argocd-config/
```

Plus one line — `  - repo-creds-externalsecret.yaml` — in each branch's existing
`infrastructure/argocd-config/kustomization.yaml`. **Do not copy this pack's
`kustomization.yaml`, `appprojects.yaml` or `admin-externalsecret.yaml` over the branch's
own files.** They are here so the directory builds standalone for validation; only the
ExternalSecret is new.

Ship the GitHub App variant or `…-pat.yaml`, never both — they own the same Secret name.

Verify (QA):

```bash
export KUBECONFIG=$HOME/.kube/op-usxpress-qa-sso.yaml   # QA · SSO
kubectl --context op-usxpress-qa -n argocd get secret argocd-repo-creds-variant-inc \
  -o jsonpath='{.metadata.labels}{"\n"}'
kubectl --context op-usxpress-qa -n argocd get application risingwave-etl \
  -o jsonpath='{.status.sync.status}{"  "}{.status.health.status}{"\n"}'
```

Want the `argocd.argoproj.io/secret-type: repo-creds` label present, and `Synced Healthy`.
