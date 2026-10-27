---
name: sso-grant-is-group-membership
description: An Identity Center permission set can exist, be provisioned to the account and be mapped in aws-auth, and still fail — because the grant is to a GROUP you are not in
metadata:
  type: project
---

**Measured 2026-10-27**, after INFRA-1661 put the webhook flags on op-usxpress-prod's API
server. The cluster was ready to accept an SSO login and no one on the platform team could
produce one.

```
aws --profile op-prod sts get-caller-identity
  -> ForbiddenException ... GetRoleCredentials: No access   (rc 254)
```

Four things were all true and none of them was the problem:

| | |
|---|---|
| the role exists in 937464026810 | `AWSReservedSSO_usx-on-prem-admins_837df2a43495aaf1` |
| prod's `aws-auth` maps exactly that ARN | -> `sso:{{SessionNameRaw}}` in `onprem-platform-admins` |
| the permission set IS assigned on prod | -> **GROUP `usx-aws-admin`** |
| `op-prod`'s profile is configured for it | `sso_role_name = usx-on-prem-admins` |

`doke@usxpress.com` is in `usx-technology`, `usx-cloud-admin`, `usx-technology-lead`,
`usx-engineering` — **not `usx-aws-admin`**. That membership is the whole gap.

⚠️ **QA's model is WORSE than prod's, so do not "make prod match QA".** QA grants
`op-qa-platform-admin` to **two named USERS** (doke@, ifagbemi@) — standing personal
exceptions that outlive the people. Prod's group-based grant is correct; the group is simply
the wrong one. Recommended fix: grant prod's existing permission set to `usx-cloud-admin`,
a group the platform team is already in, rather than joining a broad AWS-admin group to
obtain Kubernetes access.

**How to apply:**
* `AWSAdministratorAccess` on the account is **not** a way in. aws-auth maps one specific role
  ARN and full AWS admin maps to nothing. That is the design working.
* These live in the **management account** (`usx-mgmt`, instance `ssoins-7223eb10c0b8ac39`,
  store `d-90676260a8`), not the member account. No prod profile can see them.
* `sso_role_name` is readable from `~/.aws/config` **without a session**, so the profile that
  WOULD work can be named even when nobody is signed in to it. A loop that skips un-signed-in
  profiles hides the answer — see [[transport-failure-not-a-verdict]].
* Scripts: `scripts/check-onprem-admin-assignment.sh`, `scripts/check-my-sso-groups.sh`,
  `scripts/build-prod-sso-kubeconfig.sh`. Related: [[identity-names-do-not-cross-systems]].
