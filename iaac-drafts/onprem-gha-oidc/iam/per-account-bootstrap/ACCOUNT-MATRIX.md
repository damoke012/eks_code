# GHA OIDC provider — per-account rollout matrix

State of GitHub Actions OIDC federation across USXpress AWS accounts as of
**2026-05-18**. Each account is independent — adding the provider in one does
not affect any other.

## Current state (verified)

| Account ID | Account name | Profile | Has GHA OIDC provider? | Verified? |
|---|---|---|---|---|
| 700736442855 | USX-Dev | `usx-dev` | **No** | ✅ 2026-05-18 |
| 064859874041 | DevOps / ECR | `playground` (or alias) | Unknown | Run check below |
| 786352483360 | Playground | `playground` | Unknown | Run check below |
| 527101283767 | USX-QA | `usx-qa` | Unknown | Run check below |
| 937464026810 | USX-Production | `ops-controller` | Unknown | Run check below |
| 155768531003 | Infra-Networking | (no direct on-prem access) | N/A | Network team owns; out of scope |

## Verification command — run on WSL for each account

```bash
for profile in usx-dev playground usx-qa ops-controller; do
  echo "=== $profile ==="
  aws iam list-open-id-connect-providers --profile "$profile" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); [print(p['Arn']) for p in d.get('OpenIDConnectProviderList',[])]"
  echo ""
done
```

Update the table above as you confirm each one.

## Where the provider gets created in each account

Each account has its own Terraform state and its own IaC repo. The provider
goes in the IaC that owns the account's IAM:

| Account | Likely Terraform location |
|---|---|
| 700736442855 USX-Dev | `iaac-talos/deploy/terraform/modules/irsa/` (this draft) |
| 527101283767 USX-QA | `iaac-eks` or QA-specific terraform (ask the QA owner) |
| 937464026810 USX-Production | `iaac-eks` or prod-specific terraform (ask the prod owner) |
| 064859874041 DevOps/ECR | DevOps team's terraform — coordinate with whoever owns ECR |
| 786352483360 Playground | Less likely needed; only if GHA workflows target playground |

**Important**: the provider create is a **one-time, account-wide** action. Don't
duplicate it within the same account in a different terraform module — terraform
will error with "EntityAlreadyExists". If two consuming roles need to reference
the same provider, both use `data "aws_iam_openid_connect_provider"`, only one
file (`github-actions-oidc-provider.tf`) creates it.

## When to add the provider to a new account

**Pattern**: don't pre-create. Add when a real use case appears.

Pre-creating in every account costs nothing technically, but:
- Adds Terraform churn (`terraform plan` noise) in accounts not actively using it
- Crosses ownership boundaries — the team owning the account may want to know
  before federation is established to their account
- Forces premature decisions about which repos/branches should have trust

**Rule of thumb**: when a specific workflow lands that needs to read AWS in
account X, then add the provider to account X's terraform. That keeps the
federation surface aligned with actual usage.

## Use-case mapping (forecast)

| Likely future use case | Account | Owner of the ask |
|---|---|---|
| Tim's `risingwave-poc` reading RW secrets | 700736442855 (USX-Dev) ✅ in progress | Idris + Tim |
| Octopus on-prem `onboard-app.yaml` running terraform apply | 700736442855 (USX-Dev) — covered by same provider | On-prem platform team |
| ECR push from GHA without long-lived keys | 064859874041 (DevOps/ECR) | DevOps team |
| Cloud terraform-variant-apps GHA workflows | Likely already exists in 700736442855 or 527101283767 | Cloud team / Vibin-replacement |
| QA-only smoke-test workflows reading QA secrets | 527101283767 (USX-QA) | Whoever owns QA platform |
| Prod release workflows reading prod secrets | 937464026810 (USX-Prod) | Steve / release engineering |

## Coordination notes

- **064859874041 (ECR / DevOps)** — DevOps team likely has its own GHA→AWS setup
  for ECR pushes from app-team workflows. Before duplicating in this account,
  check with DevOps team to see if a provider already exists.
- **527101283767 (USX-QA) + 937464026810 (USX-Prod)** — these accounts are
  cloud-team territory. Cloud may already have a GHA OIDC provider for their
  own deployment workflows (e.g., the cloud `iaac-eks/octo.yaml` references
  `id-token: write` — suggesting OIDC is already wired somewhere). Verify
  before adding.
- **155768531003 (Infra-Networking)** — network team's account. Out of scope.
  If on-prem ever needs GHA→AWS federation to this account (unlikely), it's a
  network-team ask.

## Single source of truth — file naming convention

To keep the "this account's GHA OIDC provider is here" question easy to answer
across many terraform repos, use the consistent filename:

```
github-actions-oidc-provider.tf
```

Then any future engineer can search across IaC repos for that exact filename
and immediately see which accounts have the provider stood up.
