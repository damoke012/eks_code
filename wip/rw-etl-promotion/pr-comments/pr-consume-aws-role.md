## What

`role-to-assume` in the `execute` job becomes `${{ needs.validate.outputs.aws_role }}`. It was
a hardcoded literal.

## Why

The workflow computes the role ARN per environment, publishes it as a job output, and then
ignores it:

| line | |
|---|---|
| 35 | `aws_role: ${{ steps.env-detect.outputs.aws_role }}` — exposed as a job output |
| 79 | `echo "aws_role=arn:aws:iam::${AWS_ACCOUNT_ID}:role/gha-op-usxpress-${ENV}-risingwave-${ROLE_KIND}-secrets"` — computed per environment |
| 226 | `role-to-assume: arn:aws:iam::700736442855:role/gha-op-usxpress-dev-risingwave-pipeline-secrets` — a literal |

Identical on `master`, `qa` and `dev`, checked.

So every environment assumed the **dev account's** role. A `qa` run reached for a role in
`700736442855` while its secret path interpolated to `op-usxpress-qa/...` — the wrong account,
not merely the wrong role. The secret id on lines 233 and 244 does interpolate correctly from
`needs.validate.outputs`, so the role is the only frozen value.

This is consistent with the three historical runs all failing at "Pull Postgres credentials"
with exit 254.

## What this means for #33 and #35

Both edited the producer — #33 made the role follow the namespace, #35 moved dev to
`risingwave`. Neither changed runtime behaviour, because nothing read the value. Both reviewed
clean, because the producer was correct and the consumer was a syntactically valid literal. The
defect is only visible by following the wire from one to the other.

## Scope and safety

- One line changed, plus a comment recording why it must not be re-frozen.
- No change to which role any environment *should* use — `dev` → `gha-op-usxpress-dev-risingwave-poc-secrets`,
  and the same shape for qa and prod, exactly as env-detect already computes.
- The patch script also reports any account id still hardcoded outside the env-detect case
  statement, so the same defect in another step cannot hide behind this fix.
