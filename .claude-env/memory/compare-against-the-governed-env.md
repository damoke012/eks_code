---
name: compare-against-the-governed-env
description: "Drift checks are only meaningful against the environment that HOLDS the config's state, not the one you can reach. Comparing iaac-risingwave-onprem to dev produced a merged PR that would have changed QA's live IAM."
metadata:
  type: feedback
---

**2026-10-15.** I compared `iaac-risingwave-onprem` against **op-usxpress-dev**, found three
mismatches, and shipped PR #56 to "make the module describe the environment it names". All
three findings were real about dev. The PR was still wrong, and it merged.

**Dev is not an environment on that Octopus project.** Its variables are scoped only to
`Environments-602` (qa) and `Environments-41` (production). Dev's RisingWave estate was built
entirely **by hand** — which is exactly why its IAM role carries an *attached managed* policy
and no inline one.

**QA is what the module governs**, and QA's state exists:
`s3://lazy-tf-state-425rbol87rmn6c7m/iaac/risingwave/op-usxpress-qa.tfstate`, serial 2,
23 resources, managing `aws_iam_role_policy.risingwave_s3` — the **inline** form.

So #56 would have made the next QA apply **destroy the inline policy granting RisingWave its
S3 access** and create a replacement. QA has `TfApply = true`, so that was one Octopus deploy
away, on a working environment. Reverted by #58.

**Why:** dev was reachable and familiar, so it felt like the reference. Reachability is not
relevance. A config's reality is the environment whose **state file** it writes.

**How to apply — before any drift comparison or import:**
1. Find the state. `TF_STATE_KEY` and `S3_BUCKET` per environment, and
   `aws s3api head-object` to see whether the object exists.
2. **Read the state's resource list** before reading live AWS:
   `aws s3 cp s3://$B/$K - | jq -r '.resources[] | "\(.mode) \(.type).\(.name)"'`.
   That is the set of things the module actually owns. Everything else is noise.
3. Only then compare, and only against that environment.

⚠️ An environment you can reach but that holds no state is **unmanaged**, and matching the
module to it is how you break the one that is managed.

⚠️ The state file carries `secret_string` in **plaintext**. Pipe it, print only resource
names, and `shred -u` anything written to disk.

Related: [[onprem-app-cicd]], [[two-projects-one-resource]],
[[promotion-order-qa2-dev-qa-prod]], [[proxy-is-not-the-property]].
