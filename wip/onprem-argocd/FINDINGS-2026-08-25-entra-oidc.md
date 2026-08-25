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

## The route around the groups claim, opened 2026-08-25

`groups` is not the only claim Argo CD can key RBAC on. `configs.rbac.scopes` names the
claims Argo searches for a subject — it defaults to `[groups]`, and `[roles, groups]`
makes it match either. And `roles` is issued from **appRoleAssignments on the service
principal**, a different path from directory group membership, so whatever suppresses
group claims in this tenant has no reason to touch it.

That path is entirely inside the registration we created and own. It needs nothing from
whoever owns the directory, which matters because the group claim is now a dependency on
another team with no committed date.

`scripts/entra-argocd-app-roles.sh` — `--inspect`, `--define`, `--assign` — defines
`platform-admin` and `app-viewer` app roles with **deterministic IDs** (`uuid5` over the
app ID and the role value), so re-running `--define` is a no-op rather than a duplicate.
It refuses if a role of the same value already exists under a different ID, which would
silently split assignments across two roles, one of which nobody holds.

`scripts/pr-argocd-rbac-app-viewer.sh --role-value app-viewer` takes the other side:
the subject becomes the role value and `scopes` is rewritten to `[roles, groups]` in the
same edit. Leaving `scopes` at `[groups]` while the subject is a role value writes a
policy that can never match — precisely the failure being routed around.

**Not yet proven.** No token has been observed carrying `roles`. Nothing in the script
asserts otherwise: the only evidence that counts is a fresh sign-in read through
`scripts/argocd-token-claims.sh`, and a token minted before the change tests the old
config. Assigning a **group** (rather than a user) to an app role requires Entra ID P1;
if the tenant is not licensed, per-user assignment works on any tier and is enough to
prove the claim arrives before deciding whether to buy anything.

### One thing we should have read before any of this

`--inspect` now prints `optionalClaims` in full, first, before appRoles. The `groups`
optional claim takes `additionalProperties`, and one of those values — `emit_as_roles` —
**moves group values out of the `groups` claim and into `roles` by design**. If that is
set, there was never a missing claim; we were reading the wrong field, and every
`groupMembershipClaims` permutation tried today was aimed at the wrong thing. We
confirmed `groups` was *in* `optionalClaims.idToken`. We never printed what was next to it.

### The check that would have caught it

`scripts/argocd-token-claims.sh` prints the claim names present. It reported `GROUPS:
ABSENT` truthfully, and that was taken as "the claim is missing" rather than "look at
what else is there". A claim-name list read as a whole would have shown `roles`, or its
absence, in the same output. This is the [[adjacent-step-green-signals]] family from the
other side: a true report about the thing next to the one that matters.

## The application-team view

`scripts/pr-argocd-rbac-app-viewer.sh` adds `role:app-viewer` to `policy.csv` on all
three branches, scoped to the AppProject **derived from the branch** rather than to
`*/*`, and with `sync` granted on dev and QA but **withheld on prod** — promotion there
is human-initiated by the platform, by design.

Self-tested, both directions:

| Case | Result |
|---|---|
| prod granted `sync` | assertion fires |
| subject is a display name, not a GUID | refused before touching the repo |
| `scopes` missing or wrong for the chosen subject | assertion fires |
| branch has no `configs.rbac` yet (op-prod) | refuses, names the PR that must land first |
| run twice | second run reports "already present", exits 3 |

The prod-sync assertion is worth calling out. The first version tested for a substring in
the branch that never produces it — a check that could only ever pass. It was rewritten to
count the actual grant lines, and only then did it go red against a real violation. That is
the third check in this repo written so it could not fail; see [[merged-defect-authorizes-itself]].

**Proven:** the app-role path is configurable end to end from our own registration, and
the RBAC PR builder is self-tested red on five failure modes.
**Tested and killed:** nothing new — the groups permutations were exhausted earlier today.
**Traps:** `--app-roles` replaces the appRoles list wholesale, the same shape as
`--web-redirect-uris`; `optionalClaims` must be read in full, not queried for the one key
you expect; and a token predating the change tests the old configuration.

### `emit_as_roles` — ruled out by readback, 2026-08-25

`optionalClaims` on `Argo CD On-Prem`, read in full:

```json
{"accessToken": [], "saml2Token": [],
 "idToken": [{"name": "groups", "additionalProperties": [], "essential": false, "source": null}]}
```

`additionalProperties` is **empty**. Group values are not being redirected into `roles`;
the claim is requested in the ordinary way and Entra simply does not emit it. The
hypothesis is dead, and app roles stop being a shortcut and become the actual route.

Also read at the same time, and worth recording:

* `appRoles` on the registration is **empty** — nothing has ever been defined.
* Three principals hold **default access** (`appRoleId 00000000-0000-0000-0000-000000000000`,
  which satisfies `appRoleAssignmentRequired` and emits nothing): the group
  `usx-cloud-admin`, Dare Oke, and **Idris Fagbemi**. Idris is already assigned to the
  application, so the app-team view needs him mapped to `app-viewer`, not only the RW group.
* App **object** ID `3aafdb0b-9046-410d-8571-2089b1fa3d7c` (distinct from the app ID
  `42dc0c33-4c56-47a5-b207-d119272997aa`; Graph writes target the object ID).

**Trap:** `scripts/argocd-token-claims.sh` takes a cluster argument. It was handed over
without one and exited on usage. Corrected in the runbook and in the app-roles script's
closing instructions.

## PROVEN: the roles claim arrives. 2026-08-25, 19:18Z

```
-- token issued 19:18:27Z  sub doke@usxpress.com   <-- issued against the CURRENT config
   claims present: aud, email, exp, iat, iss, name, nbf, oid, preferred_username,
                   rh, roles, sid, sub, tid, uti, ver
   GROUPS: ABSENT
   ROLES:  1 -> platform-admin
```

**The authorization blocker is broken.** Entra will not emit `groups` for this
application under any configuration tried, but it emits `roles` from an
appRoleAssignment on the same service principal, in the same token, at the same time.

**The control was free, and it is decisive.** Idris Fagbemi signed in at 19:12:01Z, six
minutes earlier, against the identical configuration:

```
-- token issued 19:12:01Z  sub ifagbemi@usxpress.com   <-- issued against the CURRENT config
   claims present: aud, email, exp, ... (no roles)
   ROLES:  ABSENT
```

He holds only **default access** (`appRoleId 00000000-…`). Same app, same tenant, same
federation, minutes apart — the one with an assignment gets the claim, the one without
does not. Nothing about this is coincidental timing or a cached token.

**Group-to-app-role assignment worked on the first attempt.** `usx-cloud-admin`
(`b9a1ff74-…`) holds `platform-admin` directly. The Entra ID P1 caveat written into the
script was speculative and never fired — teams can be granted as groups, with no
per-user administration.

### Corrections to guesses made earlier today

* **`emit_as_roles` was never set** — `additionalProperties: []`. Ruled out by reading
  `optionalClaims` in full, which is what should have happened before any of the
  `groupMembershipClaims` permutations.
* **The Entra ID P1 limit did not apply.** Stated as a likely obstacle, it was not one.

### The check that was still lying

`argocd-token-claims.sh` printed claim **names**. `roles` appearing in that list proves
the claim was emitted and says nothing about what is inside it — and `policy.csv` matches
on the contents. It now prints values, and distinguishes `ABSENT` from
`present but EMPTY`. Same family as the escaped-JSON grep and the substring assertion:
a true statement about the thing adjacent to the one that matters.

### The invariant that replaced a warning

`policy.csv` briefly held two subjects of different kinds — the admin line on a group
object ID, the viewer line on an app-role value. Under a roles claim the first matches
nothing, and **which of the two is dead is invisible from the file**. The builder now
rekeys the admin subject in the same edit and asserts that **every `g,` subject is the
same kind**, refusing a mixed policy outright. An opt-out flag was written and then
deleted: it could only ever produce a config the invariant rejects.

**Proven:** `roles` reaches Argo CD on op-dev, carrying `platform-admin`, with a
negative control in the same log window. Group assignment needs no extra licence.
**Tested and killed:** `emit_as_roles`; the P1 limit; every `groups` permutation.
**Traps:** a claim NAME is not its value; mixed subject kinds in one `policy.csv`;
`argocd-token-claims.sh` takes a cluster argument.

## Confirmed by sign-in — op-dev, 2026-08-25

Doke confirms the Argo CD UI now grants permissions after an Entra sign-in. PR **#138**
(op-dev) and **#139** (op-qa) rekey `policy.csv` to app-role subjects and set
`scopes: "[roles, groups]"`.

**Scope of that confirmation, stated narrowly on purpose.** It covers one person, holding
`platform-admin`, on one cluster. It does **not** yet cover:

* **op-qa** — #139 is the identical change and is pushed, but a PR is not a deployment.
  QA has never had a browser sign-in at all; it was verified by `curl` against
  `/api/v1/settings`.
* **`role:app-viewer`** — nobody has exercised it. Idris holds the assignment
  (`86486897-edd4-537d-b04f-805d6aeff583`) and his sign-in is the real acceptance test:
  he should see `risingwave-etl` and nothing outside the `apps` project.
* **op-prod** — not started; see the chain below.

The reason for the caution is on this page already: on 2026-08-20 "proven end to end"
described one execution, and the path was dead an hour later for 18 hours.

### op-qa and op-prod need no Entra work

App roles and their assignments live on the **app registration**, not per cluster, and all
three callbacks were registered on 2026-08-25. `platform-admin` and `app-viewer`, and every
assignment made today, already apply to QA and prod. What each still needs is a branch PR.

**op-qa:** merge #139, then `scripts/verify-argocd-rbac.sh op-qa`, then a browser sign-in.

**op-prod is a chain of four, in order** — each blocked by the one before, and the builder
for each refuses rather than guessing:

1. `scripts/pr-cert-issuer-op-prod.sh --push` — the ACME solver still names op-qa's zone,
   so an Order for `*.op-prod.usxpress.io` matches no solver and gets **zero** Challenges.
   Written, fixed, still unpushed.
2. `wildcard-op-prod` issues. A Challenge existing at all is the milestone; it has never
   happened on this cluster.
3. `scripts/pr-argocd-entra-prod.sh` — refuses while `istio-ingress/shared-http` does not
   serve op-prod hostnames, which is correct: the OIDC callback needs somewhere to land.
   This PR is what creates `configs.rbac` on the prod branch.
4. `scripts/pr-argocd-rbac-app-viewer.sh --role-value app-viewer --only op-prod` — refuses
   today with *"op-prod has no configs.rbac yet"*, which is step 3's output, not a bug.

On prod `role:app-viewer` is written **without** `sync`: promotion there stays
human-initiated by the platform, by design.

**Procedure changed** — `.claude/skills/entra-authz-claims/SKILL.md`. The next time a login
succeeds and grants nothing, on any app in this tenant, the answer should take minutes.
Grafana on-prem uses the same tenant and the same secret convention
(`op-usxpress-*/platform/grafana/azure-ad`), so it is the likely next consumer.
