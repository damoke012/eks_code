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

## ⚠️ 2026-10-15 — the op-qa fix was PARTIAL

`op-qa-platform-admin` still cannot `secretsmanager:ListSecrets`:

```
User: arn:aws:sts::527101283767:assumed-role/AWSReservedSSO_op-qa-platform-admin_f8b5c3ff8895fdf6/
doke@usxpress.com is not authorized to perform: secretsmanager:ListSecrets
```

So "✅ op-qa fixed 2026-08-25" above is **too strong** — whatever was granted did not include
the list action. Do not plan a check around `list-secrets` on any of the three environments.

**Work around it by asking the consumer, not the account.** The in-cluster `ExternalSecret`
resolves through the **ESO IRSA role**, not a human identity, so it answers "does this secret
exist and is its value usable" without any human Secrets Manager permission:

```sh
kubectl --kubeconfig=$HOME/.kube/op-usxpress-qa-sso.yaml -n app-risingwave get externalsecret -o json
```

`.spec.data[].remoteRef.key` and `.spec.dataFrom[].extract.key` give the AWS paths; the
resulting Secret's `.data` gives the key names and whether any value is empty. Better evidence
than a listing anyway — it measures what the workload actually gets
([[eso-secretsynced-not-content-check]]). An AccessDenied here is a transport failure and must
never be reported as "the secret does not exist" ([[transport-failure-not-a-verdict]]).
