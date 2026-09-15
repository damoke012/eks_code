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
