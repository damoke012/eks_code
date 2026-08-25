---
name: argocd-sso-blocked-on-management-account
description: "INFRA-1639 step 3 is blocked: creating the Identity Center SAML app needs admin in management account 660075424663; Doke is admin in 700736442855 only"
metadata:
  type: project
---

Argo CD SSO on-prem is **blocked on management-account access**, not on design.

```
aws sso-admin list-applications --profile usx-dev --region us-east-1 \
  --instance-arn arn:aws:sso:::instance/ssoins-7223eb10c0b8ac39
-> AccessDeniedException ... AWSReservedSSO_AWSAdministratorAccess ... in 700736442855
```

The instance is owned by **660075424663**. Doke has `AWSAdministratorAccess` in the dev
member account, which is not the same thing. The denial message says "the resource does not
exist in this Region" — that is Identity Center's standard misleading wording for a
cross-account denial, not a region problem. The instance is in **us-east-1**.

**Decided 2026-08-24: AWS Identity Center, SAML via Dex.** Consistent with the cluster access
model and free of the Azure dependency blocking 1625/1558/1591. This **requires
`dex.enabled: true`** — Identity Center federates over SAML and Argo consumes SAML through
Dex. (An earlier claim that `oidc.config` would avoid installing Dex was wrong; that is only
true for an OIDC-native IdP such as Entra.)

**SAML needs no client secret.** `caData` is the IdP's public signing certificate, so the
connector config lives in git with no ExternalSecret and `argocd-secret` is never touched —
which matters on op-dev, where `configs.secret.createSecret: false` preserves the
`server.secretkey` its adopted 49-day raw install carried.

Done and merged: the route, `configs.cm.url`, and `configs.rbac` (PRs #126/#127/#129/#130).
`scripts/wizard-argocd-sso-dev.sh` walks the console half and refuses to start without
management-account access.

**Open risk for whoever runs it:** Identity Center may not expose a usable `${user:groups}`
attribute, or may emit GUIDs. If groups do not arrive, login succeeds and lands with no
permissions — see [[identity-names-do-not-cross-systems]]. Fallback is mapping identities
individually in `configs.rbac`, which is a decision to record, not to make quietly.

## The Identity Center side CANNOT be done by CLI or Terraform

Verified 2026-08-24 against aws-cli 2.33.19 with management-account credentials. Three
independent proofs, not one empty grep:

1. **No attribute-mapping operation exists.** Every `sso-admin` operation containing
   "application" was enumerated; none contains `attribute` or `mapping`. `${user:groups}`
   cannot be set through the API.
2. **`update-application` carries no SAML fields** — only `Name`, `Description`, `Status`,
   `PortalOptions`. `put-application-authentication-method`'s union has only `Iam`, no
   `Saml` (the skeleton is not truncating: `put-application-grant` shows all four of its
   union members).
3. **`create-application` refuses SAML providers outright:**
   ```
   ValidationException: The application provider with arn
   'arn:aws:sso::aws:applicationProvider/app-50e590700beb5208' is not supported
   for this action.
   ```
   It resolves `custom-saml` to an internal id before refusing. That API is for OAuth /
   trusted-identity-propagation providers only — `custom` is OAUTH, `custom-saml` is not
   creatable.

Terraform's `aws_ssoadmin_application` wraps the same API, so it does not help.

**Console-only:** creating the app, ACS URL, SAML audience, attribute mappings, and
downloading the IdP metadata XML.
**Still CLI:** `put-application-assignment-configuration --assignment-required`,
`create-application-assignment --principal-type GROUP`, and readback via
`describe-application` / `list-application-assignments`.

`scripts/idc-argocd-app.sh` does the CLI half and prints the console half with the real
values. Provider ARN for reference: `arn:aws:sso::aws:applicationProvider/custom-saml`.

⚠️ **The ACS URL, audience and attribute mappings cannot be read back through any API.**
The only verification for the three things most likely to be mistyped is a real login.

## 2026-08-24 — the AWS side is DONE for op-dev

Application `arn:aws:sso::660075424663:application/ssoins-7223eb10c0b8ac39/apl-72236face0cd1203`
— ENABLED, `AssignmentRequired: True`, `usx-cloud-admin` assigned, start URL
`https://argocd.op-dev.usxpress.io`.

**`create-application-assignment` DOES work on a SAML app** — it is the one write call that
does. Also refused, on top of the earlier list:
`put-application-assignment-configuration` and `list-application-authentication-methods`
(the console defaults assignment-required to true, so reading it is enough).

**The metadata XML needs no browser download.** The URL is public and derivable:
`base64("<account>_<instance-id>")`, where the instance id is the app ARN's `ssoins-` segment
with the `sso` prefix dropped:

```
TOK=$(printf '660075424663_ins-72236face0cd1203' | base64 -w0)
curl -sS https://portal.sso.us-east-1.amazonaws.com/saml/metadata/$TOK
```

Verified — returns the real EntityDescriptor. On WSL a console download lands in the
**Windows** profile (`/mnt/c/Users/*/Downloads`), not `~/Downloads`, so fetching beats hunting.

`scripts/dex-saml-from-metadata.sh <xml> op-dev` converts it to the Argo connector block.

**Still unverified:** the attribute mappings (`groups` -> `${user:groups}`). No API can read
them back, so the only check is a real login landing with permissions rather than an empty page.

## 2026-08-24 23:5x — STOPPED HERE. Everything verifiable is correct; login still fails.

**Cluster side is COMPLETE and proven.** dex-server Running, connector `aws` loaded with the
right issuer, `dex.config` present in `argocd-cm`, `argocd-server` restarted, and the
**LOG IN VIA AWS IAM IDENTITY CENTER** button renders at https://argocd.op-dev.usxpress.io.

**AWS side, every field verified:**

| | |
|---|---|
| app | `apl-72236face0cd1203`, Status ENABLED, Visibility ENABLED |
| ACS URL | `https://argocd.op-dev.usxpress.io/api/dex/callback` |
| SAML audience | identical to ACS |
| start URL | `https://argocd.op-dev.usxpress.io`, Origin APPLICATION (SP-initiated) |
| attribute mappings | Subject/email `${user:email}`, groups `${user:groups}` — saved |
| assignments | `usx-cloud-admin` GROUP **and** `doke@usxpress.com` USER |
| user | primary email set, SCIM group membership since 2026-02-09 |

**Symptom:** the access portal shows **no Applications section at all** (only AWS accounts),
and sign-in returns *"An error occurred while signing in to the application — No access."*

**Ruled out:** missing primary email; missing group membership; missing attribute mappings;
missing assignment (both kinds present); application disabled; portal visibility disabled.

⚠️ **Do NOT launch from the portal tile.** That is IdP-initiated and Dex only supports
SP-initiated — it returns `Bad Request: User session error` at `/api/dex/callback`. Always
start at the Argo URL.

**Next to try with fresh eyes:** propagation delay (leave it overnight and retry); a full
portal sign-out/sign-in; whether an org policy hides customer-managed applications; AWS
support. The remaining unknowns all have no API readback.

**Seventh API gap found:** `update-application` cannot set `PortalOptions.Visibility` —
only `SignInOptions`.

**Strong recommendation:** this is a lot of unverifiable console state for one cluster, and
QA and prod would each repeat it. Doke now HAS Azure/Entra access (stated 2026-08-24).
Entra app registrations are creatable by `az ad app create`, and Argo speaks OIDC natively so
**Dex is not needed at all** — no console, no SAML, real readback. See
[[onprem-ad-ldap-reachable]] for the third option. Note the Identity Center directory is
SCIM-synced (`CreatedBy: SCIM/...`), i.e. Entra is already the upstream source of truth, so
going direct removes a hop rather than adding a system.



## 2026-08-25 — the alternative was available the whole time

`az ad app update` succeeded against the `risingwave` app registration on 2026-08-13
(`wip/rw-qa-operator-split/rw-qa-dex-sso-2026-08-13.md`), which means Entra app-registration
**write** was already proven while this SAML route was being pursued. Tenant issuer format:
`https://login.microsoftonline.com/<tenantId>/v2.0`.

Argo CD speaks OIDC natively (`configs.cm.oidc.config`), so the Entra route **removes Dex**
rather than configuring it, and the callback changes from `/api/dex/callback` to
**`/auth/callback`**. Every value has a readback, which is the entire problem with the
Identity Center console route.

Two traps to settle before building, both checked by `scripts/entra-argocd-preflight.sh`:

1. **Entra emits group object IDs, not names**, unless the group is AD-synced and the app is
   configured to emit `sam_account_name`. If it is not synced, `policy.csv` must carry the GUID,
   not `usx-cloud-admin` — see [[identity-names-do-not-cross-systems]], which is the same failure
   in a different system.
2. **A human may not be able to store the client secret.** `op-qa-platform-admin` had no
   `secretsmanager:PutSecretValue` on the RisingWave path on 2026-08-13; ESO could read what a
   human could not write. OIDC needs a client secret where SAML needed none.
