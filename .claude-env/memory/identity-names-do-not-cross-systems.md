---
name: identity-names-do-not-cross-systems
description: "onprem-platform-admins is a k8s RBAC group invented in aws-auth and has NEVER existed in AWS Identity Center — cluster access is by permission set, SAML carries directory groups"
metadata:
  type: project
---

**`onprem-platform-admins` is not a directory group.** It is a Kubernetes RBAC group name
invented in `aws-auth`. Cluster access on the on-prem Talos clusters is granted by
**permission set** — the caller arrives as
`arn:aws:sts::700736442855:assumed-role/AWSReservedSSO_AWSAdministratorAccess_.../doke@usxpress.com`
— and `aws-auth` maps that role ARN to the k8s group name.

A **SAML assertion carries directory groups**, so Argo CD's `policy.csv` needs a real AWS
Identity Center group. Verified 2026-08-24: `aws identitystore list-groups
--identity-store-id d-90676260a8 --region us-east-1` returns **zero** matches for `onprem`
or `platform` across the whole store. The real groups are `usx-*` and `AWS*`.

Argo on-prem uses **`usx-cloud-admin`** (`90676260a8-dbbc2134-49b2-44ee-be04-656d3240a71c`),
which Doke is a member of. Also in: `usx-technology`, `usx-technology-lead`, `usx-engineering`.

**Why this matters:** a policy mapping a group that does not exist is invisible. The YAML is
valid, Flux is green, the HelmRelease is healthy, and the SSO login itself **succeeds**. It
surfaces only when a human logs in and lands on an empty page with access errors — which
reads as a broken login when it is authorisation. Unlike [[adjacent-step-green-signals]],
there is no adjacent green step here at all: every signal is genuinely correct, and the
defect is that a name meaningful in one system means nothing in another.

**How to apply:** before writing policy that names an identity, resolve that name **in the
system that has to recognise it**. `scripts/pr-argocd-rbac.sh` does this — with `PROFILE`
set it calls `identitystore list-groups` and refuses to write if the group does not resolve.

**Identity Center facts** (2026-08-24): instance `ssoins-7223eb10c0b8ac39`, identity store
`d-90676260a8`, region **us-east-1**, owner account **660075424663**. `sso-admin
list-instances` answers from member accounts and proves nothing about admin rights;
`sso-admin list-applications` is the discriminating call. See
[[argocd-sso-blocked-on-management-account]].
