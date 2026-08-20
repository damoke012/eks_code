# `infrastructure/argocd-config/` — the Argo CD Git credential (INFRA-1647)

Procedure, Secrets Manager payload and verification:
[`../../ARGOCD-GIT-CREDENTIAL.md`](../../ARGOCD-GIT-CREDENTIAL.md).

## What is actually new

**One file per branch.** Everything else in these directories is a copy of what already
lives on the branch, present only so `kubectl kustomize` can build the directory standalone.

| File | Push it? |
|---|---|
| `repo-creds-externalsecret.yaml` | **yes** — GitHub App variant |
| `repo-creds-externalsecret-pat.yaml` | only instead of the above, never as well |
| `kustomization.yaml` | no — add its one new `resources:` line to the branch's own file |
| `appprojects.yaml` | no — reference copy |
| `admin-externalsecret.yaml` | no — reference copy |

`op-qa/` and `op-prod/` are separate directories on purpose. The per-environment branches
of `iaac-talos-flux-platform` are copies of one another, and four defects on 2026-08-18 came
from a cluster-specific value that was never changed. The only difference between these two
is the Secrets Manager path — `op-usxpress-qa/platform/argocd` vs
`op-usxpress-prod/platform/argocd` — and it is the whole reason both exist.

## Why one secret and not one per repo

Argo CD matches `repo-creds` to an Application by longest URL prefix, so
`https://github.com/variant-inc` covers every repository in the org. Onboarding the next
application then needs no credential work at all. Access is still bounded by the `apps`
AppProject, which allows exactly that prefix and restricts destinations to `app-*`.

## Validate before pushing

```bash
kubectl kustomize wip/onprem-app-cicd/platform/argocd-config/op-qa   | grep -c '^kind:'   # 4
kubectl kustomize wip/onprem-app-cicd/platform/argocd-config/op-prod | grep -c '^kind:'   # 4
```
