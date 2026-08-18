# Push paths — exact commands, in order

Run these **on WSL**, where the corp GHE remotes live. Nothing here runs from the codespace: the
`damoke012` codespace token must never reach `variant-inc` repos.

Set the source once:

```bash
SRC=/home/doke/work/eks_code/wip/onprem-app-cicd
ls "$SRC"          # sanity: IMPLEMENTATION.md, platform/, app-template/, terraform/, argocd/
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

The platform repo carries **one branch per cluster** (`op-dev`, `op-qa`, `op-prod`). Files land on
the branch for the cluster they're for. That's why the same directory is pushed more than once.

---

## PR 1 — ECR repository + push role

**Repo:** the one that manages account `064859874041` (infra-common / devops).
**⚠️ Not `iaac-talos`** — that manages `700736442855`. Confirm the repo before raising this.

```
terraform/ecr-and-push-role.tf   →   <that repo>/<module path>/ecr-risingwave-etl.tf
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
                                       clusters/<qa>/flux-system/infra.yaml
                                       clusters/<prod>/flux-system/infra.yaml
```

Append the whole block; it defines both `app-namespaces` and `argocd-apps`.

Verify per cluster:

```bash
kubectl get kustomization -n flux-system app-namespaces argocd-apps
kubectl get ns app-risingwave -o jsonpath='{.metadata.labels}' ; echo
```

## PR 5 — the QA Application

```
platform/argocd-apps/   →   iaac-talos-flux-platform:op-qa/infrastructure/argocd-apps/
```

The directory already contains `application-qa.yaml` and a `kustomization.yaml` listing only it.
**Do not add the prod Application on this branch.**

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
argocd/application-prod.yaml  →  iaac-talos-flux-platform:op-prod/infrastructure/argocd-apps/
```

plus a `kustomization.yaml` on that branch listing `application-prod.yaml` only.

---

## Before PR 2 — one thing to check

Does `ecr-credentials-sync` populate a namespace it has never seen? If it works from a static list,
`app-risingwave` must be added to it or the Job cannot pull, and the failure looks like a bad image
reference rather than a missing credential.

```bash
export KUBECONFIG=$HOME/.kube/op-usxpress-dev-fresh.yaml
kubectl -n ecr-credentials get cronjob ecr-credentials-sync -o yaml \
  | sed -n '/containers:/,/volumeMounts\|restartPolicy/p'
```

If it enumerates all namespaces, nothing to do. If it reads a list, that list is another line in PR 2.

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
