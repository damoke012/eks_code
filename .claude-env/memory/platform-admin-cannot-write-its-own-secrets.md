---
name: platform-admin-cannot-write-its-own-secrets
description: op-*-platform-admin permission sets grant no Secrets Manager access; ESO reads what no human can inspect or rotate
metadata:
  type: feedback
---

The `op-*-platform-admin` AWS SSO permission sets shipped with **only** `sts:GetCallerIdentity`.
ESO reads Secrets Manager through the cluster's IRSA role, so every platform secret is readable
by the cluster and **invisible and unrotatable to the human who owns the platform**.

**Why:** the cluster works, so nothing surfaces the gap until someone needs to rotate or inspect
a value — typically during an incident. Hit 2026-08-13 (RisingWave QA Dex secret, `PutSecretValue`)
and again 2026-08-25 (`CreateSecret` for the Argo Entra client secret).

**How to apply:** fix it with `scripts/idc-grant-secretsmanager.sh <cluster> --apply` — management
account **660075424663**, profile `usx-mgmt`, Identity Center **us-east-1**, secrets **us-east-2**.
✅ op-qa granted and verified 2026-08-25 (permission set `ps-72231bee9cdd54cd`). ❌ op-dev and
op-prod still have the gap.

Three traps, all of which produce a result that looks like something else:
1. **`put-inline-policy-to-permission-set` REPLACES the whole policy** — read and merge, never put blind.
2. **Provisioning is ASYNC.** `provision-permission-set` returns `IN_PROGRESS`; retrying before
   `SUCCEEDED` gives the identical `AccessDenied` and reads as "the grant did not work".
3. **`aws sso login` does not refresh cached role credentials** — they keep the old policy until
   `rm -rf ~/.aws/cli/cache ~/.aws/sso/cache`.

See [[adjacent-step-green-signals]], [[argocd-onprem-entra-oidc]], [[eso-secretsynced-not-content-check]].
