# Wiring `ecr-credentials` onto op-usxpress-qa and op-usxpress-prod

Discovered 2026-08-18 while landing PR D. `app-namespaces` failed with:

```
dependency 'flux-system/ecr-credentials' not found:
kustomizations.kustomize.toolkit.fluxcd.io "ecr-credentials" not found
```

## What is actually missing

`ecr-credentials` is wired on `bm-dev` and `dpl2` only. QA's `infra.yaml` excludes it
in a **stale** comment dated 2026-07-08:

```
Excludes ... Tier 3 components (rook, velero, etcd-backup, octopus-worker, ecr-credentials).
```

Every other item on that list — `rook-ceph-operator`, `rook-ceph-cluster`, `velero`,
`etcd-backup` — is live on QA today. `ecr-credentials` is the one that was left
behind. This is an oversight in the Tier 3 catch-up, not a standing decision.

Prod is worse: its header **documents ECR as central** and cites
`ecr-credentials/cronjob.yaml`, under a banner reading "NOT PHASED — every
Kustomization is active". The Kustomization is absent. No app image can be pulled on
prod today; it is masked only because no app runs there yet.

## The trap

`infrastructure/ecr-credentials/` is byte-identical across the op-dev, op-qa and
op-prod branches — same blob hashes on `cronjob.yaml`, `namespace.yaml`, `rbac.yaml`.
All three annotate the ServiceAccount with the **dev** role:

```yaml
eks.amazonaws.com/role-arn: arn:aws:iam::700736442855:role/op-usxpress-dev-ecr-credentials-sync
```

Adding the Kustomization without fixing this gives a green Flux Kustomization, a
running CronJob, and no pull secret — because AssumeRoleWithWebIdentity fails
against an issuer the dev role does not trust. Ready=True proves the CronJob was
applied, not that it succeeded. Same class of false green as ESO SecretSynced.

## Order of work

**1. Answer this first — it may delete step 3 entirely.**

```bash
aws ecr get-repository-policy --region us-east-2 \
  --registry-id 064859874041 --repository-name <any-existing-repo>
```

If the policy grants `arn:aws:iam::700736442855:root`, then *any* role in that
account can pull, the new QA/prod roles work with no ECR-side change, and the
"who owns 064859874041" question stops blocking QA delivery. If it names the dev
role explicitly, that account's IaC must add the new roles.

**2. IAM — `terraform/ecr-puller-roles.tf`.** Creates
`op-usxpress-qa-ecr-credentials-sync` and `op-usxpress-prod-ecr-credentials-sync`
in 700736442855, each trusting its own cluster's OIDC issuer, pull-only, pinned to
`system:serviceaccount:ecr-credentials:ecr-credentials-sync`.

Before raising: confirm the OIDC issuer URLs and how iaac-talos registers them.

```bash
aws iam list-open-id-connect-providers
aws iam get-role --role-name op-usxpress-dev-ecr-credentials-sync \
  --query 'Role.AssumeRolePolicyDocument'
```

The dev trust policy is the template — match its condition keys exactly.

⚠️ Octopus deploy only. Watch that TfApply is true, or the run prints a plan,
skips the apply, and reports Success.

**3. ECR-side grant** in 064859874041, only if step 1 says it is needed.

**4. Platform repo — per branch, NOT a merge.**

`iaac-talos-flux-platform`, branch `op-qa`, `infrastructure/ecr-credentials/rbac.yaml`:

```yaml
    eks.amazonaws.com/role-arn: arn:aws:iam::700736442855:role/op-usxpress-qa-ecr-credentials-sync
```

Branch `op-prod`, same file:

```yaml
    eks.amazonaws.com/role-arn: arn:aws:iam::700736442855:role/op-usxpress-prod-ecr-credentials-sync
```

**5. Cluster repo — `iaac-talos-flux-cluster`, branch `master`.** Add to
`clusters/op-usxpress-qa/flux-system/infra.yaml` (and prod's, once prod's role
exists). Copied from `clusters/bm-dev/flux-system/infra.yaml`:

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

While editing QA's file, correct the stale Tier 3 comment at line ~162.

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

A failed AssumeRoleWithWebIdentity shows in the job log, nowhere else.

## Known concerns carried forward

* The CronJob runs `public.ecr.aws/aws-cli/aws-cli:latest` — unpinned, and it holds
  cluster-wide secret-write. Worth pinning by digest before prod.
* It patches **every** ServiceAccount in **every** namespace. Broad, but it is the
  mechanism that made `app-risingwave` work on dev without bespoke config.
