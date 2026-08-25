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

## op-prod — stopped, and why

The client secret **is** in place: `op-usxpress-prod/platform/argocd/azure-ad`, account
937464026810, **us-east-2**. No permission-set grant was needed — unlike QA, both
`ops-controller` and `usx-prod` could already write. The region was **derived from evidence**
rather than assumed (the cluster is unreachable): four existing `op-usxpress-prod/` secrets
live in us-east-2, including `platform/grafana/azure-ad`.

The branch PR is **blocked**, on two things that compound:

**1. op-prod has no Argo route.** No VirtualService for argocd, so
`argocd.op-prod.usxpress.io` does not resolve and the OIDC callback has nowhere to land.
op-dev needed one added (PR #126) before its record appeared.

**2. There is nothing safe to copy the route's wiring from.** DNS targets are not portable
— op-dev uses all 7 workers, op-qa 3 of 13 — so the builder derives them from a route already
serving the same cluster. On op-prod there is no such route:

```
infrastructure/grafana/virtualservice.yaml                  grafana.op-dev.usxpress.io
infrastructure/risingwave-routes/virtualservice-dashboard.yaml  risingwave-dashboard.op-dev.usxpress.io
infrastructure/risingwave-routes/virtualservice-overview.yaml   risingwave-overview.op-dev.usxpress.io
infrastructure/risingwave-routes/virtualservice-postgres.yaml   rw-postgres.op-dev.usxpress.io
infrastructure/risingwave-routes/virtualservice-sql.yaml        rw-sql.op-dev.usxpress.io
```

**5 of 5**, every one annotated
`external-dns.alpha.kubernetes.io/target: 10.10.82.21,.22,.26,.27,.28,.178,.180` — **dev's
seven workers**. The entire ingress layer on the prod branch is dev's.

### The part that is not about SSO

If prod's `grafana` or `risingwave-routes` Kustomizations reconcile, **prod's external-dns is
publishing op-dev hostnames pointing at op-dev nodes**. Two external-dns instances would then
compete for the same records, arbitrated only by `txtOwnerId` — itself a per-cluster literal
in the AUTO class of `wip/prod-standup/fix-op-prod-literals.sh`. This is the QA↔dev grafana
collision of 2026-08-24 (PR #128), on production, and **it cannot be confirmed without cluster
access**. Worth checking the moment INFRA-1663 lands.

### What unblocks it

INFRA-1663 — op-prod has had no persisted kubeconfig since at least 2026-08-24. Without it the
real node addresses, the ingressgateway placement and the ClusterSecretStore can only be
inferred from Git, and Git is demonstrably wrong about this cluster.

**Proven:** the secret is stored and the region is evidenced.
**Tested and killed:** deriving prod's route from its own branch — every candidate is dev's.
**Trap:** a prod branch that looks complete because it is a byte-copy of another cluster's.

## op-prod ingress — the finding under the finding

Once prod cluster access was restored (`scripts/onprem-prod-kubeconfig.sh`), the audit showed:

```
istio-ingress/shared-http
    port 80/HTTP   hosts=*.op-qa.usxpress.io
    port 443/HTTPS hosts=*.op-qa.usxpress.io  cred=wildcard-op-qa-tls
VirtualServices: none
TLS secrets in istio-ingress: none
certificate.cert-manager.io/wildcard-op-qa   Ready=False   27d
```

**Production's shared Gateway serves QA's hostnames, and its wildcard Certificate — also
named for QA — has been failing to issue for 27 days,** since the cluster came up. Prod has
never been able to terminate HTTPS for any of its own hostnames. It went unnoticed because
prod serves no routes at all, so nothing ever asked it to.

`shared-gateway.yaml` and `wildcard-cert.yaml` on the op-prod branch are byte copies of
op-qa's. Instance eight of [[manifests-copied-across-branches]], and the most consequential:
the previous seven were latent, this one has been actively failing for a month.

**Correction to an earlier claim in this note.** I wrote that prod's external-dns might be
publishing op-dev records and contending with dev's. It is not — prod has **zero** live
VirtualServices, so it publishes nothing. The copied routes are inert. The real damage is the
Gateway and the Certificate, which are live and broken.

**Ingressgateway placement is per-cluster, again:** op-prod runs it on **all 10 workers**
(5 application, 3 platform, 2 system), where op-dev uses 7 and op-qa 3 of 13. Route targets
must be read from the cluster, never carried over.
