---
name: computed-value-never-consumed
description: "A value computed correctly, published, and read by nobody — both ends review clean, so only following the wire finds it"
metadata:
  type: feedback
---

`risingwave-pipeline`'s `pipeline.yaml` computed an AWS role ARN per environment, exposed it
as a job output, and then assumed a hardcoded literal instead. Found 2026-09-15, identical on
`master`, `qa` and `dev`:

- line 35 — `aws_role: ${{ steps.env-detect.outputs.aws_role }}`, exposed as a job output
- line 79 — `echo "aws_role=arn:aws:iam::${AWS_ACCOUNT_ID}:role/gha-op-usxpress-${ENV}-risingwave-${ROLE_KIND}-secrets"`
- line 226 — `role-to-assume: arn:aws:iam::700736442855:role/gha-op-usxpress-dev-risingwave-pipeline-secrets`

So every environment assumed the **dev account's** role while its secret path interpolated to
its own account. Wrong account, not merely wrong role — QA promotion could not have worked
whatever else was fixed.

**Why:** both ends review clean in isolation. The producer computes the right ARN and reads as
a correct fix; the consumer is a syntactically valid literal that resolves to a real role. The
defect exists only in the gap between them, which no diff of either side displays.

Two PRs the same week edited the producer — #33 (role follows namespace) and #35 (dev moves to
`risingwave`) — and changed no runtime behaviour at all. Both were reviewed carefully. Fixed
in #38.

**How to apply:** when a workflow, template or module computes a value and publishes it, grep
for the consumer before believing the fix landed. `grep -n 'outputs\.<name>'` and confirm the
count is at least two — one to publish, one to read. A value with exactly one occurrence is
dead. The same check applies to Terraform outputs, Helm values and job outputs of every kind.

Related: [[adjacent-step-green-signals]], [[two-gha-roles-one-pipeline-repo]],
[[merged-defect-authorizes-itself]], [[config-can-outrun-the-image]].
