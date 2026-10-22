---
name: aws-provider-6691-breaks-lambda-read
description: "hashicorp/aws 6.69.1 fails READING aws_lambda_function via an internal ListVersionsByFunction call; pinned below it fleet-wide, not fixed. An unpinned provider is an ungated change in any repo that gitignores the lock file"
metadata:
  type: project
---

**Reported 2026-10-20** (Platform Delivery and Reliability Review), incident the Thursday
before, on `ix-kafka-topics-users` **dev** through Octopus. Fix by Parul.

The `hashicorp/aws` provider released that same day made the **read** of
`aws_lambda_function` issue an internal **`ListVersionsByFunction`** API call, which errored
and stopped the deployment. Nothing had been applied. **Nothing in USX Terraform calls that
API** — the call is inside the provider, so grepping our code for it finds nothing and that
is expected, not exculpatory.

Octopus **publishes a new Lambda version on every deploy**, so these functions carry long
version lists; that is the state the read was walking.

**Workaround in place: a provider constraint `< 6.69.1`**, merged in the shared config, so
one merge covered every environment. Newer **Lambda** versions are still fine — what is
frozen is the **provider**. The two get conflated in conversation; the blocked upgrade is the
provider's. A patch release exists and is untested; Parul owns the re-test and reverting the
pin.

**How to apply.** Symptom: a plan or refresh failing on `ListVersionsByFunction` in a project
holding a Lambda, right after the provider was resolved fresh. Read the **raw** Octopus log —
the rendered view truncates the message. Then check which provider version the run resolved,
because a repo that gitignores `.terraform.lock.hcl` resolves it at init and two runs an hour
apart can differ. **Release day is the exposure.**

⚠️ **Our own `iac-tf-manual-runs/apps/common/gha_ecr_push_roles` declares `aws = "~> 6.69"`**,
which means `>= 6.69, < 7.0` and therefore **admits the blocked range**. It is IAM-only so the
bug cannot bite it, but the constraint disagrees with the fleet's and nothing says why.

Full write-up, exit criteria and what was NOT captured (the error text — get it from the raw
log before the task ages out): `wip/onprem-app-cicd/FINDINGS-2026-10-20-aws-provider-lambda-listversions.md`.
Related: [[dont-chase-the-latest-version]], [[octopus-green-but-no-apply]].
