# Network team ask — SUPERSEDED 2026-05-18

> **STATUS: NO ASK NEEDED. Do not send this email.**
>
> On 2026-05-18, Dare inspected the actual trust policy on
> `iaac-route53-zone` in account 155768531003 (Infrastructure-Networking) using
> his `infra-common`-equivalent AWSAdministratorAccess SSO role.
>
> The trust policy is **already a wildcard pattern** that trusts any role in
> the USXpress AWS Org whose name matches `extd-usxpress-io-*` (or
> `cert-manager-*`, or the EKS-pathed variants).
>
> Therefore: we simply **name our on-prem source role to match the existing
> pattern** (`extd-usxpress-io-op-usxpress-dev`) and the trust applies
> automatically.
>
> **Saves**: days of network-team turnaround.
> **No coordination required** with `usx-aws-network@usxpress.com` for this.

---

## What the existing trust policy looks like (for reference)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "*" },
      "Action": ["sts:AssumeRole", "sts:TagSession"],
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "o-yza5l1xhrc"
        },
        "StringLike": {
          "aws:PrincipalArn": [
            "arn:aws:iam::*:role/cert-manager-*",
            "arn:aws:iam::*:role/extd-usxpress-io-*",
            "arn:aws:iam::*:role/eks/*/cert-manager-*",
            "arn:aws:iam::*:role/eks/*/extd-usxpress-io-*"
          ]
        }
      }
    }
  ]
}
```

## Implications for the full 3-piece networking plan

| Piece | Role name | Matches wildcard? |
|---|---|---|
| **2. external-dns** | `extd-usxpress-io-op-usxpress-dev` | ✅ matches `extd-usxpress-io-*` |
| **3. cert-manager public issuer** | `cert-manager-op-usxpress-dev` | ✅ matches `cert-manager-*` — **also no trust patch needed!** |

So when we get to piece 3, same naming convention applies — no network-team ask needed for that either.

## What we still need from the network team

**For non-HTTP services (BGP)** — the original P2 ask at
`risingwave_iaac_artifacts/network-team-ask.md` is unaffected by this finding.
That ask is still real (LoadBalancer Services + raw TCP need BGP or
static-routes from corp router). But it remains P2, not blocking piece 1 or
piece 2.

## Historical context

Original assumption (2026-05-13): "Cross-account IAM trust on iaac-route53-zone
will need an explicit `Principal` added for each new source role we create."
That assumption was wrong — the cloud team set up wildcard patterns explicitly
to make adding new env-specific source roles a low-friction operation.
Discovered by inspecting the actual policy with AWSAdministratorAccess on
155768531003.

**Lesson**: when planning cross-account work, look at the existing trust policy
of the target role FIRST. Often you don't need to ask for changes; you just need
to match the existing pattern.
