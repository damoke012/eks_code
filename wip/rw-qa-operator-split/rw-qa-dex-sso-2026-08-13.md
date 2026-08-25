# RisingWave QA — dashboard SSO via Dex + Entra (2026-08-13)

QA RisingWave came up: **https://risingwave-dashboard.op-qa.usxpress.io/login/**

PR #29 (`deploy/terraform` packaging) and PR #86 (routes on `op-qa`) both landed, so the workload
and its routes exist.

---

## How the SSO is wired

Dex is **embedded in the RisingWave console** — there is no separate Dex deployment.

```
ConfigMap  risingwave/risingwave-console-dex
  issuer:       https://risingwave-dashboard.op-qa.usxpress.io/dex
  connector:    Risingwave (QA)
    clientID:   e112d6ce-cc60-4884-9898-8fcc5b78b0b1
    issuer:     https://login.microsoftonline.com/bbb5a66d-.../v2.0
    redirectURI: https://risingwave-dashboard.op-qa.usxpress.io/dex/callback
```

**One Entra app registration, `risingwave`, is shared by dev and QA.** Only dev's callback was
registered, so QA login failed at Entra before any credential was checked.

Client secret is ESO-delivered, per environment:

```
ExternalSecret risingwave/dex-entra-client-secret
  ClusterSecretStore: default   refresh 1h
  remoteRef.key:  op-usxpress-qa/risingwave/dex_entra_client_secret
  property:       DEX_ENTRA_CLIENT_SECRET
  secretKey:      DEX_ENTRA_CLIENT_SECRET
```

Because the storage paths are environment-scoped but the **app registration is shared**, both
environments must hold a valid secret for the same app. Two passwords existed (2026-07-16 and
2026-08-06, both valid to 2028), which is consistent with one per environment.

---

## What was done

**Registered QA's callback** — additive, dev preserved:

```bash
az ad app update --id e112d6ce-cc60-4884-9898-8fcc5b78b0b1 \
  --web-redirect-uris \
    "https://risingwave-dashboard.op-dev.usxpress.io/dex/callback" \
    "https://risingwave-dashboard.op-qa.usxpress.io/dex/callback"
```

> ⚠️ `--web-redirect-uris` **replaces** the list. Both URIs must be passed or dev breaks.

No secret was rotated. Both existing credentials run to 2028, so expiry was not the fault.

---

## Traps hit — worth knowing before anyone repeats this

**1. `az ad app credential reset` without `--append` deletes every existing password.** On a shared
app that takes the other environment down instantly. Always `--append`.

**2. The value is only ever shown once.** `az ad app credential list` returns metadata only. If you
generate one and lose it, the credential is an orphan — delete it.

**3. Never put an interactive `read` inside a pasted block.** Bash consumes the *next line of the
paste* as the input. Capture straight into a variable instead, so the secret is never displayed:

```bash
NEWSEC=$(az ad app credential reset --id <appid> --append --display-name "<env> dex" --years 2 \
         --query password -o tsv)
echo "captured: ${#NEWSEC} chars"          # must print 40
aws secretsmanager put-secret-value \
  --secret-id op-usxpress-qa/risingwave/dex_entra_client_secret \
  --secret-string "$(jq -nc --arg v "$NEWSEC" '{DEX_ENTRA_CLIENT_SECRET:$v}')" --profile op-qa
unset NEWSEC
```

**4. The stored value must be JSON, not a bare string** — ESO reads `property:
DEX_ENTRA_CLIENT_SECRET` out of it. A raw string syncs green and serves nothing usable.

**5. `SecretSynced: True` proves the sync ran, not that the value works.** Verify by signing in.

---

## Blocker for next time

`op-qa-platform-admin` (AWS SSO) has **no Secrets Manager access** on these paths:

```
AccessDenied: secretsmanager:PutSecretValue    on op-usxpress-qa/risingwave/dex_entra_client_secret
AccessDenied: secretsmanager:GetSecretValue
AccessDenied: secretsmanager:ListSecretVersionIds
```

ESO can read it (the cluster's IRSA role); a human cannot. Add to the permission set on
`arn:aws:secretsmanager:us-east-2:527101283767:secret:op-usxpress-qa/*`:

```
secretsmanager:DescribeSecret
secretsmanager:GetSecretValue
secretsmanager:PutSecretValue
secretsmanager:ListSecretVersionIds
```

Not being able to inspect or rotate a secret the cluster depends on will bite again — the next
time something actually does expire.

**RESOLVED 2026-08-25.** It bit again, on `secretsmanager:CreateSecret` for
`op-usxpress-qa/platform/argocd/azure-ad`. Fixed by adding a `PlatformSecretsReadWrite`
statement to the `op-qa-platform-admin` permission set, scoped to
`arn:aws:secretsmanager:us-east-2:527101283767:secret:op-usxpress-qa/*`, then re-provisioning:
`scripts/idc-grant-secretsmanager.sh op-qa --apply` (management account 660075424663, profile
`usx-mgmt`, permission set `ps-72231bee9cdd54cd`). Verified by writing the Argo client secret.

Three traps in that one operation:
1. **`put-inline-policy-to-permission-set` REPLACES the entire inline policy.** The existing
   `AllowGetCallerIdentity` statement would have been destroyed by a blind put. Read, merge, write.
2. **Provisioning is asynchronous** — `provision-permission-set` returns `IN_PROGRESS`. Retrying
   before `SUCCEEDED` fails with the identical `AccessDenied`, which reads exactly like the grant
   not having worked. Poll `describe-permission-set-provisioning-status`.
3. **`aws sso login` refreshes the SSO token, not the cached assumed-role credentials.** Those
   still carry the previous policy. `rm -rf ~/.aws/cli/cache ~/.aws/sso/cache` first.

Dev and prod have the same gap; `scripts/idc-grant-secretsmanager.sh` takes `op-dev` and
`op-prod` too, and refuses prod without `ALLOW_PROD_WRITE=yes`.

---

## Still open

1. **Login untested.** The redirect URI was the structural blocker; the stored secret may be fine.
   Test in a private window. `AADSTS7000215` = rotate; `AADSTS50105` = app assignment required, a
   different fix.
2. Confirm dev's ExternalSecret points at `op-usxpress-dev/...` and not the QA key — if they share
   a key, rotation is not isolated.
3. Consider **separate app registrations per environment**. One shared app means every credential
   operation is a cross-environment risk, which is why tonight needed so much care.

Related: [pr-29-and-86-review-2026-08-12.md](pr-29-and-86-review-2026-08-12.md)
