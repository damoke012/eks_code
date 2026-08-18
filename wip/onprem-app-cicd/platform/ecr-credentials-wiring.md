# Wiring `ecr-credentials` onto op-usxpress-qa and op-usxpress-prod

Discovered 2026-08-18 while landing PR D. `app-namespaces` failed on QA with:

```
dependency 'flux-system/ecr-credentials' not found
```

**Net result: no AWS change is required.** The IAM roles already exist in every
account and the ECR registry is already open to the whole org. The entire fix is
two manifest edits and one Kustomization — no Terraform, no Octopus deploy.

## What is missing

`ecr-credentials` is wired on `bm-dev` and `dpl2` only. QA's `infra.yaml` excludes it
in a **stale** comment dated 2026-07-08:

```
Excludes ... Tier 3 components (rook, velero, etcd-backup, octopus-worker, ecr-credentials).
```

Every other item on that list — `rook-ceph-operator`, `rook-ceph-cluster`, `velero`,
`etcd-backup` — is live on QA today. `ecr-credentials` is the one left behind: an
oversight in the Tier 3 catch-up, not a standing decision.

Prod is worse. Its header **documents ECR as central** and cites
`ecr-credentials/cronjob.yaml` under a banner reading "NOT PHASED — every
Kustomization is active". The Kustomization is absent. No app image can be pulled on
prod today; it is masked only because no app runs there yet.

## The trap

`infrastructure/ecr-credentials/` is byte-identical across the op-dev, op-qa and
op-prod branches — same blob hashes on `cronjob.yaml`, `namespace.yaml`, `rbac.yaml`.
All three annotate the **dev** role:

```yaml
eks.amazonaws.com/role-arn: arn:aws:iam::700736442855:role/op-usxpress-dev-ecr-credentials-sync
```

It was authored for dev and copied. Only op-dev consumed the directory, so nothing
surfaced. Adding the Kustomization without fixing this yields a green Flux
Kustomization, a running CronJob and no pull secret: AssumeRoleWithWebIdentity fails
against an issuer dev's role does not trust. `Ready=True` proves the CronJob was
applied, not that it succeeded — the same false green as ESO `SecretSynced`.

## Ground truth — verified 2026-08-18

Account map:

| Profile | Account | Role present |
|---|---|---|
| `infra-common` | 064859874041 | ECR registry |
| `usx-dev` | 700736442855 | `op-usxpress-dev-ecr-credentials-sync` |
| `usx-qa` / `op-qa` | 527101283767 | `op-usxpress-qa-ecr-credentials-sync` |
| `usx-prod` / `ops-controller` | 937464026810 | `op-usxpress-prod-ecr-credentials-sync` |

Each cluster's roles live in **its own account**, matching prod's stated design
("SELF-CONTAINED BY DESIGN ... own OIDC provider ... no dependency on dev/QA
accounts"). The per-cluster roles were created with the clusters; only the manifest
was never differentiated.

Talos OIDC issuers (the `oidc.eks.us-east-2.*` providers are the EKS clusters, not
these):

```
dev   d3a7wcnazdrd6p.cloudfront.net
qa    d2t7d36wmf0hbm.cloudfront.net
prod  d3rxit8f4yvshu.cloudfront.net
```

ECR repository policy (`lazy/api`, representative):

```json
"Principal": { "AWS": "*" },
"Action": [ "...GetDownloadUrlForLayer", "BatchGetImage", "PutImage", ... ],
"Condition": { "StringEquals": { "aws:PrincipalOrgID": "o-yza5l1xhrc" } }
```

Any principal in org `o-yza5l1xhrc` may pull. Nothing to add.

## Status

**QA COMPLETE 2026-08-18.** iaac-talos-flux-platform#94 (rbac ARN) and
iaac-talos-flux-cluster#34 (Kustomization) merged. `ecr-credentials` Ready,
`ecr-pull-secret` distributed to 20 namespaces, `app-namespaces` Ready,
`app-risingwave` created with ambient/PSA-restricted/quota, `argocd-apps` Ready,
ApplicationSet `onprem-apps` generating `risingwave-etl`.

One wrinkle worth knowing on any rebuild: the standalone `ecr-credentials-sync-init`
Job races the ServiceAccount annotation. It failed with `InvalidIdentityToken`
(QA-issued token presented against dev's role ARN, whose account has no matching OIDC
provider), exhausted `backoffLimit: 3`, and — because Jobs are immutable — pinned the
Kustomization at Failed permanently. The scheduled 5-minute runs succeeded throughout.
Fix is to delete the Job and reconcile; Flux recreates it against the settled
annotation. Worth adding an init-container wait or dropping the init Job entirely.

**PROD COMPLETE 2026-08-18.** iaac-talos-flux-platform#95 and
iaac-talos-flux-cluster#35 merged. `ecr-credentials` Ready, init Job and scheduled Job
both Complete, pull secret distributed to 18 namespaces, `app-namespaces` Ready,
`app-risingwave` created. `argocd-apps` is deliberately absent on prod — only QA has an
ApplicationSet; prod app delivery needs its own when the app side is ready.

Verified via break-glass: prod has NO SSO path (`aws-iam-authenticator` is wired only on
op-usxpress-qa), so access was `op-usxpress-prod/talosconfig` from Secrets Manager
937464026810 → `talosctl -n 10.10.82.52 kubeconfig`. Prod's Flux Git token was healthy,
unlike QA's. Getting dev and prod onto the SSO path is separate outstanding work.

⚠️ A trailing-newline trap: `clusters/op-usxpress-prod/flux-system/infra.yaml` had no
final newline, so an appended `---` landed inside the preceding comment and silently
merged two documents. Caught pre-merge by `awk '/^---$/{c++}'` vs `grep -c '^kind:'`
vs `kubectl apply --dry-run=client -o name | wc -l` — all three must agree.

## The fix

**1. Platform repo — per branch, NOT a merge.** `iaac-talos-flux-platform`,
`infrastructure/ecr-credentials/rbac.yaml`:

branch `op-qa`:
```yaml
    eks.amazonaws.com/role-arn: arn:aws:iam::527101283767:role/op-usxpress-qa-ecr-credentials-sync
```

branch `op-prod`:
```yaml
    eks.amazonaws.com/role-arn: arn:aws:iam::937464026810:role/op-usxpress-prod-ecr-credentials-sync
```

**2. Cluster repo — `iaac-talos-flux-cluster`, branch `master`.** Add to
`clusters/op-usxpress-qa/flux-system/infra.yaml`, copied verbatim from
`clusters/bm-dev/flux-system/infra.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ecr-credentials
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/ecr-credentials
  prune: true
  wait: true
  timeout: 5m
```

Correct the stale Tier 3 comment (~line 162) in the same edit.

Prod gets the same block, but only once prod's `app-namespaces` is being wired —
prod's Flux Git token should be checked first (it is the same vintage as the QA
token that expired silently on 2026-08-16).

## Acceptance — do not stop at Ready=True

```bash
kubectl -n flux-system get kustomization ecr-credentials app-namespaces
kubectl -n ecr-credentials get cronjob
# the only evidence that counts:
kubectl -n ecr-credentials get jobs --sort-by=.metadata.creationTimestamp | tail -3
kubectl -n ecr-credentials logs job/<latest> | tail -20
kubectl -n app-risingwave get secret ecr-pull-secret
kubectl -n app-risingwave get sa default -o jsonpath='{.imagePullSecrets}{"\n"}'
```

A failed AssumeRoleWithWebIdentity appears in the job log and nowhere else.

## Findings to carry forward

* **The ECR repository policy grants `PutImage` to the entire org**, not just pull.
  Any principal in `o-yza5l1xhrc` can push to any repository. That materially weakens
  the one-app-one-repo-one-branch push roles in `ecr-app-repos.tf`: those roles
  constrain what the *pipeline* may do, but nothing constrains anyone else. Worth
  raising before prod app delivery — with IMMUTABLE tags an existing tag cannot be
  overwritten, but a new tag can be introduced by anyone in the org.
* The CronJob runs `public.ecr.aws/aws-cli/aws-cli:latest` — unpinned, holding
  cluster-wide secret-write. Pin by digest before prod.
* It patches **every** ServiceAccount in **every** namespace. Broad, but it is the
  mechanism that made `app-risingwave` work on dev with no bespoke config.
