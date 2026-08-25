# Argo CD on-prem SSO via Entra OIDC — op-dev, 2026-08-25

Replaces the AWS Identity Center SAML route of 2026-08-24, which stalled on console-only
state with no readback. Authentication is **done and proven**. Authorization is **not**:
Entra will not emit a `groups` claim for this application.

## What is now proven

**The Entra route was available all along.** `az ad app update` succeeded against the
`risingwave` registration on 2026-08-13, so app-registration write existed while the SAML
route was being pursued. Memory said "no Azure access"; that was wrong and is corrected in
place in `onprem-human-access-model`.

**USX already runs Argo CD on Entra OIDC natively.** The `Argo CD` registration
(`56078536-f4a3-4f92-810e-5106787019a8`) carries four `/auth/callback` URIs across the cloud
EKS fleet, two of them production. On-prem's Dex+SAML build was the outlier, not the norm.

**App registration `Argo CD On-Prem`, created 2026-08-25** — `42dc0c33-4c56-47a5-b207-d119272997aa`,
SP `b20084ae-9f13-4ca7-961c-b05f023fa2c2`, tenant `bbb5a66d-5c9f-482a-969a-a40304b6bc8d`.
Deliberately NOT the cloud fleet's app: that one serves two production clusters, has **zero
registered owners**, and `--web-redirect-uris` replaces the list wholesale.
All three clusters' callbacks are registered up front, so QA and prod need no Entra work.

**Argo CD v3.4.5 on op-dev. Dex is gone** — `argocd-dex-server` returns NotFound, not merely
`enabled: false`.

**The client secret reaches Argo by IaC with no new machinery.** `admin-externalsecret.yaml`
already targets `argocd-secret` with `creationPolicy: Merge`, so one extra `data` entry
delivers it and Argo resolves `$oidc.entra.clientSecret` natively. No new file, no
kustomization change, no label plumbing. Verified 40 bytes in the secret, and
`server.secretkey` from the adopted raw install survived the merge.

**op-dev's AWS account is reachable** — profile **`usx-dev`** is account 700736442855. Secrets
Manager region **us-east-2**, read from the cluster's own `ClusterSecretStore`, not assumed.
Path follows the convention already in use: `op-usxpress-dev/platform/argocd/azure-ad`,
mirroring `op-usxpress-dev/platform/grafana/azure-ad`, with keys `client_id`/`client_secret`.

**Login works.** Federated through on-prem ADFS (`usxfs.usxpress.com/adfs/ls`) → MFA → Argo.
Valid v2.0 token, correct `aud`/`iss`/`tid`, live session.

## The open failure, stated precisely

Entra issues a valid ID token for this app that contains **no `groups` claim**, so
`policy.csv` never matches and `policy.default: ""` applies. Token issued 14:50:09Z against
the current config, claims: `aud, email, exp, iat, iss, name, nbf, oid, preferred_username,
rh, sid, sub, tid, uti, ver`.

## Tested and killed

* **SPA client + PKCE, no client secret.** Rejected at the callback with `AADSTS9002327`:
  a code issued to a Single-Page Application client may only be redeemed cross-origin.
  `argocd-server` redeems server-side, so Argo requires a **confidential** client. The
  evidence was already in hand — the cloud fleet's app uses `web.redirectUris`.
* **`groups` in `requestedScopes`.** Entra's v2.0 endpoint validates scopes; a bare `groups`
  is not one. Caught before it shipped.
* **`groupMembershipClaims: ApplicationGroup`** — no claim emitted.
* **`groupMembershipClaims: SecurityGroup`** — no claim emitted either.
* **`requestedIDTokenClaims`** (Argo's OIDC `claims` request parameter, an Okta pattern) —
  removed on the hypothesis it conflicted. No change.

## Ruled out by readback, not by assumption

* User is in **42 security groups** including `b9a1ff74-efa1-4b20-be8a-8706a5ab2636`
  (`me/getMemberGroups` with `securityEnabledOnly: true`) — far below the ~200 overage
  threshold, and no `_claim_names` in the token.
* `groups` present in the app's `optionalClaims.idToken`.
* **No claims-mapping policy** on the service principal.
* `appRoleAssignmentRequired: true`, with both `usx-cloud-admin` (Group) and Dare Oke (User)
  assigned.
* 3 `web` redirect URIs, `spa` empty.

What remains is above cluster visibility: a tenant-level token issuance policy, a Conditional
Access session control, or something about the ADFS federation. That is a question for whoever
owns the directory.

## Traps

1. **`usx-cloud-admin` is cloud-only** (`onPremisesSyncEnabled: null`), so Entra can only ever
   emit its object ID — a display name is available only for AD-synced groups. `policy.csv`
   must carry the GUID. Third system in which an identity name failed to cross a boundary.
2. **A client secret's value is shown once.** If the store write fails after minting, the
   credential is an orphan. One was created and deleted here. Always `--append`, and delete
   the new credential if the write fails.
3. **`-o tsv` and `-o text` are `az` forms; the AWS CLI takes `--output text` only.** Both
   mistakes produced empty strings that guards reported as findings about the environment.
4. **Argo logs claims as escaped JSON** (`\"groups\":`), so grepping for `"groups":` finds
   nothing whether or not the claim is present — a check that can only ever report absence.
   Use `scripts/argocd-token-claims.sh`.
5. **A token predating a config change tests the old config.** Three runs were wasted on this.
   The running `argocd-server` pod's `startTime` is the boundary; the script now labels each
   token `PREDATES` or `CURRENT` against it.
6. **Zero Applications makes the Argo UI useless as an RBAC test** — an admin and an
   unauthorized user see the same empty screen.

## Merged today, all on `variant-inc/iaac-talos-flux-platform`

`#132` oidc.config in, dex.config out, dex disabled, policy.csv rekeyed to the object ID.
`#133` client secret via the existing ExternalSecret.
`#134` requestedIDTokenClaims removed.


## op-qa, later the same day

PRs #135 and #136. QA differs from dev structurally and the first attempt broke it:

* op-qa keeps ExternalSecrets in `infrastructure/argocd-config/`, dev keeps them in
  `infrastructure/argocd/`. The file was written into dev's location.
* op-qa serves `external-secrets.io/v1`; the file said `v1beta1`, from memory. Flux rejected
  it at dry-run, holding the `argocd` Kustomization not-ready — and `argocd-config` and
  `argocd-apps` depend on it, so **QA delivery froze on one string**. Fixed in #136 by taking
  the apiVersion from the branch's own working file.
* the chart owns `argocd-secret` on QA (no `admin-externalsecret.yaml` under
  `infrastructure/argocd/`), so the client secret goes in its **own** secret labelled
  `app.kubernetes.io/part-of: argocd`, referenced as `$argocd-entra-oidc:client_secret`.
  Merging into a chart-owned secret risks the next upgrade dropping the key.

Blocked first on `secretsmanager:CreateSecret` — `op-qa-platform-admin` granted only
`sts:GetCallerIdentity`. Fixed with `scripts/idc-grant-secretsmanager.sh op-qa --apply`.

Verified: 200 from the route, `/api/v1/settings` serving the Entra `oidcConfig`, and 40 bytes
in `argocd-entra-oidc`. `scripts/lint-manifest-apiversions.py` now gates the PR builder, and
was self-tested red on the real defect and green on the fix.
