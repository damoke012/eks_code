# GHA OIDC for `usxpressinc/risingwave-poc` — read RW secrets from AWS SM

Drafted 2026-05-18. Lets Tim's `usxpressinc/risingwave-poc` workflows authenticate
to AWS via GitHub OIDC federation and pull RisingWave + Postgres credentials
from Secrets Manager — replacing the anti-pattern of storing creds as GitHub
repo secrets.

## Why this exists

Idris asked (2026-05-18): "I need the OIDC to pull secrets from secret manager
rather than use github secrets." The workflow runs in Tim's repo; Tim's the
operator since he owns it. Use case: Tim's pipeline development needs to connect
to the Postgres metadata store and RisingWave Postgres.

## Files

| File | Goes to |
|---|---|
| `iam/github-actions-oidc-provider.tf` | **NEW FILE** in `iaac-talos/deploy/terraform/modules/irsa/`. Creates the account-wide GHA OIDC provider for 700736442855. ONE-TIME bootstrap per account. |
| `iam/gha-risingwave-poc-secrets-role.tf` | **NEW FILE** in the same module dir. Consumes the provider via data source. |
| `iam/gha-risingwave-poc-secrets-output.tf` | Append to `iaac-talos/deploy/terraform/modules/irsa/outputs.tf` |
| `example-workflow/connect-rw-postgres.yaml` | Reference — Tim places under `.github/workflows/` in `usxpressinc/risingwave-poc` |
| `iam/per-account-bootstrap/github-actions-oidc-provider.tf` | **Reusable template** — drop into any other AWS account's IaC when adding GHA-OIDC federation to that account |
| `iam/per-account-bootstrap/ACCOUNT-MATRIX.md` | State of GHA OIDC across all USXpress AWS accounts + rollout plan |

**Important**: as of 2026-05-18, account 700736442855 has NO GitHub Actions OIDC provider. The `github-actions-oidc-provider.tf` file BOOTSTRAPS it. After it's applied once, every future GHA-OIDC role in this account just uses `data "aws_iam_openid_connect_provider"` to reference it — never creates a duplicate.

See `iam/per-account-bootstrap/ACCOUNT-MATRIX.md` for the state of other AWS accounts (QA, Prod, DevOps/ECR, Playground) and the rollout plan for each.

## Trust + permissions scope

| Aspect | Value | Rationale |
|---|---|---|
| Trust principal | `repo:usxpressinc/risingwave-poc:ref:refs/heads/master` | Tight — only master, no PRs from forks, no other repos |
| Audience claim | `sts.amazonaws.com` | Standard GHA OIDC audience |
| Permissions | `GetSecretValue` + `DescribeSecret` on `op-usxpress-dev/risingwave/*` | Scoped to RW secrets only; cannot read other namespaces |
| List permission | `ListSecrets` (any) | Required for some SDK paths; harmless — no value disclosed |
| Account | `700736442855` (USX-Dev) | Where the secrets live |
| Region | `us-east-2` | Standard |

## Order of operations

### 1. Apply Terraform (in `variant-inc/iaac-talos`)

```bash
cd ~/work/iaac-talos
git checkout feature/irsa
# Copy the two .tf snippets into modules/irsa/main.tf and outputs.tf
cd deploy/terraform && terraform plan && terraform apply
terraform output gha_risingwave_poc_secrets_role_arn
# Expect: arn:aws:iam::700736442855:role/gha-op-usxpress-dev-risingwave-poc-secrets
```

### 2. Tim adds the workflow

In `usxpressinc/risingwave-poc` on master:
- Create `.github/workflows/connect-rw-postgres.yaml` (use the example as starting point)
- Replace `<postgres-host-or-svc>` and `<rw-host-or-worker-ip>` with actual targets
- **Trigger a test run** via the workflow_dispatch UI in GitHub

### 3. Verify

The first run logs should show `aws sts get-caller-identity` returning the
`gha-op-usxpress-dev-risingwave-poc-secrets` role ARN. If it doesn't, trust
policy condition is mismatched — check `:sub` claim vs the actual repo/branch.

## Important gotcha — GitHub-hosted runner network reach

GitHub-hosted runners run on Microsoft Azure infrastructure with public-internet
egress. They **cannot reach `10.10.82.x` corp IPs**. So if the workflow tries to
psql against on-prem worker IPs directly, it'll time out.

Options:
- **Use a self-hosted runner** inside USXpress corp network — gives the workflow
  the same network reach you have from WSL on VPN. This is the right answer for
  production.
- **Run only the SM-read steps on github-hosted, and write the secret to a step
  output**, then run the actual psql on a self-hosted runner downstream.
- **Use Tailscale / similar** to bridge github-hosted runners to corp network —
  hacky, security-debt-incurring; not recommended.

Tim should clarify which runner host he intends. If github-hosted, the workflow
won't reach on-prem Postgres/RW even with correct IAM auth — the IAM bit will
work, the network bit won't.

## Security considerations

- **Anyone with merge-to-master on `usxpressinc/risingwave-poc` effectively has
  read access to the RW secrets** via workflow runs they can trigger. Confirm
  the set of users with master-push is small and trusted (Tim + Idris,
  presumably).
- The role grants ONLY read on RW secrets — cannot read other AWS resources,
  cannot write/modify secrets, cannot rotate keys.
- The `::add-mask::` directive in the workflow scrubs secret values from logs,
  but logs are still visible to anyone with repo Read access. Don't `echo` raw
  secrets — only use them in env vars passed to commands.

## Rollback

```bash
# In iaac-talos
terraform destroy -target=aws_iam_role.gha_risingwave_poc_secrets \
                  -target=aws_iam_role_policy.gha_risingwave_poc_secrets
# In risingwave-poc
# Delete .github/workflows/connect-rw-postgres.yaml
```

Removing the role doesn't affect anything else — it's a single-purpose surface.

## Cross-reference

- Existing OIDC workflows for AWS: `iaac-octopus-overrides/.github/workflows/onprem-account-bootstrap.yaml` and `onboard-app.yaml` (local drafts, not yet committed to a real repo)
- Existing AWS SM seeds: `op-usxpress-dev/risingwave/{postgres,root}` (per `memory/risingwave_onprem_progress.md`)
- Related IRSA module: `iaac-talos/deploy/terraform/modules/irsa/main.tf` (this slots in alongside `octopus_worker`, `extd_usxpress_io`, etc.)
