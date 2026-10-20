---
name: two-projects-one-resource
description: iaac-talos and iaac-risingwave-onprem both declare RisingWave's S3 bucket and IRSA role; never import to resolve it — remove the duplicate
metadata:
  type: project
---

**`iaac-talos` and `iaac-risingwave-onprem` declare the same two AWS resources**:
`aws_s3_bucket.risingwave` (the Hummock object store, `risingwave-state-op-usxpress-<env>`)
and `aws_iam_role.risingwave_irsa` (`${cluster_name}-risingwave`). `iaac-risingwave-onprem`
created them; `iaac-talos`'s `module.irsa[0]` declares them too.

Surfaced 2026-09-11 when a QA Octopus deploy failed:

    Error: creating S3 Bucket (risingwave-state-op-usxpress-qa): BucketAlreadyOwnedByYou
    Error: creating IAM Role (op-usxpress-qa-risingwave): EntityAlreadyExists

**The obvious fix — `terraform import` into iaac-talos — is the wrong one.** Two states
owning one bucket means a `destroy`, a `taint`, or a forced replacement on *either* side
deletes RisingWave's object store. The collision error is the safety net. Remove the
declaration from `iaac-talos` instead and leave `iaac-risingwave-onprem` as sole owner.

**Why it stayed hidden:** dev and QA ran plan-only for months (`TfApply=false`), so the
duplicate never attempted creation. QA became apply-enabled in July, and this was the
first apply to reach it.

**How to apply:** before importing anything, grep the *other* repos for the resource's
name — a 409/AlreadyExists on a first apply usually means another project owns it, not
that state was lost. See [[onprem-gitops-repo-topology]],
[[terraform-state-bucket-is-per-account]], [[octopus-green-but-no-apply]].

## ⚠️ CORRECTED 2026-10-15 — iaac-talos does NOT declare the on-prem RisingWave role or bucket

The claim above sent me to the brink of refusing a correct import. Checked against
`iaac-talos` `master`: its only risingwave paths are

```
deploy/terraform/modules/irsa/gha-risingwave-pipeline-secrets-role.tf
deploy/terraform/modules/irsa/gha-risingwave-poc-secrets-role.tf
deploy/terraform/modules/irsa/risingwave-2-role.tf
```

Two GHA secrets roles, plus **`risingwave-2`** — which is the DEV-ONLY namespace and a
different role ([[risingwave-onprem]]). Neither `op-usxpress-dev-risingwave` nor
`risingwave-state-op-usxpress-dev` is declared there. **There is no double-management hazard
for those two objects.** The original warning may have been about `risingwave-2`, or about an
earlier layout; keep the rule for the general case but do not apply it to these.

## What IS true, and it is worse in a quieter way

`iaac-risingwave-onprem` has never applied ([[onprem-app-cicd]]), and **its config does not
match the environment it claims to describe**:

| | module declares | live on op-usxpress-dev |
|---|---|---|
| S3 access | `aws_iam_role_policy.risingwave_s3`, **inline**, named `risingwave-s3-access` | **attached managed** policy `op-usxpress-dev-risingwave-s3` |
| role tags | none | `purpose=risingwave-state-store`, `cluster=op-usxpress-dev` |

So `aws_iam_role_policy.risingwave_s3` **cannot be imported** — there is no inline policy. A
plan would CREATE one, leaving the role with both. And importing `aws_iam_role.risingwave_irsa`
yields a plan that wants to strip its two tags.

**How to apply:** an unapplied module is a *claim*, not a description. Before importing
anything, compare the declared shape against the live object — policy attachment style, tags,
names — not just existence. `describe`/`list-*` the live resource and diff it against the HCL.
The fix is to edit the module to match a working environment, never the reverse
([[promotion-order-qa2-dev-qa-prod]]).
