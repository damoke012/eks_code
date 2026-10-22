---
name: onprem-sso-placeholders-break-two-tiers
description: "MEASURED 2026-10-20: the aws-auth ConfigMap on BOTH op-qa and op-prod maps the operator and reader tiers to role ARNs containing literal placeholders (<FILL>, FILL_FROM_LIST_ROLES). Only the admin tier works, on either cluster, and nobody noticed because only admins use it"
metadata:
  type: project
---

**Measured on both clusters, 2026-10-20**, reading `kube-system/aws-auth`.

| Cluster | Tier | Role ARN |
|---|---|---|
| op-qa | admin | `arn:aws:iam::527101283767:role/AWSReservedSSO_op-qa-platform-admin_f8b5c3ff8895fdf6` ✅ |
| op-qa | operator | `…AWSReservedSSO_op-qa-platform-operator_<FILL>` ⛔ |
| op-qa | reader | `…AWSReservedSSO_op-qa-platform-reader_<FILL>` ⛔ |
| op-prod | admin | `arn:aws:iam::937464026810:role/AWSReservedSSO_usx-on-prem-admins_837df2a43495aaf1` ✅ |
| op-prod | operator | `…AWSReservedSSO_usx-on-prem-operators_FILL_FROM_LIST_ROLES` ⛔ |
| op-prod | reader | `…AWSReservedSSO_usx-on-prem-readers_FILL_FROM_LIST_ROLES` ⛔ |

**Four of six mappings name a role that cannot exist.** The three group-keyed
ClusterRoleBindings are present and correct on both clusters, so the *bindings* are fine —
what is broken is the map from an AWS role to a cluster group.

**Why nobody noticed.** Only the admin tier has ever been used. An operator or reader signing
in would authenticate successfully and arrive with **no groups**, which presents as "SSO is
broken" and is actually an unfinished mapping — the same shape as
[[entra-authz-claims]] on the Argo CD side.

⚠️ **The placeholder shipped through review on two clusters and survived three months.** A
template value that looks like a value (`<FILL>` inside an otherwise well-formed ARN) is not
caught by anything: the ConfigMap is valid YAML, Flux applies it happily, and the
authenticator only consults the entry when someone with that role logs in.

## ⚠️ CORRECTED the same day: there is nothing to fill them with

Listing the SSO roles in both accounts, 2026-10-20:

| Account | Roles beginning `AWSReservedSSO_` and matching op-qa / on-prem |
|---|---|
| **527101283767** (QA) | `AWSReservedSSO_op-qa-platform-admin_f8b5c3ff8895fdf6`, `AWSReservedSSO_usx-on-prem-admins_8c7f139e431625e0` |
| **937464026810** (prod) | `AWSReservedSSO_usx-on-prem-admins_837df2a43495aaf1` |

**No operator or reader permission set exists in either account.** So the fix is not a lookup
and substitution — **the permission sets have to be created and assigned first**, in AWS
Identity Center, and only then can the mapping be completed. That is a larger piece of work
than "fill in the ARN", and it is console work in Identity Center.

⚠️ **The QA account carries a second admin role that QA's `aws-auth` does not map.**
`usx-on-prem-admins` exists in **both** accounts, but QA maps only `op-qa-platform-admin`. So
anyone granted `usx-on-prem-admins` on the QA account authenticates and lands with **no
groups** — the same failure as the operator and reader tiers, from a different cause. The
newer `usx-on-prem-*` naming looks like the intended standard and `op-qa-platform-admin` the
original; QA is mid-rename and the map was never finished.

✅ **Prod's admin mapping is exact.** `aws-auth` names
`…AWSReservedSSO_usx-on-prem-admins_837df2a43495aaf1` and that role exists with that suffix —
so **prod admin sign-in will work the moment the API server flag is on**, with no AWS work at
all.

**Naming differs between the clusters** and that is not a defect, just a surprise:
op-qa uses `op-qa-platform-admin/operator/reader`, op-prod uses
`usx-on-prem-admins/operators/readers`.

**Could a check have caught it?** Yes, and it is one line: grep the rendered `aws-auth` for
`FILL`, `<`, `TBD` or `CHANGEME` and fail. Worth adding wherever the platform manifests are
linted.

Related: [[onprem-human-access-model]], [[onprem-prod-sso-is-half-landed]].
