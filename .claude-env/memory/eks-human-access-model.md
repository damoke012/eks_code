---
name: eks-human-access-model
description: "How to grant a person kubectl access to USX cloud EKS — assign an AWS SSO permission set that's already aws-auth-mapped to a group; never hand-edit aws-auth"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
  modified: 2026-07-27T21:11:44.295Z
---

**Granting a human read access to USX cloud EKS = assign an AWS SSO permission set, NOT an aws-auth edit.**

Verified on `usxpress-prod` (acct 937464026810) 2026-07-27 while actioning Timothy Preble's access
ticket (freshservice 1729384 — he wanted prod EKS read to debug geo-definition-api).

**The model:** aws-auth ConfigMap (`kube-system/aws-auth`) maps SSO permission-set roles → K8s groups.
Prod has `AWSReservedSSO_v-prod_...` (the `v-prod` permission set) → group **`view`**. The `view`
group is bound (ClusterRoleBindings) to: built-in `view` ClusterRole (cluster-wide read, **NO secrets**)
via `k8s-view-team`, plus `iaac-istio-reader` (istio config read), `port-forward-role`, `prometheus-read-role`
— subjects on all: `view,lead,dev`. So `view` = debugging-grade read-only.

**To grant:** assign the person the **`v-prod`** permission set on the account in **AWS Identity Center**.
NO cluster change — the mapping + bindings already exist. They then `aws sso login` +
`aws eks update-kubeconfig --name usxpress-prod` and have read-only kubectl.

**NEVER hand-edit aws-auth to add a user.** It's the highest-blast-radius object in EKS — a malformed
edit locks every principal out. And per-IAM-user mapUsers doesn't scale. Use the SSO-permission-set path.

**RESOLVED Timothy Preble (tpreble@usxpress.com) 2026-07-27:** direct-assigned `v-prod` to the USER on USX-Production
via Identity Center (Variant mgmt acct 660075424663 → Identity Center is us-east-1, instance ssoins-7223eb10c0b8ac39;
Doke has AWSAdministratorAccess there). ⚠️ FINDING: he was ALREADY in groups `usx-production` AND `usx-technology-lead`,
BOTH of which map to `v-prod` on prod — so he should have had it already. Root cause likely **stale login OR stale SCIM
sync** (dashboard warns "1 SCIM access token expiring/expired" — identity source = External IdP/Entra). Direct user
assignment (stored in Identity Center, independent of SCIM) guarantees it. **FOLLOW-UP: rotate the Identity Center SCIM
token** — stale sync = recurring phantom "no access" tickets. User MUST re-login to SSO portal to pick up new access
(that was likely the whole ticket). Groups→v-prod on prod: usx-production, usx-aws-production-read, usx-technology-lead.

Groups tier seen: `view` < `lead`/`dev`. Admin is via `system:masters` (lazy-octopus-devops, octopus-usxpress,
AWSReservedSSO_AWSAdministratorAccess, AWS SSO admin). Cluster ALSO has EKS Access Entries but those are for
infra/service roles (Wiz, Karpenter, node groups) — human read access goes through aws-auth `view`, not access entries.
QA (`qa-one`, 527101283767) almost certainly has the same `view`-group pattern (verify before asserting).
Prod EKS endpoint fingerprint `BF7BD0896246A3AA0A5DF5C9D8200E8A`; profile `ops-controller`. See [[wsl-kubeconfig-churn]], [[cloud-eks-platform-doc]].
