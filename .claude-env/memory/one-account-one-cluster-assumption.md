---
name: one-account-one-cluster-assumption
description: iaac-talos assumes one cluster per AWS account — Terraform's IAM grant is scoped to <cluster>-* and apply-bootstrap-perms.sh REPLACES it, so standing a second cluster up in an existing account de-authorises the first
metadata:
  type: project
---

Read from op-usxpress-qa's live `octopus-usxpress` role, 2026-09-17. Terraform's only IAM
role permissions are:

```
"Resource": [ "arn:aws:iam::527101283767:role/op-usxpress-qa-*",
              "arn:aws:iam::527101283767:role/iaac-octopus-worker-op-usxpress-qa" ]
```

Two consequences, both invisible until an apply is halfway through:

1. **A new cluster whose name does not match the prefix cannot have its IRSA roles created.**
   `op-usxpress-qa2-*` does not match `op-usxpress-qa-*`. `op-usxpress-qa-2-*` does. Naming is
   load-bearing, not cosmetic.
2. **`octopus/apply-bootstrap-perms.sh` uses `put-role-policy`, which REPLACES the policy**, and
   writes a document covering one cluster. Running it for a second cluster in an existing
   account silently de-authorises the first. Its header says "run once per account", which was
   true only while each account held one cluster.

**Why:** the grant was written when the mapping was one account, one cluster. Nothing enforces
or documents that assumption, and the failure appears as AccessDenied on roles Terraform
itself created — which reads as a credentials problem, not a scope problem.

**How to apply:** before adding a cluster to an existing account, read the live policy with
`aws iam get-role-policy --role-name octopus-usxpress --policy-name iaac-talos-bootstrap`.
Either name the cluster so it falls inside the existing prefix, or give each cluster its own
inline policy (`iaac-talos-bootstrap-<cluster>`) so none can clobber another. Never re-run the
script as written against an account that already hosts a cluster.

**Instrument note:** `aws iam simulate-principal-policy` without `--resource-arns` simulates
against `*` and returns `implicitDeny` for a correctly scoped grant. It said Terraform could
not create roles while Terraform was demonstrably creating eight. Read the policy document;
do not simulate. See [[prod-incident-instrument-check]], [[proxy-is-not-the-property]].

Related: [[promotion-order-qa2-dev-qa-prod]], [[workflow-that-never-ran]].
